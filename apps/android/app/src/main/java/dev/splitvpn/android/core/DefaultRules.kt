package dev.splitvpn.android.core

object DefaultRules {
    data class BuiltInRule(
        val label: String,
        val rule: String,
        val policy: String
    )

    // Display only: mirrors the order `mihomo:generate` in packages/vpn-core
    // emits around `RULE-SET,vpn-domains,VPN`.
    val builtInPreVpnRules = listOf(
        BuiltInRule("局域网 IP", "GEOIP,lan,DIRECT,no-resolve", "DIRECT"),
        BuiltInRule("私有域名", "GEOSITE,private,DIRECT", "DIRECT"),
        BuiltInRule("运营商内网", "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve", "DIRECT"),
        BuiltInRule("国内域名", "GEOSITE,cn,DIRECT", "DIRECT"),
        BuiltInRule("国内 IP", "GEOIP,CN,DIRECT", "DIRECT"),
        BuiltInRule("QUIC（节点不支持 UDP 时）", "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT", "REJECT")
    )

    val builtInGeoRules = listOf(
        BuiltInRule("国外域名", "GEOSITE,geolocation-!cn,VPN", "VPN"),
        BuiltInRule("国外 IP", "GEOIP,!CN,VPN", "VPN")
    )

    val openAiChatGptVpnRules = listOf(
        "DOMAIN-SUFFIX,auth.openai.com",
        "DOMAIN-SUFFIX,chatgpt.com",
        "DOMAIN-SUFFIX,ct.sendgrid.net",
        "DOMAIN-SUFFIX,featuregates.org",
        "DOMAIN-SUFFIX,google.com",
        "DOMAIN-SUFFIX,googleapis.com",
        "DOMAIN-SUFFIX,gstatic.com",
        "DOMAIN-SUFFIX,ggpht.com",
        "DOMAIN-SUFFIX,intercom.io",
        "DOMAIN-SUFFIX,intercomcdn.com",
        "DOMAIN-SUFFIX,ipdata.co",
        "DOMAIN-SUFFIX,oaistatic.com",
        "DOMAIN-SUFFIX,oaiusercontent.com",
        "DOMAIN-SUFFIX,oaistatsig.com",
        "DOMAIN-SUFFIX,openai.com",
        "DOMAIN-SUFFIX,statsig.com",
        "DOMAIN,cdn.openaimerge.com",
        "DOMAIN-SUFFIX,workos.com",
        "DOMAIN-SUFFIX,workoscdn.com",
        "DOMAIN,challenges.cloudflare.com",
        "DOMAIN,events.statsigapi.net",
        "DOMAIN-SUFFIX,featureassets.org",
        "DOMAIN,humb.apple.com",
        "DOMAIN,js.stripe.com",
        "DOMAIN,o207216.ingest.sentry.io",
        "DOMAIN,o33249.ingest.sentry.io",
        "DOMAIN-SUFFIX,prodregistryv2.org",
        "DOMAIN,rum.browser-intake-datadoghq.com",
        "DOMAIN-SUFFIX,statsigapi.net",
        "DOMAIN,workos.imgix.net"
    )
}
