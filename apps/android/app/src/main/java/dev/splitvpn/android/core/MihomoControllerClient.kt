package dev.splitvpn.android.core

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

object MihomoControllerClient {
    @Volatile private var baseUrl = "http://127.0.0.1:${CoreClient.CONTROLLER_PORT}"
    @Volatile private var secret = ""

    /** Set from each generated config; the core keeps the secret stable across runs. */
    fun configure(controller: String, secret: String) {
        baseUrl = "http://$controller"
        this.secret = secret
    }

    fun selectVpnProxy(name: String) {
        val body = JSONObject().put("name", name.ifBlank { "AUTO" }).toString()
        val connection = open("/proxies/VPN", "PUT")
        try {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            requireSuccess(connection, "节点切换失败")
        } finally {
            connection.disconnect()
        }
    }

    /** Reloads a regenerated config into the running mihomo without dropping the tunnel. */
    fun reloadConfig(path: String) {
        val body = JSONObject().put("path", path).toString()
        val connection = open("/configs?force=true", "PUT")
        try {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            requireSuccess(connection, "配置重载失败")
        } finally {
            connection.disconnect()
        }
    }

    fun currentProxyName(): String {
        val json = getJson("/proxies/VPN")
        return json.optString("now", "AUTO")
    }

    fun trafficSnapshot(): TrafficSnapshot {
        val connections = runCatching { getJson("/connections") }.getOrNull()
        return TrafficSnapshot(
            uploadBytes = connections?.optLong("uploadTotal", 0L) ?: 0L,
            downloadBytes = connections?.optLong("downloadTotal", 0L) ?: 0L,
            connectionCount = connections?.optJSONArray("connections")?.length() ?: 0,
            memoryBytes = runCatching { getJson("/memory").optLong("inuse", 0L) }.getOrDefault(0L)
        )
    }

    fun requireAvailable() {
        getJson("/version")
    }

    /** Exercises a fresh HTTPS request through the currently selected VPN group. */
    fun requireVpnHttpsEgress(
        target: String = DEFAULT_HTTPS_PROBE_URL,
        timeoutMs: Int = DEFAULT_HTTPS_PROBE_TIMEOUT_MS
    ) {
        val json = getJson(
            vpnHttpsProbePath(target, timeoutMs),
            connectTimeoutMs = CONTROLLER_CONNECT_TIMEOUT_MS,
            readTimeoutMs = timeoutMs + CONTROLLER_RESPONSE_GRACE_MS
        )
        if (!json.has("delay") || json.optLong("delay", 0L) <= 0L) {
            throw IOException("Mihomo VPN HTTPS probe returned no positive delay")
        }
    }

    fun isAvailable(): Boolean = runCatching { requireAvailable(); true }.getOrDefault(false)

    internal fun vpnHttpsProbePath(target: String, timeoutMs: Int): String {
        val url = URL(target)
        require(url.protocol == "https" && url.host.isNotBlank()) { "HTTPS probe target is invalid" }
        require(timeoutMs in 1_000..30_000) { "HTTPS probe timeout is invalid" }
        val encoded = URLEncoder.encode(target, Charsets.UTF_8.name())
        // Any completed HTTP response proves the TLS path; service status is not a transport failure.
        return "/proxies/VPN/delay?url=$encoded&timeout=$timeoutMs&expected=200-599"
    }

    private fun getJson(
        path: String,
        connectTimeoutMs: Int = CONTROLLER_CONNECT_TIMEOUT_MS,
        readTimeoutMs: Int = CONTROLLER_READ_TIMEOUT_MS
    ): JSONObject {
        val connection = open(path, "GET", connectTimeoutMs, readTimeoutMs)
        try {
            val status = connection.responseCode
            val text = if (status in 200..299) {
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            } else {
                connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            }
            if (status !in 200..299) throw IOException("Mihomo Controller HTTP $status $text")
            return JSONObject(text.ifBlank { "{}" })
        } finally {
            connection.disconnect()
        }
    }

    private fun open(
        path: String,
        method: String,
        connectTimeoutMs: Int = CONTROLLER_CONNECT_TIMEOUT_MS,
        readTimeoutMs: Int = CONTROLLER_READ_TIMEOUT_MS
    ): HttpURLConnection {
        return (URL(baseUrl + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            if (secret.isNotEmpty()) setRequestProperty("Authorization", "Bearer $secret")
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
        }
    }

    private fun requireSuccess(connection: HttpURLConnection, label: String) {
        val status = connection.responseCode
        val text = if (status in 200..299) {
            ""
        } else {
            connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        }
        if (status !in 200..299) throw IOException("$label：HTTP $status $text".trim())
    }

    private const val DEFAULT_HTTPS_PROBE_URL = "https://chatgpt.com/cdn-cgi/trace"
    private const val DEFAULT_HTTPS_PROBE_TIMEOUT_MS = 5_000
    private const val CONTROLLER_CONNECT_TIMEOUT_MS = 2_000
    private const val CONTROLLER_READ_TIMEOUT_MS = 3_000
    private const val CONTROLLER_RESPONSE_GRACE_MS = 2_000
}
