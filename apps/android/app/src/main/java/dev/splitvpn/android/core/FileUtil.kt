package dev.splitvpn.android.core

import java.io.File

object FileUtil {
    fun writeUtf8(file: File, content: String) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, ".${file.name}.tmp")
        temp.writeText(content, Charsets.UTF_8)
        if (!temp.renameTo(file)) {
            file.delete()
            if (!temp.renameTo(file)) {
                error("Cannot replace file: ${file.absolutePath}")
            }
        }
    }

    fun readUtf8(file: File): String = file.readText(Charsets.UTF_8)
}
