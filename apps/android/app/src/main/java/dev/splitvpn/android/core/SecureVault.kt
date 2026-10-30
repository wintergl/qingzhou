package dev.splitvpn.android.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound Android Keystore encryption; preferences only hold non-secret metadata. */
class SecureVault(context: Context) {
    private val directory = File(context.filesDir, "secure-secrets")
    @Synchronized fun load(account: String): String? {
        val file = file(account)
        if (!file.baseFile.exists()) return null
        return try {
            val record = JSONObject(String(file.readFully(), Charsets.UTF_8))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(record.getString("iv"), Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(record.getString("data"), Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (error: Exception) { throw IOException("安全存储暂不可用，原有凭据已保留。", error) }
    }
    @Synchronized fun save(account: String, value: String?) {
        val file = file(account)
        if (value == null) { file.delete(); return }
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val record = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("data", Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP))
            directory.mkdirs()
            val stream = file.startWrite()
            try { stream.write(record.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
            catch (error: Exception) { file.failWrite(stream); throw error }
        } catch (error: Exception) { throw IOException("无法保存安全凭据，原有配置未清除。", error) }
    }
    private fun file(account: String): AtomicFile {
        require(account.matches(Regex("[a-z-]{1,32}")))
        return AtomicFile(File(directory, "$account.bin"))
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    companion object { private const val ALIAS = "dev.splitvpn.android.secrets" }
}
