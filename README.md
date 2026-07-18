# MiniCPM X Ascend

基于 llama.cpp-omni / vLLM-Omni 与 GGML CANN backend 的 MiniCPM-o 4.5 F16 比赛基线工程。

参见 [Ascend 环境初始化指南](./ASCEND_ENV_SETUP.md)。

## Smoke test

Smoke test 直接运行 PATH 中的 `llama-omni-cli`，加载 F16 LLM + audio 模型，关闭 TTS，并使用仓库内置 WAV 完成一次 prefill 与 decode：

~~~bash
./scripts/smoke_test.sh
# 可调整测试规模和超时：
SMOKE_TEST_COUNT=2 SMOKE_TIMEOUT=900 ./scripts/smoke_test.sh
~~~