package dev.zcodeapp.zcode_companion

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// 应用锁原生通道（早前批次）：
/// - isDeviceSecure：KeyguardManager.isKeyguardSecure（设置页开启
///   「系统锁屏」模式的前置校验；无需任何权限）。
/// - requestSystemUnlock：createConfirmDeviceCredentialIntent 走系统
///   锁屏验证（指纹/面容/图案/PIN 取决于用户的系统锁方式）。选这条
///   路而非 androidx BiometricPrompt 的原因：后者要求宿主为
///   FragmentActivity（本项目 MainActivity 是 FlutterActivity，基类
///   迁移会牵连扫码/WebView/onNewIntent 全量回归），而
///   confirmDeviceCredential 自 API 23 可用且自带生物识别。
/// - setSecureFlag：锁定遮罩期间开 FLAG_SECURE（防任务栏缩略图/截屏
///   泄露，可选开关由 Dart 侧决定）。
///
/// onActivityResult 由 MainActivity 转发给 [handleActivityResult]。
class AppLockPlugin private constructor(
    private val activity: Activity,
) {
    internal var pendingResult: MethodChannel.Result? = null

    companion object {
        private const val channelName = "companion/app_lock"
        private const val requestCode = 4711

        // 单例持有：requestSystemUnlock 的 pendingResult 必须存活到
        // onActivityResult（每 call 新建实例会丢 pending result）。
        private var instance: AppLockPlugin? = null

        fun bind(engine: FlutterEngine, activity: Activity) {
            val plugin = AppLockPlugin(activity)
            instance = plugin
            MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
                .setMethodCallHandler { call, result ->
                    plugin.handle(call, result)
                }
        }

        fun release() {
            instance?.pendingResult?.success(false)
            instance?.pendingResult = null
            instance = null
        }

        fun handleActivityResult(requestCode: Int, resultCode: Int): Boolean =
            instance?.handleActivityResult(requestCode, resultCode) ?: false
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isDeviceSecure" -> {
                val km = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                result.success(km.isKeyguardSecure)
            }
            "requestSystemUnlock" -> {
            // 对抗审查 ①：并发请求先回旧 Result（防其 Dart future
                // 永久悬挂）——锁屏有 _verifying 防抖但设置页无锁。
                pendingResult?.success(false)

                val km = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                val intent: Intent? = km.createConfirmDeviceCredentialIntent(
                    "ZCode Pocket",
                    "验证以继续使用",
                )
                if (intent == null) {
                    // 无系统锁（isKeyguardSecure=false 的兜底）。
                    result.success(false)
                    return
                }
                pendingResult = result
                activity.startActivityForResult(intent, requestCode)
            }
            "setSecureFlag" -> {
                val on = call.arguments as? Boolean ?: false
                if (on) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(true)
            }
            "openSecuritySettings" -> {
                // 设备无系统锁时的引导跳转（ACTION_SECURITY_SETTINGS 在
                // 多数 ROM 可达屏幕锁设置；失败回 false 由 Dart 再提示）。
                try {
                    val intent = Intent(android.provider.Settings.ACTION_SECURITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    /// 由 MainActivity.onActivityResult 转发（requestCode 匹配时消费）。
    private fun handleActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != AppLockPlugin.requestCode) return false
        val result = pendingResult ?: return true
        pendingResult = null
        // RESULT_OK=验证通过；RESULT_CANCELED=用户取消/失败——统一 false
        // 由 Dart 停留锁屏（可重点）。
        result.success(resultCode == Activity.RESULT_OK)
        return true
    }
}
