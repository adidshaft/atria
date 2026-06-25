#!/usr/bin/env python3
import argparse
import hashlib
import re
from collections import Counter
from pathlib import Path


TOKEN_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]*)")
FRAME_RE = re.compile(r"WHOOPDBG frame ch=([0-9A-Fa-f-]+) len=(\d+) hex=([0-9A-Fa-f]+)")


def parse_tokens(line: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in TOKEN_RE.finditer(line)}


def add_offsets(counter: Counter[str], value: str) -> None:
    if not value or value == "none":
        return
    for item in value.split(","):
        if ":" not in item:
            continue
        counter[item] += 1


def parse_hex(value: str) -> bytes:
    try:
        return bytes.fromhex(value)
    except ValueError:
        return b""


def printable_runs(data: bytes, minimum_length: int = 4) -> list[str]:
    runs: list[str] = []
    current = bytearray()

    def flush() -> None:
        nonlocal current
        if len(current) >= minimum_length:
            text = current.decode("utf-8", errors="ignore").strip()
            if text:
                runs.append(text)
        current = bytearray()

    for byte in data:
        if byte in (0x0a, 0x0d) or 0x20 <= byte <= 0x7e:
            current.append(byte)
        else:
            flush()
    flush()
    return runs


def redact_identifier_like_tokens(value: str) -> str:
    redacted: list[str] = []
    for token in value.split(" "):
        letters = sum(ch.isalpha() for ch in token)
        digits = sum(ch.isdigit() for ch in token)
        if len(token) >= 8 and letters >= 3 and digits >= 3:
            redacted.append("[redacted]")
        else:
            redacted.append(token)
    return " ".join(redacted)


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
    frame_types: Counter[str] = Counter()
    metadata_lengths: Counter[str] = Counter()
    metadata_body_hashes: Counter[str] = Counter()
    metadata_printable: Counter[str] = Counter()
    metadata_explicit_model_tokens = 0

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        frame_match = FRAME_RE.search(line)
        if frame_match and frame_match.group(1).upper() == "61080005":
            frame = parse_hex(frame_match.group(3))
            if len(frame) > 4:
                frame_type = f"0x{frame[4]:02x}"
                frame_types[frame_type] += 1
                if frame_type == "0x31":
                    body = frame[4:-4]
                    metadata_lengths[str(len(frame))] += 1
                    metadata_body_hashes[hashlib.sha256(body).hexdigest()[:16]] += 1
                    redacted_runs = [redact_identifier_like_tokens(run) for run in printable_runs(body)]
                    for run in redacted_runs:
                        normalized = run.upper().replace("_", " ").replace("-", " ").replace(".", " ")
                        if any(token in normalized for token in ("WHOOP 3", "WHOOP3", "WHOOP 4", "WHOOP4", "WHOOP 5", "WHOOP5", "WHOOP MG", "WHOOPMG")):
                            metadata_explicit_model_tokens += 1
                        metadata_printable[run] += 1

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
        "frame_61080005_types": format_counter(frame_types),
        "metadata_0x31_frames": str(frame_types.get("0x31", 0)),
        "metadata_0x31_lengths": format_counter(metadata_lengths),
        "metadata_0x31_body_hashes": format_counter(metadata_body_hashes),
        "metadata_0x31_printable": format_counter(metadata_printable),
        "metadata_explicit_model_tokens": str(metadata_explicit_model_tokens),
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
