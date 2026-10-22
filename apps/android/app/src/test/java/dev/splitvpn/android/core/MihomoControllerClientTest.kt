package dev.splitvpn.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MihomoControllerClientTest {
    @Test fun vpnHttpsProbeUsesTheSelectedGroupAndEncodesTheTarget() {
        assertEquals(
            "/proxies/VPN/delay?url=https%3A%2F%2Fchatgpt.com%2Fcdn-cgi%2Ftrace&timeout=5000&expected=200-599",
            MihomoControllerClient.vpnHttpsProbePath("https://chatgpt.com/cdn-cgi/trace", 5_000)
        )
    }

    @Test fun vpnHttpsProbeRejectsNonHttpsTargetsAndUnboundedTimeouts() {
        assertThrows(IllegalArgumentException::class.java) {
            MihomoControllerClient.vpnHttpsProbePath("http://example.test", 5_000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            MihomoControllerClient.vpnHttpsProbePath("https://example.test", 60_000)
        }
    }
}
