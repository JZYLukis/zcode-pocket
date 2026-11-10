package dev.zcodeapp.zcode_companion

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统语音识别通道（companion/sys_asr）：Android 标准 SpeechRecognizer
 * 的无界面流式接线——语音识别的主体通道（所有构建默认走此通道）。
 * 零第三方依赖。
 *
 * 协议（Dart↔原生）：
 * - isAvailable → Bool：本地 Intent 查询（Manifest 已声明 RecognitionService
 *   queries，Android 11+ 包可见性）。
 * - start {language} → 开始拾音（语言随 app 界面语言传入，缺省 zh-CN；
 *   部分结果开启）；事件经 event 回推：type=partial/final/error
 *   （text/code/message）。
 * - stop → 停止拾音并尽快吐 final（用户点"说完了"）。
 * - cancel → 放弃（面板关闭）。
 *
 * 每次识别会话用新实例，final/error 后即销毁（SpeechRecognizer 实例
 * 复用语义各 ROM 实现不一，不赌）。
 */
class SystemAsrPlugin(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "companion/sys_asr"

        fun bind(engine: FlutterEngine, context: Context) {
            val plugin = SystemAsrPlugin(context.applicationContext)
            plugin.channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(plugin)
            }
            // 引擎生命周期收尾（2026-11-08 对抗审查）：Dart 面板 dispose
            // 靠通道 cancel 消息，引擎销毁/热重启时消息到不了——原生
            // recognizer 会悬空继续拾音。引擎销毁前主动 destroy。
            engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = plugin.teardown()
                override fun onEngineWillDestroy() = plugin.teardown()
            })
        }
    }

    private var recognizer: SpeechRecognizer? = null
    private var channel: MethodChannel? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {
                // isRecognitionAvailable 部分无服务实现在创建实例时才报——
                // 双保险：静态查询 + createSpeechRecognizer 的错误回调兜底。
                val ok = try {
                    SpeechRecognizer.isRecognitionAvailable(context)
                } catch (e: Exception) {
                    false
                }
                result.success(ok)
            }
            "start" -> start(call, result)
            "stop" -> {
                try { recognizer?.stopListening() } catch (e: Exception) { /* 已收尾 */ }
                result.success(null)
            }
            "cancel" -> {
                teardown()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        // 全体包 try（开源审查）：isRecognitionAvailable /
        // createSpeechRecognizer 在部分 ROM 上可抛（服务绑定异常立即失败
        // 型实现），裸抛会从平台主线程崩整个进程——对齐 companion 通道既有实现
        // 的全包形态（isAvailable 通道早已自包 try，此处补齐同款）。
        try {
            if (!SpeechRecognizer.isRecognitionAvailable(context)) {
                result.error("unavailable", "no recognition service", null)
                return
            }
            teardown()
            val r = SpeechRecognizer.createSpeechRecognizer(context)
            recognizer = r
            r.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}

                override fun onError(error: Int) {
                    // 7=no match、6=speech timeout 属"没听到内容"，其余按服务
                    // 异常报；文案人话化由 Dart 侧统一。
                    emit(mapOf("type" to "error", "code" to error))
                    // final/error 即销毁（开源审查）：兑现类头注释
                    // "不赌 ROM 复用语义"——识别服务连接/隐私指示器不滞留
                    // 到预览/整理阶段；emit 先行，本次事件不受影响。
                    teardown()
                }

                override fun onResults(results: Bundle?) {
                    val text = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull() ?: ""
                    emit(mapOf("type" to "final", "text" to text))
                    teardown()
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull() ?: ""
                    if (text.isNotEmpty()) emit(mapOf("type" to "partial", "text" to text))
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            // 识别语言跟随 app 语言（开源审查）：Dart 侧按当前
            // 界面语言传入（zh-CN/en-US），缺省中文兜底——英文界面用户
            // 不再被塞进中文识别引擎。
            val language = call.argument<String>("language") ?: "zh-CN"
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(
                    RecognizerIntent.EXTRA_CALLING_PACKAGE,
                    context.packageName,
                )
            }
            try {
                r.startListening(intent)
                result.success(null)
            } catch (e: Exception) {
                teardown()
                result.error("start_failed", e.message ?: "startListening failed", null)
            }
        } catch (e: Throwable) {
            teardown()
            result.error("start_failed", e.message ?: "start failed", null)
        }
    }

    private fun emit(payload: Map<String, Any?>) {
        val ch = channel ?: return
        ch.invokeMethod("event", payload)
    }

    private fun teardown() {
        recognizer?.let {
            try {
                it.destroy()
            } catch (e: Exception) { /* 收尾竞态 */ }
        }
        recognizer = null
    }
}
