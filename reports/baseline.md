# MiniCPM-o 4.5 Baseline

## Performance Baseline

- Date: 2026-08-13
- Hardware: Ascend 910C, single card
- Concurrency: 1
- Warmups per run: 2
- Measured requests per run: 32
- Successful requests: 32/32 for every run
- Dataset: Seed-TTS English
- Raw results: `artifacts/baseline-c1-01/results/`
- Benchmark log: `artifacts/baseline-c1-01/logs/benchmark.log`

| Run | Mean TTFT (ms) | Mean Audio TTFP (ms) | Mean Audio RTF | Throughput (req/s) |
|---|---:|---:|---:|---:|
| 20260813-031345 | 316.53 | 1015.38 | 0.4665 | 0.5052 |
| 20260813-032155 | 313.34 | 1003.43 | 0.4574 | 0.5159 |
| 20260813-034240 | 311.34 | 1005.39 | 0.4609 | 0.5109 |
| Three-run mean | 313.74 | 1008.07 | 0.4616 | 0.5107 |

## Official Reference

| Metric | Official | Local three-run mean | Relative difference |
|---|---:|---:|---:|
| TTFT | 333.27 ms | 313.74 ms | -5.86% |
| TTFP | 986.47 ms | 1008.07 ms | +2.19% |
| Chunk RTF | 0.4423 | 0.4616 | +4.36% |

## Current Assessment

The concurrency-1 performance baseline is reproducible and broadly aligned with the official reference.
This does not complete Gate 3: VideoMME, Daily-Omni, Seed-TTS ASV/WER, and Demo evidence remain pending.
