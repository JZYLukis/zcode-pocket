package dev.zcodeapp.zcode_companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * "审批提醒"前台服务（阶段 3 第二段）：常驻状态通知 + 连接保活。
 * 默认关闭——仅在设置页打开"审批提醒"时启动（phase3-notify-design
 * 档位表：开=后台实时通知，关=退后台约 90s 断连）。
 *
 * FGS 类型=specialUse（Manifest 注释详述理由：dataSync 在 Android 14+
 * 有每 24h 累计 6h 运行硬限，与过夜保活职责冲突，开源前审查 Q1 P2-1 /
 * Q2 P1-1 修正）。
 *
 * 通知为 LOW 重要性（不打扰）、ongoing、无 action；点击回到 app。
 */
class ForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "status"
        const val NOTIFICATION_ID = 100
        const val ACTION_START = "dev.zcodeapp.zcode_companion.action.START"
        const val ACTION_STOP = "dev.zcodeapp.zcode_companion.action.STOP"
        // 更新动作用自定义常量（开源审查 Q1 P3-11）：原借用公共
        // Intent.ACTION_EDIT（标准"编辑数据"语义）当私有标记，易误读且
        // 与隐式 action 解析器有理论碰撞面（服务 exported=false 实际无
        // 害，仍改同族自定义常量）。
        const val ACTION_UPDATE = "dev.zcodeapp.zcode_companion.action.UPDATE"
        const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            val intent = Intent(context, ForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ForegroundService::class.java).setAction(ACTION_STOP)
            )
        }

        fun update(context: Context, text: String) {
            context.startService(
                Intent(context, ForegroundService::class.java)
                    .setAction(ACTION_UPDATE)
                    .putExtra(EXTRA_TEXT, text)
            )
        }
    }

    private var currentText = "已连接 · 保持后台实时通知"

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 渠道名/描述走 strings.xml（开源审查 Q1 P3-7/Q2 P3-1 残项）：
            // values-en 已建基建，英文系统下系统通知设置页不再露中文
            // （渠道创建后文案不可变，仅新装+英文系统受益）。
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.fgs_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = getString(R.string.fgs_channel_desc)
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 空 intent=系统重启模式下的重启投递（或异常重启）。
        // 此时 Dart 引擎已不在、真实连接状态未知：沿用默认文案
        // 「已连接…」会留下假在线僵尸通知。直接收尾，由下次 AppState.load()
        // 按持久化的 alertsEnabled 重新补启（app_state 启动链已有）。
        if (intent == null) {
            Log.w("fgs", "null intent (system restart), stopping self")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                currentText = intent.getStringExtra(EXTRA_TEXT) ?: currentText
            }
            else -> {
                currentText = intent.getStringExtra(EXTRA_TEXT) ?: currentText
            }
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        // 不粘性：进程被杀后由 Dart 侧 load() 补启（带真实连接文案）；
        // 系统盲目重启只留一个状态未知的常驻通知，比不留更糟。
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 划掉最近任务=Dart 引擎与整个界面已销毁，保活/常驻通知失去
        // 意义。此前服务仍活着并维持「已连接」通知=假在线僵尸。
        Log.i("fgs", "task removed, stopping foreground service")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int) {
        // 超时合同（API 34+）回调：系统要求数秒内 stopSelf，默认空实现
        // 在 Android 15+ 会触发 ForegroundServiceDidNotStopInTimeException
        // 崩进程。本服务已改 specialUse 类型、无系统时限，此处纯防御覆写
        // ——万一未来再出现任何超时路径（类型误改回限额型等），优雅收尾
        // 并留日志，杜绝崩溃。守卫断言见 app/test/android_manifest_guard_test.dart。
        Log.w("fgs", "foreground service timeout (startId=$startId), stopping self")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        // 显式 intent 兜底（开源审查 Q2 P3-5）：启动入口被禁用等非常态下
        // getLaunchIntentForPackage 可返回 null，原实现直接 NPE 崩服务。
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = android.app.PendingIntent.getActivity(
            this, 0, launch,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("ZCode Pocket")
            .setContentText(currentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pending)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
