// 多账号 UI 覆盖（覆盖硬门配套）：账号管理页旅程
// （清单/当前标记/设为当前/删除守卫）、任务中心 device-not-owned 诊断+
// 换账号动作、档案卡多账号徽标、设备列表按账号拉取的错误态渲染。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/device_list_page.dart';
import 'package:zcode_pocket/ui/profiles_sheet.dart';
import 'package:zcode_pocket/ui/settings_accounts_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _MemStorage extends FlutterSecureStorage {
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
  }) async =>
      data[key];

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
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data.remove(key);
}

String _jwt(String sub) {
  String b64(Map m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({'sub': sub})}.${b64({'s': 1})}';
}

AccountV2Profile _v2(String sid, String accountId) => AccountV2Profile(
      deviceSid: sid,
      accountId: accountId,
      label: '桌面-$sid',
      addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

class _MultiAccountApp extends AppState {
  _MultiAccountApp(_MemStorage mem)
    : super(
        store: ProfileStore(storage: mem),
        accountStore: AccountStore(storage: mem),
      );

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  List<DeviceProfile> profiles = const [];

  Future<void> seed() async {
    await accountStore.save(jwt: _jwt('acc-a'), provider: 'bigmodel');
    await accountStore.save(jwt: _jwt('acc-b'), provider: 'zai');
    // multi-account-ux-1 批2：添加不再自动切当前——显式设为当前（复现
    // 「后登录的账号成为当前」的现实路径：用户在账号管理点「设为当前」）。
    await accountStore.setLastUsed('acc-b');
    final ps = store;
    await ps.upsertProfile(_v2('sid-a', 'acc-a'));
    await ps.upsertProfile(_v2('sid-b', 'acc-b'));
    profiles = await ps.listProfiles();
  }
}

class _DiagApp extends AppState {
  @override
  LinkPhase get phase => LinkPhase.error;

  @override
  List<DeviceProfile> profiles = const [];
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(child);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('账号管理页：清单/当前标记/设为当前/删除守卫', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _MultiAccountApp(_MemStorage());
    await app.seed();
    await _pump(
      tester,
      AppStateScope(
        app: app,
        child: const MaterialApp(home: SettingsAccountsPage()),
      ),
    );

    // 两个账号各一行；acc-b（后保存）=当前。
    expect(find.byKey(const ValueKey('account-acc-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('account-acc-b')), findsOneWidget);
    // multi-account-ux-1 批1：副标题改为「当前账号 [· N 台电脑][· 连接中]」
    // ——内部 id 不再直出（短标签/备注名才是用户可读标识）。
    expect(find.text('当前账号 · 1 台电脑'), findsOneWidget,
        reason: '当前账号行显示名下电脑数（批1 关联可见性）');
    // 非当前账号有「设为当前」。
    expect(find.byKey(const ValueKey('account-use-acc-a')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-use-acc-a')));
    await tester.pump(const Duration(milliseconds: 200));
    // lastUsed 已持久翻转（存储层直证——重进页面显示随动）。
    expect(await app.accountStore.lastUsedAccountId, 'acc-a');

    // 删除守卫：绑定电脑数提示出现在确认框（2026-11-05 反馈③：
    // 重命名/删除收进 ⋮ 菜单——先开行尾菜单再点删除）。
    await tester.tap(find.byKey(const ValueKey('account-menu-acc-a')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('删除账号'), findsOneWidget, reason: '行尾菜单已展开');
    await tester.tap(find.text('删除账号').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.textContaining('台电脑档案'), findsOneWidget,
        reason: '删除账号须提示其名下电脑档案后果');
    expect(find.byKey(const ValueKey('account-remove-ok')), findsOneWidget);
  });

  // 2026-11-05 反馈③：真机（大字号）非当前账号行被「设为当前」+双图标
  // 挤到标题断词（bigm/odel）、副标题不可读。重构后文本列 Expanded 恒定
  // 占宽——1.3× 字号下标题仍单行、整页无溢出异常。
  testWidgets('账号行 1.3× 字号：非当前账号标题不断词不溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _MultiAccountApp(_MemStorage());
    await app.seed();
    await _pump(
      tester,
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: AppStateScope(
          app: app,
          child: const MaterialApp(home: SettingsAccountsPage()),
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: '整页无布局异常');
    final title = find.descendant(
      of: find.byKey(const ValueKey('account-acc-a')),
      matching: find.text('bigmodel'),
    );
    expect(title, findsOneWidget, reason: '账号标题按 provider 回退渲染');
    final rp = tester.renderObject<RenderParagraph>(title);
    // 单行判定：1.3×（14×1.3≈18.2px）单行高度远低于 30；断词两行则 ~48。
    expect(
      rp.size.height,
      lessThan(30),
      reason: '标题单行完整（不再 bigm/odel 断词）',
    );
    expect(find.text('设为当前'), findsOneWidget, reason: '紧凑 chip 在场');
  });

  testWidgets('任务中心：device-not-owned 诊断带「换账号重连」动作',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _DiagApp();
    app.updateRelayFailure('device-not-owned', null);
    await _pump(
      tester,
      AppStateScope(
        app: app,
        child: const MaterialApp(home: TaskCenterPage()),
      ),
    );
    expect(find.text('这台电脑属于另一个账号'), findsOneWidget,
        reason: '专属诊断文案（多账号批）');
    expect(
      find.byKey(const ValueKey('switch-account-retry')),
      findsOneWidget,
      reason: '死路改引导：换账号动作在场',
    );
  });

  testWidgets('档案卡：多账号时显示所属账号徽标', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _MultiAccountApp(_MemStorage());
    await app.seed();
    await _pump(
      tester,
      AppStateScope(
        app: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open'),
                onPressed: () => showProfilesSheet(context),
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 两台电脑各自带账号徽标（短标签=provider 前 2+id 前 4）。
    expect(find.text('bi·acc-'), findsOneWidget, reason: 'acc-a 徽标');
    expect(find.text('za·acc-'), findsOneWidget, reason: 'acc-b 徽标');
    expect(find.text('桌面-sid-a'), findsOneWidget);
    expect(find.text('桌面-sid-b'), findsOneWidget);
  });

  testWidgets('设备列表：指定账号拉取，不可达中继出错误态（不崩）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _MultiAccountApp(_MemStorage());
    await app.seed();
    final prev = relayV2EndpointOverride;
    relayV2EndpointOverride = 'http://127.0.0.1:1';
    try {
      await _pump(
        tester,
        AppStateScope(
          app: app,
          child: const MaterialApp(home: DeviceListPage(accountId: 'acc-b')),
        ),
      );
      expect(find.textContaining('加载失败，请重试'), findsOneWidget,
          reason: '按账号拉取的失败态可读呈现（accountId=acc-b 路径；优化批 #3 人话映射）');
      expect(tester.takeException(), isNull);
    } finally {
      relayV2EndpointOverride = prev;
    }
  });
}
