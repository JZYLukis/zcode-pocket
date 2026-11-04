package dev.zcodeapp.zcode_companion

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        // 帧看门狗 recreate 滑窗上限（开源审查 Q1 P2-2）：recreate 恢复的
        // 是引擎表面而非根因（楔死根因在 Flutter/华为侧未根治），Dart 侧
        // 看门狗每次 recreate 后随新 isolate 重新武装，Dart 内存计数无法
        // 跨重建累积——进程级滑窗放这里：10 分钟内第 4 次起拒绝并留日志
        // （防"每 ~32s 整 app 无限重启"循环，用户可自行大退/切页）。
        private const val RECREATE_WINDOW_MS = 10 * 60 * 1000L
        private const val RECREATE_MAX = 3
        private val recreateAt = mutableListOf<Long>()
    }

    private var pairingUrl: String? = null
    private var pairingName: String? = null
    // V2 测试缝（ADR 0032）：am start --es relay_v2_origin/account_jwt
    private var relayV2Origin: String? = null
    private var accountJwt: String? = null
    // 长按图标快捷入口（6.6①，ADR 0061）：冷启动经 getLaunchArgs 拉取，
    // 热启动（singleTop onNewIntent）原生→Dart 推送。
    private var shortcutAction: String? = null
    private var testChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 链接器顺序加固（模拟器实证）：进程最早期先占位加载 libdartjni，
        // 避免 path_provider（jni 实现）晚加载报 found-but-not-loaded。
        try {
            System.loadLibrary("dartjni")
        } catch (e: Throwable) {
            Log.w("voice", "dartjni preload skip: ${e.message}")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop 复用时的热更新（自动化测试反复推链接）
        readExtras(intent)
        // 快捷入口热路径（开源审查 Q1 P3-3/Q2 P2-2 修正留存语义）：
        // Dart handler 在位并已消费时回 true 回执——只有拿到回执才清空
        // 留存值；无 handler 时 invokeMethod 不抛错（回执为 null），旧
        // 实现无条件清空=注释承诺的"下次冷启动 getLaunchArgs 兜底"实际
        // 不存在、动作静默丢失。通道不在位（引擎窗口期）同样保留。
        val action = shortcutAction
        val ch = testChannel
        if (action != null && ch != null) {
            ch.invokeMethod("shortcut", action, object : MethodChannel.Result {
                override fun success(reply: Any?) {
                    if (reply == true) shortcutAction = null
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    // 保留留存值，下次冷启动兜底
                }

                override fun notImplemented() {
                    // 同上：保留
                }
            })
        }
    }

    private fun readExtras(intent: Intent) {
        pairingUrl = intent.getStringExtra("pairing_url")
        pairingName = intent.getStringExtra("pairing_name")
        shortcutAction = intent.getStringExtra("shortcut_action")
        // 凭据类测试缝（H01，ADR 0046）：仅 debuggable 构建读取——MainActivity
        // 为 exported 启动入口，release 下恶意应用可借启动参数把带 Bearer 令牌
        // 的请求引向自建服务器。此处为原生侧防线，Dart 应用侧另有闸门。
        // pairing_url/name 保留：release 冷启动/持久化验证依赖（域白名单在
        // Dart 侧把关）。
        if ((applicationInfo.flags and
                    android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        ) {
            relayV2Origin = intent.getStringExtra("relay_v2_origin")
            accountJwt = intent.getStringExtra("account_jwt")
        } else {
            relayV2Origin = null
            accountJwt = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 系统语音识别通道（2026-10-28 语音泛用批）：标准 SpeechRecognizer
        // 无界面流式接线（companion/sys_asr）。
        SystemAsrPlugin.bind(flutterEngine, this)
        readExtras(intent)
        // companion/test 通道（名字沿用历史测试缝，Q2 P3-7）：现承载
        // 生产功能——长按图标快捷入口（冷启动 getLaunchArgs + 热启动
        // shortcut 推送）与自动化配对缝。勿当测试面裁剪；app.dart 侧
        // 对位注释。
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "companion/test"
        )
        testChannel = channel
        // 帧看门狗的表面重建（18091 扫码黑屏根治层 3，ADR 0080 §9）：
        // 相机纹理销毁后引擎偶发停止产帧（Dart 活/帧死/窗口黑，进程
        // 健康）——Dart 侧检测到楔死后调用 recreate 重建 Flutter 表面。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "companion/surface"
        ).setMethodCallHandler { call, result ->
            if (call.method == "recreate") {
                // 回测组5 P2-4：配对成功的确定性重建（ADR 0080 四层防线）
                // 与看门狗楔死自愈不同源——楔死可能"根因未除"需要限流，
                // 配对成功是已知健康路径，reason=paired 免滑窗（10 分钟内
                // 第 4 台电脑扫码配对此前会被静默拒建=黑屏回归面）。
                val exempt = call.argument<String>("reason") == "paired"
                // 消费型 extras 先清（开源审查 Q2 P2-4）：recreate 保留
                // 原始 intent，新实例 readExtras 会把快捷动作/配对参数
                // 重新装回 → 冷启动二次消费（快捷动作数小时后重放/同
                // URL 二次配对）。
                for (key in listOf(
                    "shortcut_action", "pairing_url", "pairing_name",
                    "relay_v2_origin", "account_jwt"
                )) {
                    intent.removeExtra(key)
                }
                val now = System.currentTimeMillis()
                recreateAt.removeAll { now - it > RECREATE_WINDOW_MS }
                if (!exempt && recreateAt.size >= RECREATE_MAX) {
                    Log.w(
                        "surface",
                        "recreate refused: ${recreateAt.size} in window " +
                            "(wedge root cause unresolved? manual restart advised)"
                    )
                    result.success(false)
                    return@setMethodCallHandler
                }
                if (!exempt) recreateAt.add(now)
                runOnUiThread { recreate() }
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        channel.setMethodCallHandler { call, result ->
            if (call.method == "getLaunchArgs") {
                result.success(
                    mapOf(
                        "pairingUrl" to pairingUrl,
                        "pairingName" to pairingName,
                        "relayV2Origin" to relayV2Origin,
                        "accountJwt" to accountJwt,
                        "shortcutAction" to shortcutAction,
                    )
                )
                pairingUrl = null
                pairingName = null
                relayV2Origin = null
                accountJwt = null
                shortcutAction = null
            } else {
                result.notImplemented()
            }
        }
        // 用量统计的本地自然日归桶（2026-10-27：缺省 UTC 导致峰值/
        // 热力图日期偏移）。只返回 IANA 时区 id，不读任何用户内容。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "companion/timezone")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") {
                    result.success(java.util.TimeZone.getDefault().id)
                } else {
                    result.notImplemented()
                }
            }
        // 本机应用版本（parity-fix-1 B27）：关于页显示自身 versionName
        // （release 含 HEAD 指纹）；零第三方依赖，走包管理器。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "companion/appinfo")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") {
                    try {
                        val pm = packageManager.getPackageInfo(packageName, 0)
                        val versionName = pm.versionName ?: "unknown"
                        @Suppress("DEPRECATION")
                        val versionCode = if (android.os.Build.VERSION.SDK_INT >= 28) {
                            pm.longVersionCode
                        } else {
                            pm.versionCode.toLong()
                        }
                        result.success(
                            mapOf(
                                "versionName" to versionName,
                                "versionCode" to versionCode,
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("appinfo_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        // 电量日志（2026-10-19 用户需求：包内常驻统计归因，无 UI）。
        // registerReceiver(null, ...) 读粘性广播——无接收器注册、无生命
        // 周期负担，每次 poll 即读即走。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "companion/battery")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") {
                    try {
                        val intent = registerReceiver(
                            null,
                            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                        )
                        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                        val pct = if (level >= 0 && scale > 0) level * 100 / scale else -1
                        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                            status == BatteryManager.BATTERY_STATUS_FULL
                        result.success(
                            mapOf(
                                "level" to pct,
                                "charging" to charging,
                                "voltage" to (intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1),
                                "temperature" to (intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1),
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("battery_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "companion/notify")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForeground" -> {
                        try {
                            // 开源审查 Q1 P3-7：初始文案由 Dart 侧按当前
                            // 语言传入；缺省时保留中文兜底（启动后
                            // updateForeground 会立即覆写为实时状态文案）。
                            val text = call.argument<String>("text")
                                ?: "已连接 · 保持后台实时通知"
                            ForegroundService.start(this, text)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("fg_start_failed", e.message, null)
                        }
                    }
                    "stopForeground" -> {
                        try {
                            ForegroundService.stop(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("fg_stop_failed", e.message, null)
                        }
                    }
                    "updateForeground" -> {
                        val text = call.argument<String>("text") ?: ""
                        try {
                            ForegroundService.update(this, text)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("fg_update_failed", e.message, null)
                        }
                    }
                    // 华为引导页三层兜底（phase3-notify-design 华为专项）：
                    // ①已知组件名直跳启动管理 → ②应用详情页 → ③图文指引
                    "openStartupManage" -> {
                        val jumped = tryJumpStartupManage()
                        if (jumped) {
                            result.success("startup")
                        } else {
                            // 回退：应用详情页（手动进"启动管理"）
                            try {
                                val intent = Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success("details")
                            } catch (e: Exception) {
                                result.success("manual")
                            }
                        }
                    }
                    // 忽略电池优化（华为省电机制的另一半）
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                @Suppress("BatteryLife")
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("battery_failed", e.message, null)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } catch (e: Exception) {
                            result.error("battery_check_failed", e.message, null)
                        }
                    }
                    // 本应用通知设置页（"允许通知"+"锁屏通知"双开关入口）
                    "openNotificationSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 已知启动管理组件名依次尝试（华为组件名随系统版本漂移——三层兜底第 1 层）。
    private fun tryJumpStartupManage(): Boolean {
        val candidates = listOf(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.optimize.process.ProtectActivity",
            ),
        )
        for (component in candidates) {
            try {
                val intent = Intent()
                    .setComponent(component)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // 尝试下一个候选
            }
        }
        return false
    }
}
