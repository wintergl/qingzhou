package dev.splitvpn.android.core

import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Test

class RuntimeStatusRepositoryTest {
    @Test fun recreationPreservesIntentDuringRecoveryAndOfflineWait() {
        val prefs = MemoryPreferences()
        val runtime = RuntimeStatusRepository(prefs)
        runtime.setConnectWanted(true)
        runtime.markConnected("fixture", 123)
        runtime.markRecovering("waiting", "fixture", waitingNetwork = true)
        val recreated = RuntimeStatusRepository(prefs)
        assertTrue(recreated.connectWanted())
        assertEquals(RuntimeStatusRepository.STATE_WAITING_NETWORK, recreated.get().state)
        assertEquals(0, recreated.get().tun2socksPid)
        assertFalse(recreated.get().controllerAvailable)
        assertEquals(0L, recreated.get().retryAt)
    }

    @Test fun explicitDisconnectBeatsStaleStatusAndSurvivesRecreation() {
        val prefs = MemoryPreferences()
        val runtime = RuntimeStatusRepository(prefs)
        runtime.setConnectWanted(true)
        runtime.markStarting("fixture")
        runtime.setConnectWanted(false)
        runtime.markRecovering("old callback", "fixture", 2_000L)
        assertFalse(RuntimeStatusRepository(prefs).connectWanted())
        runtime.markStopped()
        assertFalse(RuntimeStatusRepository(prefs).connectWanted())
        assertEquals(0L, runtime.get().retryAt)
    }

    @Test fun upgradeInfersOldRunningStateUntilAnExplicitIntentIsStored() {
        val prefs = MemoryPreferences()
        prefs.edit().putString("state", "connected").commit()
        val runtime = RuntimeStatusRepository(prefs)
        assertTrue(runtime.connectWanted())
        runtime.setConnectWanted(false)
        assertFalse(runtime.connectWanted())
        assertFalse(RuntimeStatusRepository(MemoryPreferences()).connectWanted())
    }

    @Test fun newConnectionAndStopInvalidateOldMeasurementsAndRetryTime() {
        val runtime = RuntimeStatusRepository(MemoryPreferences())
        runtime.markRecovering("retry", "fixture", 60_000L)
        assertTrue(runtime.get().retryAt > System.currentTimeMillis())
        val epoch = runtime.get().networkEpoch
        runtime.markConnected("fixture", 123)
        assertTrue(runtime.get().networkEpoch > epoch)
        assertEquals(0L, runtime.get().retryAt)
        runtime.markStopped()
        assertEquals(epoch + 2, runtime.get().networkEpoch)
    }

    @Test fun statusChangesNotifyTheUiWithoutPolling() {
        val runtime = RuntimeStatusRepository(MemoryPreferences())
        val keys = mutableSetOf<String>()
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key -> key?.let { keys.add(it) }; Unit }
        runtime.observe(listener)
        runtime.markRecovering("retry", "fixture", 5_000L)
        assertTrue(keys.contains("state"))
        runtime.unobserve(listener)
        keys.clear()
        runtime.markConnected("fixture", 123)
        assertTrue(keys.isEmpty())
    }
}

/** Storage contract fixture; exercises the real repository without a phone or VPN. */
private class MemoryPreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()
    private val listeners = mutableSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()
    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String?, defValue: String?) = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?) = values[key] as? MutableSet<String> ?: defValues
    override fun getInt(key: String?, defValue: Int) = values[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long) = values[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float) = values[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean) = values[key] as? Boolean ?: defValue
    override fun contains(key: String?) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) { listeners.add(listener) }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) { listeners.remove(listener) }
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private var clear = false
        private fun put(key: String?, value: Any?): SharedPreferences.Editor { pending[requireNotNull(key)] = value; return this }
        override fun putString(key: String?, value: String?) = put(key, value)
        override fun putStringSet(key: String?, values: MutableSet<String>?) = put(key, values)
        override fun putInt(key: String?, value: Int) = put(key, value)
        override fun putLong(key: String?, value: Long) = put(key, value)
        override fun putFloat(key: String?, value: Float) = put(key, value)
        override fun putBoolean(key: String?, value: Boolean) = put(key, value)
        override fun remove(key: String?) = put(key, null)
        override fun clear(): SharedPreferences.Editor { clear = true; return this }
        override fun commit(): Boolean {
            if (clear) values.clear()
            pending.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
            pending.keys.forEach { key -> listeners.forEach { it.onSharedPreferenceChanged(this@MemoryPreferences, key) } }
            return true
        }
        override fun apply() { commit() }
    }
}
