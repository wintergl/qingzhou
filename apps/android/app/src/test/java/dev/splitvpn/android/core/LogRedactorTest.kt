package dev.splitvpn.android.core

import org.junit.Assert.*
import org.junit.Test

class LogRedactorTest {
    @Test fun errorsDoNotExposeSubscriptionUrls() {
        val result = LogRedactor.redact("Failed https://user:password@example.test/sub?token=private and vless://credential@example.test")
        assertEquals("Failed [链接已隐藏] and [链接已隐藏]", result)
    }

    @Test fun headersAndStructuredSecretsAreHidden() {
        assertEquals("Authorization: [已隐藏]", LogRedactor.redact("Authorization: Bearer fixture-secret"))
        assertEquals("{\"secret\": [已隐藏], \"password\": [已隐藏]}",
            LogRedactor.redact("{\"secret\": \"fixture-secret\", \"password\": \"fixture-pass\"}"))
        assertEquals("api_key=[已隐藏] token=[已隐藏]", LogRedactor.redact("api_key=test-key token=test-token"))
    }

    @Test fun lifecycleMessagesStayReadable() {
        val message = "tun2socks 已退出，正在重建连接（状态 43）"
        assertEquals(message, LogRedactor.redact(message))
    }
}
