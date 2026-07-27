import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).parent / "tools" / "analyze_whoop4_gravity_walk.py"
SPEC = importlib.util.spec_from_file_location("gravity_walk", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def cadence_points(count=97, duration=92.3, alias_frequency=0.42, moving=True):
    import math

    def pseudo_noise(index, channel):
        raw = math.sin(
            (index + 1) * (12.9898 + channel * 78.233)
        ) * 43_758.5453
        fraction = raw - math.floor(raw)
        return fraction * 2 - 1

    sample_rate = (count - 1) / duration
    texture_scale = 0.55
    return [
        {
            "timestamp": index / sample_rate,
            "flash": index,
            "tick": index * 2 if moving else 0,
            "gravityX": texture_scale
            * (
                0.073
                * math.sin(2 * math.pi * alias_frequency * index / sample_rate)
                + 0.16 * pseudo_noise(index, 1)
            )
            if moving else 0,
            "gravityY": texture_scale
            * (
                0.073
                * math.cos(2 * math.pi * alias_frequency * index / sample_rate)
                + 0.16 * pseudo_noise(index, 2)
            )
            if moving else 0,
            "gravityZ": 1
            + (
                texture_scale * 0.16 * pseudo_noise(index, 3)
                if moving else 0
            ),
            "unknownMotionScalar32": 0.12 if moving else 0.02,
        }
        for index in range(count)
    ]


def test_matches_swift_synthetic_cadence_result():
    result = MODULE.estimate(cadence_points())
    assert result["steps"] == 133
    assert result["cadenceOnlySteps"] == 135
    assert result["motionVolumeSteps"] == 128
    assert result["motionTicks"] == 192
    assert result["peakDominance"] >= 1.25


def test_proven_rest_returns_zero():
    result = MODULE.estimate(cadence_points(count=70, duration=66, moving=False))
    assert result["steps"] == 0
    assert result["motionTicks"] == 0


def test_counter_consistency_selects_low_alias_only_for_material_inflation():
    assert MODULE.should_use_low_alias_for_counter_consistency(
        ordinary_cadence_steps=129,
        motion_volume_steps=117,
        motion_ticks=121,
    )
    assert not MODULE.should_use_low_alias_for_counter_consistency(
        ordinary_cadence_steps=139,
        motion_volume_steps=104,
        motion_ticks=132,
    )


def test_high_rate_subharmonic_requires_weaker_low_peak_and_tick_rate():
    assert MODULE.should_use_low_alias_for_high_rate_subharmonic(
        low_power=6.88,
        ordinary_power=10,
        gait_tick_rate=1.998,
    )
    assert not MODULE.should_use_low_alias_for_high_rate_subharmonic(
        low_power=9.83,
        ordinary_power=10,
        gait_tick_rate=1.853,
    )
    assert not MODULE.should_use_low_alias_for_high_rate_subharmonic(
        low_power=0.46,
        ordinary_power=10,
        gait_tick_rate=2.08,
    )
