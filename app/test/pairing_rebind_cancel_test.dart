// 配对页安全与取消语义回归：
// ①改绑确认取消不得被调用方当成功 pop/recreate（两页同一根因）；
// ②V1 链接非官方域必须显式确认，官方域直连；
// ③配对目标账号按显式 accountId 传递，不落 lastUsed。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/device_stack_registry.dart'
    show AccountRebindRequired;
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/relay_v2.dart' show RelayV2Device;
import 'package:zcode_pocket/ui/device_list_page.dart';
import 'package:zcode_pocket/ui/pairing_page.dart';

/// 真 AccountStore 在 widget 测试里 secure-storage 读永不完成（串行
/// 队列首读悬挂）——注入只读假 store。
class _FakeAccountStore extends AccountStore {
  @override
  Future<List<StoredAccount>> listAccounts() async => [
        const StoredAccount(id: 'acc-a', provider: 'zai', label: '账号甲'),
        const StoredAccount(id: 'acc-b', provider: 'zai', label: '账号乙'),
      ];

  @override
  Future<String?> get lastUsedAccountId async => 'acc-a';

  @override
  Future<String?> get mostRecentAccountId async => 'acc-b';

  @override
  Future<bool> get hasAccount async => true;
}

class _FakeApp extends AppState {
  _FakeApp({this.hasAccountValue = true})
      : super(accountStore: _FakeAccountStore());

  final bool hasAccountValue;

  int addComputerCalls = 0;
  String? lastComputerUrl;
  final List<Map<String, Object?>> profileCalls = [];

  /// 首次 addV2Profile 抛改绑要求（模拟该电脑已绑定另一账号）。
  bool throwRebindOnce = false;

  @override
  Future<bool> get hasAccount async => hasAccountValue;

  @override
  Future<void> addComputer(String rawUrl, {String? label}) async {
    addComputerCalls++;
    lastComputerUrl = rawUrl;
  }

  @override
  Future<void> addV2Profile(
    CompanionV2Params params, {
    String? label,
    String? accountId,
    bool forceRebind = false,
  }) async {
    profileCalls.add({
      'accountId': accountId,
      'forceRebind': forceRebind,
    });
    if (throwRebindOnce && !forceRebind) {
      throw const AccountRebindRequired(
        deviceSid: 'dev-1',
        deviceLabel: '桌面',
        fromAccountId: 'acc-a',
        toAccountId: 'acc-b',
      );
    }
  }
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  AppState app,
  Widget page,
) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-pairing'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => page),
                ),
                child: const Text('打开配对页'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-pairing')));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _enterUrl(WidgetTester tester, String url) async {
  await tester.enterText(find.byType(TextField).first, url);
  await tester.pump();
}

Future<void> _tapConnect(WidgetTester tester) async {
  await tester.tap(find.text('连接'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _v2Url = 'https://zcode.z.ai/remote/v4?sid=dev-1&mid=mid-1&name=桌面';
const _v1AppleUrl =
    'https://zcode.z.ai/remote/v4?sid=s1&hash=h1&t=1700000000';
const _v1EvilUrl =
    'https://evil.example.com/remote/v4?sid=s1&hash=h1&t=1700000000';

void main() {
  testWidgets('V2 改绑确认取消：不 pop 配对页、不 forceRebind', (tester) async {
    final app = _FakeApp()..throwRebindOnce = true;
    await _pumpLauncher(tester, app, const PairingPage());
    await _enterUrl(tester, _v2Url);
    await _tapConnect(tester);

    expect(find.text('改绑这台电脑的账号？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(PairingPage), findsOneWidget,
        reason: '修复前：取消被当成功，配对页被 pop 掉');
    expect(app.profileCalls.length, 1);
    expect(app.profileCalls.single['forceRebind'], isFalse);
    expect(find.text('连接'), findsOneWidget, reason: '连接态已复位可重试');

    // 再次连接并确认改绑 → 成功添加后正常 pop。
    await _tapConnect(tester);
    expect(find.text('改绑这台电脑的账号？'), findsOneWidget);
    await tester.tap(find.text('改绑'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 第二次连接同样先抛改绑要求（设备仍绑定旧账号）→ 确认后第三次
    // forceRebind 调用成功——共 3 次。
    expect(app.profileCalls.length, 3);
    expect(app.profileCalls.last['forceRebind'], isTrue);
    expect(find.byType(PairingPage), findsNothing);
  });

  testWidgets('显式 accountId：配对目标账号直传，不依赖登录/lastUsed', (tester) async {
    final app = _FakeApp(hasAccountValue: false);
    await _pumpLauncher(tester, app, const PairingPage(accountId: 'acc-b'));
    await _enterUrl(tester, _v2Url);
    await _tapConnect(tester);

    expect(find.byType(PairingPage), findsNothing,
        reason: '已有显式目标账号时不应再弹登录（hasAccount=false 也不拦）');
    expect(app.profileCalls.length, 1);
    expect(app.profileCalls.single['accountId'], 'acc-b',
        reason: '修复前：DeviceListPage/addV2Profile 一律 lastUsed，'
            '想给账号 B 配电脑会绑到 A');
  });

  testWidgets('设备列表改绑确认取消：页不关、列表保留', (tester) async {
    final app = _FakeApp()..throwRebindOnce = true;
    await _pumpLauncher(
      tester,
      app,
      const DeviceListPage(
        accountId: 'acc-a',
        debugDevices: [
          RelayV2Device(
            deviceSid: 'dev-1',
            deviceMid: 'mid-1',
            online: true,
            meta: {'name': '桌面'},
          ),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('device-card-dev-1')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('改绑这台电脑的账号？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DeviceListPage), findsOneWidget,
        reason: '修复前：取消被当成功，设备列表被 pop 关掉');
    expect(find.byKey(const ValueKey('device-card-dev-1')), findsOneWidget);
    expect(app.profileCalls.single['forceRebind'], isFalse);
  });

  testWidgets('V1 官方域直连：不弹确认，直接建档案', (tester) async {
    final app = _FakeApp();
    await _pumpLauncher(tester, app, const PairingPage());
    await _enterUrl(tester, _v1AppleUrl);
    await _tapConnect(tester);

    expect(find.text('连接非官方服务器？'), findsNothing);
    expect(app.addComputerCalls, 1);
    expect(app.lastComputerUrl, _v1AppleUrl);
    expect(find.byType(PairingPage), findsNothing);
  });

  testWidgets('V1 非官方域：默认拦下，确认后才连接', (tester) async {
    final app = _FakeApp();
    await _pumpLauncher(tester, app, const PairingPage());
    await _enterUrl(tester, _v1EvilUrl);
    await _tapConnect(tester);

    expect(find.text('连接非官方服务器？'), findsOneWidget);
    // URL 输入框本身也含主机名 → 对话框+输入框两处命中。
    expect(find.textContaining('evil.example.com'), findsWidgets,
        reason: '确认框须显示真实目标主机');
    await tester.tap(find.text('取消'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.addComputerCalls, 0, reason: '取消即止，不得建立连接');
    expect(find.byType(PairingPage), findsOneWidget);

    await _tapConnect(tester);
    await tester.tap(find.text('继续连接'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.addComputerCalls, 1, reason: '用户显式确认后放行');
    expect(app.lastComputerUrl, _v1EvilUrl);
  });
}
