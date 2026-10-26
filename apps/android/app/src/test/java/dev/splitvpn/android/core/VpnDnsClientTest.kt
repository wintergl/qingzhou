package dev.splitvpn.android.core

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

class VpnDnsClientTest {
    private val host = "android.chat.openai.com"

    private fun question(name: String = host): ByteArray = ByteArrayOutputStream().also { bytes ->
        DataOutputStream(bytes).use { out ->
            out.writeShort(42); out.writeShort(0x100); out.writeShort(1)
            repeat(3) { out.writeShort(0) }
            name.split('.').forEach { label -> out.writeByte(label.length); out.writeBytes(label) }
            out.writeByte(0); out.writeShort(1); out.writeShort(1)
        }
    }.toByteArray()

    private fun answer(query: ByteArray, flags: Int = 0x8180): ByteArray {
        val bytes = query.copyOf()
        bytes[2] = (flags ushr 8).toByte(); bytes[3] = flags.toByte()
        bytes[6] = 0; bytes[7] = 1
        return bytes + byteArrayOf(0xC0.toByte(), 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 198.toByte(), 18, 1, 9)
    }

    private fun handshake(socket: Socket): DataInputStream {
        socket.soTimeout = 2_000
        val input = DataInputStream(socket.getInputStream())
        val greeting = ByteArray(3); input.readFully(greeting)
        assertArrayEquals(byteArrayOf(5, 1, 0), greeting)
        socket.getOutputStream().write(byteArrayOf(5, 0))
        return input
    }

    private fun acceptConnect(socket: Socket, input: DataInputStream, address: ByteArray, port: Int) {
        val request = ByteArray(10); input.readFully(request)
        assertArrayEquals(byteArrayOf(5, 1, 0, 1) + address + byteArrayOf((port ushr 8).toByte(), port.toByte()), request)
        socket.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
    }

    @Test fun dnsTraversesSocksAndAcceptsFakeIpResponse() {
        ServerSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            val task = executor.submit {
                server.accept().use { socket ->
                    val input = handshake(socket)
                    acceptConnect(socket, input, byteArrayOf(172.toByte(), 19, 0, 2), 53)
                    val query = ByteArray(input.readUnsignedShort()); input.readFully(query)
                    val response = answer(query)
                    // Fragment both the length prefix and DNS body.
                    val framed = byteArrayOf((response.size ushr 8).toByte(), response.size.toByte()) + response
                    framed.forEach { socket.getOutputStream().write(it.toInt()); socket.getOutputStream().flush() }
                }
            }
            try {
                val result = VpnDnsClient(proxy = InetSocketAddress("127.0.0.1", server.localPort)).resolveA()
                assertEquals("198.18.1.9", result.hostAddress)
                task.get(3, TimeUnit.SECONDS)
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun failedOrTruncatedOrMismatchedDnsNeverCountsAsHealthy() {
        for (flags in listOf(0x8183, 0x8380, 0x0180)) {
            assertThrows(IOException::class.java) { VpnDnsClient.parseAddress(answer(question(), flags), host, 42) }
        }
        assertThrows(IOException::class.java) { VpnDnsClient.parseAddress(answer(question()), host, 43) }
        assertThrows(IOException::class.java) { VpnDnsClient.parseAddress(answer(question("other.example.test")), host, 42) }
        assertThrows(IOException::class.java) { VpnDnsClient.parseAddress(answer(question()).dropLast(1).toByteArray(), host, 42) }
        val loop = answer(question())
        loop[12] = 0xC0.toByte(); loop[13] = 12
        assertThrows(IOException::class.java) { VpnDnsClient.parseAddress(loop, host, 42) }
    }

    @Test fun oneDeadlineBoundsMultipleSocksAndDnsReads() {
        ServerSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            val task = executor.submit {
                server.accept().use { socket ->
                    val input = handshake(socket)
                    Thread.sleep(100)
                    acceptConnect(socket, input, byteArrayOf(172.toByte(), 19, 0, 2), 53)
                    val query = ByteArray(input.readUnsignedShort()); input.readFully(query)
                    Thread.sleep(400)
                    runCatching { DataOutputStream(socket.getOutputStream()).apply { writeShort(answer(query).size); write(answer(query)); flush() } }
                }
            }
            try {
                val start = System.nanoTime()
                assertThrows(IOException::class.java) {
                    VpnDnsClient(proxy = InetSocketAddress("127.0.0.1", server.localPort), timeoutMs = 300).resolveA()
                }
                assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 900)
                task.get(3, TimeUnit.SECONDS)
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun hardDeadlineStopsSlowDripTlsPeer() {
        ServerSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            val task = executor.submit {
                server.accept().use { socket ->
                    val input = handshake(socket)
                    acceptConnect(socket, input, byteArrayOf(172.toByte(), 19, 0, 2), 53)
                    val query = ByteArray(input.readUnsignedShort()); input.readFully(query)
                    DataOutputStream(socket.getOutputStream()).apply { writeShort(answer(query).size); write(answer(query)); flush() }
                }
                server.accept().use { socket ->
                    val input = handshake(socket)
                    acceptConnect(socket, input, byteArrayOf(198.toByte(), 18, 1, 9), 443)
                    runCatching {
                        socket.getOutputStream().write(byteArrayOf(22, 3, 3, 62, 0))
                        repeat(20) { socket.getOutputStream().write(0); socket.getOutputStream().flush(); Thread.sleep(80) }
                    }
                }
            }
            try {
                val start = System.nanoTime()
                assertThrows(VpnTlsFailure::class.java) {
                    VpnDnsClient(proxy = InetSocketAddress("127.0.0.1", server.localPort), timeoutMs = 350).requireHealthy()
                }
                assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 1_000)
                task.get(3, TimeUnit.SECONDS)
            } finally { executor.shutdownNow() }
        }
    }

    private fun tlsFixtureProbe(probeHost: String): Exception? {
        val store = KeyStore.getInstance("PKCS12")
        // Generate an ephemeral test identity; never distribute a private key fixture.
        val directory = java.nio.file.Files.createTempDirectory("vpn-tls-fixture").toFile()
        try {
            val keyFile = java.io.File(directory, "test.p12")
            val keytool = java.io.File(System.getProperty("java.home"), "bin/keytool").absolutePath
            val process = ProcessBuilder(keytool, "-genkeypair", "-alias", "fixture",
                "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
                "-dname", "CN=wrong.example.test", "-ext", "SAN=dns:wrong.example.test",
                "-storetype", "PKCS12", "-keystore", keyFile.absolutePath,
                "-storepass", "fixture-password", "-noprompt")
                .redirectErrorStream(true).redirectOutput(java.io.File(directory, "keytool.log")).start()
            try {
                check(process.waitFor(30, TimeUnit.SECONDS)) { "Test certificate generation timed out" }
                check(process.exitValue() == 0) { "Test certificate generation failed" }
                keyFile.inputStream().use { store.load(it, "fixture-password".toCharArray()) }
            } finally { if (process.isAlive) process.destroyForcibly() }
        } finally { directory.deleteRecursively() }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, "fixture-password".toCharArray()) }
        val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        val serverTls = SSLContext.getInstance("TLS").apply { init(keys.keyManagers, null, null) }
        val clientTls = SSLContext.getInstance("TLS").apply { init(null, trust.trustManagers, null) }
        ServerSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            val task = executor.submit {
                server.accept().use { socket ->
                    val input = handshake(socket)
                    acceptConnect(socket, input, byteArrayOf(172.toByte(), 19, 0, 2), 53)
                    val query = ByteArray(input.readUnsignedShort()); input.readFully(query)
                    DataOutputStream(socket.getOutputStream()).apply { writeShort(answer(query).size); write(answer(query)); flush() }
                }
                server.accept().use { socket ->
                    val input = handshake(socket)
                    acceptConnect(socket, input, byteArrayOf(198.toByte(), 18, 1, 9), 443)
                    (serverTls.socketFactory.createSocket(socket, "localhost", socket.port, true) as javax.net.ssl.SSLSocket).use { tls ->
                        tls.useClientMode = false
                        runCatching { tls.startHandshake() }
                    }
                }
            }
            try {
                val error = runCatching {
                    VpnDnsClient(proxy = InetSocketAddress("127.0.0.1", server.localPort), hostname = probeHost,
                        tlsFactory = clientTls.socketFactory).requireHealthy()
                }.exceptionOrNull()
                task.get(3, TimeUnit.SECONDS)
                return error as? Exception
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun tlsAcceptsValidTrustedHostnameAfterDnsFakeIp() {
        assertNull(tlsFixtureProbe("wrong.example.test"))
    }

    @Test fun tlsRejectsTrustedCertificateForWrongHostname() {
        val error = tlsFixtureProbe(host)
        assertTrue(error is VpnTlsFailure)
        assertTrue(error?.cause is javax.net.ssl.SSLHandshakeException)
    }
}
