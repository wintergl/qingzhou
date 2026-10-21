package dev.splitvpn.android.runtime

/** Android service lifecycle policy. Parsing, routing and config remain in Rust. */
class RecoveryPolicy {
    var failures: Int = 0
        private set
    private var connectedAt: Long? = null

    fun connected(now: Long) { connectedAt = now }
    fun reset() { failures = 0; connectedAt = null }

    fun failed(now: Long, power: PowerState): Long {
        // A short-lived successful start must not reset a crash loop to two seconds.
        if (connectedAt?.let { now - it >= 60_000L } == true) failures = 0
        connectedAt = null
        failures = (failures + 1).coerceAtMost(30)
        val normal = when (failures) {
            1 -> 2_000L
            2 -> 5_000L
            3 -> 10_000L
            4 -> 20_000L
            5 -> 30_000L
            else -> 60_000L
        }
        return if (power.conserve && failures >= 5) 120_000L else normal
    }
}

data class PowerState(val interactive: Boolean = true, val lowPower: Boolean = false,
                      val idle: Boolean = false, val uiVisible: Boolean = false) {
    val conserve: Boolean get() = !interactive || lowPower || idle
    // Process exit watchers do not poll. This is only a controller-health fallback.
    val healthIntervalMs: Long get() = when {
        idle -> 180_000L
        conserve -> 120_000L
        !uiVisible -> 60_000L
        else -> 30_000L
    }
}

data class PhysicalPath(val id: Long, val signature: String, val vpn: Boolean = false,
                        val internet: Boolean = true, val validated: Boolean = false,
                        val preference: Int = 0)

data class NetworkState(val available: Boolean?, val signature: String = "") {
    companion object {
        val Unknown = NetworkState(null)
        fun select(paths: List<PhysicalPath>, defaultId: Long?): NetworkState {
            val physical = paths.filter { !it.vpn && it.internet }
            val chosen = physical.firstOrNull { it.id == defaultId }
                ?: physical.sortedWith(compareByDescending<PhysicalPath> { it.validated }
                    .thenByDescending { it.preference }.thenBy { it.id }).firstOrNull()
            return chosen?.let { NetworkState(true, "${it.id}:${it.signature}") } ?: NetworkState(false)
        }
    }
}

/** Cancellation tokens also cover callbacks from an old child or service session. */
class LifecycleGate {
    @Volatile var revision: Long = 0
        private set
    @Volatile var wanted: Boolean = false
        private set
    @Synchronized fun start(): Long { wanted = true; return ++revision }
    @Synchronized fun change(): Long = ++revision
    @Synchronized fun advance(token: Long): Long? = if (accepts(token)) ++revision else null
    @Synchronized fun stop(): Long { wanted = false; return ++revision }
    fun accepts(token: Long): Boolean = wanted && revision == token
}
