package dev.splitvpn.android.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

class CoreException(val code: String, message: String) : IOException(message)

/**
 * Bridge to the shared Rust core (`packages/vpn-core`, `qz_core.h`). The core
 * owns subscriptions, node parsing and mihomo config generation under
 * [SplitVpnPaths.appDataDir]; Kotlin keeps UI mirrors in SharedPreferences.
 * Calls block on file IO, so never call from the main thread.
 */
class CoreClient(private val paths: SplitVpnPaths) {
    /** Runs one `{channel, payload}` request and returns its `data`. */
    fun call(channel: String, payload: JSONObject = JSONObject()): Any? {
        paths.ensure()
        val request = JSONObject().put("channel", channel).put("payload", payload).toString()
        val reply = callNative(
            paths.appDataDir.absolutePath.toByteArray(Charsets.UTF_8),
            request.toByteArray(Charsets.UTF_8)
        ) ?: throw CoreException("CORE_NULL_REPLY", "核心没有返回结果")
        val json = runCatching { JSONObject(String(reply, Charsets.UTF_8)) }
            .getOrElse { throw CoreException("CORE_BAD_REPLY", "核心返回格式无效") }
        if (json.optBoolean("ok")) return json.opt("data")
        val error = json.optJSONObject("error")
        throw CoreException(
            error?.optString("code").orEmpty().ifEmpty { "CORE_OPERATION_FAILED" },
            error?.optString("message").orEmpty().ifEmpty { "核心调用失败" }
        )
    }

    fun obj(channel: String, payload: JSONObject = JSONObject()): JSONObject =
        call(channel, payload) as? JSONObject ?: throw CoreException("CORE_BAD_REPLY", "核心返回格式无效：$channel")

    fun subscriptionStatus(): JSONObject = obj("subscription:get-status")

    /** Saves the single Android subscription URL into the first core entry and returns its id. */
    fun saveSubscription(url: String): String {
        val payload = JSONObject().put("url", url.trim())
        firstEntry(subscriptionStatus())?.optString("id")?.takeIf { it.isNotEmpty() }?.let { payload.put("id", it) }
        return firstEntry(obj("subscription:save", payload))?.optString("id")?.takeIf { it.isNotEmpty() }
            ?: throw CoreException("CORE_BAD_REPLY", "订阅保存后没有返回订阅 ID")
    }

    fun nodes(): List<ProviderNode> {
        val list = call("nodes:list") as? JSONArray ?: return emptyList()
        return (0 until list.length()).mapNotNull { index ->
            val node = list.optJSONObject(index) ?: return@mapNotNull null
            val name = node.optString("name").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            ProviderNode(name, node.optString("type"))
        }
    }

    /** Pushes the Android routing settings into the core, then writes mihomo's config. */
    fun generateMihomoConfig(settings: SettingsRepository): MihomoConfig {
        call(
            "settings:patch",
            JSONObject()
                .put("selectedProxy", settings.getSelectedProxy())
                .put("unknownTraffic", settings.getUnknownTraffic())
                .put("vpnDomainRules", JSONArray(settings.getVpnDomainRules()))
        )
        val out = obj("mihomo:generate", JSONObject().put("mixedPort", MIXED_PORT).put("controllerPort", CONTROLLER_PORT))
        return MihomoConfig(
            homeDir = out.getString("home"),
            configFile = out.getString("config"),
            controller = out.getString("controller"),
            secret = out.optString("secret"),
            providerCount = out.optInt("providerCount"),
            selectedProxy = out.getString("selectedProxy"),
            selectionValid = out.getBoolean("selectionValid"),
            selectionError = out.optString("selectionError")
        )
    }

    companion object {
        const val MIXED_PORT = 7890
        const val CONTROLLER_PORT = 9090

        init {
            System.loadLibrary("splitvpncore")
        }

        fun firstEntry(record: JSONObject): JSONObject? = record.optJSONArray("entries")?.optJSONObject(0)

        /** UTF-8 in and out; see `cpp/core_jni.cpp`. */
        @JvmStatic
        private external fun callNative(root: ByteArray, request: ByteArray): ByteArray?
    }
}

data class MihomoConfig(
    val homeDir: String,
    val configFile: String,
    val controller: String,
    val secret: String,
    val providerCount: Int,
    val selectedProxy: String,
    val selectionValid: Boolean,
    val selectionError: String
)
