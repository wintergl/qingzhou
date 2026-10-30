package dev.splitvpn.android.core

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads with HttpURLConnection; the Rust core decides which candidate URL
 * to try next, parses the content and stores the provider.
 */
class SubscriptionClient(
    private val paths: SplitVpnPaths,
    private val core: CoreClient,
    private val repository: SubscriptionRepository
) {
    fun save(url: String) {
        core.saveSubscription(url)
        sync()
    }

    fun update(url: String) {
        val id = core.saveSubscription(url)
        repository.markUpdating()
        try {
            val result = download(id)
            if (!result.optBoolean("ok")) throw IOException(result.optString("error").ifEmpty { "订阅更新失败。" })
        } finally {
            sync()
        }
    }

    fun entries(): List<JSONObject> {
        val entries = core.subscriptionStatus().optJSONArray("entries") ?: return emptyList()
        return (0 until entries.length()).mapNotNull(entries::optJSONObject)
    }

    fun saveEntry(payload: JSONObject) { core.call("subscription:save", payload); sync() }
    fun updateEntry(id: String) {
        try { val result = download(id); if (!result.optBoolean("ok")) throw IOException(result.optString("error", "订阅更新失败")) }
        finally { sync() }
    }
    fun changeEntry(channel: String, payload: JSONObject) { core.call(channel, payload); sync() }

    /** Refreshes the UI mirror, moving a pre-core subscription into the core once. */
    fun sync() {
        if (!repository.legacyMigrated() && migrateLegacy()) {
            repository.markLegacyMigrated()
        }
        repository.mirror(core.subscriptionStatus(), core.nodes())
    }

    /** Returns false when the migration should be retried on the next sync. */
    private fun migrateLegacy(): Boolean {
        val url = repository.get().url.trim()
        if (url.isEmpty()) return true
        val entry = CoreClient.firstEntry(core.subscriptionStatus())
        // An entry with another URL means the core subscription is already set up.
        if (entry != null && entry.optString("url") != url) return true
        // A successful core refresh must not be overwritten by an older cache.
        if ((entry?.optInt("nodeCount") ?: 0) > 0) return true
        val id = entry?.optString("id")?.takeIf { it.isNotEmpty() }
            ?: runCatching { core.saveSubscription(url) }.getOrNull()
            ?: return false
        // Reuse the last downloaded provider so nodes survive the upgrade offline.
        val legacy = File(paths.providerDir, "subscription.yaml")
        if (!legacy.isFile) return true
        val result = runCatching {
            val plan = core.obj("subscription:plan", JSONObject().put("id", id))
            core.obj(
                "subscription:accept",
                JSONObject().put("id", id).put("token", plan.getString("token"))
                    .put("index", 0).put("status", 200).put("content", legacy.readText(Charsets.UTF_8))
            )
        }.getOrNull()
        if (result == null || !result.optBoolean("done") || !result.optBoolean("ok")) return false
        legacy.delete()
        return true
    }

    private fun download(id: String): JSONObject {
        val plan = core.obj("subscription:plan", JSONObject().put("id", id))
        val urls = plan.optJSONArray("urls")
        if (urls == null || urls.length() == 0) throw IOException("订阅下载计划无效")
        val headers = plan.optJSONObject("headers") ?: JSONObject()
        val maxBytes = plan.optInt("maxBytes", Int.MAX_VALUE)
        var index = 0
        while (index < urls.length()) {
            val payload = JSONObject().put("id", id).put("token", plan.getString("token")).put("index", index)
            try {
                val (status, text) = fetchText(urls.getString(index), headers, maxBytes)
                payload.put("status", status).put("content", text)
            } catch (error: Exception) {
                payload.put("error", error.message ?: error.javaClass.simpleName)
            }
            val result = core.obj("subscription:accept", payload)
            if (result.optBoolean("done")) return result
            index = result.optInt("next", index + 1)
        }
        throw IOException("订阅下载没有得到结果")
    }

    private fun fetchText(value: String, headers: JSONObject, maxBytes: Int): Pair<Int, String> {
        val connection = URL(value).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.useCaches = false
            headers.keys().forEach { connection.setRequestProperty(it, headers.optString(it)) }
            val status = connection.responseCode
            val stream = (if (status in 200..299) connection.inputStream else connection.errorStream) ?: return status to ""
            // Read one byte past the limit so the core can reject oversized content.
            val bytes = stream.use { it.readAtMost(maxBytes.toLong() + 1) }
            return status to String(bytes, Charsets.UTF_8)
        } finally {
            connection.disconnect()
        }
    }

    private fun java.io.InputStream.readAtMost(limit: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (out.size() < limit) {
            val read = read(buffer, 0, minOf(buffer.size.toLong(), limit - out.size()).toInt())
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private companion object {
        const val TIMEOUT_MS = 15_000
    }
}
