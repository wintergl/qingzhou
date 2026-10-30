package dev.splitvpn.android.core

import android.content.Context
import dev.splitvpn.android.SplitVpnService
import dev.splitvpn.company.companymobile.Companymobile
import dev.splitvpn.company.companymobile.Controller
import dev.splitvpn.company.companymobile.TunnelAttempt
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Authentication stays in Go; permission compilation stays in Rust. */
class MobileCompany private constructor(context: Context) {
    private val app = context.applicationContext
    private val core = CoreClient(SplitVpnPaths(app))
    private val vault = SecureVault(app)
    private val worker = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var record = JSONObject()
    @Volatile private var recordRevision = 0L
    @Volatile private var view = JSONObject().put("phase","idle").toString()
    @Volatile private var auth: Controller? = null
    @Volatile private var attempt: TunnelAttempt? = null
    @Volatile private var wanted = false
    private val generation = java.util.concurrent.atomic.AtomicLong(0L)
    private var poll: ScheduledFuture<*>? = null
    private var pendingTransfer: String? = null
    @Volatile private var transportIdentity = JSONObject()
    private var loginPassword = ""
    private var pendingPassword: JSONObject? = null
    init { go.Seq.setContext(app);app.getSharedPreferences("split_vpn_company_runtime",Context.MODE_PRIVATE).edit().clear().apply();worker.execute { reload();publish("idle","请检测入口并登录；已保存的授权在重新认证前保持阻断") } }
    fun showInputError(message:String){worker.execute {publish("error",message)}}
    fun metadata(): JSONObject = record // Published values are replaced, never mutated.
    fun metadataRevision(): Long = recordRevision
    fun state(): JSONObject = JSONObject(view)
    private fun reload() { record=core.obj("company:mobile:get");recordRevision++ }
    private fun configure(patch: JSONObject) {record=core.obj("company:mobile:configure",patch);recordRevision++}
    private fun publish(phase:String,message:String,extra:JSONObject?=null) {
        val state=JSONObject().put("phase",phase).put("message",message).put("operation",generation.get())
        extra?.keys()?.forEach {state.put(it,extra.get(it))};view=state.toString()
        // Challenges, callback URLs and verification details stay in memory.
    }
    private fun startAuth(command:JSONObject) {
        check(attempt==null) {"请先断开接入，再更换账号或重新认证"}
        val operation=generation.incrementAndGet();poll?.cancel(false);auth?.close();auth=Companymobile.newController()
        pendingPassword=null
        publish(if(command.optString("type")=="probe")"probing" else "authenticating","正在连接认证服务")
        auth!!.send(command.toString())
        poll=worker.scheduleWithFixedDelay({if(operation==generation.get())runCatching { consumeEvents() }.onFailure {publish("error","认证结果读取失败，请重试")}},0,400,TimeUnit.MILLISECONDS)
    }
    fun probe(origin:String) {worker.execute {runCatching {
        check(attempt==null) {"请先断开接入，再检测网关"};configure(JSONObject().put("origin",origin))
        startAuth(JSONObject().put("type","probe").put("origin",record.getString("origin")))
    }.onFailure {publish("error",it.message ?: "入口检测失败")} } }
    fun login(origin:String,username:String,domain:String,fingerprint:String,password:String,remember:Boolean) {worker.execute {runCatching {
        check(attempt==null) {"请先断开接入，再更换账号"}
        configure(JSONObject().put("origin",origin).put("username",username.trim()).put("domain",domain).put("fingerprint",fingerprint).put("remember",remember))
        val saved=vault.load("company")?.let(::JSONObject)
        loginPassword=if(password.isNotEmpty())password else if(remember && !record.optBoolean("passwordChangeUncertain") && saved?.optString("origin")==record.optString("origin") && saved.optString("username")==username.trim())saved.optString("password") else ""
        check(loginPassword.isNotEmpty()) {"请输入接入密码；改密结果不明确时不会自动使用旧密码"}
        startAuth(JSONObject().put("type","login").put("origin",record.getString("origin")).put("username",username.trim()).put("domain",domain).put("fingerprint",fingerprint).put("password",loginPassword))
    }.onFailure {loginPassword="";publish("error",it.message ?: "认证失败")} } }
    fun answer(response:JSONObject) {worker.execute {runCatching {
        val challenge=state().optJSONObject("challenge") ?: error("认证步骤已变化")
        check(response.optString("id")==challenge.optString("id")) {"认证步骤已变化"}
        if(challenge.optString("kind")=="password_change") {
            check(response.optString("newPassword").isNotEmpty()) {"新密码不能为空"}
            pendingPassword=JSONObject(response.toString());configure(JSONObject().put("passwordChangeUncertain",true))
        }
        auth?.send(response.put("type","challenge_response").toString()) ?: error("认证已结束")
        publish("authenticating","正在提交认证步骤")
    }.onFailure {publish("error",it.message ?: "认证步骤未完成")} } }
    @Synchronized private fun consumeEvents() {
        val operation=generation.get()
        val controller=auth ?: return
        val values=JSONArray(controller.poll())
        for(i in 0 until values.length()) {
            if(operation!=generation.get() || controller!==auth)return
            val e=values.getJSONObject(i)
            when(e.optString("type")) {
                "probe" -> {publish("probed","核对证书指纹后选择认证方式",JSONObject().put("probe",e.getJSONObject("probe")));poll?.cancel(false)}
                "challenge" -> publish("challenge",e.optJSONObject("challenge")?.optString("message").orEmpty(),JSONObject().put("challenge",e.getJSONObject("challenge")))
                "password_changed" -> {
                    val submitted=pendingPassword
                    if(submitted!=null && e.optString("id")==submitted.optString("id")) {
                        loginPassword=submitted.optString("newPassword")
                        val user=e.optString("username").ifBlank {record.optString("username")}
                        if(record.optBoolean("remember"))vault.save("company",JSONObject().put("origin",record.optString("origin")).put("username",user).put("password",loginPassword).toString()) else vault.save("company",null)
                        configure(JSONObject().put("username",user).put("passwordChangeUncertain",false));pendingPassword=null
                    }
                }
                "login_success" -> {
                    if(e.optString("username").isNotEmpty())configure(JSONObject().put("username",e.getString("username")))
                    if(record.optBoolean("remember"))vault.save("company",JSONObject().put("origin",record.optString("origin")).put("username",record.optString("username")).put("password",loginPassword).toString()) else vault.save("company",null)
                    configure(JSONObject().put("passwordChangeUncertain",false));loginPassword=""
                }
                "resources" -> {configure(JSONObject().put("resources",e.getJSONObject("resources").getJSONArray("rows")));publish("authenticated","认证成功，已获取授权资源");poll?.cancel(false)}
                "error" -> {if(e.optString("code")=="password_change_uncertain")configure(JSONObject().put("passwordChangeUncertain",true));publish("error",e.optString("message","接入失败"));loginPassword="";pendingPassword=null;poll?.cancel(false)}
                "progress" -> publish("authenticating",e.optString("message"))
            }
        }
    }
    fun requestConnection(takeover:Boolean=true,onPermissionRequired:()->Unit) {worker.execute {runCatching {
        val old=attempt
        if(old!=null){check(JSONObject(old.status()).optString("phase")!="ready"){"接入已连接"};attempt=null;Thread {old.close()}.start()}
        pendingTransfer=auth?.exportSession() ?: error("请先完成接入认证")
        configure(JSONObject().put("enabled",takeover));wanted=true
        publish("waiting-vpn","正在准备共享 VPN 隧道")
        if(SplitVpnService.isActive)serviceReady() else onPermissionRequired()
    }.onFailure {publish("error",it.message ?: "未能准备接入连接")} } }
    fun serviceReady() {worker.execute {
        if(!wanted || attempt!=null)return@execute
        val transfer=pendingTransfer ?: return@execute
        val operation=generation.incrementAndGet()
        val deadline=android.os.SystemClock.elapsedRealtime()+45_000
        var applied=false
        val identity=JSONObject(transfer)
        transportIdentity=JSONObject().put("origin",identity.optString("origin")).put("username",identity.optString("username")).put("fingerprint",identity.optString("fingerprint"))
        attempt=Companymobile.startTunnel(transfer,"");pendingTransfer=null;publish("connecting","正在建立 aTrust TCP 接入")
        poll?.cancel(false);poll=worker.scheduleWithFixedDelay({
            if(operation!=generation.get())return@scheduleWithFixedDelay
            runCatching {
                check(applied || android.os.SystemClock.elapsedRealtime()<deadline){"接入建立或配置应用超时，授权保护保持阻断"}
                val status=JSONObject(attempt?.status() ?: "{}")
                when(status.optString("phase")) {
                    "ready" -> if(!applied) {
                        var expected=""
                        SplitVpnService.reloadRunningConfig {MihomoConfigGenerator(core,SettingsRepository(app)).generate().also {expected=it.runtimeRevision}}
                        val actual=RuntimeStatusRepository(app).get()
                        check(actual.state==RuntimeStatusRepository.STATE_CONNECTED && actual.configurationRevision==expected){"授权分流配置生效尚未确认"}
                        if(operation==generation.get()){applied=true;publish("connected",if(record.optBoolean("enabled"))"已接管授权 TCP 资源；业务地址需单独验证" else "接入已连接，其他应用的资源尚未接管")}
                    }
                    "failed","cancelled" -> {if(operation==generation.get())transportFailed(status.optString("error","接入中断，授权资源保持阻断"))}
                }
            }.onFailure {if(operation==generation.get())transportFailed(it.message ?: "接入配置未能应用，授权资源保持阻断")}
        },0,1000,TimeUnit.MILLISECONDS)
    } }
    private fun transportFailed(message:String){
        poll?.cancel(false);val old=attempt;attempt=null;transportIdentity=JSONObject();Thread {old?.close()}.start()
        if(SplitVpnService.isActive)runCatching {SplitVpnService.reloadRunningConfig {MihomoConfigGenerator(core,SettingsRepository(app)).generate()}}
        publish("error",message)
    }
    private fun binding():JSONObject? {
        val active=attempt ?: return null
        val status=runCatching {JSONObject(active.status())}.getOrNull() ?: return null
        if(status.optString("phase")!="ready")return null
        return JSONObject().put("origin",transportIdentity.optString("origin")).put("username",transportIdentity.optString("username")).put("fingerprint",transportIdentity.optString("fingerprint")).put("port",status.optInt("port"))
    }
    fun refreshResources() {worker.execute {runCatching {check(attempt==null){"请先断开接入，再刷新授权资源"};auth?.send("{\"type\":\"refresh_resources\"}") ?: error("请重新登录");val operation=generation.get();poll?.cancel(false);poll=worker.scheduleWithFixedDelay({if(operation==generation.get())consumeEvents()},0,400,TimeUnit.MILLISECONDS)}.onFailure {publish("error",it.message ?: "资源更新失败")} } }
    fun verify(target:String) {worker.execute {
        val operation=generation.get()
        runCatching {val result=attempt?.verify(target) ?: error("请先连接接入");if(operation==generation.get())publish("connected","指定业务已通过接入隧道验证",JSONObject().put("verification",JSONObject(result)))}.onFailure {if(operation==generation.get())publish(state().optString("phase"),it.message ?: "业务验证失败")}
    } }
    @Synchronized fun cancel() {generation.incrementAndGet();wanted=false;poll?.cancel(false);auth?.close();auth=null;val active=attempt;attempt=null;transportIdentity=JSONObject();Thread {active?.close()}.start();loginPassword="";pendingPassword=null;pendingTransfer=null;publish("cancelled","已取消；已启用的授权保护保留，解除接管请点断开")}
    fun disconnect() {generation.incrementAndGet();wanted=false;poll?.cancel(false);val old=attempt;attempt=null;transportIdentity=JSONObject();pendingTransfer=null;Thread {old?.close()}.start();worker.execute {runCatching {configure(JSONObject().put("enabled",false));if(SplitVpnService.isActive)SplitVpnService.reloadRunningConfig {MihomoConfigGenerator(core,SettingsRepository(app)).generate()};publish("idle","已断开接入并解除授权资源接管")}.onFailure {publish("error",it.message ?: "解除接管未确认")} } }
    @Synchronized fun networkChanged() {generation.incrementAndGet();poll?.cancel(false);val old=attempt;attempt=null;pendingTransfer=runCatching {old?.exportSession()}.getOrNull() ?: pendingTransfer;transportIdentity=JSONObject();Thread {old?.close()}.start();if(wanted)publish("recovering",if(pendingTransfer==null)"接入会话已失效，请重新登录" else "等待网络恢复后重建接入")}
    fun setTakeover(enabled:Boolean){worker.execute {val operation=generation.get();runCatching {
        check(attempt!=null && JSONObject(attempt!!.status()).optString("phase")=="ready"){"请先连接接入"}
        configure(JSONObject().put("enabled",enabled));publish("applying","正在应用资源接管选择")
        var expected="";SplitVpnService.reloadRunningConfig {MihomoConfigGenerator(core,SettingsRepository(app)).generate().also {expected=it.runtimeRevision}}
        val actual=RuntimeStatusRepository(app).get();check(actual.state==RuntimeStatusRepository.STATE_CONNECTED && actual.configurationRevision==expected){"资源接管生效尚未确认"}
        if(operation==generation.get())publish("connected",if(enabled)"已接管授权 TCP 资源" else "接入已连接，其他应用的资源尚未接管")
    }.onFailure {if(operation==generation.get())publish("error",it.message ?: "资源接管变更未确认")} }}
    fun serviceStopped() {networkChanged()}
    fun permissionDenied(){cancel();publish("cancelled","VPN 权限未授予；授权保护保留，重新连接时可再申请")}
    fun clearCredential(){worker.execute {runCatching {vault.save("company",null);configure(JSONObject().put("remember",false));publish(state().optString("phase"),"已清除记住的接入密码")}.onFailure {publish("error","安全存储暂不可用")} }}
    companion object {
        @Volatile private var instance:MobileCompany?=null
        fun get(context:Context):MobileCompany=instance ?: synchronized(this){instance ?: MobileCompany(context).also {instance=it}}
        fun connectionRequested():Boolean=instance?.wanted==true
        fun activeDescriptor():JSONObject?=instance?.binding()
    }
}
