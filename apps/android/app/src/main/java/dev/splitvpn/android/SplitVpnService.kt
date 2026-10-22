package dev.splitvpn.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.provider.Telephony
import dev.splitvpn.android.runtime.AndroidEnvironmentMonitor
import dev.splitvpn.android.runtime.HealthDecision
import dev.splitvpn.android.runtime.HealthProbePolicy
import dev.splitvpn.android.runtime.HealthProbeToken
import dev.splitvpn.android.runtime.LifecycleGate
import dev.splitvpn.android.runtime.NetworkState
import dev.splitvpn.android.runtime.PowerState
import dev.splitvpn.android.runtime.ProbeFailureKind
import dev.splitvpn.android.runtime.ProbeOutcome
import dev.splitvpn.android.runtime.RecoveryPolicy
import dev.splitvpn.android.runtime.shouldProbeVpnEgress
import dev.splitvpn.android.core.CoreClient
import dev.splitvpn.android.core.RecoveryEventCoalescer
import dev.splitvpn.android.core.MihomoConfigGenerator
import dev.splitvpn.android.core.MihomoConfig
import dev.splitvpn.android.core.MihomoControllerClient
import dev.splitvpn.android.core.RuntimeStatusRepository
import dev.splitvpn.android.core.ServiceLogRepository
import dev.splitvpn.android.core.SettingsRepository
import dev.splitvpn.android.core.SplitVpnPaths
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture

class SplitVpnService : VpnService() {
    private var mihomoProcess: Process? = null
    private var tun2socksPid: Int = 0
    @Volatile private var startupThread: Thread? = null
    private var logThread: Thread? = null
    private var tunInterface: ParcelFileDescriptor? = null
    private val dataPlaneExecutor = lifecycleExecutor
    private val monitorExecutor = Executors.newSingleThreadScheduledExecutor()
    private val probeExecutor = Executors.newSingleThreadExecutor()
    private var monitorTask: ScheduledFuture<*>? = null
    private var retryTask: ScheduledFuture<*>? = null
    private var healthProbeTask: Future<*>? = null
    private var healthProbeToken: HealthProbeToken? = null
    private val gate = LifecycleGate()
    private val recovery = RecoveryPolicy()
    private val recoveryEvents = RecoveryEventCoalescer()
    private var operationRecoveryToken: Long? = null
    private var environment: AndroidEnvironmentMonitor? = null
    @Volatile private var network = NetworkState.Unknown
    @Volatile private var power = PowerState()
    @Volatile private var destroyed = false
    @Volatile private var managedAlwaysOn = false
    private var sessionGeneration = 0L
    private val healthProbePolicy = HealthProbePolicy()
    private val runtime by lazy { RuntimeStatusRepository(this) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val commandLock = Any()
    private var operationRevision = 0L
    @Volatile private var stopRequested = false
    @Volatile
    private var preserveErrorState = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        managedAlwaysOn = if (Build.VERSION.SDK_INT >= 29) isAlwaysOn
            else managedAlwaysOn || intent?.action == SERVICE_INTERFACE
        runtime.setAlwaysOn(managedAlwaysOn)
        if (intent?.action == ACTION_STOP) {
            if (managedAlwaysOn) {
                // A stale notification action must not defeat system always-on.
                return onStartCommand(Intent(this, SplitVpnService::class.java).setAction(ACTION_START), flags, startId)
            }
            runtime.setConnectWanted(false)
            val revision = synchronized(commandLock) {
                stopRequested = true
                isActive = false
                startupThread?.interrupt()
                recoveryEvents.reset()
                gate.stop()
            }
            dataPlaneExecutor.execute {
                if (gate.revision != revision) return@execute
                cancelRetry()
                stopDataPlane(markStopped = true)
                mainHandler.post { if (gate.revision == revision && !gate.wanted) stopSelf(startId) }
            }
            return START_NOT_STICKY
        }
        val explicit = intent?.action == ACTION_START || intent?.action == ACTION_RETRY
        if (!explicit && !runtime.connectWanted() && !managedAlwaysOn) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, createNotification("正在启动轻舟"))
        if (!runtime.setConnectWanted(true)) {
            runtime.markError("无法保存连接状态，请检查手机存储后重试。")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val revision = synchronized(commandLock) {
            stopRequested = false
            preserveErrorState = false
            activeService = this
            isActive = true
            startupThread?.interrupt()
            recoveryEvents.reset()
            gate.start()
        }
        if (environment == null) {
            environment = AndroidEnvironmentMonitor(this, { uiVisible }, { onNetworkChanged(it) }, ::onPowerChanged)
            network = environment!!.start()
        }
        dataPlaneExecutor.execute {
            if (!gate.accepts(revision)) return@execute
            recovery.reset()
            requestConnection(revision, 0, "正在连接")
        }
        return START_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        environment?.close()
        synchronized(commandLock) {
            isActive = false
            if (activeService === this) activeService = null
            gate.stop()
            recoveryEvents.reset()
            stopRequested = true
            startupThread?.interrupt()
        }
        monitorExecutor.shutdownNow()
        probeExecutor.shutdownNow()
        dataPlaneExecutor.execute {
            cancelRetry()
            stopDataPlane(markStopped = !preserveErrorState && !runtime.connectWanted())
            if (!preserveErrorState && runtime.connectWanted())
                runtime.markRecovering("等待 Android 重建连接服务", SettingsRepository(this).getSelectedProxy())
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        runtime.setConnectWanted(false)
        synchronized(commandLock) {
            gate.stop()
            recoveryEvents.reset()
            stopRequested = true
            startupThread?.interrupt()
            preserveErrorState = true
        }
        RuntimeStatusRepository(this).markError("Android VPN 权限已被系统撤销。")
        appendLog("Android VPN permission revoked")
        stopSelf()
        super.onRevoke()
    }

    private fun cancelRetry() { retryTask?.cancel(false); retryTask = null }

    /** Runs only on the shared lifecycle queue. Waiting for network does not spin. */
    private fun requestConnection(revision: Long, delayMs: Long, reason: String) {
        if (destroyed || !gate.accepts(revision)) return
        cancelRetry()
        val proxy = SettingsRepository(this).getSelectedProxy()
        if (power.idle) {
            runtime.markRecovering("设备休眠中，唤醒后自动恢复", proxy)
            updateNotification("设备休眠中，唤醒后自动恢复")
            return
        }
        if (network.available == false) {
            stopDataPlane(markStopped = false, removeForeground = false)
            runtime.markRecovering("网络暂不可用，联网后自动恢复", proxy, waitingNetwork = true)
            updateNotification("等待网络，联网后自动恢复")
            scheduleHealthCheck()
            return
        }
        if (delayMs > 0) {
            runtime.markRecovering(reason, proxy, delayMs)
            updateNotification(if (delayMs >= 1_000L) "$reason · ${delayMs / 1000} 秒后重试" else reason)
            retryTask = monitorExecutor.schedule({
                dataPlaneExecutor.execute { runConnection(revision) }
            }, delayMs, TimeUnit.MILLISECONDS)
        } else runConnection(revision)
    }

    private fun runConnection(revision: Long) {
        if (destroyed || !gate.accepts(revision)) return
        if (power.idle) { requestConnection(revision, 0, "设备唤醒后恢复连接"); return }
        if (network.available == false) { requestConnection(revision, 0, "等待网络"); return }
        retryTask = null
        operationRevision = revision
        startupThread = Thread.currentThread()
        // Bound the wake lock to one rebuild. No lock is held while connected or backing off.
        val wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:rebuild")
        try {
            runCatching { wake.acquire(30_000L) }
            startMihomoIfAvailable()
        } finally {
            if (wake.isHeld) runCatching { wake.release() }
            startupThread = null
            Thread.interrupted()
        }
    }

    private fun onNetworkChanged(next: NetworkState, force: Boolean = false) {
        if (destroyed || (next == network && !force)) return
        network = next
        if (!gate.wanted) return
        val recoveryKey = if (next.available == null) "unknown:${gate.revision}"
            else "${next.available}:${next.signature}"
        val recoveryToken = recoveryEvents.request(recoveryKey) ?: return
        val revision = synchronized(commandLock) { startupThread?.interrupt(); gate.change() }
        dataPlaneExecutor.execute {
            if (!gate.accepts(revision)) return@execute
            operationRecoveryToken = recoveryToken
            recovery.reset()
            runtime.invalidateNetwork()
            stopDataPlane(markStopped = false, removeForeground = false)
            requestConnection(revision, 500L, "网络变化，正在恢复原有连接")
        }
    }

    private fun onPowerChanged(next: PowerState) {
        val previous = power
        power = next
        if (!gate.wanted || destroyed) return
        if (next.idle) {
            // A rebuild already running must not acquire/extend work in Doze.
            synchronized(commandLock) { startupThread?.interrupt() }
            dataPlaneExecutor.execute {
                cancelRetry()
                monitorTask?.cancel(false)
                monitorTask = null
                cancelHealthProbe()
                healthProbePolicy.reset()
                if (runtime.get().state != RuntimeStatusRepository.STATE_CONNECTED) {
                    val proxy = SettingsRepository(this).getSelectedProxy()
                    runtime.markRecovering("设备休眠中，唤醒后自动恢复", proxy)
                    updateNotification("设备休眠中，唤醒后自动恢复")
                }
            }
            return
        }
        if (previous.idle && !next.idle) {
            val currentNetwork = environment?.readNetwork() ?: network
            if (currentNetwork != network) {
                onNetworkChanged(currentNetwork)
            } else {
                dataPlaneExecutor.execute {
                    if (!gate.wanted || destroyed) return@execute
                    healthProbePolicy.reset()
                    if (runtime.get().state == RuntimeStatusRepository.STATE_CONNECTED) {
                        scheduleHealthCheck(1_000L)
                    } else {
                        recovery.reset()
                        requestConnection(gate.revision, 0, "设备已唤醒，正在恢复连接")
                    }
                }
            }
            return
        }
        dataPlaneExecutor.execute {
            if (!gate.wanted || destroyed) return@execute
            // Timers never wake a sleeping device. On wake, check promptly for missed events.
            scheduleHealthCheck(if ((!previous.interactive && next.interactive) || (previous.idle && !next.idle)) 1_000L else next.healthIntervalMs)
        }
    }

    private fun stopDataPlane(markStopped: Boolean, removeForeground: Boolean = true) {
        sessionGeneration++
        monitorTask?.cancel(false)
        monitorTask = null
        cancelHealthProbe()
        healthProbePolicy.reset()
        val hasDataPlaneResources = startupThread != null ||
            tun2socksPid > 0 ||
            mihomoProcess != null ||
            logThread != null ||
            tunInterface != null
        val runtimeRepository = RuntimeStatusRepository(this)
        if (!hasDataPlaneResources) {
            if (markStopped) runtimeRepository.markStopped()
            if (removeForeground) stopForeground(STOP_FOREGROUND_REMOVE)
            return
        }
        if (markStopped) runtimeRepository.markStopping()
        appendLog("Stopping VPN data plane")
        if (tun2socksPid > 0) {
            runCatching { stopNativeProcess(tun2socksPid) }
                .onFailure { appendLog("停止 tun2socks 失败：${it.message}") }
            tun2socksPid = 0
        }
        // Release captured traffic before waiting for Mihomo to terminate.
        runCatching { tunInterface?.close() }
            .onFailure { appendLog("关闭 TUN 失败：${it.message}") }
        tunInterface = null
        var mihomoStopError: String? = null
        mihomoProcess?.let { process ->
            runCatching { stopMihomoProcess(process) }
                .onSuccess { mihomoProcess = null }
                .onFailure { error ->
                    val message = "Mihomo 停止不完整：${error.message ?: error.javaClass.simpleName}"
                    mihomoStopError = message
                    appendLog(message)
                }
        }
        logThread?.interrupt()
        logThread = null
        if (markStopped) {
            val stopError = mihomoStopError
            if (stopError == null) {
                runtimeRepository.markStopped()
                appendLog("VPN data plane stopped")
            } else {
                runtimeRepository.markError(stopError)
                appendLog("VPN data plane stop failed; system TUN closed but Mihomo may still be running")
            }
        }
        if (removeForeground) stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun stopMihomoProcess(process: Process) {
        if (!process.isAlive) return

        process.destroy()
        if (process.waitFor(MIHOMO_STOP_GRACE_MS, TimeUnit.MILLISECONDS)) return

        appendLog("Mihomo did not exit during the grace period; forcing stop")
        process.destroyForcibly()
        if (!process.waitFor(MIHOMO_FORCE_STOP_TIMEOUT_MS, TimeUnit.MILLISECONDS) || process.isAlive) {
            error("强制停止后 ${MIHOMO_FORCE_STOP_TIMEOUT_MS}ms 内仍未退出")
        }
    }

    private fun startMihomoIfAvailable() {
        val paths = SplitVpnPaths(this)
        val settingsRepository = SettingsRepository(this)
        val selectedProxy = settingsRepository.getSelectedProxy()
        val runtimeRepository = RuntimeStatusRepository(this)
        try {
            checkStarting()
            if (prepare(this) != null) throw PermanentVpnFailure("Android VPN 权限需要重新授权，请点连接后确认。")
            val config = MihomoConfigGenerator(CoreClient(paths), settingsRepository).generate()
            if (!config.selectionValid) throw PermanentVpnFailure(config.selectionError)
            if (mihomoProcess?.isAlive == true && tun2socksPid > 0) {
                applyRunningConfig(config)
                return
            }
            stopDataPlane(markStopped = false, removeForeground = false)
            check(mihomoProcess == null) { "旧内核尚未退出，稍后重试。" }
            checkStarting()
            runtimeRepository.markStarting(config.selectedProxy)
            paths.ensure()
            val mihomoBinary = File(applicationInfo.nativeLibraryDir, "libmihomo.so")
            val tun2socksBinary = File(applicationInfo.nativeLibraryDir, "libtun2socks.so")
            if (!mihomoBinary.exists() || !tun2socksBinary.exists())
                throw PermanentVpnFailure("安装包缺少 Android 内核，请重新安装完整 APK。")
            prepareBundledGeodata(paths)
            checkStarting()
            val process = ProcessBuilder(
                mihomoBinary.absolutePath,
                "-d",
                config.homeDir,
                "-f",
                config.configFile
            ).redirectErrorStream(true).start()
            mihomoProcess = process
            appendLog("Mihomo started")
            logThread = Thread({ pipeLogs(process) }, "mihomo-log").also { it.start() }

            waitForMihomoController()
            selectProxyWithRetry(config.selectedProxy)
            checkStarting()

            // Do not capture Wi-Fi traffic while the local proxy is still starting.
            // Child processes use the system default network, so each rebuild
            // opens fresh upstream sockets after the physical network changes.
            tunInterface = establishTun()
            val tunFd = tunInterface?.fd ?: error("Android VPN TUN 建立失败。")
            checkStarting()
            tun2socksPid = startTun2SocksNative(
                tun2socksBinary.absolutePath,
                tunFd,
                "socks5://127.0.0.1:${CoreClient.MIXED_PORT}",
                VPN_MTU,
                paths.logFile.absolutePath
            )
            if (tun2socksPid <= 0) {
                error("tun2socks native 启动失败：$tun2socksPid")
            }
            checkStarting()
            requireDataPlaneAlive()
            appendLog("tun2socks native started pid=$tun2socksPid fd=$tunFd")
            publishConnected(config.selectedProxy)
            startDataPlaneMonitor()
        } catch (error: InterruptedException) {
            Thread.interrupted()
            if (gate.accepts(operationRevision) && !stopRequested) {
                val message = "VPN 数据面启动被中断。"
                failDataPlane(message)
            } else stopDataPlane(markStopped = false, removeForeground = !gate.wanted)
        } catch (error: PermanentVpnFailure) {
            if (gate.accepts(operationRevision)) stopWithError(error.message.orEmpty(), selectedProxy)
        } catch (error: Exception) {
            val message = "VPN 数据面启动失败：${error.message ?: error.javaClass.simpleName}"
            if (gate.accepts(operationRevision) && !stopRequested) failDataPlane(message)
            else stopDataPlane(markStopped = false, removeForeground = !gate.wanted)
        }
    }

    private fun checkStarting() {
        if (stopRequested || destroyed || !gate.accepts(operationRevision) || Thread.currentThread().isInterrupted) throw InterruptedException()
    }

    private fun publishConnected(selectedProxy: String) = synchronized(commandLock) {
        checkStarting()
        RuntimeStatusRepository(this).markConnected(selectedProxy, tun2socksPid)
        recovery.connected(SystemClock.elapsedRealtime())
        recoveryEvents.finish(operationRecoveryToken)
        operationRecoveryToken = null
        healthProbePolicy.reset()
        updateNotification("轻舟已连接：$selectedProxy")
    }

    private fun requireDataPlaneAlive() {
        require(mihomoProcess?.isAlive == true) { "Mihomo 进程已退出。" }
        val status = nativeProcessStatus(tun2socksPid)
        if (status != 0) {
            tun2socksPid = 0 // The native probe reaped it; never signal a reused PID.
            error("tun2socks 进程已退出（状态 $status）。")
        }
    }

    private fun failDataPlane(message: String) {
        val revision = synchronized(commandLock) {
            if (destroyed || stopRequested) return
            gate.advance(operationRevision) ?: return
        }
        operationRevision = revision
        Thread.interrupted()
        stopDataPlane(markStopped = false, removeForeground = false)
        runtime.invalidateNetwork()
        appendLog(message)
        val delay = recovery.failed(SystemClock.elapsedRealtime(), power)
        requestConnection(revision, delay, "连接中断，自动重试第 ${recovery.failures} 次")
    }

    private fun stopWithError(message: String, selectedProxy: String) {
        val revision = synchronized(commandLock) {
            if (destroyed || !gate.accepts(operationRevision)) return
            preserveErrorState = true
            stopRequested = true
            runtime.setConnectWanted(false)
            isActive = false
            gate.stop()
        }
        cancelRetry()
        stopDataPlane(markStopped = false)
        runtime.markError(message, selectedProxy)
        appendLog(message)
        mainHandler.post { if (gate.revision == revision) stopSelf() }
    }

    private fun startDataPlaneMonitor() {
        val session = sessionGeneration
        val process = mihomoProcess ?: return
        val tunPid = tun2socksPid
        fun exited(component: String) {
            dataPlaneExecutor.execute {
                if (!destroyed && gate.wanted && sessionGeneration == session) {
                    operationRevision = gate.revision
                    failDataPlane("$component 已退出，正在重建连接")
                }
            }
        }
        Thread({
            runCatching { process.waitFor() }.onSuccess { exited("Mihomo") }
        }, "mihomo-exit").apply { isDaemon = true; start() }
        Thread({
            waitForNativeProcessExit(tunPid)
            exited("tun2socks")
        }, "tun2socks-exit").apply { isDaemon = true; start() }
        scheduleHealthCheck(INITIAL_HTTPS_PROBE_DELAY_MS)
    }

    private fun scheduleHealthCheck(delayMs: Long = power.healthIntervalMs) {
        monitorTask?.cancel(false)
        if (destroyed || !gate.wanted || power.idle) return
        monitorTask = monitorExecutor.schedule({
            dataPlaneExecutor.execute(::runHealthCheck)
        }, delayMs, TimeUnit.MILLISECONDS)
    }

    /** Runs on the lifecycle queue; all bounded Controller/remote I/O uses [probeExecutor]. */
    private fun runHealthCheck() {
        if (destroyed || !gate.wanted || power.idle) return
        val currentNetwork = environment?.readNetwork() ?: NetworkState.Unknown
        if (currentNetwork != network) {
            mainHandler.post { onNetworkChanged(currentNetwork) }
            return
        }
        if (runtime.get().state != RuntimeStatusRepository.STATE_CONNECTED) return
        if (healthProbeToken != null) return

        operationRevision = gate.revision
        try {
            requireDataPlaneAlive()
        } catch (_: Exception) {
            failDataPlane("VPN 数据面健康检查未通过，正在恢复")
            return
        }

        val selectedProxy = SettingsRepository(this).getSelectedProxy()
        launchHealthProbe(selectedProxy, shouldProbeVpnEgress(selectedProxy, power))
    }

    private fun launchHealthProbe(selectedProxy: String, probeVpnEgress: Boolean) {
        val token = HealthProbeToken(gate.revision, sessionGeneration, network, selectedProxy)
        healthProbeToken = token
        try {
            healthProbeTask = probeExecutor.submit {
                // Both loopback Controller I/O and remote I/O are bounded, but neither may
                // delay stop, network-change or process-exit work on the lifecycle queue.
                val outcome = try {
                    MihomoControllerClient.requireAvailable()
                    if (!probeVpnEgress) {
                        ProbeOutcome.SKIPPED
                    } else {
                        try {
                            MihomoControllerClient.requireVpnHttpsEgress()
                            ProbeOutcome.HEALTHY
                        } catch (_: Exception) {
                            ProbeOutcome.EGRESS_FAILURE
                        }
                    }
                } catch (_: Exception) {
                    ProbeOutcome.CONTROLLER_FAILURE
                }
                dataPlaneExecutor.execute { completeHealthProbe(token, outcome) }
            }
        } catch (_: RuntimeException) {
            healthProbeToken = null
            healthProbeTask = null
            if (!destroyed && gate.wanted) scheduleHealthCheck()
        }
    }

    private fun completeHealthProbe(token: HealthProbeToken, outcome: ProbeOutcome) {
        if (healthProbeToken != token) return
        healthProbeToken = null
        healthProbeTask = null
        val selectedProxy = SettingsRepository(this).getSelectedProxy()
        val current = !destroyed &&
            gate.accepts(token.revision) &&
            token.matches(gate.revision, sessionGeneration, network, selectedProxy) &&
            runtime.get().state == RuntimeStatusRepository.STATE_CONNECTED &&
            !power.idle
        if (!current) {
            if (!destroyed && gate.wanted && !power.idle &&
                runtime.get().state == RuntimeStatusRepository.STATE_CONNECTED) {
                scheduleHealthCheck()
            }
            return
        }
        applyHealthDecision(healthProbePolicy.record(outcome, power))
    }

    private fun applyHealthDecision(decision: HealthDecision) {
        when (decision) {
            HealthDecision.None -> scheduleHealthCheck()
            is HealthDecision.RetryAfter -> {
                appendLog("VPN 健康检查暂未通过，将再次确认")
                scheduleHealthCheck(decision.delayMs)
            }
            is HealthDecision.Rebuild -> {
                operationRevision = gate.revision
                val message = when (decision.failure) {
                    ProbeFailureKind.CONTROLLER -> "VPN 本地控制通道连续无响应，正在恢复"
                    ProbeFailureKind.EGRESS -> "VPN HTTPS 出口连续不可用，正在恢复"
                }
                failDataPlane(message)
            }
        }
    }

    private fun cancelHealthProbe() {
        healthProbeToken = null
        healthProbeTask?.cancel(true)
        healthProbeTask = null
    }

    private fun applyRunningConfig(config: MihomoConfig) {
        checkStarting()
        require(config.selectionValid) { config.selectionError }
        requireDataPlaneAlive()
        MihomoControllerClient.reloadConfig(config.configFile)
        checkStarting()
        selectProxyWithRetry(config.selectedProxy)
        checkStarting()
        requireDataPlaneAlive()
        require(MihomoControllerClient.currentProxyName() == config.selectedProxy) { "Mihomo 未应用所选节点。" }
        publishConnected(config.selectedProxy)
    }

    private fun establishTun(): ParcelFileDescriptor {
        val builder = Builder()
            .setSession("轻舟")
            .setMtu(VPN_MTU)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("223.5.5.5")
            .addDnsServer("119.29.29.29")

        try {
            builder.addDisallowedApplication(packageName)
        } catch (error: Exception) {
            appendLog("排除本应用流量失败，可能出现代理回环：${error.message}")
        }

        // MMS binds its sockets to the carrier network. Keep the default SMS
        // app outside this VPN so Android permits that binding without making
        // the VPN bypassable for every other app.
        // Some OEMs don't expose their SMS app through the public lookup.
        // Keep a narrow fallback for the legacy system SMS package; a missing
        // package is handled below, without opening bypass for all apps.
        val smsPackage = runCatching { Telephony.Sms.getDefaultSmsPackage(this) }
            .onFailure { appendLog("无法识别默认短信应用，尝试兼容系统短信应用。") }
            .getOrNull()?.takeIf { it.isNotBlank() }
            ?: "com.android.mms".also { appendLog("系统未返回默认短信应用，尝试兼容系统短信应用。") }
        if (smsPackage != packageName) {
            try {
                builder.addDisallowedApplication(smsPackage)
                appendLog("已放行短信应用，彩信使用运营商网络。")
            } catch (_: Exception) {
                appendLog("放行短信应用失败，彩信可能无法使用运营商网络。")
            }
        }

        return builder.establish() ?: error("Android VPN 权限未授予或 TUN 建立失败。")
    }

    private fun prepareBundledGeodata(paths: SplitVpnPaths) {
        listOf("GeoSite.dat", "geoip.metadb", "country.mmdb").forEach { name ->
            val target = File(paths.mihomoDataDir, name)
            if (target.exists() && target.length() > 0L) return@forEach
            val copied = runCatching {
                assets.open("geodata/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                appendLog("已写入内置地理数据库：$name")
                target.exists() && target.length() > 0L
            }.getOrElse {
                appendLog("写入内置地理数据库失败：$name ${it.message}")
                false
            }
            require(copied) { "内置地理数据库不可用：$name" }
        }
    }

    private fun pipeLogs(process: Process) {
        runCatching {
            process.inputStream.bufferedReader(Charsets.UTF_8).useLines { lines ->
                lines.takeWhile { !Thread.currentThread().isInterrupted }.forEach { appendLog(it) }
            }
        }.onFailure { appendLog("读取 Mihomo 日志失败：${it.message}") }
    }

    private fun waitForMihomoController() {
        var lastError: Throwable? = null
        val deadline = SystemClock.elapsedRealtime() + CONTROLLER_READY_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            checkStarting()
            if (mihomoProcess?.isAlive == false) {
                error("Mihomo 进程已退出。")
            }
            try {
                MihomoControllerClient.requireAvailable()
                appendLog("Mihomo controller ready")
                return
            } catch (error: Exception) {
                lastError = error
            }
            Thread.sleep(300)
        }
        error("Mihomo Controller 未就绪：${lastError?.message ?: "timeout"}")
    }

    private fun selectProxyWithRetry(selectedProxy: String) {
        var lastError: Throwable? = null
        repeat(8) { index ->
            checkStarting()
            try {
                if (index > 0) Thread.sleep(400L * index)
                MihomoControllerClient.selectVpnProxy(selectedProxy)
                appendLog("已切换到节点：$selectedProxy")
                return
            } catch (error: InterruptedException) {
                throw error
            } catch (error: Exception) {
                lastError = error
            }
        }
        error("切换到固定节点失败：$selectedProxy，${lastError?.message ?: "unknown error"}")
    }

    private fun appendLog(message: String) {
        ServiceLogRepository.append(SplitVpnPaths(this), message)
    }

    private fun createNotification(text: String): Notification {
        createNotificationChannel()
        val stopIntent = Intent(this, SplitVpnService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val openPendingIntent = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("轻舟")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentIntent(openPendingIntent)
            .addAction(Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_stat_vpn),
                if (managedAlwaysOn) "VPN 设置" else "停止",
                if (managedAlwaysOn) PendingIntent.getActivity(this, 2, Intent(Settings.ACTION_VPN_SETTINGS), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) else stopPendingIntent).build())
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "轻舟状态", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, createNotification(text))
    }

    private external fun startTun2SocksNative(
        binaryPath: String,
        tunFd: Int,
        proxyUrl: String,
        mtu: Int,
        logPath: String
    ): Int

    private external fun stopNativeProcess(pid: Int)
    private external fun nativeProcessStatus(pid: Int): Int
    private external fun waitForNativeProcessExit(pid: Int): Int

    private class PermanentVpnFailure(message: String) : Exception(message)

    companion object {
        // A replacement service instance must wait for the previous cleanup.
        private val lifecycleExecutor = Executors.newSingleThreadExecutor()
        @Volatile private var activeService: SplitVpnService? = null
        @Volatile private var uiVisible = false
        fun setUiVisible(visible: Boolean) {
            uiVisible = visible
            activeService?.environment?.refreshPower()
        }

        /** Reload and node selection share the service's process lifecycle queue. */
        fun reloadRunningConfig(generate: () -> MihomoConfig) {
            val service = activeService ?: error("VPN 已停止。")
            try {
                service.dataPlaneExecutor.submit {
                    service.operationRevision = service.gate.revision
                    service.checkStarting()
                    service.startupThread = Thread.currentThread()
                    try {
                        val config = generate()
                        require(config.selectionValid) { config.selectionError }
                        if (service.runtime.get().state == RuntimeStatusRepository.STATE_CONNECTED) {
                            service.applyRunningConfig(config)
                        } else {
                            service.recovery.reset()
                            service.requestConnection(service.gate.revision, 1_000L, "设置已更新，准备恢复连接")
                        }
                    } catch (error: Exception) {
                        if (!service.stopRequested) {
                            service.failDataPlane("VPN 配置应用失败：${error.message}")
                        }
                        throw error
                    } finally {
                        service.startupThread = null
                        Thread.interrupted()
                    }
                }.get()
            } catch (error: ExecutionException) {
                throw (error.cause as? Exception ?: error)
            }
        }

        init {
            System.loadLibrary("tunfdexec")
        }

        const val ACTION_START = "dev.splitvpn.android.START"
        const val ACTION_RETRY = "dev.splitvpn.android.RETRY"
        const val ACTION_STOP = "dev.splitvpn.android.STOP"

        /** Includes recovery/waiting; false after a process restart until the service is recreated. */
        @Volatile
        var isActive = false
            private set
        private const val CHANNEL_ID = "split_vpn_status"
        private const val NOTIFICATION_ID = 1001
        private const val VPN_MTU = 1500
        private const val INITIAL_HTTPS_PROBE_DELAY_MS = 5_000L
        private const val CONTROLLER_READY_TIMEOUT_MS = 8_000L
        private const val MIHOMO_STOP_GRACE_MS = 1_000L
        private const val MIHOMO_FORCE_STOP_TIMEOUT_MS = 3_000L
    }
}
