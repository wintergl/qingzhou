package dev.splitvpn.android.runtime

enum class ProbeOutcome {
    HEALTHY,
    CONTROLLER_FAILURE,
    EGRESS_FAILURE,
    DNS_FAILURE,
    SKIPPED
}

enum class ProbeFailureKind {
    CONTROLLER,
    DNS,
    EGRESS
}

sealed interface HealthDecision {
    data object None : HealthDecision
    data class RetryAfter(val delayMs: Long) : HealthDecision
    data class Rebuild(val failure: ProbeFailureKind) : HealthDecision
}

/** Controller health is independent; DNS and TLS share one application-path failure budget. */
class HealthProbePolicy(
    private val controllerFailureThreshold: Int = 2,
    private val egressFailureThreshold: Int = 3,
    private val dnsFailureThreshold: Int = 3,
    private val activeRetryMs: Long = 5_000L,
    private val conserveRetryMs: Long = 15_000L
) {
    var controllerFailures: Int = 0
        private set
    var egressFailures: Int = 0
        private set

    private var applicationFailures: Int = 0

    var dnsFailures: Int = 0
        private set

    init {
        require(controllerFailureThreshold > 0)
        require(egressFailureThreshold > 0)
        require(dnsFailureThreshold > 0)
        require(activeRetryMs > 0)
        require(conserveRetryMs > 0)
    }

    fun record(outcome: ProbeOutcome, power: PowerState): HealthDecision {
        return when (outcome) {
            ProbeOutcome.HEALTHY, ProbeOutcome.SKIPPED -> {
                reset()
                HealthDecision.None
            }
            ProbeOutcome.CONTROLLER_FAILURE -> {
                egressFailures = 0
                dnsFailures = 0
                applicationFailures = 0
                controllerFailures++
                if (controllerFailures >= controllerFailureThreshold) {
                    HealthDecision.Rebuild(ProbeFailureKind.CONTROLLER)
                } else {
                    HealthDecision.RetryAfter(retryDelay(power))
                }
            }
            ProbeOutcome.DNS_FAILURE -> {
                controllerFailures = 0
                egressFailures = 0
                dnsFailures++
                applicationFailures++
                if (applicationFailures >= dnsFailureThreshold) {
                    HealthDecision.Rebuild(ProbeFailureKind.DNS)
                } else {
                    HealthDecision.RetryAfter(retryDelay(power))
                }
            }
            ProbeOutcome.EGRESS_FAILURE -> {
                controllerFailures = 0
                dnsFailures = 0
                egressFailures++
                applicationFailures++
                if (applicationFailures >= egressFailureThreshold) {
                    HealthDecision.Rebuild(ProbeFailureKind.EGRESS)
                } else {
                    HealthDecision.RetryAfter(retryDelay(power))
                }
            }
        }
    }

    fun reset() {
        controllerFailures = 0
        egressFailures = 0
        dnsFailures = 0
        applicationFailures = 0
    }

    private fun retryDelay(power: PowerState): Long =
        if (power.conserve) conserveRetryMs else activeRetryMs
}

data class HealthProbeToken(
    val revision: Long,
    val sessionGeneration: Long,
    val network: NetworkState,
    val selectedProxy: String
) {
    fun matches(
        revision: Long,
        sessionGeneration: Long,
        network: NetworkState,
        selectedProxy: String
    ): Boolean = this.revision == revision &&
        this.sessionGeneration == sessionGeneration &&
        this.network == network &&
        this.selectedProxy == selectedProxy
}

fun shouldProbeVpnEgress(selectedProxy: String, power: PowerState): Boolean =
    !power.idle && selectedProxy != "DIRECT"
