// 平台能力矩阵 + UI 门控（ios-adaptation-1 平台缝）：
// - Android（测试默认平台）五项能力全 true——本批红线「Android 零视觉
//   变化」的机器钉子；
// - iOS（debugDefaultTargetPlatformOverride 模拟）结构性三项为 false，
//   消费点按 capability 隐藏/换文案，不出现假功能开关。
//
// 测试坑：①覆写必须在测试体内复位（框架不变量检查早于 tearDown——
// 残留覆写会把真实失败掩盖成 debug 变量断言）；②设置页长列表懒构建，
// 目标行先 scrollUntilVisible 再断言（iOS 缺席断言用行下方锚点滚过
// 该区域后判 findsNothing，缺席才有意义）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/platform/capabilities.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/ui/settings_notifications_page.dart';
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

class _GatedApp extends AppState {
  _GatedApp(this.prefs);
  final UiPrefs prefs;
  @override
  UiPrefs get uiPrefs => prefs;
}

Future<void> _pump(
  WidgetTester tester,
  AppState app,
  Widget page,
) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: page),
    ),
  );
  await tester.pump();
}

/// 在指定平台覆写下执行用例体，结束前复位（框架不变量检查要求）。
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('能力矩阵', () {
    // 纯 test() 无框架不变量检查，覆写靠 tearDown 复位防泄漏到后续组。
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android（测试默认平台）五项能力全 true——零视觉变化红线', () {
      expect(ZpCapabilities.supportsSelfUpdate, isTrue);
      expect(ZpCapabilities.supportsBackgroundKeepAlive, isTrue);
      expect(ZpCapabilities.supportsOemPowerGuide, isTrue);
      expect(ZpCapabilities.supportsSystemCredentialUnlock, isTrue);
      expect(ZpCapabilities.supportsSecureFlag, isTrue);
    });

    test('iOS：结构性三项+未实现两项全 false（E/G 批落地前）', () {
      _onPlatformSync(TargetPlatform.iOS);
      // 结构性（永不翻转）。
      expect(ZpCapabilities.supportsSelfUpdate, isFalse);
      expect(ZpCapabilities.supportsOemPowerGuide, isFalse);
      expect(ZpCapabilities.supportsSecureFlag, isFalse);
      // 待实现（E/G 批翻 true，翻转时本断言同步改并留批次注记）。
      expect(ZpCapabilities.supportsBackgroundKeepAlive, isFalse);
      expect(ZpCapabilities.supportsSystemCredentialUnlock, isFalse);
    });
  });

  group('设置页更新入口门控（supportsSelfUpdate）', () {
    late AppState app;

    setUp(() async {
      final prefs = UiPrefs(storage: _MemStorage());
      await prefs.load();
      app = _GatedApp(prefs);
    });

    testWidgets('Android：软件更新/应用内更新两行在场（原样）', (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await _pump(tester, app, const SettingsPage());
        await tester.scrollUntilVisible(find.text('软件更新'), 200);
        expect(find.text('软件更新'), findsOneWidget);
        // 开关行在入口行下方，再滚一步进构建区。
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-update-in-app')),
          200,
        );
        expect(
          find.byKey(const ValueKey('settings-update-in-app')),
          findsOneWidget,
        );
      });
    });

    testWidgets('iOS：两行整体隐藏（结构性不可行项不留假开关）', (tester) async {
      await _onPlatform(TargetPlatform.iOS, () async {
        await _pump(tester, app, const SettingsPage());
        // 滚到更新行区域下方（应用锁在安全组，位于更新两行之后），
        // 证明该区域已构建后缺席才成立。
        await tester.scrollUntilVisible(find.text('应用锁'), 200);
        expect(find.text('软件更新'), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-update-in-app')),
          findsNothing,
        );
      });
    });
  });

  group('通知设置页门控（keepAlive/OEM 引导）', () {
    late AppState app;

    setUp(() async {
      final prefs = UiPrefs(storage: _MemStorage());
      await prefs.load();
      app = _GatedApp(prefs);
    });

    testWidgets('Android：保活文案+后台保障设置入口原样', (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await _pump(tester, app, const SettingsNotificationsPage());
        expect(find.textContaining('开启后后台保持连接'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('后台保障设置'), 200);
        expect(find.text('后台保障设置'), findsOneWidget);
      });
    });

    testWidgets('iOS：前台+对账文案；后台保障设置入口隐藏', (tester) async {
      await _onPlatform(TargetPlatform.iOS, () async {
        await _pump(tester, app, const SettingsNotificationsPage());
        expect(find.textContaining('回到 App 时自动补齐'), findsOneWidget);
        expect(find.textContaining('开启后后台保持连接'), findsNothing);
        // 滚到入口原位置下方（通知台账在其后），缺席断言过构建区。
        await tester.scrollUntilVisible(find.text('通知台账'), 200);
        expect(find.text('后台保障设置'), findsNothing);
      });
    });
  });
}

/// 纯 test()（非 testWidgets）的平台覆写：无框架不变量检查，复位靠
/// 组内 tearDown。
void _onPlatformSync(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
}
