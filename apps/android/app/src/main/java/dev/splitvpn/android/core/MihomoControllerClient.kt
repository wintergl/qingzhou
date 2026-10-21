package dev.splitvpn.android.core

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

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
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        requireSuccess(connection, "节点切换失败")
    }

    /** Reloads a regenerated config into the running mihomo without dropping the tunnel. */
    fun reloadConfig(path: String) {
        val body = JSONObject().put("path", path).toString()
        val connection = open("/configs?force=true", "PUT")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        requireSuccess(connection, "配置重载失败")
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

    fun isAvailable(): Boolean = runCatching { requireAvailable(); true }.getOrDefault(false)

    private fun getJson(path: String): JSONObject {
        val connection = open(path, "GET")
        val status = connection.responseCode
        val text = if (status in 200..299) {
            connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } else {
            connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        }
        connection.disconnect()
        if (status !in 200..299) throw IOException("Mihomo Controller HTTP $status $text")
        return JSONObject(text.ifBlank { "{}" })
    }

    private fun open(path: String, method: String): HttpURLConnection {
        return (URL(baseUrl + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            if (secret.isNotEmpty()) setRequestProperty("Authorization", "Bearer $secret")
            connectTimeout = 2_000
            readTimeout = 3_000
        }
    }

    private fun requireSuccess(connection: HttpURLConnection, label: String) {
        val status = connection.responseCode
        val text = if (status in 200..299) {
            ""
        } else {
            connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        }
        connection.disconnect()
        if (status !in 200..299) throw IOException("$label：HTTP $status $text".trim())
    }
}
