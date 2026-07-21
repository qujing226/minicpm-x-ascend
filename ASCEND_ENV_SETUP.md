# Ascend 环境初始化指南

环境准备流程面向官方 **CANN 9.1.0-beta.1** 镜像，包含环境校验、模型准备、源码获取、独立构建和 CLI smoke test。

## 1. 检查 CANN 与 NPU

~~~bash
cd /workspace/user_data/minicpm-x-ascend
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

## 5. 下载并构建 llama.cpp-omni

~~~bash
# 默认克隆 git@github.com:qujing226/llama.cpp-omni.git；可用 LLAMA_OMNI_REPO 覆盖
./scripts/build_llama_omni.sh
source ~/.bashrc
command -v llama-omni-server
command -v llama-omni-cli
~~~

默认构建目录为：

~~~text
/workspace/llama.cpp-omni/build-cann91
~~~

不要把旧环境中的 `build/` 或二进制复制到新环境；必须使用 9.1 beta 的头文件和库重新配置、重新编译。

## 6. smoke test

~~~bash
./scripts/smoke_test.sh
~~~

~~~bash
llama-omni-cli \
  -m /workspace/user_data/minicpm-x-ascend/models/MiniCPM-o-4_5-gguf/MiniCPM-o-4_5-F16.gguf \
  -c 4096 \
  -ngl 99 \
  --no-tts \
  --test /workspace/llama.cpp-omni/tools/omni/assets/test_case/audio_test_case/audio_test_case_ 1
~~~

