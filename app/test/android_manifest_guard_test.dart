import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 备份策略静态断言：allowBackup 未显式声明时安卓默认
/// 开启自动备份——应用目录的会话缓存/通知台账为明文 JSON，会进系统云
/// 备份/换机迁移。本断言防模板或依赖清单合并把该声明改回默认。
///
/// 前台服务类型断言（开源前审查 / ）：审批提醒保活服务
/// 必须用 specialUse 型——dataSync 型在 Android 14+ 有每 24h 累计 6h
/// 运行硬限（Android 15+ 超限后 startForeground 直接失败），过夜保活
/// 确定性失效；且超时路径须有 onTimeout 优雅收尾防
/// ForegroundServiceDidNotStopInTimeException 崩溃。
/// （终审批1）：节点归属解析——注释里出现同串不得假绿。
/// indexOf 解析（不开正则转义坑）：取 `<tag ...>` 开标签与 `</tag>` 闭标签。
String? _nodeBlock(String xml, String tag) {
  final open = xml.indexOf('<$tag');
  if (open < 0) return null;
  final tagEnd = xml.indexOf('>', open);
  if (tagEnd < 0) return null;
  final close = xml.indexOf('</$tag>', tagEnd);
  if (close < 0) return xml.substring(open, tagEnd + 1);
  return xml.substring(open, close + tag.length + 3);
}

Set<String> _usesPermissions(String xml) => RegExp(
        r'<uses-permission\s+android:name="([^"]+)"')
    .allMatches(xml)
    .map((m) => m.group(1)!)
    .toSet();

void main() {
  test('AndroidManifest 必须显式 allowBackup="false"（H02）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final start = manifest.indexOf('<application');
    final end = start < 0 ? -1 : manifest.indexOf('>', start);
    final app = (start < 0 || end <= start) ? null : manifest.substring(start, end + 1);
    expect(app, isNotNull, reason: 'manifest 缺 <application> 节点');
    expect(
      app!.contains('android:allowBackup="false"'),
      isTrue,
      reason: 'allowBackup 缺失或非 false 时，明文应用数据会随系统备份外带',
    );
  });

  test('应用内更新安装链路三件套（早前批次）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final permissions = _usesPermissions(manifest);
    expect(
      permissions.contains('android.permission.REQUEST_INSTALL_PACKAGES'),
      isTrue,
      reason: '应用内更新调起安装器必需（仅用户点「立即更新」时触发授权流程）',
    );
    final provider = _nodeBlock(manifest, 'provider');
    expect(provider, isNotNull, reason: 'manifest 缺 FileProvider 节点');
    expect(
      provider!.contains('androidx.core.content.FileProvider'),
      isTrue,
      reason: 'openApk 调起安装器需要 content:// URI 授权读取',
    );
    expect(
      File('android/app/src/main/res/xml/update_file_paths.xml')
          .existsSync(),
      isTrue,
      reason: 'FileProvider paths 配置缺失',
    );
    // 产物分享（早前批次）：分享文件只授权 cache/artifacts 子目录
    // （原生 getUriForFile 要求该目录在 paths 里登记，缺失=调起分享即抛
    // IllegalArgumentException 归 false）。
    expect(
      File('android/app/src/main/res/xml/update_file_paths.xml')
          .readAsStringSync()
          .contains('path="artifacts/"'),
      isTrue,
      reason: '产物分享的 FileProvider artifacts/ 子目录缺失',
    );
  });

  test('前台服务类型必须为 specialUse（Android 14+ dataSync 6h 硬限）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final service = _nodeBlock(manifest, 'service');
    expect(service, isNotNull, reason: 'manifest 缺 <service> 节点');
    expect(
      service!.contains('android:name=".ForegroundService"'),
      isTrue,
      reason: '保活服务节点缺失',
    );
    expect(
      service.contains('android:foregroundServiceType="specialUse"'),
      isTrue,
      reason: '审批提醒保活需 7×24 常驻，dataSync 型在 Android 14+ 有'
          '每 24h 累计 6h 运行硬限，超时被系统强制停止且 START_STICKY '
          '不保证复活——过夜审批通知确定性丢失',
    );
    expect(
      service.contains('android:foregroundServiceType="dataSync"'),
      isFalse,
      reason: 'dataSync 类型已退役；残留说明类型迁移不完整',
    );
    final permissions = _usesPermissions(manifest);
    expect(
      permissions.contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
      isTrue,
      reason: 'specialUse 型前台服务必须声明对应类型权限（Android 14+ '
          '按类型分权，缺失时 startForeground 抛 SecurityException）',
    );
    expect(
      permissions.contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      isFalse,
      reason: '旧 dataSync 类型权限应随类型一并移除；残留属半迁移',
    );
    expect(
      service.contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'),
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

  test('通知小图标资源存在且为单色白（ic_notification）', () {
    final icon = File(
      'android/app/src/main/res/drawable/ic_notification.xml',
    );
    expect(icon.existsSync(), isTrue,
        reason: 'notification_service 的 AndroidNotificationDetails '
            'icon 指向 ic_notification；资源缺失时安卓通知构建直接抛错');
    final xml = icon.readAsStringSync();
    expect(xml.contains('#FFFFFFFF'), isTrue,
        reason: '通知小图标系统按 alpha 着色，必须是不透明单色白');
  });

  test('FGS 与引擎生命周期脱钩（划掉任务不留假在线僵尸通知）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final service = _nodeBlock(manifest, 'service');
    expect(service, isNotNull);
    expect(
      service!.contains('android:stopWithTask="true"'),
      isTrue,
      reason: '划掉最近任务后 Dart 引擎已销毁，服务必须随任务停止；'
          '否则常驻通知继续显示「已连接」=假在线',
    );
    final source = File(
      'android/app/src/main/kotlin/dev/zcodeapp/zcode_companion/'
      'ForegroundService.kt',
    ).readAsStringSync();
    expect(
      source.contains('override fun onTaskRemoved('),
      isTrue,
      reason: 'stopWithTask 的系统路径之外，onTaskRemoved 兜底摘通知',
    );
    expect(
      source.contains('START_STICKY'),
      isFalse,
      reason: '进程被杀后不得由系统盲目重启——空 intent 无法知道真实'
          '连接状态，只能显示假在线；由 Dart load() 按持久化开关补启',
    );
  });
}
