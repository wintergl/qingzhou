package dev.splitvpn.android.core

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import kotlin.system.measureTimeMillis

object Diagnostics {
    private val localMihomoProxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 7890))
    private val targets = listOf(
        "Google" to "https://www.gstatic.com/generate_204",
        "ChatGPT" to "https://chatgpt.com/cdn-cgi/trace",
        "Claude" to "https://claude.ai",
        "Baidu" to "https://www.baidu.com"
    )

    fun runSpeedTest(): List<SpeedResult> = targets.map { (name, url) -> measureUrl(name, url) }

    fun checkGoogleConnectivity(): ConnectivityProbe {
        return runCatching {
            ConnectivityProbe(
                name = "Google",
                ok = true,
                latencyMs = checkEndpoint("https://www.google.com/generate_204", 8_000, viaProxy = true),
                error = null
            )
        }.getOrElse { error ->
            ConnectivityProbe(
                name = "Google",
                ok = false,
                latencyMs = null,
                error = error.message ?: error.javaClass.simpleName
            )
        }
    }

    fun runConnectivityCheck(): ConnectivityResult {
        val domestic = runCatching { checkEndpoint("https://www.baidu.com", 6_000) }
        val foreign = runCatching { checkEndpoint("https://www.google.com/generate_204", 8_000, viaProxy = true) }
        val ip = runCatching { fetchExternalIp(viaProxy = true) }
        val errors = listOf(domestic, foreign, ip).mapNotNull { it.exceptionOrNull()?.message }

        return ConnectivityResult(
            domesticOk = domestic.isSuccess,
            foreignOk = foreign.isSuccess,
            externalIp = ip.getOrNull(),
            latency = ConnectivityLatency(
                domesticMs = domestic.getOrNull(),
                foreignMs = foreign.getOrNull()
            ),
            error = errors.takeIf { it.isNotEmpty() }?.joinToString("; ")
        )
    }

    fun runRiskCheck(settingsRepository: SettingsRepository): RiskResult {
        val proxyName = runCatching { MihomoControllerClient.currentProxyName() }.getOrDefault(settingsRepository.getSelectedProxy())
        val apiKey = settingsRepository.getIpdataApiKey()
        if (apiKey.isBlank()) {
            return RiskResult(
                externalIp = null,
                country = null,
                organization = null,
                proxyName = proxyName,
                riskLevel = "未知",
                summary = "请先在风险页保存 ipdata API Key。",
                checkedAt = java.time.Instant.now().toString(),
                reasons = listOf("未配置 ipdata API Key"),
                error = "未配置 ipdata API Key"
            )
        }

        return runCatching {
            val profile = fetchJson("https://api.ipdata.co?api-key=${encodeURIComponent(apiKey)}", 8_000, viaProxy = true)
            val ip = profile.optString("ip").takeIf { it.isNotBlank() }
            var threatPayload = profile.optJSONObject("threat")
            if (ip != null && threatPayload == null) {
                threatPayload = fetchJson(
                    "https://api.ipdata.co/${encodeURIComponent(ip)}/threat?api-key=${encodeURIComponent(apiKey)}",
                    8_000,
                    viaProxy = true
                )
            }
            val scoresPayload = threatPayload?.optJSONObject("scores")
            val risk = evaluateIpdataRisk(
                proxyName = proxyName,
                ip = ip,
                threatPayload = threatPayload,
                scoresPayload = scoresPayload,
                checkedAt = java.time.Instant.now().toString()
            )
            val country = profile.optString("country_name").ifBlank { profile.optString("country_code") }.takeIf { it.isNotBlank() }
            val org = profile.optJSONObject("asn")?.optString("name")?.takeIf { it.isNotBlank() }
                ?: profile.optString("organisation").takeIf { it.isNotBlank() }
            risk.copy(country = country, organization = org)
        }.getOrElse { error ->
            RiskResult(
                externalIp = null,
                country = null,
                organization = null,
                proxyName = proxyName,
                riskLevel = "未知",
                summary = "ipdata 检测失败：${error.message ?: error.javaClass.simpleName}",
                checkedAt = java.time.Instant.now().toString(),
                reasons = listOf("ipdata 请求失败"),
                error = error.message ?: error.javaClass.simpleName
            )
        }
    }

    private fun measureUrl(name: String, value: String): SpeedResult {
        var ok = false
        var error: String? = null
        val elapsed = measureTimeMillis {
            try {
                val connection = openConnection(value, viaProxy = name != "Baidu")
                connection.requestMethod = "GET"
                connection.connectTimeout = 6_000
                connection.readTimeout = 6_000
                connection.setRequestProperty("User-Agent", "split-vpn/0.1.0 Android")
                val status = connection.responseCode
                ok = status in 200..399 || status == 204
                if (!ok) error = "HTTP $status"
                connection.inputStream?.close()
                connection.disconnect()
            } catch (e: Exception) {
                error = e.message ?: e.javaClass.simpleName
            }
        }
        return SpeedResult(name, value, if (ok) elapsed else null, ok, error)
    }

    private fun checkEndpoint(value: String, timeoutMs: Int, viaProxy: Boolean = false): Long {
        var status = 0
        val elapsed = measureTimeMillis {
            val connection = openConnection(value, viaProxy)
            connection.requestMethod = "GET"
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("User-Agent", "split-vpn/0.1.0 Android")
            status = connection.responseCode
            runCatching { connection.inputStream?.close() }
            connection.disconnect()
        }
        if (status >= 400) throw IOException("$value returned HTTP $status")
        return elapsed
    }

    private fun fetchExternalIp(viaProxy: Boolean): String {
        val json = fetchJson("https://ipinfo.io/json", 6_000, viaProxy)
        return json.optString("ip").takeIf { it.isNotBlank() }.orEmpty()
    }

    private fun fetchJson(value: String, timeoutMs: Int = 5_000, viaProxy: Boolean = false): JSONObject {
        val connection = openConnection(value, viaProxy)
        connection.connectTimeout = timeoutMs
        connection.readTimeout = timeoutMs
        val status = connection.responseCode
        val text = if (status in 200..299) {
            connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } else {
            connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        }
        connection.disconnect()
        if (status !in 200..299) throw IOException("HTTP $status")
        return JSONObject(text)
    }

    private fun openConnection(value: String, viaProxy: Boolean): HttpURLConnection {
        val url = URL(value)
        return (if (viaProxy) url.openConnection(localMihomoProxy) else url.openConnection()) as HttpURLConnection
    }

    private fun evaluateIpdataRisk(
        proxyName: String,
        ip: String?,
        threatPayload: JSONObject?,
        scoresPayload: JSONObject?,
        checkedAt: String
    ): RiskResult {
        if (ip.isNullOrBlank()) {
            return RiskResult(
                externalIp = null,
                country = null,
                organization = null,
                proxyName = proxyName,
                riskLevel = "未知",
                summary = "ipdata 未返回出口 IP，无法判断风险。",
                checkedAt = checkedAt,
                reasons = listOf("ipdata 未返回出口 IP")
            )
        }

        val threat = normalizeThreat(threatPayload)
        val scores = normalizeScores(scoresPayload)
        val reasons = mutableListOf<String>()
        var highRisk = false
        var mediumRisk = false

        listOf(
            threat.isKnownAttacker to "known attacker",
            threat.isKnownAbuser to "known abuser",
            threat.isThreat to "threat",
            threat.isTor to "Tor exit",
            threat.isBogon to "bogon IP"
        ).forEach { (value, label) ->
            if (value == true) {
                highRisk = true
                reasons += label
            }
        }

        if (!highRisk) {
            listOf(
                threat.isProxy to "proxy",
                threat.isAnonymous to "anonymous IP",
                threat.isDatacenter to "datacenter IP"
            ).forEach { (value, label) ->
                if (value == true) {
                    mediumRisk = true
                    reasons += label
                }
            }
        }

        scores.trustScore?.let {
            when {
                it < 40 -> {
                    highRisk = true
                    reasons += "trust_score $it"
                }
                it <= 60 && !highRisk -> {
                    mediumRisk = true
                    reasons += "trust_score $it"
                }
                !highRisk && !mediumRisk -> reasons += "trust_score $it"
            }
        }
        listOf(
            "threat_score" to scores.threatScore,
            "proxy_score" to scores.proxyScore,
            "vpn_score" to scores.vpnScore
        ).forEach { (label, value) ->
            if (value != null && value >= 80) reasons += "$label $value"
        }

        val hasThreatField = listOf(
            threat.isTor,
            threat.isProxy,
            threat.isDatacenter,
            threat.isAnonymous,
            threat.isKnownAttacker,
            threat.isKnownAbuser,
            threat.isThreat,
            threat.isBogon
        ).any { it != null }
        val hasScoreField = listOf(scores.vpnScore, scores.proxyScore, scores.threatScore, scores.trustScore).any { it != null }
        val level = when {
            !hasThreatField && !hasScoreField -> "未知"
            highRisk -> "高"
            mediumRisk -> "中"
            else -> "低"
        }
        val finalReasons = when {
            !hasThreatField && !hasScoreField -> listOf("ipdata threat/scores 字段缺失")
            reasons.isNotEmpty() -> reasons.distinct()
            else -> listOf("未命中风险字段")
        }

        return RiskResult(
            externalIp = ip,
            country = null,
            organization = null,
            proxyName = proxyName,
            riskLevel = level,
            summary = finalReasons.joinToString("；"),
            checkedAt = checkedAt,
            reasons = finalReasons,
            threat = threat.takeIf { hasThreatField },
            scores = scores.takeIf { hasScoreField }
        )
    }

    private fun normalizeThreat(payload: JSONObject?): IpdataThreatSummary {
        val source = payload?.optJSONObject("threat") ?: payload
        return IpdataThreatSummary(
            isTor = source?.optionalBoolean("is_tor"),
            isProxy = source?.optionalBoolean("is_proxy"),
            isDatacenter = source?.optionalBoolean("is_datacenter"),
            isAnonymous = source?.optionalBoolean("is_anonymous"),
            isKnownAttacker = source?.optionalBoolean("is_known_attacker"),
            isKnownAbuser = source?.optionalBoolean("is_known_abuser"),
            isThreat = source?.optionalBoolean("is_threat"),
            isBogon = source?.optionalBoolean("is_bogon")
        )
    }

    private fun normalizeScores(payload: JSONObject?): IpdataRiskScores = IpdataRiskScores(
        vpnScore = payload?.optionalInt("vpn_score"),
        proxyScore = payload?.optionalInt("proxy_score"),
        threatScore = payload?.optionalInt("threat_score"),
        trustScore = payload?.optionalInt("trust_score")
    )

    private fun JSONObject.optionalBoolean(name: String): Boolean? = if (has(name) && !isNull(name)) optBoolean(name) else null

    private fun JSONObject.optionalInt(name: String): Int? = if (has(name) && !isNull(name)) optInt(name) else null

    private fun encodeURIComponent(value: String): String = java.net.URLEncoder.encode(value, Charsets.UTF_8.name())
}
