# Ascend 环境初始化指南

环境准备流程包含工具安装、模型下载、源码获取、CANN 构建和一次性 CLI smoke test。

## 1. 检查 CANN 与 NPU

~~~bash
cd /workspace/user_data/minicpm
./scripts/check_env.sh
~~~

## 2. 安装 Node.js 与 uv

~~~bash
./scripts/install-node-uv.sh
source ~/.bashrc
~~~

## 3. [option] 安装 Codex

~~~bash
./scripts/install-codex.sh
source ~/.bashrc
~~~
启动 codex 请使用：
```bash
codexp
```
## 4. 下载官方模型集

~~~bash
uv sync --frozen
uv run download_model.py
./scripts/check_models.sh
~~~

## 5. 下载并安装 llama.cpp-omni 

~~~bash
./scripts/build_llama_omni.sh
source ~/.bashrc
command -v llama-omni-server
command -v llama-omni-cli
~~~

## 6. smoke test

~~~bash
./scripts/smoke_test.sh
~~~

~~~bash
llama-omni-cli \
  -m /workspace/user_data/minicpm/models/MiniCPM-o-4_5-gguf/MiniCPM-o-4_5-F16.gguf \
  -c 4096 \
  -ngl 99 \
  --no-tts \
  --test /workspace/llama.cpp-omni/tools/omni/assets/test_case/audio_test_case/audio_test_case_ 1
~~~

