package dev.splitvpn.android.core

import java.time.Instant

object ServiceLogRepository {
    private const val MAX_LOG_BYTES = 256 * 1024L
    private const val RETAIN_LINES = 160

    @Synchronized fun append(paths: SplitVpnPaths, message: String) {
        runCatching {
            paths.ensure()
            paths.logFile.appendText("${Instant.now()} ${LogRedactor.redact(message)}\n", Charsets.UTF_8)
            trimIfNeeded(paths)
        }
    }

    @Synchronized fun readTail(paths: SplitVpnPaths, maxLines: Int = 80): List<String> {
        return runCatching {
            if (!paths.logFile.exists()) return@runCatching emptyList()
            paths.logFile.readLines(Charsets.UTF_8).takeLast(maxLines).map(LogRedactor::redact)
        }.getOrDefault(emptyList())
    }

    private fun trimIfNeeded(paths: SplitVpnPaths) {
        if (!paths.logFile.exists() || paths.logFile.length() <= MAX_LOG_BYTES) return
        val tail = paths.logFile.readLines(Charsets.UTF_8).takeLast(RETAIN_LINES).joinToString("\n")
        FileUtil.writeUtf8(paths.logFile, tail + "\n")
    }
}
