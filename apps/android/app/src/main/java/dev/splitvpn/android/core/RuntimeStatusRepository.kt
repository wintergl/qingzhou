package dev.splitvpn.android.core

import android.content.Context
import android.content.SharedPreferences
import java.time.Instant

class RuntimeStatusRepository internal constructor(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences("split_vpn_runtime", Context.MODE_PRIVATE))

    fun connectWanted(): Boolean = preferences.getBoolean(KEY_WANTED, get().state in setOf(STATE_STARTING, STATE_CONNECTED, STATE_RECOVERING, STATE_WAITING_NETWORK))
    fun setConnectWanted(wanted: Boolean): Boolean = preferences.edit().putBoolean(KEY_WANTED, wanted).commit()
    fun setAlwaysOn(value: Boolean) { preferences.edit().putBoolean("alwaysOn", value).apply() }
    fun invalidateNetwork() { preferences.edit().putLong("networkEpoch", preferences.getLong("networkEpoch", 0) + 1).apply() }
    fun observe(listener: SharedPreferences.OnSharedPreferenceChangeListener) = preferences.registerOnSharedPreferenceChangeListener(listener)
    fun unobserve(listener: SharedPreferences.OnSharedPreferenceChangeListener) = preferences.unregisterOnSharedPreferenceChangeListener(listener)

    fun get(): RuntimeStatus {
        return RuntimeStatus(
            state = preferences.getString(KEY_STATE, STATE_STOPPED).orEmpty().ifBlank { STATE_STOPPED },
            startedAt = preferences.getString(KEY_STARTED_AT, "").orEmpty(),
            updatedAt = preferences.getString(KEY_UPDATED_AT, "").orEmpty(),
            selectedProxy = preferences.getString(KEY_SELECTED_PROXY, "AUTO").orEmpty().ifBlank { "AUTO" },
            lastError = preferences.getString(KEY_LAST_ERROR, "").orEmpty(),
            controllerAvailable = preferences.getBoolean(KEY_CONTROLLER_AVAILABLE, false),
            tun2socksPid = preferences.getInt(KEY_TUN2SOCKS_PID, 0),
            alwaysOn = preferences.getBoolean("alwaysOn", false),
            networkEpoch = preferences.getLong("networkEpoch", 0),
            retryAt = preferences.getLong("retryAt", 0)
        )
    }

    fun markStarting(selectedProxy: String) {
        val now = now()
        preferences.edit()
            .putString(KEY_STATE, STATE_STARTING)
            .putLong("retryAt", 0)
            .putString(KEY_STARTED_AT, now)
            .putString(KEY_UPDATED_AT, now)
            .putString(KEY_SELECTED_PROXY, selectedProxy.ifBlank { "AUTO" })
            .putString(KEY_LAST_ERROR, "")
            .putBoolean(KEY_CONTROLLER_AVAILABLE, false)
            .putInt(KEY_TUN2SOCKS_PID, 0)
            .apply()
    }

    fun markConnected(selectedProxy: String, tun2socksPid: Int) {
        val current = get()
        val now = now()
        preferences.edit()
            .putString(KEY_STATE, STATE_CONNECTED)
            .putLong("networkEpoch", current.networkEpoch + 1)
            .putString(KEY_STARTED_AT, current.startedAt.ifBlank { now })
            .putString(KEY_UPDATED_AT, now)
            .putString(KEY_SELECTED_PROXY, selectedProxy.ifBlank { "AUTO" })
            .putString(KEY_LAST_ERROR, "")
            .putBoolean(KEY_CONTROLLER_AVAILABLE, true)
            .putInt(KEY_TUN2SOCKS_PID, tun2socksPid)
            .putLong("retryAt", 0)
            .apply()
    }

    fun markRecovering(message: String, selectedProxy: String, delayMs: Long = 0, waitingNetwork: Boolean = false) {
        preferences.edit()
            .putString(KEY_STATE, if (waitingNetwork) STATE_WAITING_NETWORK else STATE_RECOVERING)
            .putString(KEY_UPDATED_AT, now())
            .putString(KEY_SELECTED_PROXY, selectedProxy)
            .putString(KEY_LAST_ERROR, message)
            .putBoolean(KEY_CONTROLLER_AVAILABLE, false)
            .putInt(KEY_TUN2SOCKS_PID, 0)
            .putLong("retryAt", if (delayMs > 0) System.currentTimeMillis() + delayMs else 0)
            .apply()
    }

    fun markStopping() {
        val current = get()
        preferences.edit()
            .putString(KEY_STATE, STATE_STOPPING)
            .putLong("retryAt", 0)
            .putString(KEY_UPDATED_AT, now())
            .putString(KEY_SELECTED_PROXY, current.selectedProxy)
            .apply()
    }

    fun markStopped() {
        val current = get()
        preferences.edit()
            .putString(KEY_STATE, STATE_STOPPED)
            .putLong("networkEpoch", current.networkEpoch + 1)
            .putLong("retryAt", 0)
            .putString(KEY_UPDATED_AT, now())
            .putString(KEY_SELECTED_PROXY, current.selectedProxy)
            .putString(KEY_LAST_ERROR, "")
            .putBoolean(KEY_CONTROLLER_AVAILABLE, false)
            .putInt(KEY_TUN2SOCKS_PID, 0)
            .apply()
    }

    fun markError(message: String, selectedProxy: String = get().selectedProxy) {
        val current = get()
        preferences.edit()
            .putString(KEY_STATE, STATE_ERROR)
            .putLong("retryAt", 0)
            .putString(KEY_STARTED_AT, current.startedAt)
            .putString(KEY_UPDATED_AT, now())
            .putString(KEY_SELECTED_PROXY, selectedProxy.ifBlank { "AUTO" })
            .putString(KEY_LAST_ERROR, message)
            .putBoolean(KEY_CONTROLLER_AVAILABLE, false)
            .putInt(KEY_TUN2SOCKS_PID, 0)
            .apply()
    }

    private fun now(): String = Instant.now().toString()

    companion object {
        const val STATE_STARTING = "starting"
        const val STATE_CONNECTED = "connected"
        const val STATE_STOPPING = "stopping"
        const val STATE_STOPPED = "stopped"
        const val STATE_ERROR = "error"
        const val STATE_RECOVERING = "recovering"
        const val STATE_WAITING_NETWORK = "waiting-network"
        private const val KEY_WANTED = "connectWanted"

        private const val KEY_STATE = "state"
        private const val KEY_STARTED_AT = "startedAt"
        private const val KEY_UPDATED_AT = "updatedAt"
        private const val KEY_SELECTED_PROXY = "selectedProxy"
        private const val KEY_LAST_ERROR = "lastError"
        private const val KEY_CONTROLLER_AVAILABLE = "controllerAvailable"
        private const val KEY_TUN2SOCKS_PID = "tun2socksPid"
    }
}
