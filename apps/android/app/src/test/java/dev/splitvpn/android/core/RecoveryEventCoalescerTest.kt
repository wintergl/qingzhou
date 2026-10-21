package dev.splitvpn.android.core

import org.junit.Assert.*
import org.junit.Test

class RecoveryEventCoalescerTest {
    @Test fun duplicateEventsDoNotQueueAnotherRecovery() {
        val events = RecoveryEventCoalescer()
        assertNotNull(events.request("wifi-a"))
        repeat(20) { assertNull(events.request("wifi-a")) }
    }

    @Test fun aNewNetworkIsNeverBlockedByTheOldAttempt() {
        val events = RecoveryEventCoalescer()
        val old = events.request("wifi-a")!!
        val next = events.request("wifi-b")!!
        events.finish(old)
        assertNull(events.request("wifi-b"))
        events.finish(next)
        assertNotNull(events.request("wifi-b"))
    }

    @Test fun returningToTheOriginalNetworkStillRequiresRecovery() {
        val events = RecoveryEventCoalescer()
        val first = events.request("wifi-a")!!
        events.request("wifi-b")
        val returning = events.request("wifi-a")!!
        events.finish(first)
        assertNull(events.request("wifi-a"))
        events.finish(returning)
        assertNotNull(events.request("wifi-a"))
    }

    @Test fun anotherDozeExitAfterSuccessStillRebuilds() {
        val events = RecoveryEventCoalescer()
        val token = events.request("wifi-a")!!
        events.finish(token)
        assertNotNull(events.request("wifi-a"))
    }

    @Test fun stopOrNewSessionInvalidatesLateCompletion() {
        val events = RecoveryEventCoalescer()
        val old = events.request("wifi-a")!!
        events.reset()
        assertNotNull(events.request("wifi-a"))
        events.finish(old)
        assertNull(events.request("wifi-a"))
    }
}
