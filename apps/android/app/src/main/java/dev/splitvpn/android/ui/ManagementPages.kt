package dev.splitvpn.android.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.view.View
import android.widget.*
import dev.splitvpn.android.core.CoreClient
import dev.splitvpn.android.core.SettingsRepository
import dev.splitvpn.android.core.SubscriptionClient
import org.json.JSONArray
import org.json.JSONObject

/** Native management pages. All validation, identities and rule edits use Rust. */
class ManagementPages(
    private val activity: Activity,
    private val core: CoreClient,
    private val settings: SettingsRepository,
    private val subscriptions: SubscriptionClient,
    private val execute: (String, () -> Unit) -> Unit,
    private val changed: () -> Unit,
    private val apply: () -> Unit,
    private val startVpn: () -> Unit
) {
    @Volatile private var snapshot = JSONObject()
    @Volatile private var busy = false
    private var query = ""
    private var subscriptionFilter = ""
    private var favoritesOnly = false
    private var limit = 100
    private var dueAttempt = 0L
    private var ruleDecision = ""
    @Volatile private var chainId = ""
    @Volatile private var chainContinue = false
    private var activeEditor: AlertDialog? = null
    private val dark get() = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val foreground get() = if (dark) 0xFFE9F1ED.toInt() else 0xFF203632.toInt()
    private val muted get() = if (dark) 0xFFA5B8B2.toInt() else 0xFF61736F.toInt()
    private val surface get() = if (dark) 0xFF1B272A.toInt() else 0xFFFFFFFF.toInt()
    private fun preferences() = snapshot.optJSONObject("settings") ?: JSONObject()
    private fun entries() = objects(snapshot.optJSONObject("subscription")?.optJSONArray("entries"))
    private fun nodes() = objects(snapshot.optJSONArray("nodes"))
    private fun groups() = objects(preferences().optJSONArray("nodeGroups"))

    fun reloadSync() {
        core.ensureSettings(settings)
        val data = core.obj("bootstrap")
        settings.syncFromCore(data.optJSONObject("settings") ?: JSONObject())
        snapshot = data
    }
    fun updateDue() {
        val now=android.os.SystemClock.elapsedRealtime()
        if(busy || now-dueAttempt<900_000) return
        val power=activity.getSystemService(android.os.PowerManager::class.java)
        val network=activity.getSystemService(android.net.ConnectivityManager::class.java)
        if(power.isPowerSaveMode || network.isActiveNetworkMetered) return
        dueAttempt=now
        perform("自动更新到期订阅", false) {
            val due=core.call("subscription:due") as? JSONArray ?: JSONArray()
            var updated=false
            strings(due).forEach { id -> runCatching { subscriptions.updateEntry(id);updated=true } }
            if(updated){reloadSync();apply()}
        }
    }
    fun refresh() = perform("读取管理数据", false) { }
    private fun perform(title: String, applyConfig: Boolean, done: () -> Unit = {}, work: () -> Unit) {
        if (busy) return
        busy = true
        execute(title) {
            try {
                work(); reloadSync()
                if (applyConfig) apply()
                activity.runOnUiThread { if (!activity.isDestroyed) done() }
            } catch (error: Exception) {
                activity.runOnUiThread { if (!activity.isDestroyed) Toast.makeText(activity, error.message ?: "操作未完成", Toast.LENGTH_LONG).show() }
                throw error
            } finally {
                activity.runOnUiThread {
                    busy = false
                    activeEditor?.let { dialog -> dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.isEnabled = true; dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.isEnabled = true; dialog.setCancelable(true) }
                    if (!activity.isDestroyed) changed()
                }
            }
        }
    }
    private fun mutate(title: String, channel: String, payload: JSONObject, applyConfig: Boolean = true) = perform(title, false) {
        val previous = core.obj("settings:get")
        try { core.call(channel, payload); reloadSync(); if(applyConfig) apply() }
        catch(error:Exception) {
            if(!channel.startsWith("subscription:")) {
                val patch=JSONObject(); listOf("selectedProxy","defaultOutlet","unknownTraffic","geoFallback","vpnDomainRules","directDomainRules","specialCompatibilityRules","favoriteNodeNames","nodeGroups","ipv6","lanDirect","tailscaleDirect","staticExit").forEach { key -> if(previous.has(key))patch.put(key,previous.get(key)) }
                core.call("settings:patch",patch);reloadSync();if(applyConfig)runCatching { apply() }
            }
            throw error
        }
    }

    fun subscriptionPage(): View = page("订阅", "多订阅独立管理，下载失败保留上次可用节点").apply {
        addView(button("添加订阅") { subscriptionEditor(null) })
        val values = entries()
        if (values.isEmpty()) addView(label("还没有订阅，添加后点击更新获取节点。"))
        values.forEach { entry ->
            addView(card().apply {
                addView(check(entry.optString("name", "订阅"), entry.optBoolean("enabled", true)) { enabled -> mutate("更新订阅状态", "subscription:set-enabled", JSONObject().put("id", entry.getString("id")).put("enabled", enabled)) })
                addView(label("${entry.optInt("nodeCount")} 个节点 · ${entry.optString("status")} · 更新间隔 ${entry.optInt("updateIntervalMinutes", 1440)} 分钟（0 为手动）"))
                if (!entry.isNull("lastError") && entry.optString("lastError").isNotEmpty()) addView(label(entry.optString("lastError")))
                addView(row(button("更新") { perform("更新订阅", true) { subscriptions.updateEntry(entry.getString("id")) } },
                    button("编辑") { subscriptionEditor(entry) }, button("删除") {
                        AlertDialog.Builder(activity).setTitle("删除这条订阅及节点？").setNegativeButton("取消", null).setPositiveButton("删除") { _, _ -> mutate("删除订阅", "subscription:delete", JSONObject().put("id", entry.getString("id"))) }.show()
                    }))
            })
        }
    }

    private fun subscriptionEditor(entry: JSONObject?) {
        val name = input("订阅名称", entry?.optString("name").orEmpty())
        val url = input("https://example.test/subscription", entry?.optString("url").orEmpty())
        val interval = input("更新间隔，0 表示仅手动", (entry?.optInt("updateIntervalMinutes", 1440) ?: 1440).toString(), number = true)
        val body = column(label("名称"), name, label("订阅 URL"), url, label("自动更新间隔（分钟）"), interval)
        editor("订阅信息", body) { dialog ->
            val minutes = interval.text.toString().toIntOrNull()
            if (minutes == null || minutes != 0 && minutes !in 5..10080) { interval.error = "填写 0 或 5～10080"; return@editor }
            val payload = JSONObject().put("name", name.text.toString()).put("url", url.text.toString()).put("updateIntervalMinutes", minutes)
            entry?.optString("id")?.let { payload.put("id", it) }
            perform("保存订阅", true, { dialog.dismiss() }) { subscriptions.saveEntry(payload) }
        }
    }

    fun nodesPage(): View = page("节点", "按订阅和身份选择，避免同名节点误选").apply {
        val search = input("搜索节点、协议或订阅", query)
        addView(row(search, button("搜索") { query = search.text.toString(); limit = 100; changed() }))
        addView(check("仅看收藏", favoritesOnly) { favoritesOnly = it; changed() })
        val values = entries().filter { it.optBoolean("enabled", true) }
        val scope = selector(listOf("全部订阅") + values.map { it.optString("name") }, (values.indexOfFirst { it.optString("id") == subscriptionFilter } + 1).coerceAtLeast(0)) { index ->
            subscriptionFilter = if (index == 0) "" else values[index - 1].optString("id"); limit = 100; changed()
        }
        addView(scope); addView(button("管理节点组") { groupsDialog() })
        addView(row(*listOf("AUTO", "BALANCE", "DIRECT").map { name -> button(name) { mutate("切换出口", "nodes:select", JSONObject().put("nodeName", name)) } }.toTypedArray()))
        val favorites = strings(preferences().optJSONArray("favoriteNodeNames"))
        val filtered = nodes().filter { node ->
            (subscriptionFilter.isEmpty() || node.optString("subscriptionId") == subscriptionFilter) &&
                (!favoritesOnly || node.optString("name") in favorites) &&
                (query.isEmpty() || "${node.optString("name")} ${node.optString("type")} ${node.optString("subscriptionName")}".contains(query, true))
        }
        val selected = preferences().optJSONObject("defaultOutlet")?.optString("identityKey").orEmpty()
        filtered.take(limit).forEach { node ->
            addView(card().apply {
                val identity = node.optString("identityKey")
                addView(label((if (identity.isNotEmpty() && identity == selected) "✓ " else "") + node.optString("name"), true))
                addView(label("${node.optString("subscriptionName")} · ${node.optString("type")}"))
                val select = button(if (node.optBoolean("identityAmbiguous")) "同名冲突，暂不能选择" else "选择节点") { mutate("切换节点", "nodes:select-v2", JSONObject().put("identityKey", identity)) }
                select.isEnabled = identity.isNotEmpty() && !node.optBoolean("identityAmbiguous") && !busy
                addView(button("检测节点延迟") { perform("节点测速", false) { val value=mobile().call("mobile:diagnostics:node",JSONObject().put("identityKey",identity));activity.runOnUiThread {Toast.makeText(activity,if(value.optBoolean("ok")) "${value.optLong("delay")} ms" else value.optString("error","检测失败"),Toast.LENGTH_LONG).show()} } })
                addView(row(select, button(if (node.optString("name") in favorites) "取消收藏" else "收藏") { mutate("保存收藏", "native:favorite", JSONObject().put("name", node.optString("name")), false) }))
            })
        }
        if (filtered.size > limit) addView(button("继续显示（${limit}/${filtered.size}）") { limit += 100; changed() })
        if (filtered.isEmpty()) addView(label("没有符合条件的节点。"))
    }

    fun routingPage(): View = page("分流规则", "域名、IP、网段或网址；共享核心负责校验和匹配").apply {
        addView(card().apply {
            addView(label("未命中策略", true))
            addView(selector(listOf("直连", "VPN"), if (settings.getUnknownTraffic() == "vpn") 1 else 0) { index -> mutate("保存默认策略", "settings:patch", JSONObject().put("unknownTraffic", if (index == 1) "vpn" else "direct")) })
            addView(label("Geo 数据缺失时"))
            val policies = listOf("cn-direct-else-vpn", "follow-default", "block")
            addView(selector(listOf("国内名单直连，其余 VPN", "跟随默认策略", "拒绝连接"), policies.indexOf(preferences().optString("geoFallback")).coerceAtLeast(0)) { index -> mutate("保存 Geo 策略", "settings:patch", JSONObject().put("geoFallback", policies[index])) })
            for ((key, title) in listOf("lanDirect" to "局域网直连", "tailscaleDirect" to "Tailscale 直连")) addView(check(title, preferences().optBoolean(key, true)) { mutate("保存分流设置", "settings:patch", JSONObject().put(key, it)) })
        })
        addView(button("添加规则") { ruleEditor(null, "vpn") })
        for ((key, outlet, title) in listOf(Triple("directDomainRules", "direct", "直连规则"), Triple("vpnDomainRules", "vpn", "VPN 规则"))) {
            addView(card().apply {
                addView(label(title, true))
                strings(preferences().optJSONArray(key)).forEach { rule -> addView(column(label(rule), row(button("编辑") { ruleEditor(rule, outlet) }, button("删除") { mutate("删除规则", "routing:delete-rule", JSONObject().put("rule", rule).put("target", outlet)) }))) }
                addView(button("添加$title") { ruleEditor(null, outlet) })
            })
        }
        addView(card().apply {
            addView(label("检查自定义规则", true)); val target = input("域名、IP 或网址"); addView(target)
            addView(label("不测试联网或查询 Geo；直连规则优先于重叠的代理规则。"))
            addView(button("检查匹配") { perform("检查规则", false) { val result = core.obj("routing:diagnose", JSONObject().put("target", target.text.toString())); ruleDecision = "${result.optString("host")} · ${result.optString("policy")}" } })
            if (ruleDecision.isNotEmpty()) addView(label(ruleDecision))
        })
    }

    private fun ruleEditor(original: String?, originalOutlet: String) {
        val target = selector(listOf("走 VPN", "直连"), if (originalOutlet == "direct") 1 else 0) { }
        val address = input("域名、IP、网段或网址", original.orEmpty())
        editor(if (original == null) "添加规则" else "编辑规则", column(target, address, label("每条填写一个地址；保存时可同时更换出口。"))) { dialog ->
            val payload = JSONObject().put("rule", address.text.toString()).put("target", if (target.selectedItemPosition == 1) "direct" else "vpn")
            if (original != null) payload.put("originalRule", original).put("originalTarget", originalOutlet)
            perform("保存规则", true, { dialog.dismiss() }) { core.call(if (original == null) "routing:add-rule" else "routing:edit-rule", payload) }
        }
    }

    fun toolsCard(): View = card().apply {
        addView(label("连接管理", true))
        addView(button("aTrust 私有网络") { CompanyPage(activity,startVpn).show() })
        addView(row(button("静态 ISP 出口") { staticExitEditor() }, button("节点组") { groupsDialog() }))
        addView(button("ISP 线路测试与比较") { chainDialog() })
        addView(label("已接入与桌面共用的订阅、节点身份、分流和 ISP 设置。"))
    }

    private fun mobile() = dev.splitvpn.android.core.MobileDiagnostics(core, dev.splitvpn.android.core.RuntimeStatusRepository(activity))
    fun pauseMeasurements() {
        chainContinue = false
        val id = chainId
        if (id.isNotEmpty()) Thread { runCatching { core.obj("mobile:chain:cancel", JSONObject().put("id", id)) } }.start()
    }
    private fun chainDialog() {
        val results = column()
        val scopeEntries = entries().filter { it.optBoolean("enabled", true) }
        var scope = ""
        var strategy = "balanced"
        var offset = 0
        val status = label("请先连接，保存 ISP 配置后可独立检测机场 → ISP；每节点约 1.5 MiB。")
        val body = column(status)
        body.addView(selector(listOf("全部订阅") + scopeEntries.map { it.optString("name") }, 0) { index -> scope = if(index==0) "" else scopeEntries[index-1].optString("id") })
        body.addView(selector(listOf("综合推荐", "下载优先", "响应优先"),0) { strategy = listOf("balanced","download","latency")[it] })
        fun show(state: JSONObject) {
            status.text = "${state.optInt("completed")}/${state.optInt("total")} · ${if(state.optBoolean("running")) "测试中" else "已暂停／完成"}"
            results.removeAllViews()
            objects(state.optJSONArray("results")).take(100).forEach { value ->
                results.addView(card().apply {
                    addView(label(value.optString("nodeName",value.optString("name")),true))
                    addView(label("${value.optString("status")} · ${value.optString("latencyMs")} ms · ${value.optString("downloadMbps")} Mbps · ${value.optString("exitIp")}"))
                    if(value.optString("status")=="available") addView(button("复核并使用") {
                        perform("复核并应用 ISP 线路", false) {
                            val old = core.obj("settings:get")
                            try {
                                val verified=mobile().call("mobile:chain:prepare-use",JSONObject().put("identityKey",value.getString("identityKey")))
                                mobile().call("mobile:chain:commit-use",JSONObject().put("ticket",verified.getString("ticket")))
                                reloadSync(); apply()
                                val confirmed=mobile().call("mobile:diagnostics:verify-exit")
                                activity.runOnUiThread { status.text = "已确认实际出口：${confirmed.optString("externalIp")}" }
                            } catch(error:Exception) {
                                core.call("settings:patch",JSONObject().put("selectedProxy",old.get("selectedProxy")).put("defaultOutlet",old.get("defaultOutlet")).put("staticExit",old.get("staticExit")))
                                reloadSync(); runCatching { apply() }; throw error
                            }
                        }
                    })
                })
            }
        }
        fun begin(mode:String) {
            if(chainContinue) return
            chainContinue=true
            execute("ISP 线路测试") {
                try {
                    val payload=JSONObject().put("mode",mode); if(scope.isNotEmpty())payload.put("subscriptionId",scope)
                    var state=mobile().call("mobile:chain:start",payload)
                    chainId=state.getString("id")
                    while(chainContinue && state.optBoolean("running")) {
                        state=mobile().call("mobile:chain:next",JSONObject().put("id",chainId).put("strategy",strategy))
                        val view=state;activity.runOnUiThread { if(!activity.isDestroyed)show(view) }
                        if(mode=="continuous") { Thread.sleep(15_000) }
                    }
                } finally { chainContinue=false }
            }
        }
        body.addView(row(button("快速") { begin("quick") },button("全面") { begin("full") },button("少量复测") { begin("maintenance") },button("持续") { begin("continuous") },button("暂停") { pauseMeasurements() }))
        body.addView(button("验证实际出口") { execute("验证实际出口") { val value=mobile().call("mobile:diagnostics:verify-exit");activity.runOnUiThread {status.text="实际出口：${value.optString("externalIp")}"} } })
        body.addView(button("历史（下一页）") { execute("读取历史") { val page=core.obj("mobile:chain:history",JSONObject().put("offset",offset).put("limit",30));offset+=30;activity.runOnUiThread { results.removeAllViews();objects(page.optJSONArray("items")).forEach { row -> val r=row.optJSONObject("result")?:JSONObject();results.addView(label("${r.optString("nodeName")} · ${r.optString("status")} · ${row.optString("checkedAt")}")) };if(offset>=page.optInt("total"))offset=0 } } })
        body.addView(results)
        execute("读取线路结果") { val state=core.obj("mobile:chain:get",JSONObject().put("strategy",strategy));activity.runOnUiThread {show(state)} }
        AlertDialog.Builder(activity).setTitle("ISP 线路").setView(scroll(body)).setPositiveButton("关闭",null).create().apply { setOnDismissListener { pauseMeasurements() };show() }
    }

    private fun groupsDialog() {
        val content = column(label("节点组用于整理；连接时选择具体节点。"))
        groups().forEach { group -> content.addView(row(label("${group.optString("name")} · ${group.optJSONArray("nodeNames")?.length() ?: 0} 个"),
            button("编辑") { groupEditor(group) }, button("删除") { mutate("删除节点组", "node-groups:save", JSONObject().put("nodeGroups", JSONArray(groups().filterNot { it.optString("id") == group.optString("id") }))) })) }
        content.addView(button("添加节点组") { groupEditor(null) })
        AlertDialog.Builder(activity).setTitle("节点组").setView(scroll(content)).setPositiveButton("关闭", null).show()
    }
    private fun groupEditor(group: JSONObject?) {
        val name = input("名称", group?.optString("name").orEmpty())
        val names = strings(group?.optJSONArray("nodeNames"))
        val selected = nodes().filter { it.optString("name") in names }.map { it.optString("identityKey") }.toMutableSet()
        val body = column(name)
        nodes().filterNot { it.optBoolean("identityAmbiguous") }.forEach { node -> body.addView(check(node.optString("name"), node.optString("identityKey") in selected) { checked -> if (checked) selected.add(node.optString("identityKey")) else selected.remove(node.optString("identityKey")) }) }
        editor("节点组", body) { dialog ->
            val value = group?.let { JSONObject(it.toString()) } ?: JSONObject().put("id", java.util.UUID.randomUUID().toString()).put("strategy", "manual")
            value.put("name", name.text.toString())
            val chosen = nodes().filter { it.optString("identityKey") in selected }
            val knownNames = nodes().map { it.optString("name") }.toSet()
            value.put("nodeNames", JSONArray(chosen.map { it.optString("name") } + names.filterNot { it in knownNames }))
            val knownIds = nodes().map { it.optString("identityKey") }.toSet()
            value.put("members", JSONArray(chosen.map { JSONObject().put("identityKey", it.optString("identityKey")).put("lastKnownName", it.optString("name")) } + objects(group?.optJSONArray("members")).filterNot { it.optString("identityKey") in knownIds }))
            val list = groups().filterNot { it.optString("id") == value.optString("id") } + value
            perform("保存节点组", true, { dialog.dismiss() }) { core.call("node-groups:save", JSONObject().put("nodeGroups", JSONArray(list))) }
        }
    }

    private fun staticExitEditor() {
        val value = preferences().optJSONObject("staticExit") ?: JSONObject()
        val enabled = check("经机场连接静态 ISP", value.optBoolean("enabled")) { }
        val protocol = selector(listOf("SOCKS5", "HTTP", "HTTPS"), listOf("socks5", "http", "https").indexOf(value.optString("protocol", "socks5")).coerceAtLeast(0)) { }
        val server = input("服务器", value.optString("server")); val port = input("端口", value.optInt("port").takeIf { it > 0 }?.toString().orEmpty(), number = true)
        val username = input("用户名", value.optString("username")); val password = input("密码（留空沿用相同出口的已存密码）", secret = true)
        val expected = input("预期出口 IP（选填）", value.optString("expectedIp")); val pasted = input("hostname:port:username:password", secret = true)
        val body = column(enabled, label("只替换代理流量，保留直连规则。代理出口仅支持 TCP。"), pasted,
            button("解析粘贴内容") { perform("解析出口", false) {
                val result = core.obj("static-exit:parse", JSONObject().put("line", pasted.text.toString()))
                val parsed = result.getJSONObject("configuration")
                activity.runOnUiThread { server.setText(parsed.optString("server")); port.setText(parsed.optInt("port").toString()); username.setText(parsed.optString("username")); password.setText(result.optString("password")); pasted.setText("") }
            } }, protocol, server, port, username, password, expected, label("密码由 Android Keystore 加密，不进入偏好或诊断导出。"))
        editor("静态 ISP 出口", body) { dialog ->
            val number = port.text.toString().ifBlank { "0" }.toIntOrNull()
            if (number == null || number !in 0..65535) { port.error = "请输入有效端口"; return@editor }
            val configuration = JSONObject().put("enabled", enabled.isChecked).put("protocol", listOf("socks5", "http", "https")[protocol.selectedItemPosition])
                .put("server", server.text.toString().trim()).put("port", number).put("username", username.text.toString()).put("expectedIp", expected.text.toString().trim())
            val entered = password.text.toString()
            perform("保存 ISP 配置", false, { password.setText(""); pasted.setText(""); dialog.dismiss() }) {
                val old = settings.getStaticExitCredential(); val oldConfig = JSONObject(value.toString())
                val same = listOf("server", "port", "protocol", "username").all { old?.optJSONObject("configuration")?.opt(it) == configuration.opt(it) }
                val secret = if (entered.isEmpty() && same) old?.optString("password").orEmpty() else entered
                settings.setStaticExitCredential(JSONObject().put("configuration", configuration).put("password", secret))
                try { core.call("static-exit:configure", JSONObject().put("configuration", configuration)); settings.syncFromCore(core.obj("settings:get")); apply() }
                catch (error: Exception) { settings.setStaticExitCredential(old); core.call("static-exit:configure", JSONObject().put("configuration", oldConfig)); settings.syncFromCore(core.obj("settings:get")); throw error }
            }
        }
    }

    private fun editor(title: String, body: View, submit: (AlertDialog) -> Unit) {
        val dialog = AlertDialog.Builder(activity).setTitle(title).setView(scroll(body)).setNegativeButton("取消", null).setPositiveButton("保存", null).create()
        activeEditor = dialog
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            if (!busy) { submit(dialog); if (busy) { dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false; dialog.getButton(AlertDialog.BUTTON_NEGATIVE).isEnabled = false; dialog.setCancelable(false) } }
        } }
        dialog.setOnDismissListener { if (activeEditor === dialog) activeEditor = null }
        dialog.show()
    }
    private fun selector(values: List<String>, selected: Int, changed: (Int) -> Unit): Spinner = Spinner(activity).apply {
        adapter = ArrayAdapter(activity, android.R.layout.simple_spinner_dropdown_item, values)
        setSelection(selected)
        post { onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            private var prior = selected
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { if (prior != position) { prior = position; changed(position) } }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) { }
        } }
    }
    private fun check(title: String, checked: Boolean, changed: (Boolean) -> Unit) = CheckBox(activity).apply { text = title; setTextColor(this@ManagementPages.foreground); isChecked = checked; setOnCheckedChangeListener { _, value -> changed(value) } }
    private fun button(title: String, action: () -> Unit) = Button(activity).apply { text = title; isAllCaps = false; minHeight = dp(44); setOnClickListener { if (!busy) action() } }
    private fun input(hint: String, value: String = "", number: Boolean = false, secret: Boolean = false) = EditText(activity).apply {
        this.hint = hint; setText(value); setTextColor(this@ManagementPages.foreground); setHintTextColor(muted); textSize = 14f; minHeight = dp(48); isSingleLine = true
        inputType = if (number) InputType.TYPE_CLASS_NUMBER else if (secret) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
    }
    private fun label(value: String, strong: Boolean = false) = TextView(activity).apply { text = value; textSize = if (strong) 16f else 13f; setTextColor(if (strong) this@ManagementPages.foreground else muted); if (strong) setTypeface(null, Typeface.BOLD); setPadding(0, dp(6), 0, dp(6)) }
    private fun column(vararg views: View) = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; views.forEach { addView(it) } }
    private fun row(vararg views: View) = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL; views.forEach { addView(it, LinearLayout.LayoutParams(0, -2, 1f)) } }
    private fun card() = column().apply { setPadding(dp(16), dp(12), dp(16), dp(12)); background = GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(surface) }; layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, dp(12), 0, 0) } }
    private fun page(title: String, subtitle: String) = column(label(title, true), label(subtitle))
    private fun scroll(view: View) = ScrollView(activity).apply { addView(view); setPadding(dp(16), dp(8), dp(16), dp(8)) }
    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
    private fun objects(array: JSONArray?): List<JSONObject> = if (array == null) emptyList() else (0 until array.length()).mapNotNull(array::optJSONObject)
    private fun strings(array: JSONArray?): List<String> = if (array == null) emptyList() else (0 until array.length()).map { array.optString(it) }
}
