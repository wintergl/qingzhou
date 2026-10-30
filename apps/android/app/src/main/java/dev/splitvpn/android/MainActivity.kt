package dev.splitvpn.android

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.content.res.ColorStateList
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.net.VpnService
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.splitvpn.android.core.ConnectivityProbe
import dev.splitvpn.android.core.ConnectivityResult
import dev.splitvpn.android.core.CoreClient
import dev.splitvpn.android.core.DefaultRules
import dev.splitvpn.android.core.Diagnostics
import dev.splitvpn.android.core.MihomoConfigGenerator
import dev.splitvpn.android.core.MihomoControllerClient
import dev.splitvpn.android.core.ProviderNode
import dev.splitvpn.android.core.RiskResult
import dev.splitvpn.android.core.RuntimeStatus
import dev.splitvpn.android.core.RuntimeStatusRepository
import dev.splitvpn.android.core.ServiceLogRepository
import dev.splitvpn.android.core.SettingsRepository
import dev.splitvpn.android.core.SpeedResult
import dev.splitvpn.android.core.SplitVpnPaths
import dev.splitvpn.android.core.SubscriptionClient
import dev.splitvpn.android.core.SubscriptionRepository
import dev.splitvpn.android.core.TrafficSnapshot
import dev.splitvpn.android.ui.ManagementPages
import java.io.File
import java.text.DateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 轻舟 Android main screen. Layout and wording follow the macOS native app
 * (apps/macos-native): white cards on a light background, a big status card,
 * 兜底策略 segmented control and 44dp actions; mobile uses a bottom tab bar.
 */
class MainActivity : Activity() {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var paths: SplitVpnPaths
    private lateinit var subscriptionRepository: SubscriptionRepository
    private lateinit var settingsRepository: SettingsRepository
    private lateinit var runtimeStatusRepository: RuntimeStatusRepository
    private lateinit var subscriptionClient: SubscriptionClient
    private lateinit var configGenerator: MihomoConfigGenerator
    private lateinit var managementPages: ManagementPages

    private lateinit var topBar: LinearLayout
    private lateinit var statusPill: TextView
    private lateinit var notice: LinearLayout
    private lateinit var noticeText: TextView
    private lateinit var scrollView: ScrollView
    private lateinit var content: LinearLayout
    private lateinit var tabRow: LinearLayout

    private var currentTab = Tab.Overview
    private var nodeQuery = ""
    private var lastConnectivityResult: ConnectivityResult? = null
    private var lastGoogleResult: ConnectivityProbe? = null
    private var lastSpeedResults: List<SpeedResult>? = null
    private var lastTrafficSnapshot: TrafficSnapshot? = null
    private var lastRiskResult: RiskResult? = null
    private var lastRenderedRuntimeKey = ""
    private var lastNetworkEpoch = -1L
    private var automaticDiagnosticEpoch = -1L
    private lateinit var mobileDiagnostics: dev.splitvpn.android.core.MobileDiagnostics
    private var visible = false
    private val runtimeRefreshRunnable = Runnable {
        if (visible && runtimeStatusKey(runtimeStatusRepository.get()) != lastRenderedRuntimeKey) refresh()
    }
    private val runtimeListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        // One preference transaction can change several keys; render only once.
        mainHandler.removeCallbacks(runtimeRefreshRunnable)
        if (visible) mainHandler.post(runtimeRefreshRunnable)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        paths = SplitVpnPaths(this)
        subscriptionRepository = SubscriptionRepository(this)
        settingsRepository = SettingsRepository(this)
        runtimeStatusRepository = RuntimeStatusRepository(this)
        val core = CoreClient(paths)
        mobileDiagnostics = dev.splitvpn.android.core.MobileDiagnostics(core, runtimeStatusRepository)
        subscriptionClient = SubscriptionClient(paths, core, subscriptionRepository)
        configGenerator = MihomoConfigGenerator(core, settingsRepository)
        managementPages = ManagementPages(this, core, settingsRepository, subscriptionClient,
            execute = { label, work -> runTask(label, task = work) }, changed = { refresh() }, apply = { applyConfig() }, startVpn = { requestVpnPermissionAndStart() })

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 33)
        }

        layoutEdgeToEdge()
        setContentView(createShell())
        window.decorView.post { applySystemBarsAppearance() }
        refresh()
        // Opening the app can resume a connection Android has not yet recreated.
        // Permission revocation and a deliberate disconnect never silently reconnect.
        if (!SplitVpnService.isActive && runtimeStatusRepository.connectWanted()) {
            if (VpnService.prepare(this) == null) startVpnService()
            else {
                runtimeStatusRepository.setConnectWanted(false)
                runtimeStatusRepository.markError("VPN 权限需要重新授权，请点连接后确认。")
                refresh()
            }
        } else if (!SplitVpnService.isActive && isTunnelRunning(runtimeStatusRepository.get())) {
            runtimeStatusRepository.markStopped()
            refresh()
        }
        runTask("同步订阅", announce = false) { subscriptionClient.sync(); managementPages.reloadSync() }
        handleAutomationIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAutomationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        visible = true
        SplitVpnService.setUiVisible(true)
        if (::runtimeStatusRepository.isInitialized) {
            runtimeStatusRepository.observe(runtimeListener)
            refresh()
            if (::managementPages.isInitialized) managementPages.updateDue()
        }
    }

    override fun onPause() {
        visible = false
        if (::managementPages.isInitialized) managementPages.pauseMeasurements()
        SplitVpnService.setUiVisible(false)
        runtimeStatusRepository.unobserve(runtimeListener)
        mainHandler.removeCallbacks(runtimeRefreshRunnable)
        super.onPause()
    }

    override fun onDestroy() {
        runtimeStatusRepository.unobserve(runtimeListener)
        mainHandler.removeCallbacks(runtimeRefreshRunnable)
        executor.shutdownNow()
        super.onDestroy()
    }

    @Deprecated("Deprecated in Android API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            if (resultCode == RESULT_OK) startVpnService() else dev.splitvpn.android.core.MobileCompany.get(this).permissionDenied()
        }
    }

    // region Shell

    /** Android 15 enforces edge-to-edge for targetSdk 35; do the same on older versions and pad with insets. */
    @Suppress("DEPRECATION")
    private fun layoutEdgeToEdge() {
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                (if (Build.VERSION.SDK_INT >= 27) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0)
        }
    }

    private fun applySystemBarsAppearance() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.setSystemBarsAppearance(
                if (darkAppearance) 0 else android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        } else if (darkAppearance) {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility and
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv() and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
        }
    }

    private fun createShell(): View {
        val shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BG)
        }

        topBar = horizontal().apply { setBackgroundColor(SURFACE) }
        topBar.addView(ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            contentDescription = null
        }, LinearLayout.LayoutParams(dp(38), dp(38)))
        val brand = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(11), 0, 0, 0)
        }
        brand.addView(text(getString(R.string.app_name), 20, Typeface.BOLD, TEXT))
        brand.addView(text("让连接从容有序", 12, Typeface.NORMAL, SECONDARY))
        topBar.addView(brand, LinearLayout.LayoutParams(0, -2, 1f))
        statusPill = statusPillView("", SECONDARY)
        topBar.addView(statusPill, LinearLayout.LayoutParams(-2, -2))
        shell.addView(topBar, LinearLayout.LayoutParams(-1, -2))
        shell.addView(divider())

        notice = horizontal().apply {
            setPadding(dp(20), dp(10), dp(10), dp(10))
            setBackgroundColor(SELECTION)
            visibility = View.GONE
        }
        noticeText = text("", 14, Typeface.NORMAL, TEXT)
        notice.addView(noticeText, LinearLayout.LayoutParams(0, -2, 1f))
        notice.addView(text("✕", 15, Typeface.NORMAL, SECONDARY).apply {
            gravity = Gravity.CENTER
            setOnClickListener { setNotice("") }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        shell.addView(notice, LinearLayout.LayoutParams(-1, -2))

        scrollView = ScrollView(this).apply { setBackgroundColor(BG) }
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(18), dp(16), dp(20))
        }
        scrollView.addView(content, android.widget.FrameLayout.LayoutParams(if (resources.configuration.screenWidthDp > 720) dp(720) else -1, -2, Gravity.CENTER_HORIZONTAL))
        shell.addView(scrollView, LinearLayout.LayoutParams(-1, 0, 1f))

        shell.addView(divider())
        tabRow = horizontal().apply {
            gravity = Gravity.CENTER
            setBackgroundColor(SURFACE)
        }
        shell.addView(tabRow, LinearLayout.LayoutParams(-1, -2))

        topBar.setPadding(dp(18), dp(12), dp(16), dp(12))
        tabRow.setPadding(dp(8), dp(6), dp(8), dp(6))
        shell.setOnApplyWindowInsetsListener { _, insets ->
            val (top, bottom) = systemBarInsets(insets)
            topBar.setPadding(dp(18), top + dp(12), dp(16), dp(12))
            tabRow.setPadding(dp(8), dp(6), dp(8), bottom + dp(6))
            insets
        }
        return shell
    }

    @Suppress("DEPRECATION")
    private fun systemBarInsets(insets: WindowInsets): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= 30) {
            insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime()).let { it.top to it.bottom }
        } else {
            insets.systemWindowInsetTop to insets.systemWindowInsetBottom
        }

    private fun refresh() {
        val runtime = runtimeStatusRepository.get()
        if (lastNetworkEpoch != runtime.networkEpoch) {
            clearNetworkResults()
            lastNetworkEpoch = runtime.networkEpoch
        }
        lastRenderedRuntimeKey = runtimeStatusKey(runtime)
        styleStatusPill(statusPill, runtimeStateText(runtime.state), runtimeStateColor(runtime.state))
        if (visible && runtime.state == "connected" && runtime.configurationRevision.isNotEmpty() && automaticDiagnosticEpoch != runtime.networkEpoch) {
            automaticDiagnosticEpoch = runtime.networkEpoch
            runTask("自动连接与站点检测", announce = false) {
                runCatching { lastConnectivityResult = mobileDiagnostics.connectivityModel(mobileDiagnostics.connectivity()) }
                runCatching { lastSpeedResults = mobileDiagnostics.websiteModels(mobileDiagnostics.websites()) }
            }
        }
        renderTabs()
        content.removeAllViews()
        when (currentTab) {
            Tab.Overview -> renderOverview(runtime)
            Tab.Subscription -> renderSubscription()
            Tab.Nodes -> renderNodes()
            Tab.Routing -> renderRouting()
            Tab.Diagnostics -> renderDiagnostics()
        }
    }

    private fun selectTab(tab: Tab) {
        currentTab = tab
        managementPages.refresh()
        refresh()
        scrollView.scrollTo(0, 0)
    }

    private fun renderTabs() {
        tabRow.removeAllViews()
        Tab.entries.forEach { tab ->
            val active = tab == currentTab
            val item = text(tab.title, 13, if (active) Typeface.BOLD else Typeface.NORMAL, if (active) ACCENT else SECONDARY).apply {
                gravity = Gravity.CENTER
                background = RippleDrawable(ColorStateList.valueOf(withAlpha(ACCENT, 0.12f)), rounded(if (active) SELECTION else SURFACE, 12), rounded(Color.WHITE, 12))
                isSelected = active
                isFocusable = true
                contentDescription = "${tab.title}${if (active) "，已选中" else ""}"
                setOnClickListener { selectTab(tab) }
            }
            tabRow.addView(item, LinearLayout.LayoutParams(0, actionHeight(), 1f).apply { setMargins(dp(3), 0, dp(3), 0) })
        }
    }

    // endregion

    // region Pages

    private fun renderOverview(runtime: RuntimeStatus) {
        val readiness = vpnReadiness()
        val running = isTunnelRunning(runtime)
        val record = subscriptionRepository.get()

        val status = card(24).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(Color.rgb(0x2C, 0x52, 0x45), HERO)).apply { cornerRadius = dp(24).toFloat() }
        }
        status.addView(text("连接概览  ·  轻舟", 12, Typeface.NORMAL, HERO_MUTED).apply { letterSpacing = 0.12f; setPadding(0, 0, 0, dp(18)) })
        val head = horizontal().apply { gravity = Gravity.TOP }
        val titles = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(text(runtimeHeadline(runtime.state), 30, Typeface.BOLD, HERO_TEXT))
        val subtitleColor = if (runtime.state == RuntimeStatusRepository.STATE_ERROR || !readiness.canCaptureTraffic) Color.rgb(0xFF, 0xBC, 0xB5) else HERO_MUTED
        titles.addView(text(runtimeSubtitle(runtime, readiness), 14, Typeface.NORMAL, subtitleColor).apply {
            setPadding(0, dp(6), 0, 0)
        })
        head.addView(titles, LinearLayout.LayoutParams(0, -2, 1f))
        status.addView(head)
        val connect = when {
            running && runtime.alwaysOn -> button("系统 VPN 设置")
            running -> button("断开 VPN")
            else -> button("连接 VPN", ButtonKind.Prominent)
        }
        connect.apply {
            setEnabledLook(running || readiness.canCaptureTraffic)
            setOnClickListener {
                if (running && runtime.alwaysOn) openSystemSettings(Settings.ACTION_VPN_SETTINGS)
                else if (running) stopVpnService() else requestVpnPermissionAndStart()
            }
        }
        status.addView(connect, fullWidth(top = 18))
        if (runtime.state == RuntimeStatusRepository.STATE_RECOVERING) {
            status.addView(button("立即重试").apply { setOnClickListener { startVpnService(retry = true) } }, fullWidth(top = 8))
        }
        if (running && runtime.alwaysOn) status.addView(footnote("已启用系统“始终开启 VPN”，需要到系统设置中关闭。"))
        content.addView(status)

        val summaries = horizontal().apply { gravity = Gravity.FILL_VERTICAL }
        summaries.addView(
            summaryCard("分流模式", unknownTrafficText(), "Android VPN 智能分流"),
            LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(0, 0, dp(6), 0) }
        )
        summaries.addView(
            summaryCard("当前出口", runtime.selectedProxy.ifBlank { settingsRepository.getSelectedProxy() }, "在节点页切换"),
            LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(6), 0, 0, 0) }
        )
        content.addView(summaries, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(12)) })

        val actions = horizontal()
        actions.addView(button("切换节点").apply { setOnClickListener { selectTab(Tab.Nodes) } }, weighted(end = 8))
        actions.addView(button("更新订阅").apply {
            setEnabledLook(record.url.isNotBlank())
            setOnClickListener { updateSubscription(record.url) }
        }, weighted(end = 8))
        actions.addView(button("分流规则").apply { setOnClickListener { selectTab(Tab.Routing) } }, weighted())
        content.addView(actions, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(12)) })

        content.addView(connectivityCard())
        content.addView(websiteCard(compact = true))
        content.addView(fallbackCard())

        content.addView(text(
            "${if (record.url.isBlank()) 0 else 1} 订阅 · ${record.nodeCount} 节点 · ${settingsRepository.getVpnDomainRules().size} 分流规则",
            12, Typeface.NORMAL, SECONDARY
        ).apply { setPadding(dp(4), dp(2), 0, 0) })
    }

    private fun renderSubscription() { content.addView(managementPages.subscriptionPage()) }

    private fun renderNodes() { content.addView(managementPages.nodesPage()) }

    private fun renderRouting() { content.addView(managementPages.routingPage()) }

    private fun renderDiagnostics() {
        content.addView(pageHeader("诊断与风险", "连通性、站点表现和风险各自保留真实检测结果"))
        content.addView(managementPages.toolsCard())
        content.addView(backgroundCard())
        content.addView(connectivityCard())
        content.addView(websiteCard(compact = false))
        content.addView(trafficCard())
        content.addView(riskCard())
        content.addView(logCard())
    }

    // endregion

    // region Cards

    private fun backgroundCard(): View {
        val panel = card()
        panel.addView(cardHeading("后台运行"))
        val unrestricted = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        panel.addView(resultRow("电池优化", if (unrestricted) "已豁免" else "受系统优化管理"))
        panel.addView(caption("关闭界面后继续连接；内核异常、断网或切换 Wi-Fi / 移动网络后会自动恢复。手动断开会取消重连。"))
        panel.addView(button("设置始终开启 VPN").apply {
            setOnClickListener { openSystemSettings(Settings.ACTION_VPN_SETTINGS) }
        }, fullWidth(top = 12))
        panel.addView(button("电池与后台设置").apply {
            setOnClickListener { openSystemSettings(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS) }
        }, fullWidth(top = 8))
        panel.addView(footnote("若锁屏后仍被系统清理，可将轻舟设为“不限制”，并在手机管家中允许后台运行 / 自启动。系统“强行停止”后需要重新打开应用。"))
        return panel
    }

    private fun openSystemSettings(action: String) {
        runCatching { startActivity(Intent(action)) }.onFailure {
            runCatching { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
                .onFailure { setNotice("请在手机系统设置中打开轻舟的应用详情。") }
        }
    }

    private fun clearNetworkResults() {
        lastConnectivityResult = null
        lastGoogleResult = null
        lastSpeedResults = null
        lastTrafficSnapshot = null
        lastRiskResult = null
    }

    private fun fallbackCard(): View {
        val panel = card()
        panel.addView(cardHeading("兜底策略"))
        panel.addView(caption("未命中分流规则的流量，继续使用当前默认策略。"))
        panel.addView(segmented(listOf("direct" to "默认直连", "vpn" to "默认 VPN"), settingsRepository.getUnknownTraffic()) { value ->
            if (value == settingsRepository.getUnknownTraffic()) return@segmented
            settingsRepository.setUnknownTraffic(value)
            runTask("切换兜底策略") { applyConfig() }
        })
        return panel
    }

    private fun connectivityCard(): View {
        val panel = card()
        panel.addView(cardHeader("连接检测") { runTask("连接检测") { lastConnectivityResult = mobileDiagnostics.connectivityModel(mobileDiagnostics.connectivity()) } })
        val result = lastConnectivityResult
        panel.addView(resultRow("国内网络", result?.let { checkText(it.domesticOk, it.latency.domesticMs) } ?: "尚未检测"))
        panel.addView(resultRow("应用 DNS", result?.systemDnsOk?.let { if (it) "正常" else "失败" } ?: "尚未检测"))
        panel.addView(resultRow("ChatGPT HTTP", result?.chatgptStatus ?: "尚未检测"))
        panel.addView(resultRow("国外网络", result?.let { checkText(it.foreignOk, it.latency.foreignMs) } ?: "尚未检测"))
        panel.addView(resultRow("出口 IP", result?.externalIp?.takeIf { it.isNotBlank() } ?: lastRiskResult?.externalIp ?: "尚未读取"))
        panel.addView(resultRow("出口风险", lastRiskResult?.riskLevel ?: "尚未检测"))
        panel.addView(footnote(result?.error ?: "检测包含国内站点、Google 与当前出口 IP。"))
        return panel
    }

    private fun websiteCard(compact: Boolean): View {
        val panel = card()
        panel.addView(cardHeader("站点测速") { runTask("站点测速") { lastSpeedResults = mobileDiagnostics.websiteModels(mobileDiagnostics.websites()) } })
        val results = lastSpeedResults
        if (results == null) {
            panel.addView(text("Google · ChatGPT · Claude", 15, Typeface.BOLD, TEXT).apply { setPadding(0, dp(12), 0, 0) })
            panel.addView(footnote("通过当前出口检测站点响应，结果在此显示。"))
        } else {
            (if (compact) results.take(3) else results).forEach { item ->
                panel.addView(resultRow(item.name, if (item.ok) item.latencyMs?.let { "$it ms" } ?: "连通" else item.error ?: "失败"))
            }
        }
        if (compact) {
            panel.addView(linkText("查看完整诊断", ACCENT) { selectTab(Tab.Diagnostics) }.apply { setPadding(0, dp(12), 0, 0) })
        } else {
            lastGoogleResult?.let { panel.addView(resultRow("Google 单独检测", if (it.ok) "正常 · ${it.latencyMs ?: "-"} ms" else it.error ?: "未连通")) }
            panel.addView(linkText("单独检测 Google", ACCENT) {
                runTask("Google 检测") { lastGoogleResult = Diagnostics.checkGoogleConnectivity() }
            }.apply { setPadding(0, dp(12), 0, 0) })
        }
        return panel
    }

    private fun trafficCard(): View {
        val panel = card()
        panel.addView(cardHeader("流量", "刷新") { runTask("读取流量") { lastTrafficSnapshot = MihomoControllerClient.trafficSnapshot() } })
        val snapshot = lastTrafficSnapshot
        panel.addView(resultRow("上传", snapshot?.let { formatBytes(it.uploadBytes) } ?: "—"))
        panel.addView(resultRow("下载", snapshot?.let { formatBytes(it.downloadBytes) } ?: "—"))
        panel.addView(resultRow("活跃连接", snapshot?.connectionCount?.toString() ?: "—"))
        panel.addView(resultRow("内核内存", snapshot?.let { formatBytes(it.memoryBytes) } ?: "—"))
        if (snapshot == null) panel.addView(footnote("连接 VPN 后从内核读取累计流量。"))
        return panel
    }

    private fun riskCard(): View {
        val panel = card()
        panel.addView(cardHeader("出口风险") {
            runTask("风险检测") { lastRiskResult = mobileDiagnostics.riskModel(mobileDiagnostics.risk(settingsRepository)) }
        })
        val keyInput = input("ipdata API Key", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD).apply {
            hint = "输入新密钥，保存后加密存储"
        }
        val keyRow = horizontal()
        keyRow.addView(keyInput, LinearLayout.LayoutParams(0, actionHeight(), 1f).apply { setMargins(0, 0, dp(8), 0) })
        keyRow.addView(button("保存").apply {
            setOnClickListener {
                val key = keyInput.text.toString()
                runTask("保存风险密钥") { settingsRepository.setIpdataApiKey(key) }
            }
        }, LinearLayout.LayoutParams(-2, dp(44)))
        panel.addView(keyRow, fullWidth(top = 12, height = WRAP))
        panel.addView(footnote("风险结果用于提示；切换线路后重新检测实际出口。"))
        lastRiskResult?.let { result ->
            panel.addView(resultRow("风险等级", result.riskLevel))
            panel.addView(resultRow("检测节点", result.proxyName))
            panel.addView(resultRow("出口 IP", result.externalIp ?: "—"))
            panel.addView(resultRow("地区", result.country ?: "—"))
            panel.addView(resultRow("组织", result.organization ?: "—"))
            result.scores?.let { scores ->
                panel.addView(resultRow("信任 / 威胁分", "${scores.trustScore ?: "-"} / ${scores.threatScore ?: "-"}"))
            }
            result.threat?.let { threat ->
                val flags = listOfNotNull(
                    "代理".takeIf { threat.isProxy == true },
                    "数据中心".takeIf { threat.isDatacenter == true },
                    "匿名".takeIf { threat.isAnonymous == true },
                    "Tor".takeIf { threat.isTor == true },
                    "威胁".takeIf { threat.isThreat == true },
                    "攻击者".takeIf { threat.isKnownAttacker == true },
                    "滥用".takeIf { threat.isKnownAbuser == true }
                )
                panel.addView(resultRow("标记", flags.joinToString("、").ifEmpty { "无" }))
            }
            panel.addView(resultRow("检测时间", formatInstant(result.checkedAt)))
            panel.addView(footnote(result.error ?: result.summary))
        }
        return panel
    }

    private fun logCard(): View {
        val panel = card()
        val lines = ServiceLogRepository.readTail(paths, LOG_LINES)
        panel.addView(cardHeader("日志", "复制") {
            getSystemService(ClipboardManager::class.java)
                ?.setPrimaryClip(ClipData.newPlainText("轻舟日志", lines.joinToString("\n")))
            setNotice("已复制最近 ${lines.size} 行日志。")
        })
        panel.addView(text(lines.joinToString("\n").ifEmpty { "暂无日志。" }, 11, Typeface.NORMAL, SECONDARY).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = rounded(BG, 10)
        }, fullWidth(top = 12, height = WRAP))
        panel.addView(footnote("应用与内核日志，最近 $LOG_LINES 行。"))
        return panel
    }

    // endregion

    // region Actions

    private fun updateSubscription(url: String) {
        runTask("更新订阅") {
            subscriptionClient.update(url)
            applyConfig()
        }
    }

    /** Regenerates mihomo's config and hot-reloads it into a running tunnel. Runs on the executor. */
    private fun applyConfig() {
        if (SplitVpnService.isActive) {
            SplitVpnService.reloadRunningConfig { configGenerator.generate() }
        } else {
            configGenerator.generate()
        }
    }

    private fun selectNode(name: String) {
        if (isTunnelRunning(runtimeStatusRepository.get())) {
            runTask("切换节点") {
                val previous = settingsRepository.getSelectedProxy()
                settingsRepository.setSelectedProxy(name)
                try {
                    applyConfig()
                } catch (error: Exception) {
                    settingsRepository.setSelectedProxy(previous)
                    configGenerator.generate()
                    throw error
                }
            }
        } else {
            settingsRepository.setSelectedProxy(name)
            setNotice("已选择出口：$name")
            refresh()
        }
    }

    private fun requestVpnPermissionAndStart() {
        val readiness = vpnReadiness()
        if (!readiness.canCaptureTraffic) {
            setNotice(readiness.message)
            refresh()
            return
        }
        runTask("准备连接") {
            val record = subscriptionRepository.get()
            val privateOnly = dev.splitvpn.android.core.MobileCompany.get(this).metadata().optBoolean("enabled") || dev.splitvpn.android.core.MobileCompany.connectionRequested()
            require(record.status == "ready" && record.nodeCount > 0 || privateOnly) { "请先更新个人订阅，或在私有网络页完成 aTrust 认证。" }
            val config = configGenerator.generate()
            require(config.selectionValid) { config.selectionError }
            mainHandler.post {
                if (isDestroyed || isFinishing) return@post
                val intent = VpnService.prepare(this)
                if (intent != null) startActivityForResult(intent, VPN_PERMISSION_REQUEST) else startVpnService()
            }
        }
    }

    private fun startVpnService(retry: Boolean = false) {
        val readiness = vpnReadiness()
        if (!readiness.canCaptureTraffic) {
            runtimeStatusRepository.markError(readiness.message, settingsRepository.getSelectedProxy())
            setNotice(readiness.message)
            refresh()
            return
        }
        val intent = Intent(this, SplitVpnService::class.java)
            .setAction(if (retry) SplitVpnService.ACTION_RETRY else SplitVpnService.ACTION_START)
        val selectedProxy = settingsRepository.getSelectedProxy()
        try {
            check(runtimeStatusRepository.setConnectWanted(true)) { "无法保存连接状态，请检查手机存储。" }
            runtimeStatusRepository.markStarting(selectedProxy)
            startForegroundService(intent)
            setNotice("VPN 启动中，出口：$selectedProxy。")
            refresh()
        } catch (error: Exception) {
            runtimeStatusRepository.setConnectWanted(false)
            val message = error.message ?: error.javaClass.simpleName
            runtimeStatusRepository.markError(message, selectedProxy)
            setNotice(message)
            refresh()
        }
    }

    private fun stopVpnService() {
        if (runtimeStatusRepository.get().alwaysOn && SplitVpnService.isActive) {
            openSystemSettings(Settings.ACTION_VPN_SETTINGS)
            return
        }
        runtimeStatusRepository.setConnectWanted(false)
        try {
            if (SplitVpnService.isActive) {
                runtimeStatusRepository.markStopping()
                startService(Intent(this, SplitVpnService::class.java).setAction(SplitVpnService.ACTION_STOP))
            } else runtimeStatusRepository.markStopped()
            setNotice("VPN 断开中。")
        } catch (error: Exception) {
            setNotice("未能发送断开请求，请在系统 VPN 设置中断开连接。")
        }
        refresh()
    }

    private fun runTask(label: String, refreshAfter: Boolean = true, announce: Boolean = true, task: () -> Unit) {
        if (announce) setNotice("${label}中…")
        executor.submit {
            val networkEpoch = runtimeStatusRepository.get().networkEpoch
            try {
                task()
                mainHandler.post {
                    if (isDestroyed || isFinishing) return@post
                    if (networkEpoch != runtimeStatusRepository.get().networkEpoch) clearNetworkResults()
                    if (refreshAfter) {
                        if (announce) setNotice("${label}完成。")
                        refresh()
                    }
                }
            } catch (error: Exception) {
                mainHandler.post {
                    if (isDestroyed || isFinishing) return@post
                    if (networkEpoch != runtimeStatusRepository.get().networkEpoch) clearNetworkResults()
                    setNotice(error.message ?: error.toString())
                    if (refreshAfter) refresh()
                }
            }
        }
    }

    private fun handleAutomationIntent(intent: Intent?) {
        when (intent?.action) {
            ACTION_AUTOMATION_START -> mainHandler.post { requestVpnPermissionAndStart() }
            ACTION_AUTOMATION_STOP -> mainHandler.post { stopVpnService() }
        }
    }

    private fun vpnReadiness(): VpnReadiness {
        val androidCoreReady = File(applicationInfo.nativeLibraryDir, "libmihomo.so").exists()
        val tunBridgeReady = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").exists()
        val message = when {
            !androidCoreReady -> "当前 APK 没有打包 Android 版 mihomo 内核，不能接管手机网络。"
            !tunBridgeReady -> "当前 APK 没有打包 tun2socks TUN bridge，不能接管手机网络。"
            else -> "可以接管手机网络。"
        }
        return VpnReadiness(androidCoreReady && tunBridgeReady, message)
    }

    private fun setNotice(value: String) {
        if (::notice.isInitialized) {
            noticeText.text = value
            notice.visibility = if (value.isBlank()) View.GONE else View.VISIBLE
        }
    }

    // endregion

    // region Text

    private fun isTunnelRunning(runtime: RuntimeStatus): Boolean = runtime.state in setOf(
        RuntimeStatusRepository.STATE_STARTING,
        RuntimeStatusRepository.STATE_CONNECTED,
        RuntimeStatusRepository.STATE_RECOVERING,
        RuntimeStatusRepository.STATE_WAITING_NETWORK,
        RuntimeStatusRepository.STATE_STOPPING
    )

    private fun runtimeStateText(state: String): String = when (state) {
        RuntimeStatusRepository.STATE_STARTING -> "连接中"
        RuntimeStatusRepository.STATE_CONNECTED -> "已连接"
        RuntimeStatusRepository.STATE_RECOVERING -> "恢复中"
        RuntimeStatusRepository.STATE_WAITING_NETWORK -> "等待网络"
        RuntimeStatusRepository.STATE_STOPPING -> "断开中"
        RuntimeStatusRepository.STATE_ERROR -> "异常"
        else -> "未连接"
    }

    private fun runtimeHeadline(state: String): String = when (state) {
        RuntimeStatusRepository.STATE_STARTING -> "正在连接"
        RuntimeStatusRepository.STATE_CONNECTED -> "智能分流中"
        RuntimeStatusRepository.STATE_RECOVERING -> "正在恢复连接"
        RuntimeStatusRepository.STATE_WAITING_NETWORK -> "等待网络恢复"
        RuntimeStatusRepository.STATE_STOPPING -> "正在断开"
        RuntimeStatusRepository.STATE_ERROR -> "连接需要处理"
        else -> "网络总览"
    }

    private fun runtimeSubtitle(runtime: RuntimeStatus, readiness: VpnReadiness): String = when {
        !readiness.canCaptureTraffic -> readiness.message
        runtime.state == RuntimeStatusRepository.STATE_CONNECTED -> "关闭界面后继续运行，连接异常时自动恢复。"
        runtime.state == RuntimeStatusRepository.STATE_WAITING_NETWORK -> "联网后会自动重连，可随时手动断开。"
        runtime.state == RuntimeStatusRepository.STATE_RECOVERING -> runtime.lastError +
            if (runtime.retryAt > 0) " · 计划于 ${DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(runtime.retryAt))} 重试" else ""
        runtime.state == RuntimeStatusRepository.STATE_ERROR && runtime.lastError.isNotBlank() -> runtime.lastError
        runtime.state == RuntimeStatusRepository.STATE_STARTING -> "正在建立 Android VPN 与内核"
        else -> "选择节点后连接 VPN"
    }

    private fun runtimeStateColor(state: String): Int = when (state) {
        RuntimeStatusRepository.STATE_CONNECTED -> GREEN
        RuntimeStatusRepository.STATE_STARTING,
        RuntimeStatusRepository.STATE_RECOVERING,
        RuntimeStatusRepository.STATE_WAITING_NETWORK,
        RuntimeStatusRepository.STATE_STOPPING -> ACCENT
        RuntimeStatusRepository.STATE_ERROR -> DESTRUCTIVE
        else -> SECONDARY
    }

    private fun runtimeStatusKey(runtime: RuntimeStatus): String = listOf(
        runtime.state,
        runtime.updatedAt,
        runtime.selectedProxy,
        runtime.lastError,
        runtime.controllerAvailable.toString(),
        runtime.tun2socksPid.toString(),
        runtime.alwaysOn.toString(),
        runtime.networkEpoch.toString(),
        runtime.retryAt.toString()
    ).joinToString("|")

    private fun unknownTrafficText(): String = if (settingsRepository.getUnknownTraffic() == "vpn") "默认 VPN" else "默认直连"

    private fun subscriptionStatusText(status: String): String = when (status) {
        "ready" -> "可用"
        "error" -> "更新失败"
        "updating" -> "更新中"
        "saved" -> "待更新"
        else -> "未配置"
    }

    private fun checkText(ok: Boolean, latencyMs: Long?): String =
        if (ok) "正常${latencyMs?.let { " · $it ms" } ?: ""}" else "未连通"

    private fun formatInstant(value: String): String {
        if (value.isBlank()) return "尚无记录"
        return runCatching {
            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date.from(Instant.parse(value)))
        }.getOrDefault(value)
    }

    private fun formatBytes(value: Long): String {
        val units = listOf("B", "KB", "MB", "GB")
        var size = value.toDouble()
        var unit = 0
        while (size >= 1024 && unit < units.lastIndex) {
            size /= 1024
            unit++
        }
        return if (unit == 0) "$value B" else String.format(Locale.getDefault(), "%.1f %s", size, units[unit])
    }

    // endregion

    // region Components (mirror apps/macos-native Theme.swift / Components.swift)

    private fun card(padding: Int = 18): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
        background = rounded(SURFACE, 18, BORDER)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(12)) }
    }

    private fun pageHeader(title: String, subtitle: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(4), 0, dp(4), dp(16))
        addView(text(title, 26, Typeface.BOLD, TEXT))
        addView(text(subtitle, 14, Typeface.NORMAL, SECONDARY).apply { setPadding(0, dp(6), 0, 0) })
    }

    private fun cardHeading(title: String): TextView = text(title, 17, Typeface.BOLD, TEXT)

    private fun caption(value: String): TextView = text(value, 13, Typeface.NORMAL, SECONDARY).apply {
        setPadding(0, dp(6), 0, dp(12))
    }

    private fun cardHeader(title: String, action: String = "检测", onClick: () -> Unit): View {
        val row = horizontal()
        row.addView(cardHeading(title), LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(button(action).apply {
            textSize = 14f
            setPadding(dp(14), 0, dp(14), 0)
            setOnClickListener { onClick() }
        }, LinearLayout.LayoutParams(-2, actionHeight()))
        return row
    }

    private fun summaryCard(title: String, value: String, note: String): View = card(16).apply {
        addView(text(title, 13, Typeface.NORMAL, SECONDARY))
        addView(text(value, 17, Typeface.BOLD, TEXT).apply {
            maxLines = 2
            minHeight = dp(50)
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(7), 0, dp(5))
        })
        addView(text(note, 12, Typeface.NORMAL, SECONDARY).apply {
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        })
    }

    private fun resultRow(title: String, value: String): View = horizontal().apply {
        setPadding(0, dp(12), 0, 0)
        addView(text(title, 14, Typeface.NORMAL, SECONDARY), LinearLayout.LayoutParams(-2, -2))
        addView(text(value, 14, Typeface.BOLD, TEXT).apply {
            gravity = Gravity.END
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(12), 0, 0, 0)
        }, LinearLayout.LayoutParams(0, -2, 1f))
    }

    private fun nodeRow(node: ProviderNode, selected: Boolean): View {
        val row = listRow()
        val labels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        labels.addView(text(node.name, 15, if (selected) Typeface.BOLD else Typeface.NORMAL, if (selected) ACCENT else TEXT).apply {
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        })
        if (node.type.isNotBlank()) {
            labels.addView(text(node.type, 12, Typeface.NORMAL, SECONDARY).apply { setPadding(0, dp(2), 0, 0) })
        }
        row.addView(labels, LinearLayout.LayoutParams(0, -2, 1f))
        if (selected) {
            row.addView(statusPillView("当前出口", GREEN))
        } else {
            row.addView(linkText("切换", ACCENT) { selectNode(node.name) })
            row.setOnClickListener { selectNode(node.name) }
        }
        return row
    }

    /** Table-style row with a hairline separator on top, like the macOS list cards. */
    private fun listRow(): LinearLayout = horizontal().apply {
        setPadding(0, dp(12), 0, dp(12))
        background = topBorder()
    }

    private fun topBorder(): Drawable {
        val line = GradientDrawable().apply { setColor(BORDER) }
        val fill = GradientDrawable().apply { setColor(SURFACE) }
        return LayerDrawable(arrayOf(line, fill)).apply { setLayerInset(1, 0, dp(1), 0, 0) }
    }

    private fun segmented(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit): View {
        val group = horizontal().apply {
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = rounded(SEGMENT_BG, 12)
        }
        options.forEachIndexed { index, (value, label) ->
            val active = value == selected
            group.addView(text(label, 15, Typeface.BOLD, if (active) ACCENT else SECONDARY).apply {
                gravity = Gravity.CENTER
                if (active) background = rounded(SELECTION, 10)
                isSelected = active
                isFocusable = true
                setOnClickListener { onSelect(value) }
            }, LinearLayout.LayoutParams(0, actionHeight(), 1f).apply {
                if (index > 0) setMargins(dp(4), 0, 0, 0)
            })
        }
        return group
    }

    private fun statusPillView(title: String, color: Int): TextView = text("", 13, Typeface.BOLD, color).apply {
        styleStatusPill(this, title, color)
    }

    private fun styleStatusPill(view: TextView, title: String, color: Int) {
        view.text = title
        view.setTextColor(color)
        view.gravity = Gravity.CENTER_VERTICAL
        view.setPadding(dp(12), dp(6), dp(13), dp(6))
        view.compoundDrawablePadding = dp(7)
        view.background = rounded(withAlpha(color, 0.09f), 100)
        val dot = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
            setSize(dp(7), dp(7))
        }
        view.setCompoundDrawablesRelativeWithIntrinsicBounds(dot, null, null, null)
    }

    private enum class ButtonKind { Normal, Prominent, Destructive }

    private fun button(label: String, kind: ButtonKind = ButtonKind.Normal): TextView =
        text(label, 15, Typeface.BOLD, if (kind == ButtonKind.Normal) TEXT else Color.WHITE).apply {
            gravity = Gravity.CENTER
            maxLines = 2
            minHeight = dp(48)
            setPadding(dp(12), 0, dp(16), 0)
            val fill = when (kind) {
                ButtonKind.Normal -> rounded(SURFACE, 13, BORDER)
                ButtonKind.Prominent -> rounded(BUTTON_ACCENT, 13)
                ButtonKind.Destructive -> rounded(Color.rgb(0xAC, 0x41, 0x48), 13)
            }
            background = RippleDrawable(ColorStateList.valueOf(withAlpha(ACCENT, 0.14f)), fill, rounded(Color.WHITE, 13))
            accessibilityDelegate = object : View.AccessibilityDelegate() {
                override fun onInitializeAccessibilityNodeInfo(host: View, info: android.view.accessibility.AccessibilityNodeInfo) {
                    super.onInitializeAccessibilityNodeInfo(host, info)
                    info.className = "android.widget.Button"
                }
            }
            isClickable = true
            isFocusable = true
        }

    private fun View.setEnabledLook(enabled: Boolean) {
        isEnabled = enabled
        alpha = if (enabled) 1f else 0.48f
    }

    private fun linkText(label: String, color: Int, onClick: () -> Unit): TextView = text(label, 14, Typeface.BOLD, color).apply {
        setPadding(dp(12), dp(6), 0, dp(6))
        setOnClickListener { onClick() }
    }

    private fun input(hint: String, type: Int): EditText = EditText(this).apply {
        setSingleLine(true)
        this.hint = hint
        inputType = type
        imeOptions = EditorInfo.IME_ACTION_DONE
        textSize = 15f
        setTextColor(TEXT)
        setHintTextColor(withAlpha(SECONDARY, 0.7f))
        setPadding(dp(14), 0, dp(14), 0)
        background = rounded(SURFACE, 10, BORDER)
    }

    private fun footnote(value: String): TextView = text(value, 12, Typeface.NORMAL, SECONDARY).apply {
        setPadding(0, dp(12), 0, 0)
    }

    private fun empty(value: String): TextView = text(value, 14, Typeface.NORMAL, SECONDARY).apply {
        setPadding(0, dp(14), 0, 0)
    }

    private fun divider(): View = View(this).apply {
        setBackgroundColor(BORDER)
        layoutParams = LinearLayout.LayoutParams(-1, dp(1))
    }

    private fun horizontal(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun text(value: String, sp: Int, style: Int, color: Int): TextView = TextView(this).apply {
        text = value
        textSize = sp.toFloat()
        typeface = if (style == Typeface.BOLD) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        setTextColor(color)
        setLineSpacing(dp(2).toFloat(), 1.0f)
    }

    private fun rounded(color: Int, radiusDp: Int, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
        stroke?.let { setStroke(dp(1), it) }
    }

    private fun withAlpha(color: Int, alpha: Float): Int =
        Color.argb((alpha * 255).toInt(), Color.red(color), Color.green(color), Color.blue(color))

    private fun weighted(end: Int = 0): LinearLayout.LayoutParams = LinearLayout.LayoutParams(0, actionHeight(), 1f).apply {
        setMargins(0, 0, dp(end), 0)
    }

    private fun fullWidth(top: Int = 0, height: Int = 48): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(-1, if (height == WRAP) -2 else if (height == 48) actionHeight() else dp(height)).apply { setMargins(0, dp(top), 0, 0) }

    private fun actionHeight(): Int = dp(maxOf(48, (36 * resources.configuration.fontScale).toInt()))

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    // endregion

    private data class VpnReadiness(val canCaptureTraffic: Boolean, val message: String)

    private enum class Tab(val title: String) {
        Overview("总览"),
        Subscription("订阅"),
        Nodes("节点"),
        Routing("分流"),
        Diagnostics("诊断")
    }

    // Shared visual roles; read the current system appearance without changing preferences.
    private val darkAppearance: Boolean get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private fun themed(light: Int, dark: Int): Int = (if (darkAppearance) dark else light) or (0xFF shl 24)
    private val BG get() = themed(0xF5F5F2, 0x121B1D)
    private val SURFACE get() = themed(0xFFFFFF, 0x1B272A)
    private val TEXT get() = themed(0x203632, 0xE9F1ED)
    private val SECONDARY get() = themed(0x61736F, 0xA5B8B2)
    private val BORDER get() = themed(0xE1E7E2, 0x324440)
    private val SELECTION get() = themed(0xE1ECE5, 0x29443C)
    private val ACCENT get() = themed(0x216650, 0x97DABB)
    private val BUTTON_ACCENT get() = themed(0x216650, 0x276D53)
    private val DESTRUCTIVE get() = themed(0xAC4148, 0xF29AA0)
    private val GREEN get() = themed(0x24785C, 0x87D9AE)
    private val SEGMENT_BG get() = themed(0xEAEFEA, 0x22332D)
    private val HERO = Color.rgb(0x14, 0x38, 0x2E)
    private val HERO_TEXT = Color.rgb(0xF0, 0xF7, 0xE8)
    private val HERO_MUTED = Color.rgb(0xAB, 0xCC, 0xBA)

    companion object {
        const val ACTION_AUTOMATION_START = "dev.splitvpn.android.AUTOMATION_START"
        const val ACTION_AUTOMATION_STOP = "dev.splitvpn.android.AUTOMATION_STOP"
        private const val VPN_PERMISSION_REQUEST = 10
        private const val NODE_LIMIT = 200
        private const val LOG_LINES = 60
        private const val WRAP = -1
    }
}
