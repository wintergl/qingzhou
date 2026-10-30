package dev.splitvpn.android.core

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL

/** Native DNS evidence plus shared measurements through the actual exit. */
class MobileDiagnostics(private val core: CoreClient, private val runtime: RuntimeStatusRepository) {
    fun payload(): JSONObject {
        val status = runtime.get()
        check(status.state == "connected" && status.configurationRevision.isNotEmpty()) { "请先连接并等待配置生效" }
        return JSONObject().put("connected", true).put("runtimeRevision", status.configurationRevision).put("networkEpoch", status.networkEpoch.toString())
    }
    fun call(channel: String, extra: JSONObject = JSONObject()): JSONObject {
        val token = payload()
        extra.keys().forEach { key -> token.put(key, extra.get(key)) }
        val result = core.obj(channel, token)
        val now = runtime.get()
        check(now.state == "connected" && now.configurationRevision == token.optString("runtimeRevision") && now.networkEpoch.toString() == token.optString("networkEpoch")) { "连接已变化，本次结果已丢弃" }
        return result
    }
    fun connectivity(): JSONObject {
        val dns = runCatching { VpnDnsClient().requireHealthy() }
        val web = JSONObject()
        runCatching {
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 7890))
            val conn = URL("https://chatgpt.com/cdn-cgi/trace").openConnection(proxy) as HttpURLConnection
            try {
                conn.connectTimeout = 6000; conn.readTimeout = 6000; conn.instanceFollowRedirects = false
                val status = conn.responseCode
                web.put("ok", status in 200..299).put("httpStatus", status)
                    .put("error", if (status in 200..299) JSONObject.NULL else "ChatGPT 返回 HTTP $status")
                    .put("failureReason", if (status in listOf(403,429,451)) "restricted" else "http-status")
            } finally { conn.disconnect() }
        }.onFailure { web.put("ok", false).put("error", "ChatGPT 请求失败").put("failureReason", "transport") }
        return call("mobile:diagnostics:connectivity", JSONObject().put("systemDns", JSONObject().put("ok", dns.isSuccess).put("error", if(dns.isSuccess) JSONObject.NULL else "应用 DNS／TLS 路径检测失败" )).put("chatgpt", web))
    }
    fun websites() = call("mobile:diagnostics:websites")
    fun risk(settings: SettingsRepository) = call("mobile:diagnostics:risk", JSONObject().put("apiKey", settings.getIpdataApiKey().also { check(it.isNotBlank()) { "请先保存 ipdata API Key" } }))
    fun connectivityModel(value: JSONObject): ConnectivityResult {
        val c = value.getJSONObject("connectivity"); val latency = c.optJSONObject("latency")
        return ConnectivityResult(c.optBoolean("domesticOk"),c.optBoolean("foreignOk"),c.optString("externalIp").takeIf { it!="null" }, ConnectivityLatency(latency?.optionalLong("domesticMs"),latency?.optionalLong("foreignMs")),c.optString("error").takeIf { it!="null" },c.optBoolean("proxyOk"),c.optJSONObject("systemDns")?.optBoolean("ok"),c.optJSONObject("chatgpt")?.optString("httpStatus"))
    }
    fun websiteModels(value: JSONObject): List<SpeedResult> {
        val rows = value.optJSONArray("results") ?: return emptyList()
        return (0 until rows.length()).map { i -> val v = rows.getJSONObject(i); SpeedResult(v.optString("label"),v.optString("url"),v.optionalLong("delay"),v.optBoolean("ok"),v.optString("error").takeIf { it!="null" }) }
    }
    fun riskModel(v: JSONObject) = RiskResult(v.optString("ip"),v.optString("country"),v.optString("organization"),v.optString("nodeName"),mapOf("high" to "高","medium" to "中","low" to "低")[v.optString("riskLevel")] ?: "未知", (v.optJSONArray("reasons")?.let { a -> (0 until a.length()).map { a.optString(it) }.joinToString("；") }).orEmpty(), checkedAt=v.optString("checkedAt"))
    private fun JSONObject.optionalLong(key: String): Long? = if(has(key)&&!isNull(key))optLong(key)else null
}
