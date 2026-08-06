#!/usr/bin/env python3
"""Score one exact WHOOP 4 v24 walking interval without phone motion."""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path
from typing import Any, Iterable

ALGORITHM_VERSION = "whoop4-impact-gait-ensemble-v13"
STEPS_PER_MOTION_VOLUME = 9.69448197
ORDINARY_GAIT_IDLE_GAP = 10.0
MAXIMUM_GAIT_IDLE_GAP = 12.0
MINIMUM_RESUME_BATCH_FLAT_SECONDS = 5.0
MINIMUM_REGULAR_POSITIVE_INCREMENT_COUNT = 55
MINIMUM_REGULAR_POSITIVE_INCREMENT_MEAN = 1.60
MAXIMUM_GRAVITY_DELTA_MAGNITUDE_MAD = 0.060
MINIMUM_DOMINANT_BURST_TICK_SHARE = 0.80
HIGH_IMPACT_SCALAR_MEAN = 0.13
MINIMUM_LOW_ALIAS_TO_ORDINARY_POWER_RATIO = 1.25
MINIMUM_ORDINARY_ESTIMATE_TO_COUNTER_RATIO = 1.20
MINIMUM_HIGH_RATE_SUBHARMONIC_TICK_RATE = 1.90
MINIMUM_HIGH_RATE_SUBHARMONIC_POWER_RATIO = 0.40
MINIMUM_COUNTER_TO_LOW_ALIAS_CADENCE_RATIO = 1.20
MINIMUM_SOFT_GAIT_TICK_RATE = 2.00
MAXIMUM_SOFT_GAIT_GRAVITY_MAD = 0.030
MINIMUM_SOFT_GAIT_BAND_POWER_SHARE = 0.28
MAXIMUM_SOFT_GAIT_SCALAR_MEAN = 0.105
MAXIMUM_SOFT_GAIT_LOW_ALIAS_POWER_RATIO = 1.10
PHYSICALLY_VALIDATED_TICKS_PER_STEP = 155.0 / 132.0


def iter_rows(path: Path) -> Iterable[dict[str, Any]]:
    files = [path] if path.is_file() else sorted(path.rglob("*.jsonl"))
    for file in files:
        with file.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    yield value


def flash_delta(previous: int, current: int) -> int:
    return current - previous if current >= previous else current + 2**32 - previous


def tick_delta(previous: int, current: int) -> int:
    return current - previous if current >= previous else current + 65_536 - previous


def median(values: list[float]) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[middle - 1] + ordered[middle]) / 2
    return ordered[middle]


def gait_diagnostics(ordered: list[dict[str, Any]]) -> dict[str, float]:
    positive_indices: list[int] = []
    regular_positive_increments: list[int] = []
    motion_ticks = 0
    last_positive_timestamp: float | None = None
    for index, (previous, current) in enumerate(
        zip(ordered, ordered[1:]), start=1
    ):
        gap = current["timestamp"] - previous["timestamp"]
        delta = tick_delta(previous["tick"], current["tick"])
        if gap <= 0 or gap > 3 or delta > 16:
            raise ValueError("unqualified gait transition")
        if delta > 0:
            flat_seconds = current["timestamp"] - (
                last_positive_timestamp
                if last_positive_timestamp is not None
                else ordered[0]["timestamp"]
            )
            if 1 <= delta <= 4:
                regular_positive_increments.append(delta)
            elif not (
                is_resume_batch(delta, flat_seconds)
                or (last_positive_timestamp is None and 11 <= delta <= 13)
            ):
                raise ValueError("unvalidated positive motion increment")
            positive_indices.append(index)
            motion_ticks += delta
            last_positive_timestamp = current["timestamp"]
    if not positive_indices:
        raise ValueError("no counter-active gait burst")
    if len(regular_positive_increments) < MINIMUM_REGULAR_POSITIVE_INCREMENT_COUNT:
        raise ValueError("insufficient regular positive motion transitions")
    regular_positive_increment_mean = (
        sum(regular_positive_increments) / len(regular_positive_increments)
    )
    if regular_positive_increment_mean < MINIMUM_REGULAR_POSITIVE_INCREMENT_MEAN:
        raise ValueError("regular positive increment mean is not gait-like")
    for previous, current in zip(positive_indices, positive_indices[1:]):
        gap = ordered[current]["timestamp"] - ordered[previous]["timestamp"]
        resumed_delta = tick_delta(
            ordered[current - 1]["tick"], ordered[current]["tick"]
        )
        if not motion_burst_continues(gap, resumed_delta):
            raise ValueError("multiple counter-active bursts")
    active = ordered[
        max(0, positive_indices[0] - 1) : positive_indices[-1] + 1
    ]
    duration = active[-1]["timestamp"] - active[0]["timestamp"]
    if duration < 30:
        raise ValueError("counter-active burst shorter than 30 seconds")
    differences = [
        tuple(current[axis] - previous[axis] for axis in ("gravityX", "gravityY", "gravityZ"))
        for previous, current in zip(active, active[1:])
    ]
    scalars = [point["unknownMotionScalar32"] for point in active]
    if (
        len(scalars) != len(active)
        or any(not math.isfinite(value) or not 0 <= value <= 8 for value in scalars)
    ):
        raise ValueError("missing or invalid v24 motion scalar")
    mean_scalar = sum(scalars) / len(scalars)
    mean_gravity_delta = sum(
        math.sqrt(sum(component * component for component in difference))
        for difference in differences
    ) / len(differences)
    gravity_delta_magnitudes = [
        math.sqrt(sum(component * component for component in difference))
        for difference in differences
    ]
    gravity_delta_median = median(gravity_delta_magnitudes)
    gravity_delta_magnitude_mad = median(
        [abs(value - gravity_delta_median) for value in gravity_delta_magnitudes]
    )
    impact_orientation_ratio = mean_scalar / mean_gravity_delta
    count = len(differences)
    sample_rate = count / duration
    tick_rate = motion_ticks / duration
    powers: list[tuple[float, float]] = []
    for bin_index in range(1, count // 2 + 1):
        power = 0.0
        for axis in range(3):
            real = 0.0
            imaginary = 0.0
            for index, difference in enumerate(differences):
                phase = 2 * math.pi * bin_index * index / count
                real += difference[axis] * math.cos(phase)
                imaginary -= difference[axis] * math.sin(phase)
            power += real * real + imaginary * imaginary
        powers.append((bin_index * sample_rate / count, power))
    total_power = sum(power for _, power in powers)
    if not math.isfinite(total_power) or total_power <= 0 or len(powers) <= 1:
        raise ValueError("invalid gait spectrum")
    band_power_share = sum(
        power
        for frequency, power in powers
        if 0.35 <= frequency <= min(0.50, sample_rate / 2)
    ) / total_power
    spectral_entropy = -sum(
        probability * math.log(probability)
        for _, power in powers
        if (probability := power / total_power) > 0
    ) / math.log(len(powers))
    paired_count = count - 2
    if paired_count <= 0:
        raise ValueError("insufficient gait autocorrelation rows")
    first_means = [
        sum(differences[index][axis] for index in range(paired_count))
        / paired_count
        for axis in range(3)
    ]
    second_means = [
        sum(differences[index + 2][axis] for index in range(paired_count))
        / paired_count
        for axis in range(3)
    ]
    covariance = first_energy = second_energy = 0.0
    for index in range(paired_count):
        for axis in range(3):
            first = differences[index][axis] - first_means[axis]
            second = differences[index + 2][axis] - second_means[axis]
            covariance += first * second
            first_energy += first * first
            second_energy += second * second
    denominator = math.sqrt(first_energy * second_energy)
    if not math.isfinite(denominator) or denominator <= 0:
        raise ValueError("invalid gait autocorrelation")
    lag_two_autocorrelation = covariance / denominator
    result = {
        "gaitTickRate": tick_rate,
        "gaitBandPowerShare": band_power_share,
        "gaitSpectralEntropy": spectral_entropy,
        "gaitLagTwoAutocorrelation": lag_two_autocorrelation,
        "unknownMotionScalarMean": mean_scalar,
        "impactOrientationRatio": impact_orientation_ratio,
        "gravityDeltaMagnitudeMAD": gravity_delta_magnitude_mad,
        "regularPositiveIncrementCount": len(regular_positive_increments),
        "regularPositiveIncrementMean": regular_positive_increment_mean,
    }
    if not (
        tick_rate >= 1.55
        and spectral_entropy >= 0.75
        and gravity_delta_magnitude_mad <= MAXIMUM_GRAVITY_DELTA_MAGNITUDE_MAD
    ):
        raise ValueError(f"counter-active burst is not qualified gait: {result}")
    return result


def dominant_motion_window(
    ordered: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    positive: list[tuple[int, int]] = []
    for index, (previous, current) in enumerate(
        zip(ordered, ordered[1:]), start=1
    ):
        delta = tick_delta(previous["tick"], current["tick"])
        if delta > 0:
            positive.append((index, delta))
    if not positive:
        raise ValueError("no counter-active burst")
    clusters: list[list[tuple[int, int]]] = [[positive[0]]]
    for transition in positive[1:]:
        prior = clusters[-1][-1]
        gap = (
            ordered[transition[0]]["timestamp"]
            - ordered[prior[0]]["timestamp"]
        )
        if not motion_burst_continues(gap, transition[1]):
            clusters.append([transition])
        else:
            clusters[-1].append(transition)
    if len(clusters) == 1:
        return ordered
    totals = [sum(ticks for _, ticks in cluster) for cluster in clusters]
    maximum = max(totals)
    if totals.count(maximum) != 1:
        raise ValueError("no unique dominant counter-active burst")
    total = sum(totals)
    if maximum / total < MINIMUM_DOMINANT_BURST_TICK_SHARE:
        raise ValueError("dominant counter-active burst has insufficient tick share")
    cluster = clusters[totals.index(maximum)]
    first_index = cluster[0][0]
    last_index = cluster[-1][0]
    start_target = (
        ordered[first_index]["timestamp"] - MAXIMUM_GAIT_IDLE_GAP
    )
    end_target = ordered[last_index]["timestamp"] + MAXIMUM_GAIT_IDLE_GAP
    lower = max(0, first_index - 1)
    while lower > 0 and ordered[lower - 1]["timestamp"] >= start_target:
        lower -= 1
    upper = last_index
    while (
        upper + 1 < len(ordered)
        and ordered[upper + 1]["timestamp"] <= end_target
    ):
        upper += 1
    return ordered[lower : upper + 1]


def is_resume_batch(delta: int, flat_seconds: float) -> bool:
    return 11 <= delta <= 13 and flat_seconds >= MINIMUM_RESUME_BATCH_FLAT_SECONDS


def motion_burst_continues(gap: float, resumed_delta: int) -> bool:
    if gap > MAXIMUM_GAIT_IDLE_GAP:
        return False
    if gap <= ORDINARY_GAIT_IDLE_GAP:
        return True
    return is_resume_batch(resumed_delta, gap)


def counter_steps(motion_ticks: int) -> int:
    return math.floor(motion_ticks / PHYSICALLY_VALIDATED_TICKS_PER_STEP + 0.5)


def should_use_low_alias_for_counter_consistency(
    ordinary_cadence_steps: int,
    motion_volume_steps: int,
    motion_ticks: int,
) -> bool:
    projected = counter_steps(motion_ticks)
    if ordinary_cadence_steps <= 0 or motion_volume_steps < 0 or projected <= 0:
        return False
    ordinary_estimate = math.floor(
        (2 * ordinary_cadence_steps + motion_volume_steps) / 3 + 0.5
    )
    return (
        ordinary_estimate
        >= projected * MINIMUM_ORDINARY_ESTIMATE_TO_COUNTER_RATIO
    )


def should_use_low_alias_for_high_rate_subharmonic(
    low_power: float,
    ordinary_power: float,
    gait_tick_rate: float,
) -> bool:
    return (
        math.isfinite(low_power)
        and math.isfinite(ordinary_power)
        and math.isfinite(gait_tick_rate)
        and low_power >= 0
        and ordinary_power > 0
        and low_power < ordinary_power
        and (
            low_power / ordinary_power
            >= MINIMUM_HIGH_RATE_SUBHARMONIC_POWER_RATIO
        )
        and gait_tick_rate >= MINIMUM_HIGH_RATE_SUBHARMONIC_TICK_RATE
    )


def estimate(points: list[dict[str, Any]]) -> dict[str, Any]:
    by_flash: dict[int, dict[str, Any]] = {}
    for point in points:
        flash = point["flash"]
        if flash in by_flash and by_flash[flash] != point:
            raise ValueError(f"conflicting rows for flash counter {flash}")
        by_flash[flash] = point
    ordered = sorted(by_flash.values(), key=lambda item: (item["timestamp"], item["flash"]))
    if len(ordered) < 30:
        raise ValueError("fewer than 30 canonical samples")

    original_duration = ordered[-1]["timestamp"] - ordered[0]["timestamp"]
    if not math.isfinite(original_duration) or original_duration < 30:
        raise ValueError("interval is shorter than 30 seconds")

    motion_ticks = 0
    for previous, current in zip(ordered, ordered[1:]):
        gap = current["timestamp"] - previous["timestamp"]
        if gap <= 0 or gap > 3:
            raise ValueError(f"discontinuous samples: {gap:.6f}s")
        if flash_delta(previous["flash"], current["flash"]) <= 0:
            raise ValueError("non-monotonic flash counter")
        delta = tick_delta(previous["tick"], current["tick"])
        if delta > 16:
            raise ValueError(f"implausible motion-tick delta: {delta}")
        motion_ticks += delta

    if motion_ticks == 0:
        return {
            "steps": 0,
            "durationSeconds": original_duration,
            "sampleRateHz": (len(ordered) - 1) / original_duration,
            "aliasFrequencyHz": 0,
            "cadenceHz": 0,
            "peakDominance": None,
            "motionTicks": 0,
            "motionVolume": 0,
            "cadenceOnlySteps": 0,
            "motionVolumeSteps": 0,
            "rows": len(ordered),
        }

    ordered = dominant_motion_window(ordered)
    duration = ordered[-1]["timestamp"] - ordered[0]["timestamp"]
    if not math.isfinite(duration) or duration < 30:
        raise ValueError("selected motion interval is shorter than 30 seconds")
    motion_ticks = sum(
        tick_delta(previous["tick"], current["tick"])
        for previous, current in zip(ordered, ordered[1:])
    )
    sample_rate = (len(ordered) - 1) / duration
    if not 0.8 <= sample_rate <= 1.25:
        raise ValueError(f"sample rate outside qualified range: {sample_rate:.6f}Hz")

    gait = gait_diagnostics(ordered)
    differences = [
        tuple(current[axis] - previous[axis] for axis in ("gravityX", "gravityY", "gravityZ"))
        for previous, current in zip(ordered, ordered[1:])
    ]
    motion_volume = sum(
        math.sqrt(sum(component * component for component in difference))
        for difference in differences
    )
    count = len(differences)
    high_impact_gait = gait["unknownMotionScalarMean"] >= HIGH_IMPACT_SCALAR_MEAN
    spectrum: list[tuple[float, float]] = []
    for bin_index in range(1, count // 2 + 1):
        frequency = bin_index * sample_rate / count
        power = 0.0
        for axis in range(3):
            real = 0.0
            imaginary = 0.0
            for index, difference in enumerate(differences):
                phase = 2 * math.pi * bin_index * index / count
                real += difference[axis] * math.cos(phase)
                imaginary -= difference[axis] * math.sin(phase)
            power += real * real + imaginary * imaginary
        if math.isfinite(power):
            spectrum.append((frequency, power))
    low_alias_candidates = [
        item for item in spectrum if 0.08 <= item[0] <= min(0.20, sample_rate / 2)
    ]
    ordinary_alias_candidates = [
        item for item in spectrum if 0.35 <= item[0] <= min(0.50, sample_rate / 2)
    ]
    if not low_alias_candidates or not ordinary_alias_candidates:
        raise ValueError("no qualified cadence bins")
    low_alias_peak = max(low_alias_candidates, key=lambda item: item[1])
    ordinary_alias_peak = max(ordinary_alias_candidates, key=lambda item: item[1])
    if ordinary_alias_peak[1] <= 0:
        raise ValueError("zero ordinary cadence power")
    low_alias_power_ratio = low_alias_peak[1] / ordinary_alias_peak[1]
    spectral_low_alias = (
        low_alias_power_ratio >= MINIMUM_LOW_ALIAS_TO_ORDINARY_POWER_RATIO
    )
    ordinary_alias_cadence_steps = math.floor(
        (sample_rate + ordinary_alias_peak[0]) * duration + 0.5
    )
    motion_volume_steps = math.floor(
        motion_volume * STEPS_PER_MOTION_VOLUME + 0.5
    )
    counter_arbitrated_low_alias = (
        should_use_low_alias_for_counter_consistency(
            ordinary_alias_cadence_steps,
            motion_volume_steps,
            motion_ticks,
        )
    )
    high_rate_subharmonic_low_alias = (
        should_use_low_alias_for_high_rate_subharmonic(
            low_alias_peak[1],
            ordinary_alias_peak[1],
            gait["gaitTickRate"],
        )
    )
    soft_gait_low_alias = (
        gait["gaitTickRate"] >= MINIMUM_SOFT_GAIT_TICK_RATE
        and gait["gravityDeltaMagnitudeMAD"]
        <= MAXIMUM_SOFT_GAIT_GRAVITY_MAD
        and gait["gaitBandPowerShare"]
        >= MINIMUM_SOFT_GAIT_BAND_POWER_SHARE
        and gait["unknownMotionScalarMean"]
        <= MAXIMUM_SOFT_GAIT_SCALAR_MEAN
        and MINIMUM_HIGH_RATE_SUBHARMONIC_POWER_RATIO
        <= low_alias_power_ratio
        <= MAXIMUM_SOFT_GAIT_LOW_ALIAS_POWER_RATIO
    )
    total_spectrum_power = sum(power for _, power in spectrum)
    if not math.isfinite(total_spectrum_power) or total_spectrum_power <= 0:
        raise ValueError("invalid total cadence power")
    ordinary_band_power = sum(power for _, power in ordinary_alias_candidates)
    ordinary_alias_overconcentrated = gait["gaitBandPowerShare"] > 0.65
    candidates = (
        low_alias_candidates
        if high_impact_gait
        or spectral_low_alias
        or ordinary_alias_overconcentrated
        or counter_arbitrated_low_alias
        or high_rate_subharmonic_low_alias
        or soft_gait_low_alias
        else ordinary_alias_candidates
    )
    if not candidates:
        raise ValueError("no qualified cadence bins")
    alias_frequency, peak_power = max(candidates, key=lambda item: item[1])
    powers = sorted(power for _, power in candidates)
    median_power = powers[len(powers) // 2]
    if peak_power <= 0 or median_power <= 0:
        raise ValueError("zero cadence power")
    dominance = peak_power / median_power
    if not math.isfinite(dominance) or dominance < 1.25:
        raise ValueError(f"ambiguous cadence spectrum: dominance {dominance:.6f}")

    cadence = sample_rate + alias_frequency
    cadence_only_steps = math.floor(cadence * duration + 0.5)
    if high_impact_gait or ordinary_alias_overconcentrated:
        steps = cadence_only_steps
    elif soft_gait_low_alias and not (
        spectral_low_alias
        or counter_arbitrated_low_alias
        or high_rate_subharmonic_low_alias
    ):
        steps = cadence_only_steps
    elif (
        spectral_low_alias
        or counter_arbitrated_low_alias
        or high_rate_subharmonic_low_alias
        or soft_gait_low_alias
    ):
        tick_steps = counter_steps(motion_ticks)
        if (
            tick_steps / cadence_only_steps
            >= MINIMUM_COUNTER_TO_LOW_ALIAS_CADENCE_RATIO
        ):
            steps = tick_steps
        else:
            steps = math.floor((2 * cadence_only_steps + tick_steps) / 3 + 0.5)
    else:
        steps = math.floor(
            (2 * cadence_only_steps + motion_volume_steps) / 3 + 0.5
        )
    if steps <= 0 or steps > duration * 3.5:
        raise ValueError(f"implausible step result: {steps}")
    return {
        "steps": steps,
        "durationSeconds": duration,
        "sampleRateHz": sample_rate,
        "aliasFrequencyHz": alias_frequency,
        "cadenceHz": cadence,
        "peakDominance": dominance,
        "motionTicks": motion_ticks,
        "motionVolume": motion_volume,
        "cadenceOnlySteps": cadence_only_steps,
        "motionVolumeSteps": motion_volume_steps,
        "lowAliasPowerRatio": low_alias_power_ratio,
        "lowAliasFrequencyHz": low_alias_peak[0],
        "ordinaryAliasFrequencyHz": ordinary_alias_peak[0],
        "spectralLowAlias": spectral_low_alias,
        "counterArbitratedLowAlias": counter_arbitrated_low_alias,
        "highRateSubharmonicLowAlias": high_rate_subharmonic_low_alias,
        "softGaitLowAlias": soft_gait_low_alias,
        "ordinaryAliasOverconcentrated": ordinary_alias_overconcentrated,
        "ordinaryBandPowerShare": ordinary_band_power / total_spectrum_power,
        "rows": len(ordered),
        **gait,
    }

def decoded_history_identity(row: dict[str, Any]) -> str:
    value = row.get("_atriaHistoryKey")
    if not isinstance(value, str):
        return ""
    try:
        return bytes.fromhex(value).decode("latin1", errors="ignore")
    except ValueError:
        return ""


def evidence_frame_point(
    row: dict[str, Any],
    clock_offset_seconds: int,
) -> dict[str, Any] | None:
    if row.get("event") != "evidence_historical_frame":
        return None
    try:
        payload = bytes.fromhex(row["payload_hex"])
        if len(payload) != 96 or payload[0] != 0x2F or payload[1] != 24:
            return None
        device_unix = struct.unpack_from("<I", payload, 7)[0]
        subsecond = struct.unpack_from("<H", payload, 11)[0]
        return {
            "timestamp": device_unix + subsecond / 32_768,
            "wallTimestamp": device_unix
            + clock_offset_seconds
            + subsecond / 32_768,
            "clockDriftSeconds": clock_offset_seconds,
            "flash": struct.unpack_from("<I", payload, 3)[0],
            "tick": struct.unpack_from("<H", payload, 88)[0],
            "gravityX": struct.unpack_from("<f", payload, 36)[0],
            "gravityY": struct.unpack_from("<f", payload, 40)[0],
            "gravityZ": struct.unpack_from("<f", payload, 44)[0],
            "unknownMotionScalar32": struct.unpack_from("<f", payload, 32)[0],
            "rawPayloadHex": row["payload_hex"],
            "observedAtUnix": float(row.get("received_at_unix", math.inf)),
        }
    except (KeyError, TypeError, ValueError, struct.error):
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--start", required=True, type=float, help="Unix seconds")
    parser.add_argument("--end", required=True, type=float, help="Unix seconds")
    parser.add_argument("--strap-id")
    parser.add_argument("--counted-steps", type=int)
    parser.add_argument(
        "--evidence-clock-offset",
        type=int,
        help="Wall minus device seconds for evidence_historical_frame JSONL",
    )
    parser.add_argument("--first-flash", type=int)
    parser.add_argument("--last-flash", type=int)
    args = parser.parse_args()
    if args.end <= args.start:
        parser.error("--end must be later than --start")

    candidates: list[dict[str, Any]] = []
    for row in iter_rows(args.raw):
        if args.evidence_clock_offset is not None:
            point = evidence_frame_point(row, args.evidence_clock_offset)
            if point is not None:
                if args.start - 123 <= point["timestamp"] <= args.end + 123:
                    candidates.append(point)
                continue
        if row.get("sequence") != 24 or row.get("clockCorrectionStatus") != "clock_ref_present":
            continue
        if args.strap_id and args.strap_id not in decoded_history_identity(row):
            continue
        try:
            device_unix = float(row["unix7"])
            subsecond = float(row["subsec11"])
            tick_value = row.get("nativeStepCounter88")
            if tick_value is None:
                tick_value = row.get("motionTickCounter88")
            point = {
                "timestamp": device_unix + subsecond / 32_768,
                "wallTimestamp": float(row["clockCorrectedUnix7"])
                + subsecond / 32_768,
                "clockDriftSeconds": int(row.get("clockDriftSeconds", 0)),
                "flash": int(row["flash13"]),
                "tick": int(tick_value),
                "gravityX": float(row["gravityX36"]),
                "gravityY": float(row["gravityY40"]),
                "gravityZ": float(row["gravityZ44"]),
                "unknownMotionScalar32": struct.unpack_from(
                    "<f", bytes.fromhex(row["rawPayloadHex"]), 32
                )[0],
                "rawPayloadHex": row["rawPayloadHex"],
                "observedAtUnix": float(
                    row.get("_atriaHistoryObservedAtUnix", math.inf)
                ),
            }
        except (KeyError, TypeError, ValueError):
            continue
        if args.start - 123 <= point["timestamp"] <= args.end + 123:
            candidates.append(point)
    if len(candidates) < 2:
        raise SystemExit("no qualified v24 rows around requested interval")

    earliest_by_payload: dict[str, dict[str, Any]] = {}
    for point in candidates:
        identity = point["rawPayloadHex"]
        existing = earliest_by_payload.get(identity)
        if (
            existing is None
            or point["observedAtUnix"] < existing["observedAtUnix"]
        ):
            earliest_by_payload[identity] = point
    ordered = sorted(
        earliest_by_payload.values(),
        key=lambda item: (item["timestamp"], item["flash"]),
    )
    if (args.first_flash is None) != (args.last_flash is None):
        parser.error("--first-flash and --last-flash must be provided together")
    if args.first_flash is not None and args.last_flash is not None:
        try:
            first_index = next(
                index
                for index, point in enumerate(ordered)
                if point["flash"] == args.first_flash
            )
            last_index = next(
                index
                for index, point in enumerate(ordered)
                if point["flash"] == args.last_flash
            )
        except StopIteration:
            raise SystemExit("requested flash boundary is absent")
        if last_index <= first_index:
            raise SystemExit("requested flash boundaries are not ordered")
        window = ordered[first_index : last_index + 1]
        try:
            result = estimate(window)
        except ValueError as error:
            raise SystemExit(f"flash-selected workout window did not qualify: {error}")
        first = window[0]
        last = window[-1]
        offset = first["clockDriftSeconds"]
        result.update(
            {
                "algorithmVersion": ALGORITHM_VERSION,
                "phoneMotionUsed": False,
                "requestedStart": args.start,
                "requestedEnd": args.end,
                "selectedClockOffsetSeconds": offset,
                "firstTimestamp": first["timestamp"],
                "lastTimestamp": last["timestamp"],
                "firstWallTimestamp": first["timestamp"] + offset,
                "lastWallTimestamp": last["timestamp"] + offset,
                "coverageFraction": min(
                    1.0,
                    (last["timestamp"] - first["timestamp"])
                    / (args.end - args.start),
                ),
            }
        )
        if args.counted_steps is not None:
            error = abs(result["steps"] - args.counted_steps)
            relative = error / max(1, args.counted_steps)
            result.update(
                {
                    "countedSteps": args.counted_steps,
                    "absoluteError": error,
                    "relativeError": relative,
                    "passed": relative <= 0.05,
                }
            )
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    offset_support: dict[int, int] = {}
    for point in ordered:
        offset = point["clockDriftSeconds"]
        if abs(offset) <= 120:
            offset_support[offset] = offset_support.get(offset, 0) + 1
    if not offset_support:
        offset_support = {0: 1}
    aligned: list[
        tuple[int, int, float, dict[str, Any], dict[str, Any], list[dict[str, Any]]]
    ] = []
    for offset in sorted(offset_support):
        raw_start = args.start - offset
        raw_end = args.end - offset
        first = min(ordered, key=lambda point: abs(point["timestamp"] - raw_start))
        last = min(ordered, key=lambda point: abs(point["timestamp"] - raw_end))
        if (
            abs(first["timestamp"] - raw_start) > 3
            or abs(last["timestamp"] - raw_end) > 3
            or last["timestamp"] <= first["timestamp"]
        ):
            continue
        window = ordered[ordered.index(first) : ordered.index(last) + 1]
        boundary_error = abs(first["timestamp"] - raw_start) + abs(
            last["timestamp"] - raw_end
        )
        local_support = sum(
            point["clockDriftSeconds"] == offset for point in window
        )
        aligned.append(
            (offset, local_support, boundary_error, first, last, window)
        )
    if not aligned:
        raise SystemExit("no single-offset workout window qualified")
    strongest_support = max(item[1] for item in aligned)
    supported = [item for item in aligned if item[1] == strongest_support]
    best_boundary_error = min(item[2] for item in supported)
    boundary_matched = [
        item for item in supported if abs(item[2] - best_boundary_error) < 0.001
    ]
    if len(boundary_matched) != 1:
        raise SystemExit("clock provenance could not identify one physical window")
    offset, _, _, first, last, window = boundary_matched[0]
    try:
        result = estimate(window)
    except ValueError as error:
        raise SystemExit(f"clock-selected workout window did not qualify: {error}")
    result.update(
        {
            "algorithmVersion": ALGORITHM_VERSION,
            "phoneMotionUsed": False,
            "requestedStart": args.start,
            "requestedEnd": args.end,
            "selectedClockOffsetSeconds": offset,
            "firstTimestamp": first["timestamp"],
            "lastTimestamp": last["timestamp"],
            "firstWallTimestamp": first["timestamp"] + offset,
            "lastWallTimestamp": last["timestamp"] + offset,
            "coverageFraction": min(
                1.0,
                (last["timestamp"] - first["timestamp"]) / (args.end - args.start),
            ),
        }
    )
    if args.counted_steps is not None:
        error = abs(result["steps"] - args.counted_steps)
        relative = error / max(1, args.counted_steps)
        result.update(
            {
                "countedSteps": args.counted_steps,
                "absoluteError": error,
                "relativeError": relative,
                "passed": relative <= 0.05,
            }
        )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
