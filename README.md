# MiniCPM X Ascend

基于 llama.cpp-omni 与 GGML CANN backend 的 MiniCPM-o 4.5 F16 比赛基线工程。

参见 [Ascend 环境初始化指南](./ASCEND_ENV_SETUP.md)。

## Smoke test

Smoke test 加载 F16 LLM + audio 模型，关闭 TTS，并使用仓库内置 WAV 完成一次 prefill 与 decode：

~~~bash
./scripts/smoke_test.sh
# 可调整测试规模和超时：
SMOKE_TEST_COUNT=2 SMOKE_TIMEOUT=900 ./scripts/smoke_test.sh
~~~

## Simplex audio-to-text benchmark

Benchmark 每轮重新启动 `llama-omni-cli`，将模型初始化和请求阶段分开统计。默认先 warmup 1 次，再正式测量 5 次；使用固定 seed 和严格生成上限保证各轮输出工作量一致：

~~~bash
./scripts/benchmark_simplex.sh
~~~

可通过环境变量调整实验参数：

~~~bash
BENCH_WARMUP=1 \
BENCH_RUNS=5 \
BENCH_SEED=42 \
BENCH_N_PREDICT=128 \
BENCH_SAMPLE_INTERVAL=0.2 \
./scripts/benchmark_simplex.sh
~~~

结果保存在 `var/benchmark/<UTC时间>/`：

- `results.jsonl`：每个正式轮次的延迟、生成 step、回答与 NPU 采样结果；
- `summary.json`：min、P50、nearest-rank P95、max 和双 Chip 资源峰值；
- `*.cli.log` / `*.npu.log`：用于复核指标来源的原始日志。

`text_ttft_ms` 表示从开始处理用户音频到首个可见文本 token 的用户侧 TTFT；`first_token_decode_ms` 表示从 LLM decode 开始到首个成功采样 token 的引擎首步延迟。`generated_token_steps_per_second` 只计算逐 token 生成区间，不包含 assistant prompt 注入；`request_e2e_ms` 则覆盖用户音频 prefill 到回答准备完成的完整请求路径。
