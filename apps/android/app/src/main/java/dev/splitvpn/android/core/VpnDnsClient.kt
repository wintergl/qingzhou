package dev.splitvpn.android.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InterruptedIOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

class VpnDnsFailure(cause: Exception) : IOException("VPN DNS path failed", cause)
class VpnTlsFailure(cause: Exception) : IOException("VPN DNS-resolved HTTPS path failed", cause)

/**
 * Checks the same DNS destination and IP-based SOCKS route used by applications.
 * The service UID is excluded from Android VPN routing, so ordinary URLConnection
 * or InetAddress lookups here would silently test the physical network instead.
 * This check covers mixed-port/DNS/Fake-IP/TLS; TUN and tun2socks still need device
 * validation and their existing process/session monitoring.
 */
class VpnDnsClient internal constructor(
    private val proxy: InetSocketAddress = InetSocketAddress("127.0.0.1", 7890),
    private val dnsAddress: ByteArray = byteArrayOf(172.toByte(), 19, 0, 2),
    private val hostname: String = "android.chat.openai.com",
    private val timeoutMs: Int = 6_000,
    private val tlsFactory: SSLSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory
) {
    init {
        require(timeoutMs in 100..30_000)
        require(dnsAddress.size == 4)
    }

    fun requireHealthy() {
        Deadline(timeoutMs).use { deadline ->
            val address = try {
                resolveA(deadline)
            } catch (error: Exception) {
                throw VpnDnsFailure(error)
            }
            try {
                openSocks(address.address, 443, deadline).use { transport ->
                    val tls = tlsFactory.createSocket(transport, hostname, 443, true) as SSLSocket
                    tls.use {
                        it.soTimeout = deadline.remainingMs()
                        it.sslParameters = it.sslParameters.apply {
                            endpointIdentificationAlgorithm = "HTTPS"
                        }
                        it.startHandshake()
                        deadline.remainingMs()
                    }
                }
            } catch (error: Exception) {
                throw VpnTlsFailure(error)
            }
        }
    }

    internal fun resolveA(): Inet4Address = Deadline(timeoutMs).use { resolveA(it) }

    private fun resolveA(deadline: Deadline): Inet4Address {
        val id = SecureRandom().nextInt(65_536)
        val query = dnsQuery(hostname, id)
        return openSocks(dnsAddress, 53, deadline).use { socket ->
            val output = DataOutputStream(socket.getOutputStream())
            output.writeShort(query.size)
            output.write(query)
            output.flush()
            val length = readBytes(socket, 2, deadline).let { u16(it, 0) }
            if (length !in 12..4_096) throw IOException("Invalid DNS frame length")
            parseAddress(readBytes(socket, length, deadline), hostname, id)
        }
    }

    private fun openSocks(address: ByteArray, port: Int, deadline: Deadline): Socket {
        require(address.size == 4)
        val socket = Socket().also(deadline::register)
        try {
            socket.connect(proxy, deadline.remainingMs())
            socket.soTimeout = deadline.remainingMs()
            val output = socket.getOutputStream()
            output.write(byteArrayOf(5, 1, 0))
            output.flush()
            if (!readBytes(socket, 2, deadline).contentEquals(byteArrayOf(5, 0)))
                throw IOException("SOCKS authentication unavailable")
            output.write(byteArrayOf(5, 1, 0, 1) + address + byteArrayOf((port ushr 8).toByte(), port.toByte()))
            output.flush()
            val reply = readBytes(socket, 4, deadline)
            if (reply[0] != 5.toByte() || reply[1] != 0.toByte() || reply[2] != 0.toByte())
                throw IOException("SOCKS connection rejected")
            val boundLength = when (reply[3].toInt() and 255) {
                1 -> 4
                4 -> 16
                3 -> readBytes(socket, 1, deadline)[0].toInt() and 255
                else -> throw IOException("Invalid SOCKS address type")
            }
            readBytes(socket, boundLength + 2, deadline)
            return socket
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    private class Deadline(timeoutMs: Int) : Closeable {
        private val end = System.nanoTime() + timeoutMs * 1_000_000L
        private val sockets = ConcurrentHashMap.newKeySet<Socket>()
        private val expiry = deadlineExecutor.schedule({ sockets.forEach { runCatching { it.close() } } },
            timeoutMs.toLong(), TimeUnit.MILLISECONDS)

        fun register(socket: Socket) {
            sockets.add(socket)
            try { remainingMs() } catch (error: Exception) { socket.close(); throw error }
        }

        override fun close() {
            expiry.cancel(false)
            sockets.forEach { runCatching { it.close() } }
            sockets.clear()
        }
        fun remainingMs(): Int {
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("VPN probe cancelled")
            val remaining = end - System.nanoTime()
            if (remaining <= 0) throw SocketTimeoutException("VPN probe deadline exceeded")
            return ((remaining + 999_999) / 1_000_000).toInt().coerceAtLeast(1)
        }
    }

    companion object {
        // One daemon scheduler, with cancelled tasks immediately removed. A hard
        // socket-close deadline also bounds peers that drip TLS records forever.
        private val deadlineExecutor = ScheduledThreadPoolExecutor(1) { runnable ->
            Thread(runnable, "vpn-probe-deadline").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }

        private fun readBytes(socket: Socket, size: Int, deadline: Deadline): ByteArray {
            val bytes = ByteArray(size)
            var offset = 0
            val input = socket.getInputStream()
            while (offset < size) {
                socket.soTimeout = deadline.remainingMs()
                val count = input.read(bytes, offset, size - offset)
                if (count < 0) throw IOException("Truncated VPN probe response")
                offset += count
            }
            return bytes
        }

        private fun dnsQuery(hostname: String, id: Int): ByteArray {
            val bytes = ByteArrayOutputStream()
            DataOutputStream(bytes).use { out ->
                out.writeShort(id); out.writeShort(0x100); out.writeShort(1)
                out.writeShort(0); out.writeShort(0); out.writeShort(0)
                for (label in hostname.split('.')) {
                    val encoded = label.toByteArray(Charsets.US_ASCII)
                    require(encoded.size in 1..63)
                    out.writeByte(encoded.size); out.write(encoded)
                }
                out.writeByte(0); out.writeShort(1); out.writeShort(1)
            }
            return bytes.toByteArray()
        }

        private fun u16(data: ByteArray, offset: Int): Int {
            if (offset < 0 || offset + 2 > data.size) throw IOException("Truncated DNS response")
            return ((data[offset].toInt() and 255) shl 8) or (data[offset + 1].toInt() and 255)
        }

        /** Validates the question and follows only its answer CNAME chain. */
        internal fun parseAddress(data: ByteArray, hostname: String, id: Int): Inet4Address {
            if (data.size < 12 || u16(data, 0) != id) throw IOException("DNS transaction mismatch")
            val flags = u16(data, 2)
            if (flags and 0x8000 == 0 || flags and 0x7A0F != 0 || u16(data, 4) != 1)
                throw IOException("DNS response failed or truncated")
            val reader = DnsReader(data)
            val question = reader.name(12)
            if (!question.first.equals(hostname, ignoreCase = true) ||
                u16(data, question.second) != 1 || u16(data, question.second + 2) != 1)
                throw IOException("DNS question mismatch")
            var offset = question.second + 4
            val aliases = mutableMapOf<String, String>()
            val addresses = mutableMapOf<String, Inet4Address>()
            repeat(u16(data, 6)) {
                val owner = reader.name(offset)
                offset = owner.second
                val type = u16(data, offset)
                val clazz = u16(data, offset + 2)
                val length = u16(data, offset + 8)
                offset += 10
                if (offset + length > data.size) throw IOException("Truncated DNS answer")
                if (clazz == 1 && type == 1 && length == 4) {
                    addresses[owner.first.lowercase()] = InetAddress.getByAddress(data.copyOfRange(offset, offset + 4)) as Inet4Address
                } else if (clazz == 1 && type == 5) {
                    val alias = reader.name(offset)
                    if (alias.second > offset + length) throw IOException("Invalid CNAME length")
                    aliases[owner.first.lowercase()] = alias.first.lowercase()
                }
                offset += length
            }
            var current = hostname.lowercase()
            val visited = mutableSetOf<String>()
            repeat(16) {
                if (!visited.add(current)) throw IOException("DNS CNAME loop")
                addresses[current]?.let { address ->
                    if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isMulticastAddress)
                        throw IOException("Unusable DNS answer")
                    return address
                }
                current = aliases[current] ?: throw IOException("DNS returned no IPv4 answer")
            }
            throw IOException("DNS CNAME chain too long")
        }

        private class DnsReader(private val data: ByteArray) {
            fun name(start: Int): Pair<String, Int> {
                val labels = mutableListOf<String>()
                val visited = mutableSetOf<Int>()
                var offset = start
                var next: Int? = null
                while (true) {
                    if (offset !in data.indices || !visited.add(offset) || visited.size > 128)
                        throw IOException("Invalid DNS name")
                    val size = data[offset].toInt() and 255
                    if (size and 192 == 192) {
                        val pointer = u16(data, offset) and 0x3FFF
                        if (next == null) next = offset + 2
                        offset = pointer
                    } else {
                        if (size > 63 || offset + 1 + size > data.size) throw IOException("Invalid DNS label")
                        offset++
                        if (size == 0) return labels.joinToString(".") to (next ?: offset)
                        labels += String(data, offset, size, Charsets.US_ASCII)
                        offset += size
                    }
                }
            }
        }
    }
}
