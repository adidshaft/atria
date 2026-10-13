package com.adidshaft.atria.ble

import com.adidshaft.atria.protocol.Cmd
import com.adidshaft.atria.protocol.HistoricalRecord
import com.adidshaft.atria.protocol.HistoryCursorRange
import com.adidshaft.atria.protocol.HistoryMarker

/**
 * Oldest-first, persist-before-ACK drain of the strap's banked history.
 *
 *   22/00 GET_DATA_RANGE → pending > 0 ?
 *   16/00 SEND_HISTORICAL_DATA → 31·START, 2F rows…, 31·END(token)
 *   persist rows durably → 17 (01+token) ACK → next 16/00 … until 31·COMPLETE
 *
 * The strap does not start the next page by itself after the ACK, and a page
 * is only acknowledged after its rows are durable, so a dropped link replays
 * the same page instead of losing it (the iOS "persist-before-ACK" rule).
 * WHOOP 4.0 has no seek: the drain always resumes from the strap read cursor.
 */
class HistoryDrain(
    private val maxPagesPerSlice: Int = 400,
) {
    sealed interface Action {
        data class Send(val command: Int, val payload: ByteArray) : Action
        data class Persist(val records: List<HistoricalRecord>, val then: Action) : Action
        data class Finished(val reason: String, val pages: Int, val rows: Int) : Action
    }

    enum class Phase { IDLE, AWAITING_RANGE, AWAITING_START, RECEIVING, AWAITING_PERSIST, DONE }

    var phase = Phase.IDLE
        private set
    var pages = 0
        private set
    var rows = 0
        private set
    var pendingAtStart: Long? = null
        private set
    var lastRange: HistoryCursorRange? = null
        private set
    private val page = ArrayList<HistoricalRecord>()
    var lastActivityMs = 0L
        private set

    val isActive get() = phase != Phase.IDLE && phase != Phase.DONE

    fun start(nowMs: Long): Action {
        pages = 0; rows = 0; page.clear(); pendingAtStart = null
        phase = Phase.AWAITING_RANGE
        lastActivityMs = nowMs
        return Action.Send(Cmd.GET_DATA_RANGE, byteArrayOf(0x00))
    }

    fun onRange(range: HistoryCursorRange, nowMs: Long): Action? {
        if (phase != Phase.AWAITING_RANGE) { lastRange = range; return null }
        lastRange = range
        lastActivityMs = nowMs
        if (pendingAtStart == null) pendingAtStart = range.pendingRecords
        if (range.pendingRecords == 0L) return finish("caught_up")
        phase = Phase.AWAITING_START
        return Action.Send(Cmd.SEND_HISTORICAL_DATA, byteArrayOf(0x00))
    }

    fun onRecord(record: HistoricalRecord, nowMs: Long) {
        if (phase != Phase.RECEIVING && phase != Phase.AWAITING_START) return
        phase = Phase.RECEIVING
        lastActivityMs = nowMs
        page += record
    }

    fun onMarker(marker: HistoryMarker, nowMs: Long): Action? {
        lastActivityMs = nowMs
        return when (marker) {
            is HistoryMarker.Start -> { if (phase == Phase.AWAITING_START) phase = Phase.RECEIVING; null }
            is HistoryMarker.End -> {
                if (phase != Phase.RECEIVING && phase != Phase.AWAITING_START) return null
                val records = page.toList(); page.clear()
                pages++; rows += records.size
                phase = Phase.AWAITING_PERSIST
                val next: Action = Action.Send(Cmd.HISTORICAL_DATA_RESULT, marker.ackPayload)
                Action.Persist(records, next)
            }
            is HistoryMarker.Complete -> {
                val records = page.toList(); page.clear()
                if (records.isNotEmpty()) { rows += records.size; Action.Persist(records, finish("complete")) } else finish("complete")
            }
        }
    }

    /** Called after the persist + ACK write both succeeded: request the next page. */
    fun onAckDelivered(nowMs: Long): Action {
        lastActivityMs = nowMs
        if (pages >= maxPagesPerSlice) return finish("slice_budget")
        phase = Phase.AWAITING_START
        return Action.Send(Cmd.SEND_HISTORICAL_DATA, byteArrayOf(0x00))
    }

    /** No traffic for too long: end the slice without ACKing the partial page (it will replay). */
    fun onTimeout(nowMs: Long, idleLimitMs: Long = 20_000): Action? {
        if (!isActive || nowMs - lastActivityMs < idleLimitMs) return null
        page.clear()
        return finish(if (rows == 0) "no_rows_timeout" else "idle_timeout")
    }

    fun abort(reason: String): Action.Finished { page.clear(); return finish(reason) }

    private fun finish(reason: String): Action.Finished {
        phase = Phase.DONE
        return Action.Finished(reason, pages, rows)
    }
}
