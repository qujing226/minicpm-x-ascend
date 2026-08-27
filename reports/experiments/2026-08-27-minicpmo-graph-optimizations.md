# MiniCPM-o 4.5 Ascend 双阶段图优化实验报告

## 1. 摘要

本文记录 2026-08-26 至 2026-08-27 在 Ascend 910C 单卡环境中完成的两项
MiniCPM-o 4.5 推理优化：

1. 对 Stage 2 Code2Wav 的 CFM DiT estimator 引入精确签名 NPUGraph；
2. 将 Stage 1 Talker 的图模式从 `PIECEWISE` 调整为
   `FULL_DECODE_ONLY`。

两项优化分别针对不同的调度碎片：

```text
Code2Wav：大量短算子由 CPU 逐个下发
→ 对固定 tensor 签名捕获并回放 CFM estimator

Talker：一次 codec decode 被拆成约 21 个图片段
→ 将一次完整 decode 合并为一次图调用
```

在相同的中文 Seed-TTS、32 请求、单并发工作负载下，最终组合结果相对本地
eager 基线为：

| 指标 | 本地 eager 基线 | 两项优化后 | 相对改善 |
|---|---:|---:|---:|
| Mean E2EL | 1835.63 ms | 1587.15 ms | 13.54% |
| Mean TTFT | 294.81 ms | 290.02 ms | 1.62% |
| Mean Audio TTFP | 980.10 ms | 861.59 ms | 12.09% |
| Mean Audio RTF | 0.4400 | 0.3788 | 13.91% |

Profiler 同时证明两项改动降低了调度或空闲时间，而不是通过减少模型计算、
缩短输出或改变 Benchmark 口径获得性能收益：

- Stage 2 NPU Computing 基本不变，host kernel launch 数下降 86.13%；
- Stage 1 NPU Computing 基本不变，每个 codec decode 的图调用从约 21 次降至
  1 次。

当前结论属于完成了性能因果验证的本地优化结果。优化后完整 2020 条 Seed-TTS
精度回归、Demo、全双工、多轮和稳定性回归尚未完成，因此本文不将其表述为已
满足最终提交门槛。

## 2. 实验范围与环境

### 2.1 固定环境

| 项目 | 值 |
|---|---|
| Model | MiniCPM-o 4.5 |
| Runtime | vLLM-Omni |
| Hardware | Ascend 910C，单卡 |
| Official image | `vllm-omni:v0.25.0-a3` |
| Pipeline | Thinker → Talker → Code2Wav |
| 上游工作分支 | `minicpm-challenge` |
| 优化开发分支 | `perf/minicpmo-stage-profiling` |
| 优化前源码基点 | `a964efc55b6c36ed6a9214a8cf4bb131f368183d` |
| Code2Wav 优化提交 | `04f7e2ea66fe71188f8322fe1f5015e9c8250368` |
| Talker 优化提交 | `9842bb4c7f3d9c9ca12cba69745496603956a68b` |

### 2.2 工作负载

性能对比采用以下受控工作负载：

```text
Dataset: Seed-TTS Chinese
Dataset path: /workspace/data_set/seed-tts-eval
Prompts: 32
Selection: disable shuffle, no oversample
Concurrency: 1
Backend: openai-chat-omni
Endpoint: /v1/chat/completions
Modalities: text + audio
enable_thinking: false
use_tts_template: true
```

服务进入 warm 状态后再执行保存结果的测量请求。Profiler 请求单独执行，且不将
带 profiler 开销的 TTFT、TTFP 或 RTF 用于性能 A/B。

### 2.3 指标与计算方法

本文使用以下指标：

- TTFT：请求开始到第一个有效文本 token；
- Audio TTFP：请求开始到第一个可播放音频包；
- Audio RTF：生成音频所需时间与生成音频时长的比值；
- E2EL：端到端请求时延。

对 lower-is-better 指标，本文的相对改善计算为：

```text
relative improvement = (before - after) / before × 100%
```

Profiler 的 `Free` 是 step window 中未归入 NPU Computing/Communication 的剩余
时间，可能包含 host 调度、queue、同步和等待，不能全部解释成可直接消除的 NPU
空闲。CFM 与 decode batch 的 wall time 来自 profiler 标记区间，同样不是纯 kernel
执行时间。

## 3. 基线与证据边界

### 3.1 官方性能参考

| 指标 | 官方参考 |
|---|---:|
| TTFT | 333.27 ms |
| TTFP | 986.47 ms |
| Chunk RTF | 0.4423 |

官方参考用于判断结果量级，不作为两项改动的受控 A/B 基线，因为其运行时间、
机器负载和代码版本不与本次实验完全一致。

### 3.2 本地 eager 基线

同一中文 32 请求工作负载的本地 eager 汇总如下：

| 指标 | Mean | Median | P99 |
|---|---:|---:|---:|
| E2EL | 1835.63 ms | 1801.14 ms | 2578.17 ms |
| TTFT | 294.81 ms | 265.91 ms | 486.34 ms |
| Audio TTFP | 980.10 ms | 950.15 ms | 1188.79 ms |
| Audio RTF | 0.4400 | 0.4400 | 0.5000 |

该轮 32/32 请求成功，生成音频总时长为 135.64 秒。此基线保留了终端汇总，
但当时未保存原始 JSON，因此本文对其只保留到终端显示精度。后续候选结果均以
原始 JSON 中的高精度数值为准。

## 4. 优化一：Code2Wav CFM 精确签名 NPUGraph

### 4.1 观察

Stage 2 trace 显示 Code2Wav 在生成一个 4.68 秒音频样本时存在：

- 1 次 setup CFM；
- 5 次 streaming decode CFM；
- 5 次 HiFT/STFT，对应 5 个 waveform chunk；
- 74,233 次 `aclrtLaunchKernelWithHostArgs`；
- NPU Computing 约 885 ms，但 Stage span 达到约 2235 ms。

这说明 Code2Wav 不只是 NPU 算子计算，还存在大量 host 侧小算子下发和算子间
空隙。

### 4.2 从 trace 还原执行结构

Profiler 中包含 960 次 `FlashAttentionScore`。源码中的 DiT depth 为 16，CFM
采样使用 10 个 timestep，因此：

```text
960 / 16 layers / 10 timesteps = 6 CFM invocations
```

这 6 次调用与源码执行路径完全对应：

```text
setup_batch:  1 CFM
decode_batch: 5 CFM
total:        6 CFM
```

同时出现 5 次 STFT，与 5 个 decode waveform chunk 对应。这组关系把 profiler
事件、模型结构和源码循环对齐，排除了仅根据算子名称猜测热点的可能。

### 4.3 根因假设

CFM 的 estimator 在每个 timestep 都重复运行相同的 DiT 结构。对于相同 tensor
形状、dtype、device 和 cache 状态，这条计算路径具有可重复图结构；eager 模式
却需要 CPU 持续逐算子下发，形成高频 launch 开销。

根因假设为：

```text
CFM estimator 的数学计算不是主要新增成本；
大量重复的 host kernel dispatch 扩大了 Code2Wav 的关键路径。
```

### 4.4 修改方法

实现没有对整个 Code2Wav stage 强制套用静态图，而是只捕获 tensor-only 的 CFM
estimator 内层：

1. 使用 operation、常量以及 tensor 的 shape、dtype、device 构建精确签名；
2. 新签名第一次先 eager 执行，完成 lazy kernel 和 allocator 初始化；
3. 为该签名捕获 NPUGraph；
4. 后续相同签名把请求输入复制到 static input buffer 后 replay；
5. replay 输出会被下一次执行覆盖，因此 clone 后再交给请求级 streaming cache；
6. 捕获失败后 fail fast，要求重启 stage，避免在可能失效的 allocator/RNG capture
   状态上继续执行。

图 key 可概括为：

```text
operation
+ constants
+ [(shape, dtype, device), ...]
```

host-backed timestep embedding 保留在图外；CFM estimator 的 tensor-only 主体进入
图内。Stage 2 外层仍为 eager，以保留 streaming 状态和动态 shape 的灵活性。

部署配置为：

```yaml
- stage_id: 2
  additional_config:
    code2wav_enable_npu_graph: true
    code2wav_max_npu_graphs: 6
```

`max_graphs=6` 是容量扫描后对当前固定工作负载选择的缓存上限，最多保留 6 个精确
签名。容量过小会使后续签名退回 eager，降低 replay 覆盖率；容量过大则允许更多
冷签名进入捕获，增加图内存和测量期首次捕获扰动。Trace 中的 6 次 CFM 调用用于
还原执行结构，并不自动等价于 6 种不同签名。该容量是当前工作负载的经验选择，
不等价于所有输入下的全局最优值。

### 4.5 Trace A/B

对比 trace：

- Before：`minicpmo-58a8615a-stage2/.../2544680f4271_1707382_20260826161903189_ascend_pt`
- After：`minicpmo-npugraph-stage2/.../2544680f4271_1812046_20260826183633391_ascend_pt`

| Trace 指标 | Eager | NPUGraph | 变化 |
|---|---:|---:|---:|
| Stage span | 2234.99 ms | 1869.46 ms | -16.36% |
| NPU Computing | 885.18 ms | 885.01 ms | -0.02% |
| NPU Free | 1349.81 ms | 984.44 ms | -27.07% |
| Host kernel launches | 74,233 | 10,295 | -86.13% |
| Setup CFM wall time | 227.88 ms | 150.50 ms | -33.95% |
| 5 次 decode CFM wall time | 1137.59 ms | 595.79 ms | -47.63% |
| 5 次 decode batch wall time | 1328.52 ms | 844.71 ms | -36.42% |

图模式中观察到 60 次 `aclmdlRIExecuteAsync`：

```text
6 CFM invocations × 10 timesteps = 60 graph replays
```

NPU Computing 基本不变，而 NPU Free、host launch 数和 CFM wall time明显下降，
支持“减少 CPU 下发碎片”这一根因假设。它没有减少 DiT 层数、CFM timestep 或
输出 chunk 数。

### 4.6 性能结果

Graph-only 代表性 warm 结果：

| 指标 | Mean | Median | P99 |
|---|---:|---:|---:|
| E2EL | 1696.49 ms | 1613.47 ms | 2356.42 ms |
| TTFT | 287.39 ms | 258.70 ms | 468.08 ms |
| Audio TTFP | 911.86 ms | 887.97 ms | 1095.04 ms |
| Audio RTF | 0.4034 | 0.3962 | 0.4643 |

相对本地 eager 终端基线：

| 指标 | Eager | Stage 2 NPUGraph | 相对改善 |
|---|---:|---:|---:|
| E2EL | 1835.63 ms | 1696.49 ms | 7.58% |
| TTFT | 294.81 ms | 287.39 ms | 2.52% |
| Audio TTFP | 980.10 ms | 911.86 ms | 6.96% |
| Audio RTF | 0.4400 | 0.4034 | 8.32% |

共享环境存在明显抖动。同一候选的另一次 cold 结果为 RTF 0.4341、TTFP
946.35 ms、E2EL 1830.56 ms。本文保留该退化样本，不用单次最优值掩盖环境
方差；代表性 warm 结果只用于描述已进入稳定图回放后的性能。

### 4.7 正确性保护

实现增加了 6 个 CPU 测试用例，覆盖：

- replay 输出必须 clone，避免请求持有被下一次 replay 覆盖的 static output；
- 相同精确签名先 capture 再 replay；
- capture 失败后停止继续使用图运行器；
- graph 模式要求可捕获的 math SDPA 路径；
- 有 cache 和无 cache 两种 legacy backend 分发路径。

测试结果为 6 passed。当前环境的 Python/torch 退出阶段存在已知 teardown 异常，
因此测试通过证据来自 `pytest.main` 完成后显式退出的隔离方式；这不等价于解决了
环境 teardown 问题。

## 5. 优化二：Talker FULL_DECODE_ONLY

### 5.1 观察

完成 Stage 2 优化后，Stage 1 Talker 成为下一条可观测的关键路径。PIECEWISE
trace 中观察到：

- 116 次 `_compute_slot_mapping_kernel` anchor；
- 115 次 codec token sampling；
- 2320 次 `FusedInferAttentionScore`；
- 2415 次 `aclmdlRIExecuteAsync`。

模型结构可由数据交叉验证：

```text
2320 attention calls / 116 anchors = 20 Transformer layers
```

sampling 次数与实际 codec decode step 数对应，因此：

```text
2415 graph executions / 115 decode steps = 21 graph executions per step
```

PIECEWISE 虽然已经捕获部分模型区域，但一次 codec token decode 仍被拆成约 21
个图片段。短图片段反复回到 host，再由 host 发起下一次执行，形成调度空隙。

### 5.2 根因假设

Talker 是自回归 codec token 生成器。每一步重复执行近似相同的 Transformer
decode，并更新 KV cache。其重复性适合完整 decode graph。

根因假设为：

```text
Talker PIECEWISE 图覆盖过碎；
每个 codec token 内约 21 次图启动拉长了稳定 decode 间隔。
```

### 5.3 修改方法

只修改 Stage 1 的图模式：

```yaml
- stage_id: 1
  compilation_config:
    cudagraph_mode: FULL_DECODE_ONLY
```

这里的 `cudagraph_mode` 是 vLLM 跨平台配置名称；在本实验的 Ascend 后端中，它
控制对应的 NPU 图执行策略，并不表示实际使用 CUDA。

选择 `FULL_DECODE_ONLY` 而不是捕获整个请求，原因是：

- prefill 和首次 setup 的 shape、控制流与资源需求更动态；
- decode 会重复一百余次，收益可在每个 codec token 上累积；
- 只扩大 decode 覆盖范围的风险小于强制图化整个请求。

这是单变量配置实验：Stage 0 保持 `PIECEWISE`，Stage 2 保持优化一中的精确签名
NPUGraph 和 `max_graphs=6`。

### 5.4 Trace A/B

对比 trace：

- Before：`minicpmo-npugraph-stage1/.../2544680f4271_1986541_20260826222746117_ascend_pt`
- After：`minicpmo-stage1-full-decode/.../2544680f4271_2052740_20260827000857185_ascend_pt`

| Trace 指标 | PIECEWISE | FULL_DECODE_ONLY | 变化 |
|---|---:|---:|---:|
| Stage span | 1477.57 ms | 1146.53 ms | -22.40% |
| NPU Computing | 301.28 ms | 301.74 ms | +0.15% |
| NPU Free | 1176.29 ms | 844.79 ms | -28.18% |
| Graph executions | 2415 | 115 | -95.24% |
| 稳定 decode 间隔 mean | 12.560 ms | 9.670 ms | -23.01% |
| 稳定 decode 间隔 median | 12.391 ms | 9.385 ms | -24.26% |
| 稳定 decode 间隔 P95 | 13.740 ms | 11.036 ms | -19.68% |

稳定 decode 间隔排除了第一个 interval，因为它包含首次 setup/capture 等一次性
行为。优化后的图执行数满足：

```text
115 graph executions / 115 codec decode steps = 1 graph execution per step
```

NPU Computing 再次基本不变，而 NPU Free 和 decode 间隔下降。这证明改动合并了
host dispatch 边界，没有减少 Transformer 层数、codec token 数或模型计算量。

### 5.5 性能 A/B

Before 使用 Stage 2 graph-only 的代表性 warm JSON，After 在相同数据、顺序、
单并发和 Stage 2 配置下仅切换 Stage 1 图模式：

| 指标 | Stage 1 PIECEWISE | FULL_DECODE_ONLY | 相对变化 |
|---|---:|---:|---:|
| Mean E2EL | 1696.49 ms | 1587.15 ms | -6.45% |
| Mean TTFT | 287.39 ms | 290.02 ms | +0.92% |
| Mean Audio TTFP | 911.86 ms | 861.59 ms | -5.51% |
| Mean Audio RTF | 0.4034 | 0.3788 | -6.10% |
| P99 E2EL | 2356.42 ms | 2374.73 ms | +0.78% |
| P99 Audio TTFP | 1095.04 ms | 1039.66 ms | -5.06% |
| P99 Audio RTF | 0.4643 | 0.4516 | -2.74% |

TTFT 主要位于 Stage 0 Thinker critical path，因此 Stage 1 改动不应显著改善
TTFT；观测到的 +0.92% 属于当前环境噪声量级。TTFP、RTF 和 E2EL 按假设改善，
与 Talker 所在的音频生成关键路径一致。

P99 E2EL 没有随均值改善，说明单次 32 请求仍不足以刻画共享环境的 tail latency，
也不能只依据 mean 宣称所有尾部行为均已改善。

## 6. 两项优化的累计效果

最终候选结果来自：

```text
/workspace/benchmarks/minicpmo-stage1-full-decode/full-decode-32-run1.json
```

该轮完成 32/32 请求，输入 token 总数 4755，输出文本 token 总数 435，生成音频
总时长 135.64 秒。

| 指标 | 本地 eager | Stage 2 Graph | Stage 1 Full Decode + Stage 2 Graph |
|---|---:|---:|---:|
| Mean E2EL | 1835.63 ms | 1696.49 ms | 1587.15 ms |
| Mean TTFT | 294.81 ms | 287.39 ms | 290.02 ms |
| Mean Audio TTFP | 980.10 ms | 911.86 ms | 861.59 ms |
| Mean Audio RTF | 0.4400 | 0.4034 | 0.3788 |

相对本地 eager 的累计改善为：

```text
E2EL: 13.54%
TTFP: 12.09%
RTF:  13.91%
TTFT:  1.62%
```

最终候选相对官方参考的数值差异为 TTFT -12.98%、TTFP -12.66%、RTF
-14.36%。这组数据只能说明最终数值低于官方参考，不能全部归因于本次优化；
官方参考与本地实验不是同一次受控 A/B。

## 7. 精度与功能验证

### 7.1 已有证据

优化前中文 Seed-TTS 全量 2020 条结果：

| 指标 | 结果 |
|---|---:|
| WER | 0.0138 |
| SIM mean | 0.8489 |
| SIM median | 0.8535 |
| Request failed | 0 |

其中 WER 为 scorer 输出的比例值，`0.0138` 对应约 1.38%。

Stage 2 NPUGraph 的固定前 32 条 smoke：

| 指标 | 结果 |
|---|---:|
| Evaluated | 32 |
| Request failed | 0 |
| No PCM captured | 0 |
| ASR failed | 0 |
| WER mean | 0.05536 |
| WER median | 0.00000 |
| SIM mean | 0.83996 |
| SIM median | 0.85106 |

32 条中 17 条 WER 为 0，9 条 WER 大于或等于 0.1。逐条 ASR 显示高 WER 样本
主要是语义连贯的句尾缺失，而非随机噪声或 PCM 损坏。这与此前记录的 Talker
音频 token 预算/尾部截断问题一致，但 smoke 结果本身不能证明图优化对完整精度
无影响。

原始结果：

```text
/workspace/benchmarks/minicpmo-npugraph/max6/max6-accuracy-smoke32.json
```

### 7.2 尚未完成的 gate

以下回归仍需在最终提交前完成：

- 优化组合后的中文 Seed-TTS 2020 条全量 WER/SIM；
- VideoMME；
- Daily-Omni；
- 官方 Demo；
- streaming continuity 的长时间验证；
- full-duplex、multi-turn、cancel 和 barge-in；
- 多轮重复性能测试与稳定性测试。

因此当前准确表述是：32 条请求功能和 PCM 完整性通过，性能因果链成立；完整精度
和功能准入尚未闭环。

## 8. 局限性与剩余瓶颈

### 8.1 实验局限性

1. 共享机器存在明显抖动，尚未完成每个候选至少三次的 matched A/B；
2. 本地 eager 基线没有保存原始 JSON，只保留了终端汇总；
3. 精确签名图的容量 6 针对当前固定工作负载选择，其他音频长度可能产生新签名；
4. FULL_DECODE_ONLY 尚未覆盖高并发和全双工动态输入；
5. 完整准确率和 Demo gate 尚未执行。

### 8.2 图优化后的剩余信号

FULL_DECODE_ONLY trace 中仍观察到：

```text
aten::item / aten::_local_scalar_dense: 923 次
aten::_local_scalar_dense total:        58.51 ms
Event::synchronize total:               19.34 ms
aten::multinomial:                      115 次
aten::bincount:                         114 次
```

这些事件说明采样、设备到 host 的标量读取以及同步可能成为图覆盖扩大后的下一层
开销。但 aggregate time 不等于 critical-path 可优化时间；下一步需要把这些事件
与每个 codec decode 边界对齐，确认依赖关系后再提出修改，不能仅凭 `.item()`
看起来昂贵就直接删除同步。

## 9. 结论

本轮优化完成了两条可复核的性能因果链。

Code2Wav：

```text
大量 host kernel launch
→ 精确签名捕获 CFM estimator
→ launch 数下降 86.13%
→ NPU Computing 不变、NPU Free 下降 27.07%
→ graph-only RTF 降至 0.4034
```

Talker：

```text
每个 codec decode 约 21 次图执行
→ FULL_DECODE_ONLY
→ 每步 1 次图执行
→ 稳定 decode 间隔下降 23.01%
→ 组合 RTF 降至 0.3788
```

两项优化都没有改变模型层数、CFM timestep、输出 token 数、音频时长或 Benchmark
统计口径。最终组合在当前本地工作负载上实现约 13.91% RTF、12.09% TTFP 和
13.54% E2EL 改善，并通过 profiler 证明收益来自调度碎片和空闲时间下降。

## 10. 代码与原始证据索引

### 10.1 代码提交

```text
04f7e2ea [Perf][MiniCPM-o] Add Ascend NPUGraph for Code2Wav CFM
9842bb4c [Perf][MiniCPM-o] Use full decode graph for Talker
```

### 10.2 Benchmark JSON

```text
/workspace/benchmarks/minicpmo-npugraph/max6/max6-clean-hot1.json
/workspace/benchmarks/minicpmo-npugraph/max6/max6-clean-cold-final.json
/workspace/benchmarks/minicpmo-npugraph/max6/max6-accuracy-smoke32.json
/workspace/benchmarks/minicpmo-stage1-full-decode/smoke1.json
/workspace/benchmarks/minicpmo-stage1-full-decode/full-decode-32-run1.json
```

### 10.3 Profiler trace

```text
# Stage 2 eager
/workspace/profiler/minicpmo-58a8615a-stage2/stage2_rank0/
  2544680f4271_1707382_20260826161903189_ascend_pt/

# Stage 2 NPUGraph
/workspace/profiler/minicpmo-npugraph-stage2/stage2_rank0/
  2544680f4271_1812046_20260826183633391_ascend_pt/

# Stage 1 PIECEWISE
/workspace/profiler/minicpmo-npugraph-stage1/stage1_rank0/
  2544680f4271_1986541_20260826222746117_ascend_pt/

# Stage 1 FULL_DECODE_ONLY
/workspace/profiler/minicpmo-stage1-full-decode/stage1_rank0/
  2544680f4271_2052740_20260827000857185_ascend_pt/
```

每个有效 trace 的 `ASCEND_PROFILER_OUTPUT/` 中均包含 `analyse.done`、
`trace_view.json`、`api_statistic.csv`、`op_statistic.csv`、
`step_trace_time.csv` 和分析数据库。
