package dev.splitvpn.android.runtime

import org.junit.Assert.*
import org.junit.Test

class RecoveryPolicyTest {
    @Test fun repeatedFailuresBackOffAndStayBounded() {
        val policy = RecoveryPolicy()
        assertEquals(listOf(2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 60_000L, 60_000L),
            (1..7).map { policy.failed(it * 10_000L, PowerState()) })
        repeat(100) { assertEquals(60_000L, policy.failed(100_000L, PowerState())) }
    }

    @Test fun brieflySuccessfulCrashLoopDoesNotResetBackoff() {
        val policy = RecoveryPolicy()
        policy.failed(0, PowerState())
        policy.connected(5_000L)
        assertEquals(5_000L, policy.failed(6_000L, PowerState()))
        policy.connected(10_000L)
        assertEquals(10_000L, policy.failed(20_000L, PowerState()))
    }

    @Test fun stableConnectionResetsBackoff() {
        val policy = RecoveryPolicy()
        repeat(8) { policy.failed(0, PowerState()) }
        policy.connected(10_000L)
        assertEquals(2_000L, policy.failed(70_000L, PowerState()))
    }

    @Test fun networkChangeOrExplicitRetryCanStartFresh() {
        val policy = RecoveryPolicy()
        repeat(8) { policy.failed(0, PowerState()) }
        policy.reset()
        assertEquals(0, policy.failures)
        assertEquals(2_000L, policy.failed(0, PowerState()))
    }

    @Test fun batterySaverAndScreenOffKeepFastInitialRecoveryThenSlowDown() {
        for (power in listOf(PowerState(interactive = false), PowerState(lowPower = true), PowerState(idle = true))) {
            val policy = RecoveryPolicy()
            assertEquals(2_000L, policy.failed(0, power))
            repeat(3) { policy.failed(0, power) }
            assertEquals(120_000L, policy.failed(0, power))
        }
    }

    @Test fun healthChecksSlowDownInBackgroundAndDoze() {
        assertEquals(30_000L, PowerState(uiVisible = true).healthIntervalMs)
        assertEquals(60_000L, PowerState().healthIntervalMs)
        assertEquals(120_000L, PowerState(interactive = false).healthIntervalMs)
        assertEquals(120_000L, PowerState(lowPower = true, uiVisible = true).healthIntervalMs)
        assertEquals(180_000L, PowerState(idle = true).healthIntervalMs)
    }

    @Test fun disconnectInvalidatesEveryPendingRetry() {
        val gate = LifecycleGate()
        val start = gate.start()
        val retry = gate.advance(start)!!
        val stop = gate.stop()
        assertFalse(gate.accepts(start))
        assertFalse(gate.accepts(retry))
        assertNull(gate.advance(retry))
        assertEquals(stop, gate.revision) // Late failure must not cancel the queued stop.
        assertFalse(gate.wanted)
    }

    @Test fun oldNetworkAndProcessCallbacksCannotReplaceTheNewConnection() {
        val gate = LifecycleGate()
        val old = gate.start()
        val changed = gate.change()
        assertNull(gate.advance(old))
        assertTrue(gate.accepts(changed))
        gate.stop()
        val restarted = gate.start()
        assertFalse(gate.accepts(changed))
        assertNull(gate.advance(changed))
        assertTrue(gate.accepts(restarted))
    }

    @Test fun onlyOneFailureCanScheduleRecoveryForTheSameConnection() {
        val gate = LifecycleGate()
        val session = gate.start()
        assertNotNull(gate.advance(session))
        assertNull(gate.advance(session))
    }

    private val wifi = PhysicalPath(1, "wifi|10.0.0.8|default|dns", validated = true, preference = 2)
    private val mobile = PhysicalPath(2, "mobile", validated = true, preference = 1)
    private val vpn = PhysicalPath(3, "tun", vpn = true, preference = 9)

    @Test fun ourOwnVpnDoesNotBecomeThePhysicalDefault() {
        assertEquals(NetworkState.select(listOf(wifi, mobile), 1), NetworkState.select(listOf(wifi, mobile, vpn), 3))
        assertEquals(NetworkState.select(listOf(wifi, mobile), 1), NetworkState.select(listOf(wifi, mobile, vpn.copy(id = 99)), 99))
    }

    @Test fun switchWifiToMobileOrDefaultRouteChangesIdentity() {
        val before = NetworkState.select(listOf(wifi, mobile), 1)
        val after = NetworkState.select(listOf(mobile), 2)
        assertTrue(before.available == true && after.available == true)
        assertNotEquals(before, after)
        assertNotEquals(before, NetworkState.select(listOf(wifi, mobile), 2))
    }

    @Test fun addressGatewayAndDnsChangesTriggerRecoveryOnTheSameInterface() {
        val before = NetworkState.select(listOf(wifi), 1)
        for (signature in listOf("wifi|10.0.0.9|default|dns", "wifi|10.0.0.8|new-gateway|dns", "wifi|10.0.0.8|default|new-dns")) {
            assertNotEquals(before, NetworkState.select(listOf(wifi.copy(signature = signature)), 1))
        }
    }

    @Test fun duplicateCallbacksAndUnrelatedInterfacesDoNotTriggerRecovery() {
        val before = NetworkState.select(listOf(wifi, mobile), 1)
        assertEquals(before, NetworkState.select(listOf(mobile.copy(signature = "other"), vpn, wifi), 1))
    }

    @Test fun lossOfAllPhysicalNetworksWaitsEvenIfVpnIsStillListed() {
        assertEquals(NetworkState(false), NetworkState.select(listOf(vpn), 3))
        assertEquals(NetworkState(false), NetworkState.select(listOf(wifi.copy(internet = false)), 1))
        assertNotEquals(NetworkState.Unknown, NetworkState(false))
    }

    @Test fun validatedBackupIsPreferredWhenDefaultIsVpn() {
        assertEquals(NetworkState.select(listOf(mobile), 2),
            NetworkState.select(listOf(wifi.copy(validated = false), mobile, vpn), 3))
    }
}
