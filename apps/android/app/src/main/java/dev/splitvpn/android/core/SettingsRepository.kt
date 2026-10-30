package dev.splitvpn.android.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class SettingsRepository(context: Context) {
    private val preferences = context.getSharedPreferences("split_vpn_settings", Context.MODE_PRIVATE)
    private val vault = SecureVault(context)

    init {
        if (!preferences.contains(KEY_RULES)) setVpnDomainRules(DefaultRules.openAiChatGptVpnRules)
        if (!preferences.contains(KEY_UNKNOWN_TRAFFIC)) preferences.edit().putString(KEY_UNKNOWN_TRAFFIC, "vpn").apply()
        if (!preferences.contains(KEY_SELECTED_PROXY)) preferences.edit().putString(KEY_SELECTED_PROXY, "AUTO").apply()
        if (!preferences.contains(KEY_BLOCK_HIGH_RISK)) preferences.edit().putBoolean(KEY_BLOCK_HIGH_RISK, false).apply()
        migrateDefaults()
    }

    fun getUnknownTraffic(): String {
        val value = preferences.getString(KEY_UNKNOWN_TRAFFIC, "vpn") ?: "vpn"
        return if (value == "vpn") "vpn" else "direct"
    }

    fun setUnknownTraffic(value: String) {
        preferences.edit().putString(KEY_UNKNOWN_TRAFFIC, if (value == "vpn") "vpn" else "direct").apply()
    }

    fun getSelectedProxy(): String = preferences.getString(KEY_SELECTED_PROXY, "AUTO") ?: "AUTO"

    fun setSelectedProxy(value: String) {
        preferences.edit().putString(KEY_SELECTED_PROXY, value).apply()
    }

    fun getBlockHighRisk(): Boolean = preferences.getBoolean(KEY_BLOCK_HIGH_RISK, false)

    fun setBlockHighRisk(value: Boolean) {
        preferences.edit().putBoolean(KEY_BLOCK_HIGH_RISK, value).apply()
    }

    fun getIpdataApiKey(): String {
        vault.load("ipdata")?.let { return it }
        val legacy = preferences.getString(KEY_IPDATA_API_KEY, "").orEmpty()
        if (legacy.isNotEmpty()) { vault.save("ipdata", legacy); preferences.edit().remove(KEY_IPDATA_API_KEY).apply() }
        return legacy
    }

    fun setIpdataApiKey(value: String) {
        vault.save("ipdata", value.trim().takeIf { it.isNotEmpty() })
        preferences.edit().remove(KEY_IPDATA_API_KEY).apply()
    }

    fun getStaticExitCredential(): JSONObject? = vault.load("static-exit")?.let(::JSONObject)
    fun setStaticExitCredential(value: JSONObject?) = vault.save("static-exit", value?.toString())
    fun corePreferences(): JSONObject = runCatching { JSONObject(preferences.getString("corePreferences", "{}").orEmpty()) }.getOrDefault(JSONObject())
    fun syncFromCore(value: JSONObject) {
        preferences.edit().putString("corePreferences", value.toString())
            .putString(KEY_SELECTED_PROXY, value.optString("selectedProxy", getSelectedProxy()))
            .putString(KEY_UNKNOWN_TRAFFIC, value.optString("unknownTraffic", getUnknownTraffic()))
            .putString(KEY_RULES, (value.optJSONArray("vpnDomainRules") ?: JSONArray(getVpnDomainRules())).toString()).apply()
    }

    fun getVpnDomainRules(): List<String> {
        val raw = preferences.getString(KEY_RULES, "[]") ?: "[]"
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val rule = array.optString(index).trim()
                    if (rule.isNotEmpty()) add(rule)
                }
            }
        }.getOrElse { DefaultRules.openAiChatGptVpnRules }
    }

    fun setVpnDomainRules(rules: List<String>) {
        val array = JSONArray()
        rules.map { VpnRuleFormatter.normalize(it) }
            .filter { it.isNotEmpty() }
            .distinct()
            .forEach { array.put(it) }
        preferences.edit().putString(KEY_RULES, array.toString()).apply()
    }

    fun addVpnRule(rule: String) {
        val normalized = VpnRuleFormatter.normalize(rule)
        if (normalized.isEmpty()) return
        setVpnDomainRules(getVpnDomainRules() + normalized)
    }

    fun deleteVpnRule(rule: String) {
        setVpnDomainRules(getVpnDomainRules().filterNot { it == rule })
    }

    private companion object {
        const val CURRENT_SETTINGS_VERSION = 7
        const val KEY_SETTINGS_VERSION = "settingsVersion"
        const val KEY_UNKNOWN_TRAFFIC = "unknownTraffic"
        const val KEY_SELECTED_PROXY = "selectedProxy"
        const val KEY_RULES = "vpnDomainRules"
        const val KEY_BLOCK_HIGH_RISK = "blockHighRisk"
        const val KEY_IPDATA_API_KEY = "ipdataApiKey"
    }

    private fun migrateDefaults() {
        val version = preferences.getInt(KEY_SETTINGS_VERSION, 1)
        if (version < 2) {
            preferences.edit()
                .putString(KEY_UNKNOWN_TRAFFIC, "direct")
                .apply()
        }
        if (version < 4) {
            val rules = (getVpnDomainRules() + DefaultRules.openAiChatGptVpnRules).distinct()
            preferences.edit()
                .putString(KEY_SELECTED_PROXY, "AUTO")
                .putInt(KEY_SETTINGS_VERSION, CURRENT_SETTINGS_VERSION)
                .apply()
            setVpnDomainRules(rules)
        }
        if (version < 5 && preferences.getString(KEY_UNKNOWN_TRAFFIC, "direct") == "vpn") {
            preferences.edit()
                .putString(KEY_UNKNOWN_TRAFFIC, "direct")
                .apply()
        }
        if (version < 6) {
            preferences.edit()
                .putString(KEY_UNKNOWN_TRAFFIC, "vpn")
                .apply()
        }
        if (version < 7) {
            setVpnDomainRules((getVpnDomainRules() + DefaultRules.openAiChatGptVpnRules).distinct())
        }
        if (version != CURRENT_SETTINGS_VERSION) {
            preferences.edit().putInt(KEY_SETTINGS_VERSION, CURRENT_SETTINGS_VERSION).apply()
        }
    }
}
