bench:
	cd /workspace/vllm-omni && \
	(timeout 300 bash -c 'until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8091/health | grep -q "200"; do sleep 1; done') && \
	vllm bench serve \
	--omni \
	--port 8091 \
	--trust-remote-code \
	--max-concurrency 1 \
	--num-warmups 3 \
	--dataset-name seed-tts \
	--dataset-path /workspace/data_set/seed-tts-eval \
	--seed-tts-locale zh \
	--num-prompts 32 \
	--disable-shuffle \
	--no-oversample \
	--model openbmb/MiniCPM-o-4_5 \
	--tokenizer /workspace/shared_assets/models/OpenBMB/MiniCPM-o-4_5 \
	--endpoint /v1/chat/completions \
	--backend openai-chat-omni \
	--percentile-metrics ttft,e2el,audio_ttfp,audio_rtf,audio_duration \
	--extra_body '{"modalities":["text","audio"],"chat_template_kwargs":{"enable_thinking":false,"use_tts_template":true}}'

bench-save:
	cd /workspace/vllm-omni && \
	(timeout 300 bash -c 'until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8091/health | grep -q "200"; do sleep 1; done') && \
	vllm bench serve \
	--omni \
	--port 8091 \
	--trust-remote-code \
	--max-concurrency 1 \
	--num-warmups 3 \
	--dataset-name seed-tts \
	--dataset-path /workspace/data_set/seed-tts-eval \
	--seed-tts-locale zh \
	--num-prompts 32 \
	--disable-shuffle \
	--no-oversample \
	--model openbmb/MiniCPM-o-4_5 \
	--tokenizer /workspace/shared_assets/models/OpenBMB/MiniCPM-o-4_5 \
	--endpoint /v1/chat/completions \
	--backend openai-chat-omni \
	--percentile-metrics ttft,e2el,audio_ttfp,audio_rtf,audio_duration \
	--extra_body '{"modalities":["text","audio"],"chat_template_kwargs":{"enable_thinking":false,"use_tts_template":true}}' \
	--save-result \
	--save-detailed \
	--result-dir /workspace/benchmarks/minicpmo-npugraph/max6 \
	--result-filename max6-clean-hot1.json \
	--metadata candidate=npugraph_max6 run=clean_hot1


profile:
	cd /workspace/vllm-omni && \
	vllm bench serve \
	--omni \
	--port 8091 \
	--trust-remote-code \
	--max-concurrency 1 \
	--num-warmups 2 \
	--dataset-name seed-tts \
	--dataset-path /workspace/data_set/seed-tts-eval \
	--seed-tts-locale zh \
	--num-prompts 1 \
	--disable-shuffle \
	--no-oversample \
	--model openbmb/MiniCPM-o-4_5 \
	--tokenizer /workspace/shared_assets/models/OpenBMB/MiniCPM-o-4_5 \
	--endpoint /v1/chat/completions \
	--backend openai-chat-omni \
	--percentile-metrics ttft,e2el,audio_ttfp,audio_rtf,audio_duration \
	--extra_body '{"modalities":["text","audio"],"chat_template_kwargs":{"enable_thinking":false,"use_tts_template":true}}'

	cd /workspace/vllm-omni && \
	curl -sS \
	-X POST http://127.0.0.1:8091/start_profile \
	-H 'Content-Type: application/json' \
	-d '{"stages":[2]}'

	vllm bench serve \
	--omni \
	--port 8091 \
	--trust-remote-code \
	--max-concurrency 1 \
	--num-warmups 0 \
	--dataset-name seed-tts \
	--dataset-path /workspace/data_set/seed-tts-eval \
	--seed-tts-locale zh \
	--num-prompts 1 \
	--disable-shuffle \
	--no-oversample \
	--model openbmb/MiniCPM-o-4_5 \
	--tokenizer /workspace/shared_assets/models/OpenBMB/MiniCPM-o-4_5 \
	--endpoint /v1/chat/completions \
	--backend openai-chat-omni \
	--percentile-metrics ttft,e2el,audio_ttfp,audio_rtf,audio_duration \
	--extra_body '{"modalities":["text","audio"],"chat_template_kwargs":{"enable_thinking":false,"use_tts_template":true}}'

	curl -sS \
	-X POST http://127.0.0.1:8091/stop_profile \
	-H 'Content-Type: application/json' \
	-d '{"stages":[2]}'