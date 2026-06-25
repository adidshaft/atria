#!/usr/bin/env python3
import argparse
import re
from collections import Counter
from pathlib import Path


TOKEN_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]*)")


def parse_tokens(line: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in TOKEN_RE.finditer(line)}


def add_offsets(counter: Counter[str], value: str) -> None:
    if not value or value == "none":
        return
    for item in value.split(","):
        if ":" not in item:
            continue
        counter[item] += 1


def analyze(path: Path) -> dict[str, str]:
    rows = 0
    sources: Counter[str] = Counter()
    model_generations: Counter[str] = Counter()
    spo2_offsets: Counter[str] = Counter()
    temp_offsets: Counter[str] = Counter()
    max_spo2_candidate_frames = 0
    max_temp_candidate_frames = 0
    metric_promotions = 0
    healthkit_writes = 0
    raw_storage = 0

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "WHOOPDBG sensor_research_probe " not in line:
            continue
        rows += 1
        tokens = parse_tokens(line)
        sources[tokens.get("source", "unknown")] += 1
        model_generations[tokens.get("model_generation", "unknown")] += 1
        add_offsets(spo2_offsets, tokens.get("spo2_offsets", ""))
        add_offsets(temp_offsets, tokens.get("skin_temp_offsets", ""))
        max_spo2_candidate_frames = max(max_spo2_candidate_frames, int(tokens.get("spo2_candidate_frames", "0") or "0"))
        max_temp_candidate_frames = max(max_temp_candidate_frames, int(tokens.get("skin_temp_candidate_frames", "0") or "0"))
        metric_promotions += int(tokens.get("metric_promotions", "0") or "0")
        healthkit_writes += int(tokens.get("healthkit_write", "0") or "0")
        raw_storage += int(tokens.get("raw_storage", "0") or "0")

    return {
        "probe_rows": str(rows),
        "probe_sources": format_counter(sources),
        "model_generations": format_counter(model_generations),
        "spo2_candidate_frames": str(max_spo2_candidate_frames),
        "spo2_top_offsets": format_counter(spo2_offsets),
        "skin_temp_candidate_frames": str(max_temp_candidate_frames),
        "skin_temp_top_offsets": format_counter(temp_offsets),
        "metric_promotions": str(metric_promotions),
        "healthkit_writes": str(healthkit_writes),
        "raw_storage": str(raw_storage),
        "research_only": "1" if rows > 0 and metric_promotions == 0 and healthkit_writes == 0 and raw_storage == 0 else "0",
    }


def format_counter(counter: Counter[str], limit: int = 12) -> str:
    if not counter:
        return "none"
    return ",".join(f"{key}:{count}" for key, count in counter.most_common(limit))


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize Atria sensor research probe rows from a WHOOPDBG log.")
    parser.add_argument("log", type=Path)
    args = parser.parse_args()

    summary = analyze(args.log)
    for key, value in summary.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
