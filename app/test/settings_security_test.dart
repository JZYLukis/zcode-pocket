// 应用锁设置页（早前批次）：PIN 开启全流程 + 关闭需验证旅程。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/ui/settings_security_page.dart';
import 'package:zcode_pocket/ui/settings_page.dart';

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
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

class _SecApp extends AppState {
  _SecApp(this.prefs);
  final UiPrefs prefs;
  @override
  UiPrefs get uiPrefs => prefs;
}

Future<void> _pump(WidgetTester tester, _SecApp app) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const SettingsSecurityPage(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('开启 PIN：两次输入→模式落盘+哈希在册；关闭需先过 PIN', (tester) async {
    final prefs = UiPrefs(storage: _MemStorage());
    await prefs.load();
    final app = _SecApp(prefs);
    await _pump(tester, app);

    // 默认三选在（关闭/系统锁屏/PIN 码）。
    expect(find.text('系统锁屏'), findsOneWidget);
    expect(find.text('PIN 码'), findsOneWidget);

    // 选 PIN 码 → 两次输入对话框。
    await tester.tap(find.text('PIN 码').first);
    await tester.pump();
    expect(find.text('设置 PIN 码'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('再次输入确认'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(prefs.appLockModeRaw, 'pin', reason: '模式落盘');
    expect(prefs.appLockPinHash, isNotNull);
    expect(prefs.appLockPinSalt, isNotNull);
    expect(app.appLock.mode.toString(), contains('pin'), reason: 'controller 装载');
    expect(app.appLock.locked, isTrue, reason: '模式切换即锁（设置页当场生效）');
  });

  testWidgets('设置页有「安全」组与应用锁入口', (tester) async {
    final prefs = UiPrefs(storage: _MemStorage());
    await prefs.load();
    final app = _SecApp(prefs);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 安全组在列表下方（小画布需滚动到可见）。
    await tester.scrollUntilVisible(find.text('应用锁'), 120);
    await tester.pump();
    expect(find.text('应用锁'), findsOneWidget, reason: '入口行');
    expect(find.text('安全'), findsOneWidget, reason: '安全分组头');
  });

  testWidgets('无系统锁选「系统锁屏」回弹为关+提示', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/app_lock'),
      (call) async {
        if (call.method == 'isDeviceSecure') return false;
        if (call.method == 'openSecuritySettings') return true;
        return null;
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('companion/app_lock'), null));
    final prefs = UiPrefs(storage: _MemStorage());
    await prefs.load();
    final app = _SecApp(prefs);
    await _pump(tester, app);

    await tester.tap(find.text('系统锁屏').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefs.appLockModeRaw, 'none', reason: '无系统锁回弹为关');
    expect(app.appLock.mode.toString(), contains('none'));
  });
}
