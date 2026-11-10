// 深色模式批2-1：主题档位切换状态机（dark-mode-plan 批2：
// ui_prefs 读写/三档解析/重启保持 + 闸门「切换/重启路径日志断言」的
// 测试侧等价——widget 断言即时生效）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';

class FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

void main() {
  test('三档解析：非法值回落 system，合法值透传', () async {
    final st = FakeSecureStorage();
    final p = UiPrefs(storage: st);
    expect(p.themeMode, 'system'); // 默认跟随系统（拍板③）
    await p.setThemeMode('dark');
    expect(p.themeMode, 'dark');
    await p.setThemeMode('light');
    expect(p.themeMode, 'light');
    await p.setThemeMode('nonsense');
    expect(p.themeMode, 'system', reason: '非法值回落 system');
  });

  test('落盘往返+重启保持（新实例 load 回读档位）', () async {
    final st = FakeSecureStorage();
    final p1 = UiPrefs(storage: st);
    await p1.setThemeMode('dark');
    expect(st.data['ui.themeMode'], 'dark');
    // 模拟重启：新实例同一存储。
    final p2 = UiPrefs(storage: st);
    await p2.load();
    expect(p2.themeMode, 'dark', reason: '重启保持');
    // 切回 system 也持久化。
    await p2.setThemeMode('system');
    final p3 = UiPrefs(storage: st);
    await p3.load();
    expect(p3.themeMode, 'system');
  });

  test('load 读到非法存量值按默认走（容错）', () async {
    final st = FakeSecureStorage();
    st.data['ui.themeMode'] = 'blue';
    final p = UiPrefs(storage: st);
    await p.load();
    expect(p.themeMode, 'system');
  });

  testWidgets('真根树：system 档系统亮度翻转→状态栏注解随帧更新（A-1 靶）',
      (tester) async {
    final app = AppState()..loaded = true;
    addTearDown(app.dispose);
    await tester.pumpWidget(ZcodeCompanionApp(app: app));
    Brightness iconOf() {
      final regions = find
          .byType(AnnotatedRegion<SystemUiOverlayStyle>)
          .evaluate()
          .toList();
      expect(regions, isNotEmpty);
      final w = regions.first.widget as AnnotatedRegion<SystemUiOverlayStyle>;
      return w.value.statusBarIconBrightness!;
    }

    // system（默认档）+系统浅 → 深色图标。
    expect(iconOf(), Brightness.dark);
    // 系统切深 → 注解必须翻转（原实现不刷新）。
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(iconOf(), Brightness.light, reason: '系统翻深后状态栏图标应变浅');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(iconOf(), Brightness.dark, reason: '系统回浅后状态栏图标应变深');
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });

  testWidgets('切换即时生效：notifyListeners 驱动 MaterialApp.themeMode 重建',
      (tester) async {
    // fake async 环境里真实 secure storage 的 future 永不落地（挂起超时），
    // 注入纯 Dart 假 storage（微任务可完成）。
    final prefs = UiPrefs(storage: FakeSecureStorage());
    ThemeMode? seenMode;
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: prefs,
        builder: (context, _) {
          seenMode = switch (prefs.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
          return MaterialApp(
            theme: buildAppTheme(),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: seenMode,
            home: const Scaffold(body: SizedBox()),
          );
        },
      ),
    );
    expect(seenMode, ThemeMode.system);
    await tester.pump();
    await prefs.setThemeMode('dark');
    await tester.pump();
    expect(seenMode, ThemeMode.dark, reason: '切深色即时生效');
    // 同屏深色套生效（scaffold 背景变 #161616）。
    await prefs.setThemeMode('light');
    await tester.pump();
    expect(seenMode, ThemeMode.light, reason: '切浅色即时生效');
  });
}