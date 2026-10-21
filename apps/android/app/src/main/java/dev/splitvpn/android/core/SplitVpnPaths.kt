package dev.splitvpn.android.core

import android.content.Context
import java.io.File

/** [appDataDir] is also the Rust core root; mihomo runs in its `mihomo/` subdirectory. */
class SplitVpnPaths(context: Context) {
    val appDataDir = File(context.filesDir, "split-vpn")
    val mihomoDataDir = File(appDataDir, "mihomo")
    val providerDir = File(mihomoDataDir, "providers")
    val logFile = File(appDataDir, "service.log")

    fun ensure() {
        listOf(appDataDir, mihomoDataDir, providerDir).forEach { dir ->
            if (!dir.exists() && !dir.mkdirs()) {
                error("Cannot create directory: ${dir.absolutePath}")
            }
        }
    }
}
