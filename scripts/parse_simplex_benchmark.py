#!/usr/bin/env python3
"""Parse llama.cpp-omni simplex benchmark logs and build JSON reports."""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from pathlib import Path
from typing import Any


DAY_MS = 24 * 60 * 60 * 1000
TIMESTAMP_RE = re.compile(r"(?P<clock>\d{2}:\d{2}:\d{2}\.\d{3})")
RESPONSE_RE = re.compile(
    r"^=== Assistant Response ===\s*$\n(?P<response>.*?)"
    r"^=== End Assistant Response ===\s*$",
    re.MULTILINE | re.DOTALL,
)
NPU_SAMPLE_RE = re.compile(
    r"^=== NPU SAMPLE epoch_ms=(?P<epoch_ms>\d+) "
    r"phase=(?P<phase>baseline|runtime) ===$"
)
NPU_CHIP_ROW_RE = re.compile(
    r"^\|\s*(?P<chip_id>\d+)\s+\d+\s*\|\s*"
    r"(?P<bus_id>0000:[^|]+)\|\s*(?P<stats>[^|]+)\|$"
)
PERF_EVENT_RE = re.compile(
    r"^OMNI_PERF (?P<name>[a-z_]+)_us=(?P<value>\d+)$",
    re.MULTILINE,
)


def _clock_to_ms(clock: str) -> int:
    hours, minutes, seconds = clock.split(":")
    whole_seconds, milliseconds = seconds.split(".")
    return (
        int(hours) * 60 * 60 * 1000
        + int(minutes) * 60 * 1000
        + int(whole_seconds) * 1000
        + int(milliseconds)
    )


def _elapsed_ms(start_ms: int, end_ms: int) -> float:
    if end_ms < start_ms:
        end_ms += DAY_MS
    return float(end_ms - start_ms)


def _marker_timestamp(log_text: str, marker: str) -> int | None:
    for line in log_text.splitlines():
        if marker not in line:
            continue
        match = TIMESTAMP_RE.search(line)
        if match:
            return _clock_to_ms(match.group("clock"))
    return None


def _duration_between(
    log_text: str,
    start_marker: str,
    end_marker: str,
) -> float | None:
    start_ms = _marker_timestamp(log_text, start_marker)
    end_ms = _marker_timestamp(log_text, end_marker)
    if start_ms is None or end_ms is None:
        return None
    return _elapsed_ms(start_ms, end_ms)


def _prefill_ms(log_text: str, index: int) -> float | None:
    pattern = re.compile(
        rf"^prefill {index} \(audio\)\s*:\s*(?P<seconds>[0-9.]+)\s+s\s*$",
        re.MULTILINE,
    )
    match = pattern.search(log_text)
    if not match:
        return None
    return float(match.group("seconds")) * 1000.0


def _n_past_for_marker(log_text: str, marker: str) -> int | None:
    for line in log_text.splitlines():
        if marker not in line:
            continue
        match = re.search(r"\bn_past=(?P<n_past>\d+)", line)
        if match:
            return int(match.group("n_past"))
    return None


def _perf_events_us(log_text: str) -> dict[str, int]:
    return {
        match.group("name"): int(match.group("value"))
        for match in PERF_EVENT_RE.finditer(log_text)
    }


def _perf_elapsed_ms(
    events_us: dict[str, int],
    start_event: str,
    end_event: str,
) -> float | None:
    start_us = events_us.get(start_event)
    end_us = events_us.get(end_event)
    if start_us is None or end_us is None or end_us < start_us:
        return None
    return (end_us - start_us) / 1000.0


def parse_cli_log(log_text: str) -> dict[str, Any]:
    """Extract request-level timings and response text from one CLI log."""
    errors: list[str] = []
    perf_events_us = _perf_events_us(log_text)
    startup_ms = _duration_between(
        log_text,
        "=== omni_init start",
        "=== omni_init success:",
    )
    reference_prefill_ms = _prefill_ms(log_text, 0)
    user_prefill_ms = _prefill_ms(log_text, 1)
    decode_ms = _duration_between(log_text, "stream_decode 开始", "Decode 结束")
    token_decode_ms = _duration_between(log_text, "LLM decode:", "Decode 结束")
    generation_start_n_past = _n_past_for_marker(log_text, "LLM decode:")
    decode_end_n_past = _n_past_for_marker(log_text, "Decode 结束")
    generated_token_steps = None
    if generation_start_n_past is not None and decode_end_n_past is not None:
        token_step_delta = decode_end_n_past - generation_start_n_past
        if token_step_delta > 0:
            generated_token_steps = token_step_delta
    generated_token_steps_per_second = (
        generated_token_steps / (token_decode_ms / 1000.0)
        if generated_token_steps is not None
        and token_decode_ms is not None
        and token_decode_ms > 0
        else None
    )
    request_e2e_ms = _duration_between(
        log_text,
        "stream_prefill(index=1): processing user audio:",
        "为下一轮准备:",
    )
    n_predict_match = re.search(r"\bn_predict = (?P<n_predict>-?\d+)", log_text)
    text_ttft_ms = _perf_elapsed_ms(
        perf_events_us,
        "simplex_request_start",
        "text_first_visible",
    )
    first_token_decode_ms = _perf_elapsed_ms(
        perf_events_us,
        "llm_decode_start",
        "llm_first_sample",
    )
    n_predict = int(n_predict_match.group("n_predict")) if n_predict_match else None
    if "LLM: detected end token" in log_text:
        termination_reason = "end_token"
    elif n_predict is not None and n_predict > 0 and decode_end_n_past is not None:
        termination_reason = "length"
    elif n_predict == -1 and decode_end_n_past is not None:
        termination_reason = "context_limit"
    else:
        termination_reason = None

    response_match = RESPONSE_RE.search(log_text)
    response_text = response_match.group("response").strip() if response_match else ""

    required_metrics = {
        "startup_ms": startup_ms,
        "reference_prefill_ms": reference_prefill_ms,
        "user_prefill_ms": user_prefill_ms,
        "decode_ms": decode_ms,
        "token_decode_ms": token_decode_ms,
        "request_e2e_ms": request_e2e_ms,
        "text_ttft_ms": text_ttft_ms,
        "first_token_decode_ms": first_token_decode_ms,
    }
    for name, value in required_metrics.items():
        if value is None:
            errors.append(f"missing metric: {name}")
    if generated_token_steps is None:
        errors.append("missing metric: generated_token_steps")
    if termination_reason is None:
        errors.append("missing termination reason")
    if response_match is None:
        errors.append("missing assistant response markers")
    elif not response_text:
        errors.append("empty assistant response")

    return {
        **required_metrics,
        "generated_token_steps": generated_token_steps,
        "generated_token_steps_per_second": generated_token_steps_per_second,
        "n_predict": n_predict,
        "termination_reason": termination_reason,
        "response_text": response_text,
        "response_chars": len(response_text),
        "errors": errors,
    }


def _parse_npu_samples(log_text: str) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    for line in log_text.splitlines():
        header_match = NPU_SAMPLE_RE.match(line)
        if header_match:
            current = {
                "epoch_ms": int(header_match.group("epoch_ms")),
                "phase": header_match.group("phase"),
                "chips": {},
            }
            samples.append(current)
            continue

        if current is None:
            continue
        chip_match = NPU_CHIP_ROW_RE.match(line)
        if not chip_match:
            continue

        stats = chip_match.group("stats")
        aicore_match = re.match(r"\s*(?P<aicore>[0-9.]+)", stats)
        usage_pairs = re.findall(r"(?P<used>\d+)\s*/\s*(?P<total>\d+)", stats)
        if aicore_match is None or not usage_pairs:
            continue

        hbm_used, hbm_total = usage_pairs[-1]
        chip_id = int(chip_match.group("chip_id"))
        current["chips"][chip_id] = {
            "chip_id": chip_id,
            "bus_id": chip_match.group("bus_id").strip(),
            "aicore_pct": float(aicore_match.group("aicore")),
            "hbm_used_mb": int(hbm_used),
            "hbm_total_mb": int(hbm_total),
        }

    return samples


def parse_npu_log(log_text: str, process_id: int) -> dict[str, Any]:
    """Aggregate sampled per-chip HBM/AICore data and process visibility."""
    errors: list[str] = []
    samples = _parse_npu_samples(log_text)
    baseline_samples = [sample for sample in samples if sample["phase"] == "baseline"]
    runtime_samples = [sample for sample in samples if sample["phase"] == "runtime"]

    process_pattern = re.compile(
        rf"^\|\s*\d+\s+\d+\s*\|\s*{process_id}\s*\|",
        re.MULTILINE,
    )
    npu_seen = process_pattern.search(log_text) is not None

    chip_ids = sorted({chip_id for sample in samples for chip_id in sample["chips"]})
    chips: list[dict[str, Any]] = []
    for chip_id in chip_ids:
        baseline_rows = [
            sample["chips"][chip_id]
            for sample in baseline_samples
            if chip_id in sample["chips"]
        ]
        runtime_rows = [
            sample["chips"][chip_id]
            for sample in runtime_samples
            if chip_id in sample["chips"]
        ]
        all_rows = baseline_rows + runtime_rows
        if not all_rows:
            continue

        baseline_hbm_mb = baseline_rows[0]["hbm_used_mb"] if baseline_rows else None
        peak_hbm_mb = max(row["hbm_used_mb"] for row in all_rows)
        peak_aicore_pct = (
            max(row["aicore_pct"] for row in runtime_rows) if runtime_rows else None
        )
        if baseline_hbm_mb is None:
            errors.append(f"missing baseline HBM for chip {chip_id}")
        if peak_aicore_pct is None:
            errors.append(f"missing runtime utilization for chip {chip_id}")
        chips.append(
            {
                "chip_id": chip_id,
                "bus_id": all_rows[0]["bus_id"],
                "baseline_hbm_mb": baseline_hbm_mb,
                "peak_hbm_mb": peak_hbm_mb,
                "peak_hbm_delta_mb": (
                    peak_hbm_mb - baseline_hbm_mb
                    if baseline_hbm_mb is not None
                    else None
                ),
                "sampled_peak_aicore_pct": peak_aicore_pct,
            }
        )

    if not samples:
        errors.append("missing NPU samples")
    elif not runtime_samples:
        errors.append("missing runtime NPU samples")
    if not chips:
        errors.append("missing per-chip NPU data")
    if not npu_seen:
        errors.append(f"process {process_id} was not visible in npu-smi")

    return {
        "npu_seen": npu_seen,
        "npu_sample_count": len(runtime_samples),
        "chips": chips,
        "errors": errors,
    }


def build_run_record(
    *,
    cli_log_text: str,
    npu_log_text: str,
    run_id: int,
    exit_code: int,
    process_id: int,
    process_elapsed_ms: float,
) -> dict[str, Any]:
    cli_result = parse_cli_log(cli_log_text)
    npu_result = parse_npu_log(npu_log_text, process_id)
    errors = list(cli_result.pop("errors")) + list(npu_result.pop("errors"))
    if exit_code != 0:
        errors.insert(0, f"llama-omni-cli exited with code {exit_code}")

    return {
        "schema_version": 1,
        "run_id": run_id,
        "status": "pass" if not errors else "fail",
        "exit_code": exit_code,
        "process_id": process_id,
        "process_elapsed_ms": process_elapsed_ms,
        **cli_result,
        **npu_result,
        "errors": errors,
    }


def _nearest_rank(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile / 100.0 * len(ordered)))
    return ordered[rank - 1]


def _metric_summary(
    records: list[dict[str, Any]], metric: str
) -> dict[str, float] | None:
    values = [
        float(record[metric])
        for record in records
        if record["status"] == "pass" and record.get(metric) is not None
    ]
    if not values:
        return None
    return {
        "min": min(values),
        "p50": float(statistics.median(values)),
        "p95": _nearest_rank(values, 95.0),
        "max": max(values),
    }


def build_summary(
    records: list[dict[str, Any]],
    metadata: dict[str, Any],
) -> dict[str, Any]:
    passed_records = [record for record in records if record["status"] == "pass"]
    failed_records = [record for record in records if record["status"] == "fail"]
    metric_names = (
        "process_elapsed_ms",
        "startup_ms",
        "reference_prefill_ms",
        "user_prefill_ms",
        "decode_ms",
        "token_decode_ms",
        "request_e2e_ms",
        "text_ttft_ms",
        "first_token_decode_ms",
    )

    chip_ids = sorted(
        {
            chip["chip_id"]
            for record in passed_records
            for chip in record.get("chips", [])
        }
    )
    chip_summary: list[dict[str, Any]] = []
    for chip_id in chip_ids:
        rows = [
            chip
            for record in passed_records
            for chip in record.get("chips", [])
            if chip["chip_id"] == chip_id
        ]
        hbm_deltas = [
            row["peak_hbm_delta_mb"]
            for row in rows
            if row["peak_hbm_delta_mb"] is not None
        ]
        aicore_peaks = [
            row["sampled_peak_aicore_pct"]
            for row in rows
            if row["sampled_peak_aicore_pct"] is not None
        ]
        chip_summary.append(
            {
                "chip_id": chip_id,
                "peak_hbm_mb": max(row["peak_hbm_mb"] for row in rows),
                "peak_hbm_delta_mb": max(hbm_deltas) if hbm_deltas else None,
                "sampled_peak_aicore_pct": (
                    max(aicore_peaks) if aicore_peaks else None
                ),
            }
        )

    expected_runs = int(metadata["measured_runs"])
    summary_status = (
        "pass" if len(records) == expected_runs and not failed_records else "fail"
    )
    return {
        "schema_version": 1,
        "status": summary_status,
        "metadata": metadata,
        "runs": {
            "expected": expected_runs,
            "recorded": len(records),
            "passed": len(passed_records),
            "failed": len(failed_records),
        },
        "metrics_ms": {
            metric: _metric_summary(records, metric) for metric in metric_names
        },
        "decode_work": {
            "generated_token_steps": _metric_summary(
                records,
                "generated_token_steps",
            ),
            "generated_token_steps_per_second": _metric_summary(
                records,
                "generated_token_steps_per_second",
            ),
        },
        "chips": chip_summary,
        "failed_runs": [
            {"run_id": record["run_id"], "errors": record["errors"]}
            for record in failed_records
        ],
    }


def _read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


def _append_jsonl(path: str, value: dict[str, Any]) -> None:
    with Path(path).open("a", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, separators=(",", ":"))
        output.write("\n")


def _load_jsonl(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in _read_text(path).splitlines():
        if line.strip():
            records.append(json.loads(line))
    return records


def _run_command(args: argparse.Namespace) -> int:
    record = build_run_record(
        cli_log_text=_read_text(args.cli_log),
        npu_log_text=_read_text(args.npu_log),
        run_id=args.run_id,
        exit_code=args.exit_code,
        process_id=args.process_id,
        process_elapsed_ms=args.process_elapsed_ms,
    )
    _append_jsonl(args.output, record)
    decode_speed = record["generated_token_steps_per_second"]
    decode_speed_text = f"{decode_speed:.2f}" if decode_speed is not None else "null"
    print(
        f"run {record['run_id']:03d}: {record['status']} "
        f"request_e2e_ms={record['request_e2e_ms']} "
        f"decode_steps_per_second={decode_speed_text}"
    )
    return 0 if record["status"] == "pass" else 2


def _summary_command(args: argparse.Namespace) -> int:
    records = _load_jsonl(args.results)
    metadata = {
        "started_at_utc": args.started_at_utc,
        "warmup_runs": args.warmup_runs,
        "measured_runs": args.measured_runs,
        "sample_interval_seconds": args.sample_interval_seconds,
        "seed": args.seed,
        "n_predict": args.n_predict,
        "model_path": args.model_path,
        "audio_prefix": args.audio_prefix,
        "cli_path": args.cli_path,
        "project_commit": args.project_commit,
        "llama_commit": args.llama_commit,
        "text_ttft_definition": (
            "user audio processing start to first visible assistant text token"
        ),
        "first_token_decode_definition": (
            "LLM decode start to first successfully sampled token"
        ),
    }
    summary = build_summary(records, metadata)
    Path(args.output).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"summary: {summary['status']} "
        f"passed={summary['runs']['passed']} failed={summary['runs']['failed']}"
    )
    return 0 if summary["status"] == "pass" else 2


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="append one parsed run to JSONL")
    run_parser.add_argument("--cli-log", required=True)
    run_parser.add_argument("--npu-log", required=True)
    run_parser.add_argument("--run-id", required=True, type=int)
    run_parser.add_argument("--exit-code", required=True, type=int)
    run_parser.add_argument("--process-id", required=True, type=int)
    run_parser.add_argument("--process-elapsed-ms", required=True, type=float)
    run_parser.add_argument("--output", required=True)
    run_parser.set_defaults(handler=_run_command)

    summary_parser = subparsers.add_parser("summary", help="write aggregate JSON")
    summary_parser.add_argument("--results", required=True)
    summary_parser.add_argument("--output", required=True)
    summary_parser.add_argument("--started-at-utc", required=True)
    summary_parser.add_argument("--warmup-runs", required=True, type=int)
    summary_parser.add_argument("--measured-runs", required=True, type=int)
    summary_parser.add_argument(
        "--sample-interval-seconds",
        required=True,
        type=float,
    )
    summary_parser.add_argument("--seed", required=True, type=int)
    summary_parser.add_argument("--n-predict", required=True, type=int)
    summary_parser.add_argument("--model-path", required=True)
    summary_parser.add_argument("--audio-prefix", required=True)
    summary_parser.add_argument("--cli-path", required=True)
    summary_parser.add_argument("--project-commit", required=True)
    summary_parser.add_argument("--llama-commit", required=True)
    summary_parser.set_defaults(handler=_summary_command)

    return parser


def main() -> int:
    args = _build_parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
