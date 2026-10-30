package dev.splitvpn.android.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Base64
import android.view.MotionEvent
import android.view.View
import android.widget.*
import dev.splitvpn.android.core.MobileCompany
import org.json.JSONArray
import org.json.JSONObject

/** Native authentication UI; challenges and permissions come from the shared backend. */
class CompanyPage(private val activity:Activity,private val requestVpn:()->Unit) {
    private val company=MobileCompany.get(activity)
    private val handler=Handler(Looper.getMainLooper())
    private fun input(hint:String,secret:Boolean=false)=EditText(activity).apply {this.hint=hint;isSingleLine=true;inputType=if(secret)InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI}
    private fun text(value:String)=TextView(activity).apply {text=value;textSize=14f;setPadding(0,12,0,8);setTextIsSelectable(true)}
    private fun column()=LinearLayout(activity).apply {orientation=LinearLayout.VERTICAL;setPadding(24,8,24,12)}
    private fun button(title:String,action:()->Unit)=Button(activity).apply {text=title;setOnClickListener {action()} }
    fun show() {
        val body=column();val origin=input("HTTPS 接入地址");val username=input("接入账号");val password=input("接入密码；留空使用已记住的密码",true)
        val domain=Spinner(activity);val remember=CheckBox(activity).apply {text="使用设备安全存储记住密码"};val confirm=CheckBox(activity).apply {text="已核对并确认当前证书指纹"}
        val status=text("正在读取接入设置");val certificate=text("");val resources=column();val challenge=column();val target=input("HTTP/HTTPS 业务验证地址")
        val takeover=CheckBox(activity).apply {text="连接后接管授权资源";isChecked=true}
        var methods=listOf<JSONObject>();var fingerprint="";var probeOrigin="";var shownChallenge="";var loaded=false;var lastResources=-1L
        val detect=button("检测入口与证书") {confirm.isChecked=false;company.probe(origin.text.toString())}
        val login=button("登录并获取授权资源") {
            if(!confirm.isChecked || fingerprint.isBlank() || origin.text.toString().trim().trimEnd('/')!=probeOrigin) {company.showInputError("请检测当前入口并核对证书");return@button}
            val method=methods.getOrNull(domain.selectedItemPosition)?.optString("loginDomain").orEmpty()
            if(method.isBlank()){company.showInputError("请先检测认证方式");return@button}
            company.login(probeOrigin,username.text.toString(),method,fingerprint,password.text.toString(),remember.isChecked);password.text.clear()
        }
        body.addView(text("aTrust 私有网络"));body.addView(origin);body.addView(detect);body.addView(certificate);body.addView(confirm);body.addView(username);body.addView(password);body.addView(domain);body.addView(remember);body.addView(login)
        body.addView(button("清除已记住的密码") {company.clearCredential();remember.isChecked=false})
        body.addView(status);body.addView(challenge)
        body.addView(takeover)
        body.addView(button("连接接入") {company.requestConnection(takeover.isChecked) {activity.runOnUiThread {requestVpn()}}})
        body.addView(button("应用资源接管选择") {company.setTakeover(takeover.isChecked)})
        body.addView(button("断开并解除接管") {company.disconnect()});body.addView(button("取消当前操作") {company.cancel()})
        body.addView(text("只接管授权 TCP 地址和端口；后端未就绪或失效时保留阻断，明确断开后解除接管。"))
        body.addView(button("刷新授权资源") {company.refreshResources()});body.addView(resources);body.addView(target);body.addView(button("通过当前接入隧道验证业务") {company.verify(target.text.toString())})
        val dialog=AlertDialog.Builder(activity).setTitle("私有网络").setView(ScrollView(activity).apply {addView(body)}).setPositiveButton("关闭",null).create()
        val refresh=object:Runnable {override fun run(){
            if(!dialog.isShowing || activity.isDestroyed)return
            val record=company.metadata();val state=company.state()
            if(!loaded && record.has("origin")){loaded=true;if(origin.text.isEmpty())origin.setText(record.optString("origin"));username.setText(record.optString("username"));remember.isChecked=record.optBoolean("remember")}
            val statusText=state.optString("message")+if(record.optBoolean("passwordChangeUncertain"))"\n改密结果尚未确认，请手动输入当前密码；不会自动使用旧密码。" else ""
            if(status.text.toString()!=statusText)status.text=statusText
            state.optJSONObject("probe")?.let {probe->
                if(probe.optString("fingerprint")!=fingerprint){fingerprint=probe.optString("fingerprint");probeOrigin=probe.optString("origin");certificate.text="${probe.optString("subject")}\n有效期至 ${probe.optString("validTo")}\nSHA-256：$fingerprint";methods=objects(probe.optJSONArray("methods"));domain.adapter=ArrayAdapter(activity,android.R.layout.simple_spinner_dropdown_item,methods.map {it.optString("authName")})}
            }
            val active=state.optString("phase") in listOf("connected","connecting","applying","waiting-vpn","recovering")
            val working=state.optString("phase") in listOf("probing","authenticating","challenge")
            origin.isEnabled=!active&&!working;username.isEnabled=!active&&!working;detect.isEnabled=!active&&!working;login.isEnabled=!active&&!working
            val revision=company.metadataRevision();if(revision!=lastResources){lastResources=revision;resources.removeAllViews();val rows=objects(record.optJSONArray("resources"));val list=ListView(activity).apply {adapter=ArrayAdapter(activity,android.R.layout.simple_list_item_1,rows.map {r->"${r.optString("name")}\n${r.optString("address")} · ${r.optString("network")} · ${r.optString("ports")}"});setOnTouchListener {v,event->v.parent.requestDisallowInterceptTouchEvent(event.action!=MotionEvent.ACTION_UP);false}};resources.addView(text("授权资源：${rows.size} 条"));resources.addView(list,LinearLayout.LayoutParams(-1,(260*activity.resources.displayMetrics.density).toInt()))}
            val c=state.optJSONObject("challenge")
            if(c!=null && c.optString("id")!=shownChallenge){shownChallenge=c.optString("id");challenge.removeAllViews();renderChallenge(challenge,c)}
            if(c==null && shownChallenge.isNotEmpty()){shownChallenge="";challenge.removeAllViews()}
            handler.postDelayed(this,600)
        }}
        dialog.setOnDismissListener {handler.removeCallbacks(refresh);if(company.state().optString("phase") in listOf("probing","authenticating","challenge"))company.cancel()}
        dialog.show();handler.post(refresh)
    }
    private fun renderChallenge(body:LinearLayout,c:JSONObject) {
        val kind=c.optString("kind");body.addView(text(c.optString("title")));body.addView(text(c.optString("message")))
        if(c.optString("errorMessage").isNotEmpty())body.addView(text(c.optString("errorMessage")))
        val answer=JSONObject().put("id",c.getString("id"));val fields=mutableMapOf<String,EditText>();val points=JSONArray()
        fun field(key:String,hint:String,secret:Boolean=false){val view=input(hint,secret);fields[key]=view;body.addView(view)}
        if(kind=="password_change") {
            val rules=c.optJSONArray("rules");if(rules!=null)for(i in 0 until rules.length())body.addView(text(rules.optString(i)))
            if(c.optBoolean("requireUsername"))field("newUsername","新账号名")
            field("oldPassword","旧密码",true);field("newPassword","新密码",true);field("confirmPassword","确认新密码",true)
        }else if(kind=="external") {
            body.addView(button("打开统一认证页面") {val uri=Uri.parse(c.optString("url"));if(uri.scheme=="https")activity.startActivity(Intent(Intent.ACTION_VIEW,uri))})
            field("callbackURL","完成后粘贴最终回调地址")
        }else {
            if(c.optString("imageBase64").isNotEmpty()) {
                runCatching {
                    val bytes=Base64.decode(c.getString("imageBase64"),Base64.DEFAULT);check(bytes.size<=4*1024*1024)
                    val bounds=BitmapFactory.Options().apply {inJustDecodeBounds=true};BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
                    check(bounds.outWidth>0&&bounds.outHeight>0&&bounds.outWidth.toLong()*bounds.outHeight<=4_194_304)
                    val bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.size) ?: throw IllegalStateException("图片无法读取")
                    val image=ImageView(activity).apply {setImageBitmap(bitmap);adjustViewBounds=true;scaleType=ImageView.ScaleType.FIT_CENTER;minimumHeight=160}
                    body.addView(image,LinearLayout.LayoutParams(-1,-2));answer.put("width",bitmap.width).put("height",bitmap.height)
                    if(kind=="click") {
                        val chosen=text("请按提示依次点选")
                        image.setOnTouchListener {view,event->
                            if(event.action==MotionEvent.ACTION_UP&&points.length()<20){
                                val scale=minOf(view.width.toFloat()/bitmap.width,view.height.toFloat()/bitmap.height)
                                val x=(event.x-(view.width-bitmap.width*scale)/2)/scale;val y=(event.y-(view.height-bitmap.height*scale)/2)/scale
                                if(x>=0&&y>=0&&x<bitmap.width&&y<bitmap.height){points.put(JSONObject().put("x",x.toInt()).put("y",y.toInt()));chosen.text="已点选 ${points.length()} 处";view.performClick()}
                            };true
                        }
                        body.addView(chosen);body.addView(button("重新点选") {while(points.length()>0)points.remove(0);chosen.text="请重新依次点选"})
                    }
                }.onFailure {body.addView(text("验证码图片无效或过大，请重新检测入口"))}
            }
            if(kind!="click")field("code","验证码／动态口令")
        }
        val error=text("");body.addView(error)
        body.addView(button("提交认证步骤") {
            if(kind=="password_change"&&(fields["newPassword"]?.text.isNullOrEmpty()||fields["newPassword"]?.text.toString()!=fields["confirmPassword"]?.text.toString())){error.text="两次新密码需要一致且不能为空";return@button}
            if(kind=="click"&&points.length()==0){error.text="请先按提示点选图片";return@button}
            fields.filterKeys {it!="confirmPassword"}.forEach {(key,view)->answer.put(key,view.text.toString());view.text.clear()}
            if(kind=="click")answer.put("points",points)
            company.answer(answer)
        })
    }
    private fun objects(values:JSONArray?):List<JSONObject> = if(values==null)emptyList()else(0 until values.length()).mapNotNull(values::optJSONObject)
}
