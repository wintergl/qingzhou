package dev.splitvpn.android.core

/** Merge only requests already awaiting recovery; never cache a healthy path. */
class RecoveryEventCoalescer {
    private var generation = 0L
    private var pendingKey: String? = null

    @Synchronized fun request(key: String): Long? {
        if (pendingKey == key) return null
        pendingKey = key
        return ++generation
    }

    @Synchronized fun finish(token: Long?) {
        if (token == generation) pendingKey = null
    }

    @Synchronized fun reset() {
        generation++
        pendingKey = null
    }
}
