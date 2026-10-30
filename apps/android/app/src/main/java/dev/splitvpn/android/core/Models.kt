package dev.splitvpn.android.core

data class SubscriptionRecord(
    val url: String,
    val status: String,
    val nodeCount: Int,
    val updatedAt: String,
    val lastError: String
)

data class ProviderNode(
    val name: String,
    val type: String = "",
    val identityKey: String? = null,
    val subscriptionId: String? = null,
    val subscriptionName: String? = null,
    val identityAmbiguous: Boolean = false
)

data class RuntimeStatus(
    val state: String,
    val startedAt: String,
    val updatedAt: String,
    val selectedProxy: String,
    val lastError: String,
    val controllerAvailable: Boolean,
    val tun2socksPid: Int,
    val alwaysOn: Boolean = false,
    val networkEpoch: Long = 0,
    val retryAt: Long = 0,
    val configurationRevision: String = ""
)

data class TrafficSnapshot(
    val uploadBytes: Long,
    val downloadBytes: Long,
    val connectionCount: Int,
    val memoryBytes: Long
)

data class SpeedResult(
    val name: String,
    val url: String,
    val latencyMs: Long?,
    val ok: Boolean,
    val error: String?
)

data class ConnectivityProbe(
    val name: String,
    val ok: Boolean,
    val latencyMs: Long?,
    val error: String?
)

data class ConnectivityLatency(
    val domesticMs: Long?,
    val foreignMs: Long?
)

data class ConnectivityResult(
    val domesticOk: Boolean,
    val foreignOk: Boolean,
    val externalIp: String?,
    val latency: ConnectivityLatency,
    val error: String?,
    val proxyOk: Boolean? = null,
    val systemDnsOk: Boolean? = null,
    val chatgptStatus: String? = null
)

data class RiskResult(
    val externalIp: String?,
    val country: String?,
    val organization: String?,
    val proxyName: String,
    val riskLevel: String,
    val summary: String,
    val source: String = "ipdata",
    val checkedAt: String = "",
    val reasons: List<String> = emptyList(),
    val threat: IpdataThreatSummary? = null,
    val scores: IpdataRiskScores? = null,
    val error: String? = null
)

data class IpdataThreatSummary(
    val isTor: Boolean? = null,
    val isProxy: Boolean? = null,
    val isDatacenter: Boolean? = null,
    val isAnonymous: Boolean? = null,
    val isKnownAttacker: Boolean? = null,
    val isKnownAbuser: Boolean? = null,
    val isThreat: Boolean? = null,
    val isBogon: Boolean? = null
)

data class IpdataRiskScores(
    val vpnScore: Int? = null,
    val proxyScore: Int? = null,
    val threatScore: Int? = null,
    val trustScore: Int? = null
)
