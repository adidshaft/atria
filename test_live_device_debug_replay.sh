#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

log="$tmpdir/live-device.log"
out="$tmpdir/summary.out"

cat > "$log" <<'LOG'
2026-06-12 18:39:00.375 Atria[5457:962682] ATRIADBG notifyState ch=61080005-8D6D-82B8-614A-1C8CB0F8DCC6 notifying=1 err=nil
2026-06-12 18:39:03.532 Atria[5457:962682] ATRIADBG send mode=wwr cmd=03 seq=0 to=61080002-8D6D-82B8-614A-1C8CB0F8DCC6 props=12 frame=aa0800a82300030199bce9cf
2026-06-12 18:39:03.700 Atria[5457:962682] ATRIADBG frame ch=61080003 len=16 hex=aa0c00fc242003000200000096a2d488
2026-06-12 18:39:03.795 Atria[5457:962682] ATRIADBG cmdResp ch=61080003-8D6D-82B8-614A-1C8CB0F8DCC6 payload=2420030002000000
2026-06-12 18:39:04.000 Atria[5457:962682] ATRIADBG frame ch=61080004 len=20 hex=aa100057300f2100e9332c6a983d0000eff824ae
2026-06-12 18:39:04.577 Atria[5457:962682] ATRIADBG frame ch=61080005 len=28 hex=aa0e005c2802ef042c6ab8765100a17b5091
2026-06-12 18:39:05.000 Atria[5457:962682] ATRIADBG frame ch=61080007 len=12 hex=aa0800010802a7020103010a
2026-06-12 18:39:16.247 Atria[5457:962682] ATRIADBG rr hr=84 rrnum=1 decoded=1 total_decoded=1 truncated=0 hr_mismatch=0 implied_bpm=81 values=740
2026-06-12 18:39:33.000 Atria[5457:962682] ATRIADBG probeSweep send index=0 raw=0302 cmd=03 data=02 interval_s=30.0 mode=wwr
2026-06-12 18:40:03.795 Atria[5457:962682] ATRIADBG cmdResp ch=61080003-8D6D-82B8-614A-1C8CB0F8DCC6 payload=2421030002000000
2026-06-12 18:40:04.000 Atria[5457:962682] ATRIADBG frame ch=61080004 len=12 hex=2f2c010403
2026-06-12 18:40:04.577 Atria[5457:962682] ATRIADBG frame ch=61080005 len=28 hex=aa1000572802ef042c6ab8765101e60211111111
LOG

./live_device_debug.sh --replay-log "$log" --seconds 1 --no-build > "$out"

grep -q 'notify_61080005=True' "$out"
grep -q 'realtime_start=True' "$out"
grep -q 'cmd_response=True' "$out"
grep -q 'frame_61080005=True' "$out"
grep -q 'cmd_response_count=2' "$out"
grep -q 'cmd_response_last_seq=33' "$out"
grep -q 'cmd_response_last_cmd=0x03' "$out"
grep -q 'cmd_response_last_status=0002000000' "$out"
grep -q 'cmd_response_statuses=seq=32:cmd=0x03:status=0002000000;seq=33:cmd=0x03:status=0002000000' "$out"
grep -q 'frame_61080003_count=1' "$out"
grep -q 'frame_61080004_count=2' "$out"
grep -q 'frame_61080005_count=2' "$out"
grep -q 'frame_61080007_count=1' "$out"
grep -q 'frame_61080004_types=0x2f:1,0x30:1' "$out"
grep -q 'frame_61080005_types=0x28:2' "$out"
grep -q 'frame_61080007_types=0x08:1' "$out"
grep -q 'historical_2f_frames=1' "$out"
grep -q 'historical_2f_candidate_rr_values=2' "$out"
grep -q 'historical_2f_first_prefix=2f2c010403' "$out"
grep -q 'realtime_frames=2' "$out"
grep -q 'realtime_rr_frames=1' "$out"
grep -q 'realtime_rr_zero_frames=1' "$out"
grep -q 'realtime_rr_fraction=0.500' "$out"
grep -q 'realtime_rr_percent=50.0' "$out"
grep -q 'realtime_zero_rr_tail_nonzero_frames=0' "$out"
grep -q 'realtime_zero_rr_tail_valid_candidate_frames=0' "$out"
grep -q 'last_realtime_rr_bytes=' "$out"
grep -q 'rr_values=1' "$out"
grep -q 'segment_0_label=initial' "$out"
grep -q 'segment_0_raw=03' "$out"
grep -q 'segment_0_frames=1' "$out"
grep -q 'segment_0_rr_fraction=0.000' "$out"
grep -q 'segment_0_cmd_status=seq=32:cmd=0x03:status=0002000000' "$out"
grep -q 'segment_0_frame_61080004_count=1' "$out"
grep -q 'segment_0_frame_61080005_count=1' "$out"
grep -q 'segment_0_frame_61080007_count=1' "$out"
grep -q 'segment_0_frame_61080004_types=0x30:1' "$out"
grep -q 'segment_0_frame_61080005_types=0x28:1' "$out"
grep -q 'segment_0_frame_61080007_types=0x08:1' "$out"
grep -q 'segment_1_label=sweep_0' "$out"
grep -q 'segment_1_raw=0302' "$out"
grep -q 'segment_1_frames=1' "$out"
grep -q 'segment_1_rr_fraction=1.000' "$out"
grep -q 'segment_1_cmd_status=seq=33:cmd=0x03:status=0002000000' "$out"
grep -q 'segment_1_frame_61080004_count=1' "$out"
grep -q 'segment_1_frame_61080005_count=1' "$out"
grep -q 'segment_1_frame_61080004_types=0x2f:1' "$out"
grep -q 'segment_1_frame_61080005_types=0x28:1' "$out"
grep -q 'segment_1_historical_2f_frames=1' "$out"
grep -q 'segment_1_historical_2f_candidate_rr_values=2' "$out"

echo "test_live_device_debug_replay.sh: pass"

health_log="$tmpdir/healthkit-sleep-auth.log"
health_out="$tmpdir/healthkit-sleep-auth.out"

cat > "$health_log" <<'LOG'
2026-06-15 18:50:00.000 Atria[100:200] ATRIADBG launch_exports status=scheduled rr_reference=0 rr_reference_ui=0 hr_reference=0 hr_reference_ui=0 rr_reference_validation=0 hr_reference_validation=0 reference_clear=0 healthkit=1 healthkit_reference_audit=0 healthkit_reset_rebuild=0 workout_confirm=0 sleep_confirm=1
2026-06-15 18:50:00.100 Atria[100:200] ATRIADBG sleep_confirm status=already_confirmed id=123 source=launch_arg candidate_source=aggregate_sleep start=2026-06-15T00:00:00Z end=2026-06-15T06:00:00Z confidence=user_confirmed_hr_only motion_source=unavailable motion_validated=0 metric_promotions=0 auto_gate_e_unchanged=1
2026-06-15 18:50:00.200 Atria[100:200] ATRIADBG healthkit_sleep_export status=authorization_required sleeps=1 authorization=not_determined action=request_health_sleep_analysis metric_promotions=0 auto_gate_e_unchanged=1
2026-06-15 18:50:00.300 Atria[100:200] ATRIADBG healthkit_export status=authorization_requested sessions=10 hr_samples=0 workouts=0 hrv_samples=0 sleeps=1 read_hr=1 read_sleep=1
2026-06-15 18:50:15.300 Atria[100:200] ATRIADBG healthkit_export status=authorization_pending sessions=10 hr_samples=0 workouts=0 hrv_samples=0 sleeps=1 read_hr=1 read_sleep=1 timeout_s=15 action=approve_health_permissions_on_device
2026-06-15 18:50:16.000 Atria[100:200] ATRIADBG launch_exports status=completed rr_reference=0 rr_reference_ui=0 hr_reference=0 hr_reference_ui=0 rr_reference_validation=0 hr_reference_validation=0 reference_clear=0 healthkit=1 healthkit_reference_audit=0 healthkit_reset_rebuild=0 workout_confirm=0 sleep_confirm=1
LOG

./live_device_debug.sh --replay-log "$health_log" --seconds 1 --no-build --healthkit-export --confirm-best-sleep-candidate > "$health_out"

grep -q 'healthkit_export_complete=True' "$health_out"
grep -q 'healthkit_export_authorization_pending_complete=True' "$health_out"
grep -q 'healthkit_sleep_export_deferred_complete=True' "$health_out"
grep -q 'healthkit_export_verify_complete=False' "$health_out"
grep -q 'healthkit_sleep_export_verify_complete=False' "$health_out"

echo "test_live_device_debug_replay.sh: healthkit sleep auth pending pass"
