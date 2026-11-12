// /②：Dart 侧 invokeMethod 的方法名必须与原生 when 分支
// 一一对应——通道名/方法名错配在运行时表现为 MissingPluginException 被
// catch 吞掉（应用内更新"永远已是最新"事故）。本测试静态解析两侧源码
// 做契约断言（android_manifest_guard 同族静态守卫先例）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String updateFlow;
  late final String mainActivity;

  setUpAll(() {
    updateFlow = File('lib/ui/update_flow.dart').readAsStringSync();
    mainActivity = File(
      'android/app/src/main/kotlin/dev/zcodeapp/zcode_companion/MainActivity.kt',
    ).readAsStringSync();
  });

  test('update_flow 对 companion/update 的每个 _invoke 都有原生分支', () {
    // 抓 _invoke<...>('name') 形态。
    final invoked = RegExp(r"_invoke<[^>]*>\('(\w+)'")
        .allMatches(updateFlow)
        .map((m) => m.group(1)!)
        .toSet();
    expect(invoked, isNotEmpty, reason: '解析失败会让本守卫失效');

    // Kotlin companion/update 的 when 分支名。
    final updateBlock = _channelBlock(mainActivity, 'companion/update');
    expect(updateBlock, isNotNull, reason: 'companion/update 通道缺失');
    final nativeMethods = RegExp(r'"(\w+)"\s*->')
        .allMatches(updateBlock!)
        .map((m) => m.group(1)!)
        .toSet();

    final missing = invoked.difference(nativeMethods);
    expect(
      missing,
      isEmpty,
      reason: 'Dart 调用 ${missing.toList()} 在原生 companion/update 无分支'
          '——运行时 MissingPluginException 被吞（H1 同族事故）',
    );
  });

  test('update_flow 的版本号读取走 companion/appinfo（不再错调 update 通道）', () {
    expect(
      updateFlow.contains("invokeMethod<Map<dynamic, dynamic>>('get')"),
      isTrue,
      reason: '版本号必须走 appinfo.get（修复点）',
    );
    expect(
      updateFlow.contains("'appVersion'"),
      isFalse,
      reason: 'companion/update 无 appVersion 方法——不得回退错误调用',
    );
  });

  test('app_lock/system_inset 的通道调用也有原生分支', () {
    final lockSrc = File('lib/core/app_lock.dart').readAsStringSync();
    final insetSrc = File('lib/core/system_inset.dart').readAsStringSync();
    final notifyBlock = _channelBlock(mainActivity, 'companion/notify');
    expect(notifyBlock, isNotNull);

    // app_lock.dart: companion/app_lock 的 requestSystemUnlock/setSecureFlag。
    final lockInvoked =
        RegExp(r"invokeMethod<\w+>\('(\w+)'\)").allMatches(lockSrc).map((m) => m.group(1)!);
    // app_lock 通道在 AppLockPlugin.kt。
    final pluginSrc = File(
      'android/app/src/main/kotlin/dev/zcodeapp/zcode_companion/AppLockPlugin.kt',
    ).readAsStringSync();
    final pluginMethods =
        RegExp(r'"(\w+)"\s*->').allMatches(pluginSrc).map((m) => m.group(1)!).toSet();
    for (final m in lockInvoked) {
      if (m == 'systemInsetChanged') continue; // 反向推送（原生→Dart）。
      expect(
        pluginMethods.contains(m),
        isTrue,
        reason: 'app_lock 调用 $m 在 AppLockPlugin 无分支',
      );
    }

    // system_inset: currentSystemInset/systemInsetChanged 在 notify 块。
    for (final m in ['currentSystemInset']) {
      expect(
        notifyBlock!.contains('"$m"'),
        isTrue,
        reason: 'system_inset 调用 $m 在 companion/notify 无分支',
      );
    }
    expect(insetSrc.contains('refreshSystemInset'), isTrue);
  });
}

String? _channelBlock(String source, String channelName) {
  // 取最后一次出现（通道名可能先出现在局部变量/listener 处，handler 注册在后）。
  final i = source.lastIndexOf('"$channelName"');
  if (i < 0) return null;
  // 取通道注册点到下一个 MethodChannel 注册或 3000 字符。
  final tail = source.substring(i);
  final next = tail.indexOf('MethodChannel(', 10);
  return next > 0 ? tail.substring(0, next) : tail.substring(0, 3000);
}
