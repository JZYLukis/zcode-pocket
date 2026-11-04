import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 备份策略静态断言（H02）：allowBackup 未显式声明时安卓默认
/// 开启自动备份——应用目录的会话缓存/通知台账为明文 JSON，会进系统云
/// 备份/换机迁移。本断言防模板或依赖清单合并把该声明改回默认。
///
/// 前台服务类型断言（开源前审查 / ）：审批提醒保活服务
/// 必须用 specialUse 型——dataSync 型在 Android 14+ 有每 24h 累计 6h
/// 运行硬限（Android 15+ 超限后 startForeground 直接失败），过夜保活
/// 确定性失效；且超时路径须有 onTimeout 优雅收尾防
/// ForegroundServiceDidNotStopInTimeException 崩溃。
void main() {
  test('AndroidManifest 必须显式 allowBackup="false"（H02）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(
      manifest.contains('android:allowBackup="false"'),
      isTrue,
      reason: 'allowBackup 缺失或非 false 时，明文应用数据会随系统备份外带',
    );
  });

  test('前台服务类型必须为 specialUse（Android 14+ dataSync 6h 硬限）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(
      manifest.contains('android:foregroundServiceType="specialUse"'),
      isTrue,
      reason: '审批提醒保活需 7×24 常驻，dataSync 型在 Android 14+ 有'
          '每 24h 累计 6h 运行硬限，超时被系统强制停止且 START_STICKY '
          '不保证复活——过夜审批通知确定性丢失',
    );
    expect(
      manifest.contains('android:foregroundServiceType="dataSync"'),
      isFalse,
      reason: 'dataSync 类型已退役；残留说明类型迁移不完整',
    );
    expect(
      manifest.contains(
          'android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
      isTrue,
      reason: 'specialUse 型前台服务必须声明对应类型权限（Android 14+ '
          '按类型分权，缺失时 startForeground 抛 SecurityException）',
    );
    expect(
      manifest.contains(
          'android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      isFalse,
      reason: '旧 dataSync 类型权限应随类型一并移除；残留属半迁移',
    );
    expect(
      manifest.contains(
          'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'),
      isTrue,
      reason: 'specialUse 服务必须用 <property> 声明用途说明'
          '（PROPERTY_SPECIAL_USE_FGS_SUBTYPE），缺失在 Android 14+ '
          '安装/运行时校验不通过',
    );
  });

  test('ForegroundService 必须覆写 onTimeout 防超时崩溃路径', () {
    final source = File(
      'android/app/src/main/kotlin/dev/zcodeapp/zcode_companion/'
      'ForegroundService.kt',
    ).readAsStringSync();
    expect(
      source.contains('override fun onTimeout('),
      isTrue,
      reason: '超时回调默认空实现不 stopSelf，Android 15+ 会抛 '
          'ForegroundServiceDidNotStopInTimeException 崩进程；即使已改 '
          'specialUse 也须保留防御覆写（Q2 P1-1）',
    );
  });
}
