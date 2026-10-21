package dev.splitvpn.android.core

import java.net.URI
import java.util.Locale

object VpnRuleFormatter {
    fun normalize(input: String?): String {
        val value = input?.trim().orEmpty()
        if (value.isEmpty()) return ""
        val upper = value.uppercase(Locale.ROOT)
        if (
            upper.startsWith("DOMAIN,") ||
            upper.startsWith("DOMAIN-SUFFIX,") ||
            upper.startsWith("DOMAIN-KEYWORD,") ||
            upper.startsWith("GEOSITE,")
        ) {
            return value
        }
        val host = extractHost(value)
        return if (host.isEmpty()) value else "DOMAIN-SUFFIX,$host"
    }

    private fun extractHost(value: String): String {
        return runCatching {
            val uri = URI(if (value.contains("://")) value else "https://$value")
            val host = uri.host.orEmpty()
            if (host.startsWith("www.")) host.removePrefix("www.") else host
        }.getOrDefault("")
    }
}
