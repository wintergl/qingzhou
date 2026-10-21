package dev.splitvpn.android.core

/** Error paths can contain subscription links or controller credentials. */
object LogRedactor {
    private val urls = Regex("(?i)\\b(?:https?|socks[45]?|ssr?|vmess|vless|trojan|hysteria2?|tuic)://[^\\s\"'<>]+")
    private val authorization = Regex("(?i)(authorization\\s*[:=]\\s*)(?:Bearer|Basic)\\s+[^\\s,;\"]+")
    private val secrets = Regex("(?i)([\"']?(?:password|passwd|token|secret|api[_-]?key|access[_-]?token)[\"']?\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;]+)")

    fun redact(message: String): String = secrets.replace(
        authorization.replace(urls.replace(message, "[链接已隐藏]")) { "${it.groupValues[1]}[已隐藏]" }
    ) { "${it.groupValues[1]}[已隐藏]" }
}
