package dev.splitvpn.android.core

/** Writes mihomo's config through the Rust core and points the controller client at it. */
class MihomoConfigGenerator(
    private val core: CoreClient,
    private val settingsRepository: SettingsRepository
) {
    fun generate(): MihomoConfig = core.generateMihomoConfig(settingsRepository).also {
        MihomoControllerClient.configure(it.controller, it.secret)
    }
}
