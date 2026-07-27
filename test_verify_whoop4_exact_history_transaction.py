import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOL = ROOT / "tools" / "verify_whoop4_exact_history_transaction.py"


class ExactHistoryTransactionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.log = Path(self.scratch.name) / "recovery.log"

    def tearDown(self):
        self.scratch.cleanup()

    @staticmethod
    def valid_trace() -> str:
        identity = (
            "authority_generation=4 attempt=2 transport_generation=9 "
            "request_identifier=request-44"
        )
        return "\n".join([
            "ATRIADBG history_request_authority status=bound reason=acceptance "
            f"{identity} peripheral=strap strap=strap4 start_unix=1800000000 "
            "end_unix=1800000090 source=gap-window-test",
            "ATRIADBG historical_exact_range_write status=confirmed "
            f"{identity} exact_interval_authority=1 selector=verified-test",
            "ATRIADBG history_clock_authority status=verified "
            f"{identity} device_unix=1800000100 wall_unix=1800000101 drift_s=1",
            "ATRIADBG historyDrain status=durable generation=9 "
            'boundary=batch(\"enddata:aabb\") rows_since_ack=90 error=nil',
            "ATRIADBG historyAck status=sending key=enddata:aabb generation=9 "
            "attempt=1 payload=01aabb write_mode=wr",
            "ATRIADBG historyAck status=confirmed key=enddata:aabb generation=9 attempts=1",
            "ATRIADBG historyTerminal status=received sequence=8 generation=9 pending=0 action=reduce",
            "ATRIADBG offline_sync status=complete reason=acceptance_terminal action=preserve_live_connection",
            "ATRIADBG historical_consumers status=committed authority_generation=4 "
            "attempt=2 transport_generation=9 receipts=5 detail=ok raw_retained=1",
        ]) + "\n"

    @staticmethod
    def valid_production_trace() -> str:
        gap = "7f8f3af8-b06a-4f58-a80e-dd211db8470a"
        return "\n".join([
            "ATRIADBG history_request_authority status=candidate_selected "
            f"reason=acceptance detail=full_flash_positive_gap_authority gap={gap} "
            "action=clock_then_drain",
            "ATRIADBG historyRange status=requested generation=9 sequence=4 "
            "payload=00 attempt=1 mutation=0",
            "ATRIADBG historyRange status=write_confirmed generation=9 sequence=4 mutation=0",
            "ATRIADBG historyRange status=observed response_seq=5 request_seq_echo=4 "
            "matched=1 write=800 read=710 capacity=1000 pending=90 mutation=0 payload=aabb",
            "ATRIADBG historyRange status=matched_clock_authority generation=9 "
            "sequence=4 pending=90 device_unix=1800000100 drift_s=1 source=2200",
            "ATRIADBG historyRange status=forward_backlog_available generation=9 "
            "pending=90 action=monotonic_settle_then_1600",
            "ATRIADBG historyRange status=post_response_settle_confirmed generation=9 "
            "settle_s=2.0 clock_source=2200 action=send_verified_1600",
            "ATRIADBG historical_full_drain_write status=confirmed generation=9 "
            "sequence=5 command=1600 exact_interval_authority=0",
            "ATRIADBG historyMeta status=start sequence=6 generation=9",
            "ATRIADBG historical_full_drain_authority status=armed generation=9 "
            f"gap={gap} clock_seq=4 drain_seq=5 history_start_seq=6",
            "ATRIADBG historyDrain status=durable generation=9 "
            'boundary=batch("enddata:aabb") rows_since_ack=90 error=nil',
            "ATRIADBG historyAck status=sending key=enddata:aabb generation=9 "
            "attempt=1 payload=01aabb write_mode=wr",
            "ATRIADBG historyAck status=gatt_confirmed key=enddata:aabb generation=9 "
            "attempt=1 command_seq=7 action=await_logical_0x17",
            "ATRIADBG historyAck status=accepted key=enddata:aabb generation=9 "
            "attempt=1 command_seq=7 proof=confirmed_gatt_write_plus_logical_response "
            "response_seq=8 response=1700",
            "ATRIADBG historyTerminal status=received sequence=9 generation=9 "
            "pending=0 action=reduce",
            "ATRIADBG offline_sync status=complete reason=acceptance_terminal "
            "generation=9 rows=90 new_rows=90 live_restored=1 action=preserve_live_connection",
            "ATRIADBG historical_full_drain_reconcile "
            f"gap={gap} generation=9 status=resolved density=90 maximum_gap=3 p95_gap=1",
            "ATRIADBG historical_full_drain_publish status=resolved generation=9 "
            f"gap={gap} receipts=5",
        ]) + "\n"

    def run_tool(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3", str(TOOL),
                "--recovery-log", str(self.log),
                "--requested-start-unix", "1800000000",
                "--requested-end-unix", "1800000090",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def test_accepts_only_complete_attempt_bound_transaction(self):
        self.log.write_text(self.valid_trace(), encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exact_history_transaction_status=pass", result.stdout)
        self.assertIn("exact_range_write_confirmed=1", result.stdout)
        self.assertIn("clock_authority_verified=1", result.stdout)
        self.assertIn("consumer_receipts=5", result.stdout)
        self.assertIn("blockers=none", result.stdout)

    def test_accepts_actual_production_full_drain_markers_without_claiming_selector(self):
        self.log.write_text(self.valid_production_trace(), encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exact_history_transaction_status=pass", result.stdout)
        self.assertIn("transaction_mode=production_full_drain_gap_bound", result.stdout)
        self.assertIn("requested_bounds_verified=0", result.stdout)
        self.assertIn("exact_range_write_confirmed=0", result.stdout)
        self.assertIn("full_drain_write_confirmed=1", result.stdout)
        self.assertIn("range_sequence=4", result.stdout)
        self.assertIn("clock_authority_verified=1", result.stdout)
        self.assertIn("ack_confirmations=1", result.stdout)
        self.assertIn("consumer_receipts=5", result.stdout)
        self.assertIn("blockers=none", result.stdout)

    def test_accepts_exact_coverage_when_typed_consumers_need_future_context(self):
        gap = "7f8f3af8-b06a-4f58-a80e-dd211db8470a"
        trace = self.valid_production_trace().replace(
            "ATRIADBG historical_full_drain_reconcile "
            f"gap={gap} generation=9 status=resolved density=90 maximum_gap=3 p95_gap=1",
            "ATRIADBG historical_full_drain_coverage status=persisted "
            f"gap={gap} generation=9 observed=90 expected=90 "
            "density=100 maximum_gap=1 p95_gap=1",
        ).replace(
            "ATRIADBG historical_full_drain_publish status=resolved generation=9 "
            f"gap={gap} receipts=5",
            "ATRIADBG historical_full_drain_publish "
            "status=gap_resolved_consumers_pending generation=9 "
            f"gap={gap} required_end=1800003600 receipts=0 raw_retained=1",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exact_history_transaction_status=pass", result.stdout)
        self.assertIn("consumer_receipts=0", result.stdout)
        self.assertIn("blockers=none", result.stdout)

    def test_production_accepts_known_twelve_second_clock_correction(self):
        self.log.write_text(
            self.valid_production_trace().replace("drift_s=1", "drift_s=12"),
            encoding="utf-8",
        )
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("transaction_mode=production_full_drain_gap_bound", result.stdout)
        self.assertIn("clock_drift_s=12.0", result.stdout)
        self.assertIn("blockers=none", result.stdout)

    def test_uses_latest_authority_mode_in_a_multi_transaction_console_log(self):
        trace = self.valid_trace() + self.valid_production_trace()
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("transaction_mode=production_full_drain_gap_bound", result.stdout)
        self.assertIn("gap_identifier=7f8f3af8-b06a-4f58-a80e-dd211db8470a", result.stdout)

    def test_full_dump_and_dense_rows_cannot_substitute_for_exact_authority(self):
        self.log.write_text(
            "ATRIADBG history_request_authority status=deferred "
            "detail=full_dump_has_no_verified_exact_range_acceptance\n"
            "ATRIADBG historical_full_drain_write status=confirmed generation=9 "
            "command=1600 exact_interval_authority=0\n"
            "ATRIADBG historyTerminal status=received sequence=8 generation=9 pending=0\n",
            encoding="utf-8",
        )
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing_exact_request_authority_binding", result.stdout)
        self.assertIn("missing_confirmed_exact_range_write", result.stdout)
        self.assertIn("missing_attempt_bound_clock_authority", result.stdout)

    def test_rejects_ack_before_matching_fsync(self):
        trace = self.valid_trace()
        durable = (
            "ATRIADBG historyDrain status=durable generation=9 "
            'boundary=batch(\"enddata:aabb\") rows_since_ack=90 error=nil\n'
        )
        trace = trace.replace(durable, "").replace(
            "ATRIADBG historyAck status=confirmed key=enddata:aabb generation=9 attempts=1\n",
            "ATRIADBG historyAck status=confirmed key=enddata:aabb generation=9 attempts=1\n" + durable,
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ack_sent_before_matching_fsync:enddata:aabb", result.stdout)

    def test_rejects_cross_generation_clock_or_consumer_evidence(self):
        trace = self.valid_trace().replace(
            "ATRIADBG history_clock_authority status=verified authority_generation=4 "
            "attempt=2 transport_generation=9",
            "ATRIADBG history_clock_authority status=verified authority_generation=4 "
            "attempt=2 transport_generation=10",
        ).replace(
            "historical_consumers status=committed authority_generation=4 attempt=2 "
            "transport_generation=9",
            "historical_consumers status=committed authority_generation=4 attempt=2 "
            "transport_generation=10",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("clock_transport_generation_mismatch", result.stdout)
        self.assertIn("consumer_transport_generation_mismatch", result.stdout)

    def test_rejects_prefix_token_fsync_substitution(self):
        trace = self.valid_trace().replace(
            'boundary=batch(\"enddata:aabb\")',
            'boundary=batch(\"enddata:aabbcc\")',
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ack_sent_before_matching_fsync:enddata:aabb", result.stdout)

    def test_rejects_failed_or_nonterminal_completion_even_with_later_markers(self):
        trace = self.valid_trace().replace(
            "ATRIADBG historyTerminal status=received sequence=8 generation=9 pending=0 action=reduce\n",
            "ATRIADBG historyTerminal status=received sequence=8 generation=9 pending=0 action=reduce\n"
            "ATRIADBG historyDrain status=failed generation=9 "
            "failure=durableFlush action=retain_gap_and_retry\n",
        ).replace(
            "reason=acceptance_terminal action=preserve_live_connection",
            "reason=acceptance_drain_failed action=preserve_live_connection",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("history_drain_failed", result.stdout)
        self.assertIn("offline_sync_completion_not_terminal", result.stdout)

    def test_rejects_partial_consumer_receipt_set(self):
        trace = self.valid_trace().replace("receipts=5", "receipts=1")
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("verified_consumer_receipt_set_incomplete", result.stdout)

    def test_production_rejects_cross_sequence_range_clock_or_drain_authority(self):
        trace = self.valid_production_trace().replace(
            "clock_seq=4 drain_seq=5 history_start_seq=6",
            "clock_seq=3 drain_seq=8 history_start_seq=2",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("full_drain_clock_sequence_mismatch", result.stdout)
        self.assertIn("full_drain_command_sequence_mismatch", result.stdout)
        self.assertIn("full_drain_history_start_sequence_mismatch", result.stdout)

    def test_production_rejects_ack_acceptance_without_matching_attempt_or_proof(self):
        trace = self.valid_production_trace().replace(
            "status=accepted key=enddata:aabb generation=9 attempt=1 command_seq=7 "
            "proof=confirmed_gatt_write_plus_logical_response",
            "status=accepted key=enddata:aabb generation=9 attempt=2 command_seq=7 "
            "proof=unverified",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ack_not_confirmed_after_send:enddata:aabb", result.stdout)

    def test_production_rejects_matching_ack_with_unverified_acceptance_proof(self):
        trace = self.valid_production_trace().replace(
            "proof=confirmed_gatt_write_plus_logical_response",
            "proof=unverified",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ack_acceptance_proof_invalid:enddata:aabb", result.stdout)

    def test_production_accepts_write_callback_after_correlated_history_start(self):
        trace = self.valid_production_trace()
        full_write = (
            "ATRIADBG historical_full_drain_write status=confirmed generation=9 "
            "sequence=5 command=1600 exact_interval_authority=0\n"
        )
        history_start = "ATRIADBG historyMeta status=start sequence=6 generation=9\n"
        trace = trace.replace(full_write + history_start, history_start + full_write)
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("blockers=none", result.stdout)

    def test_production_accepts_range_response_before_matching_write_callback(self):
        trace = self.valid_production_trace()
        write = (
            "ATRIADBG historyRange status=write_confirmed generation=9 sequence=4 mutation=0\n"
        )
        response = (
            "ATRIADBG historyRange status=observed response_seq=5 request_seq_echo=4 "
            "matched=1 write=800 read=710 capacity=1000 pending=90 mutation=0 payload=aabb\n"
        )
        trace = trace.replace(write + response, response + write)
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("blockers=none", result.stdout)

    def test_production_rejects_weak_gap_resolution_or_mismatched_consumer_gap(self):
        trace = self.valid_production_trace().replace(
            "status=resolved density=90 maximum_gap=3 p95_gap=1",
            "status=resolved density=89 maximum_gap=4 p95_gap=2",
        ).replace(
            "status=resolved generation=9 gap=7f8f3af8-b06a-4f58-a80e-dd211db8470a receipts=5",
            "status=resolved generation=9 gap=ffffffff-ffff-ffff-ffff-ffffffffffff receipts=5",
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("resolved_gap_density_below_90_percent", result.stdout)
        self.assertIn("resolved_gap_maximum_gap_over_3s", result.stdout)
        self.assertIn("resolved_gap_p95_gap_over_1s", result.stdout)
        self.assertIn("missing_committed_verified_consumers", result.stdout)

    def test_production_rejects_full_drain_authority_without_matching_gap_selection(self):
        trace = self.valid_production_trace().replace(
            "status=candidate_selected",
            "status=raw_only_no_closed_gap",
            1,
        )
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing_matching_gap_candidate_selection", result.stdout)

    def test_rejects_nonfinite_verification_thresholds(self):
        self.log.write_text(self.valid_production_trace().replace(
            "drift_s=1", "drift_s=999999999"
        ), encoding="utf-8")
        result = subprocess.run(
            [
                "python3", str(TOOL),
                "--recovery-log", str(self.log),
                "--requested-start-unix", "1800000000",
                "--requested-end-unix", "1800000090",
                "--maximum-production-clock-drift-seconds", "nan",
            ],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid_maximum_production_clock_drift_seconds", result.stdout)

    def test_production_cannot_borrow_batch_and_terminal_before_authority(self):
        trace = self.valid_production_trace()
        authority = (
            "ATRIADBG historical_full_drain_authority status=armed generation=9 "
            "gap=7f8f3af8-b06a-4f58-a80e-dd211db8470a clock_seq=4 "
            "drain_seq=5 history_start_seq=6\n"
        )
        first_batch = trace.index("ATRIADBG historyDrain status=durable")
        completion = trace.index("ATRIADBG offline_sync status=complete")
        batch = trace[first_batch:completion]
        trace = trace[:first_batch] + trace[completion:]
        trace = trace.replace(authority, batch + authority)
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing_generation_matching_history_complete", result.stdout)
        self.assertIn("missing_durable_archive_flush", result.stdout)
        self.assertIn("missing_history_ack_send", result.stdout)

    def test_production_rejects_resolution_and_publication_before_terminal(self):
        trace = self.valid_production_trace()
        reconcile = (
            "ATRIADBG historical_full_drain_reconcile "
            "gap=7f8f3af8-b06a-4f58-a80e-dd211db8470a generation=9 "
            "status=resolved density=90 maximum_gap=3 p95_gap=1\n"
        )
        publish = (
            "ATRIADBG historical_full_drain_publish status=resolved generation=9 "
            "gap=7f8f3af8-b06a-4f58-a80e-dd211db8470a receipts=5\n"
        )
        terminal = (
            "ATRIADBG historyTerminal status=received sequence=9 generation=9 "
            "pending=0 action=reduce\n"
        )
        trace = trace.replace(reconcile, "").replace(publish, "")
        trace = trace.replace(terminal, reconcile + publish + terminal)
        self.log.write_text(trace, encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("gap_coverage_resolved_before_history_terminal", result.stdout)
        self.assertIn("consumers_committed_before_history_terminal", result.stdout)


if __name__ == "__main__":
    unittest.main()
