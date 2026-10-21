package dev.splitvpn.android.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** UI mirror of the core subscription state, readable from the main thread. */
class SubscriptionRepository(context: Context) {
    private val preferences = context.getSharedPreferences("split_vpn_subscription", Context.MODE_PRIVATE)

    fun get(): SubscriptionRecord {
        val url = preferences.getString(KEY_URL, "").orEmpty()
        val status = preferences.getString(KEY_STATUS, if (url.isEmpty()) "not-configured" else "saved").orEmpty()
        return SubscriptionRecord(
            url = url,
            status = status.ifEmpty { "not-configured" },
            nodeCount = preferences.getInt(KEY_NODE_COUNT, 0),
            updatedAt = preferences.getString(KEY_UPDATED_AT, "").orEmpty(),
            lastError = preferences.getString(KEY_LAST_ERROR, "").orEmpty()
        )
    }

    fun nodes(): List<ProviderNode> {
        val array = runCatching { JSONArray(preferences.getString(KEY_NODES, "[]")) }.getOrElse { JSONArray() }
        return (0 until array.length()).mapNotNull { index ->
            val node = array.optJSONObject(index) ?: return@mapNotNull null
            ProviderNode(node.optString("name"), node.optString("type")).takeIf { it.name.isNotEmpty() }
        }
    }

    /** Pre-core builds kept the URL here and the provider in `providers/subscription.yaml`. */
    fun legacyMigrated(): Boolean = preferences.getBoolean(KEY_CORE_MIGRATED, false)

    fun markLegacyMigrated() {
        preferences.edit().putBoolean(KEY_CORE_MIGRATED, true).apply()
    }

    fun markUpdating() {
        preferences.edit().putString(KEY_STATUS, "updating").putString(KEY_LAST_ERROR, "").apply()
    }

    /** Mirrors `subscription:get-status` and `nodes:list` from the core. */
    fun mirror(status: JSONObject, nodes: List<ProviderNode>) {
        val array = JSONArray()
        nodes.forEach { array.put(JSONObject().put("name", it.name).put("type", it.type)) }
        preferences.edit()
            .putString(KEY_URL, status.optString("url"))
            .putString(KEY_STATUS, status.optString("status", "not-configured"))
            .putInt(KEY_NODE_COUNT, status.optInt("nodeCount", 0))
            .putString(KEY_UPDATED_AT, if (status.isNull("updatedAt")) "" else status.optString("updatedAt"))
            .putString(KEY_LAST_ERROR, if (status.isNull("lastError")) "" else status.optString("lastError"))
            .putString(KEY_NODES, array.toString())
            .apply()
    }

    private companion object {
        const val KEY_URL = "url"
        const val KEY_STATUS = "status"
        const val KEY_NODE_COUNT = "nodeCount"
        const val KEY_UPDATED_AT = "updatedAt"
        const val KEY_LAST_ERROR = "lastError"
        const val KEY_NODES = "nodes"
        const val KEY_CORE_MIGRATED = "coreMigrated"
    }
}
