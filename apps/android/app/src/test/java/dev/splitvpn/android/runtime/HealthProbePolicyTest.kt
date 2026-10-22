package dev.splitvpn.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthProbePolicyTest {
    private val active = PowerState(interactive = true)

    @Test fun controllerNeedsTwoConsecutiveFailures() {
        val policy = HealthProbePolicy()
        assertEquals(HealthDecision.RetryAfter(5_000L),
            policy.record(ProbeOutcome.CONTROLLER_FAILURE, active))
        assertEquals(HealthDecision.Rebuild(ProbeFailureKind.CONTROLLER),
            policy.record(ProbeOutcome.CONTROLLER_FAILURE, active))
    }

    @Test fun egressNeedsThreeConsecutiveFailures() {
        val policy = HealthProbePolicy()
        assertEquals(HealthDecision.RetryAfter(5_000L),
            policy.record(ProbeOutcome.EGRESS_FAILURE, active))
        assertEquals(HealthDecision.RetryAfter(5_000L),
            policy.record(ProbeOutcome.EGRESS_FAILURE, active))
        assertEquals(HealthDecision.Rebuild(ProbeFailureKind.EGRESS),
            policy.record(ProbeOutcome.EGRESS_FAILURE, active))
    }

    @Test fun healthyAndSkippedOutcomesResetBothFailureStreaks() {
        for (reset in listOf(ProbeOutcome.HEALTHY, ProbeOutcome.SKIPPED)) {
            val policy = HealthProbePolicy()
            policy.record(ProbeOutcome.CONTROLLER_FAILURE, active)
            policy.record(ProbeOutcome.EGRESS_FAILURE, active)
            assertEquals(HealthDecision.None, policy.record(reset, active))
            assertEquals(0, policy.controllerFailures)
            assertEquals(0, policy.egressFailures)
        }
    }

    @Test fun controllerAndEgressFailuresDoNotCombine() {
        val policy = HealthProbePolicy()
        policy.record(ProbeOutcome.CONTROLLER_FAILURE, active)
        policy.record(ProbeOutcome.EGRESS_FAILURE, active)
        assertEquals(0, policy.controllerFailures)
        assertEquals(1, policy.egressFailures)
        assertEquals(HealthDecision.RetryAfter(5_000L),
            policy.record(ProbeOutcome.CONTROLLER_FAILURE, active))
    }

    @Test fun retrySlowsDownWhileConservingPower() {
        val policy = HealthProbePolicy()
        assertEquals(HealthDecision.RetryAfter(15_000L),
            policy.record(ProbeOutcome.EGRESS_FAILURE, PowerState(interactive = false)))
    }

    @Test fun directAndDozeSkipTheRemoteProbe() {
        assertFalse(shouldProbeVpnEgress("DIRECT", active))
        assertFalse(shouldProbeVpnEgress("AUTO", PowerState(idle = true)))
        assertTrue(shouldProbeVpnEgress("AUTO", active))
        assertTrue(shouldProbeVpnEgress("节点 A", active))
    }

    @Test fun resultTokenRejectsOldLifecycleSessionNetworkAndSelection() {
        val network = NetworkState(true, "wifi|address|route|dns")
        val token = HealthProbeToken(4, 7, network, "AUTO")
        assertTrue(token.matches(4, 7, network, "AUTO"))
        assertFalse(token.matches(5, 7, network, "AUTO"))
        assertFalse(token.matches(4, 8, network, "AUTO"))
        assertFalse(token.matches(4, 7, network.copy(signature = "mobile"), "AUTO"))
        assertFalse(token.matches(4, 7, network, "DIRECT"))
    }
}
