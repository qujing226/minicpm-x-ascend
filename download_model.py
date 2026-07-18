import os
from pathlib import Path

from modelscope.hub.file_download import model_file_download


MODEL_ID = "OpenBMB/MiniCPM-o-4_5-gguf"
MODEL_DIR = Path(__file__).resolve().parent / "models" / "MiniCPM-o-4_5-gguf"
FILES = [
    "MiniCPM-o-4_5-F16.gguf",
    "audio/MiniCPM-o-4_5-audio-F16.gguf",
    "vision/MiniCPM-o-4_5-vision-F16.gguf",
    "tts/MiniCPM-o-4_5-tts-F16.gguf",
    "tts/MiniCPM-o-4_5-projector-F16.gguf",
    "token2wav-gguf/encoder.gguf",
    "token2wav-gguf/flow_matching.gguf",
    "token2wav-gguf/flow_extra.gguf",
    "token2wav-gguf/hifigan2.gguf",
    "token2wav-gguf/prompt_cache.gguf",
]


MODEL_DIR.mkdir(parents=True, exist_ok=True)

for filename in FILES:
    print(f"[DOWNLOAD] {filename}", flush=True)
    path = model_file_download(
        MODEL_ID,
        filename,
        local_dir=str(MODEL_DIR),
    )
    print(f"[DONE]     {path} ({os.path.getsize(path)} bytes)", flush=True)
