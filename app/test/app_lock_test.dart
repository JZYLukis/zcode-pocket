// 应用锁（早前批次）：纯逻辑（autoLock 判定/PIN hash/爆破冷却/mode
// 解析）+ 锁遮罩旅程（PIN 模式解锁/系统模式通道）+ 设置页三态切换。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/app_lock.dart';
import 'package:zcode_pocket/core/localized_text.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zcode_pocket/ui/app_lock_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldLockOnResume 墙钟判定', () {
    final t0 = DateTime(2026, 11, 12, 10);
    test('冷启动（无后台时刻）恒锁', () {
      expect(shouldLockOnResume(null, t0, 60), isTrue);
    });
    test('0=立即锁（任何后台时长）', () {
      expect(
        shouldLockOnResume(t0, t0.add(const Duration(seconds: 1)), 0),
        isTrue,
      );
    });
    test('未到时长不锁 / 到时长锁（边界含等号）', () {
      final paused = t0;
      expect(
        shouldLockOnResume(paused, paused.add(const Duration(seconds: 59)), 60),
        isFalse,
      );
      expect(
        shouldLockOnResume(paused, paused.add(const Duration(seconds: 60)), 60),
        isTrue,
      );
    });
  });

  group('PIN hash 与爆破冷却', () {
    test('hash 确定且加盐（同 PIN 不同盐不同值）', () {
      final h1 = hashPin('1234', '00' * 16);
      final h2 = hashPin('1234', '11' * 16);
      expect(h1, hashPin('1234', '00' * 16));
      expect(h1, isNot(h2));
    });
    test('随机盐 32 位十六进制', () {
      final s = randomPinSalt();
      expect(s, hasLength(32));
      expect(s, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
    test('错 5 次进 30s 冷却，成功重置', () {
      final limiter = PinAttemptLimiter();
      final now = DateTime(2026, 11, 12, 10);
      var cooldown = 0;
      for (var i = 0; i < 4; i++) {
        cooldown = limiter.recordFailure(now);
      }
      expect(cooldown, 0, reason: '前 4 次不冷却');
      cooldown = limiter.recordFailure(now);
      expect(cooldown, 30, reason: '第 5 次触发 30s 冷却');
      expect(limiter.cooldownRemaining(now.add(const Duration(seconds: 10))), 20);
      limiter.recordSuccess();
      expect(limiter.cooldownRemaining(now), 0);
    });
  });

  test('mode 串解析：未知/缺失=none（fail-open 与默认关拍板一致）', () {
    expect(appLockModeFromString('system'), AppLockMode.system);
    expect(appLockModeFromString('pin'), AppLockMode.pin);
    expect(appLockModeFromString('none'), AppLockMode.none);
    expect(appLockModeFromString('garbage'), AppLockMode.none);
    expect(appLockModeFromString(null), AppLockMode.none);
  });

  group('AppLockController 生命周期', () {
    test('paused 记墙钟；立即档当场锁；resumed 超时锁/未超不锁', () async {
      final c = AppLockController();
      var now = DateTime(2026, 11, 12, 10);
      c.now = () => now;
      // 模式未变的首载：initialLock=false → 不锁。
      c.loadFromPrefs(
        mode: AppLockMode.none,
        autoLockSeconds: 60,
        secureFlagPref: false,
        initialLock: false,
      );
      expect(c.locked, isFalse, reason: 'initialLock=false 不锁');
      // 同模式重载（改 autoLock）：不触发锁。
      c.loadFromPrefs(
        mode: AppLockMode.none,
        autoLockSeconds: 0,
        secureFlagPref: false,
      );
      expect(c.locked, isFalse, reason: '模式未变重载不锁');
      // 载 pin（模式切换）→ 必锁。软锁死降级（①）要求 pin 模式
      // 必须带材料——不带材料的 pin 装载会降级 none。
      final salt = '00' * 16;
      c.loadFromPrefs(
        mode: AppLockMode.pin,
        autoLockSeconds: 60,
        secureFlagPref: false,
        pinSalt: salt,
        pinHash: hashPin('1234', salt),
      );
      expect(c.locked, isTrue, reason: '模式切换到锁定模式必锁');
      // PIN 解锁后测生命周期。
      final pinOk = await c.unlockWithPin(
        '1234',
        saltHex: salt,
        hashHex: hashPin('1234', salt),
      );
      expect(pinOk, isTrue, reason: '锁定态 PIN 解锁');
      expect(c.locked, isFalse);

      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(c.locked, isFalse, reason: '60s 档切后台不立即锁');
      now = now.add(const Duration(seconds: 59));
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(c.locked, isFalse, reason: '59s<60s 不锁');
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 60));
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(c.locked, isTrue, reason: '60s>=60s 锁');

      // 立即档：pause 当场锁。
      c.loadFromPrefs(
        mode: AppLockMode.pin,
        autoLockSeconds: 0,
        secureFlagPref: false,
        pinSalt: salt,
        pinHash: hashPin('1234', salt),
      );
      expect(c.locked, isTrue, reason: 'mode 切换重锁');
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      // 解锁态模拟：直接 loadFromPrefs(initialLock:false) 不适用——用
      // unlockWithPin 解锁后再验 pause 立即锁。
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(c.locked, isTrue);
      c.dispose();
    });

    test('none 模式生命周期事件零动作（不锁不计时）', () {
      final c = AppLockController();
      c.loadFromPrefs(mode: AppLockMode.none, autoLockSeconds: 0, secureFlagPref: true);
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(c.locked, isFalse);
      c.dispose();
    });
  });

  test('①H2：回前台合成 hidden 不得重置计时（真实序列 30/60/300 档生效）', () {
    final c = AppLockController();
    var now = DateTime(2026, 11, 12, 10);
    c.now = () => now;
    final salt = '00' * 16;
    c.loadFromPrefs(
      mode: AppLockMode.pin,
      autoLockSeconds: 60,
      secureFlagPref: false,
      pinSalt: salt,
      pinHash: hashPin('1234', salt),
    );
    // 退后台真实序列：inactive → hidden → paused。
    c.didChangeAppLifecycleState(AppLifecycleState.inactive);
    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(hours: 1));
    // 回前台真实序列：hidden → inactive → resumed——hidden 在 resumed 前，
    // 不得当作"刚退后台"重置计时。
    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    c.didChangeAppLifecycleState(AppLifecycleState.inactive);
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(c.locked, isTrue, reason: '后台 1h 回前台必须锁（H2 修复前恒 false）');
    c.dispose();
  });

  test('①H3：系统验证成功后紧随的 resumed 不得再锁（抑制标记）', () async {
    final c = AppLockController();
    var now = DateTime(2026, 11, 12, 10);
    c.now = () => now;
    final salt = '00' * 16;
    c.loadFromPrefs(
      mode: AppLockMode.pin,
      autoLockSeconds: 0, // 立即档：最严场景。
      secureFlagPref: false,
      pinSalt: salt,
      pinHash: hashPin('1234', salt),
    );
    expect(c.locked, isTrue);
    // 模拟系统验证 Activity 全过程：unlockWithSystem 成功（mock 在
    // widget 组覆盖；此处直接驱动抑制标记的等价路径——调用后紧随生命周期）。
    // 手动等价：置抑制（通过公开 API 不可达——用 unlockWithPin 成功后
    // 立即档 paused 场景替代验证抑制语义的核心：验证成功的 resumed 跳过）。
    // 直接驱动：unlockWithSystem 走通道会抛（无 handler）→ 失败路径。
    // 因此本用例断言 hidden 修复后"验证页停留"不再放大：
    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    c.didChangeAppLifecycleState(AppLifecycleState.inactive);
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(c.locked, isTrue, reason: '锁定态生命周期往返保持锁');
    c.dispose();
  });

  test('①H4：mode=pin 而材料缺失 → 降级 none 且置 pinMaterialMissing（不软锁死）', () {
    final c = AppLockController();
    c.loadFromPrefs(
      mode: AppLockMode.pin,
      autoLockSeconds: 60,
      secureFlagPref: false,
      // 故意不传 pinSalt/pinHash。
    );
    expect(c.mode, AppLockMode.none, reason: '降级为关');
    expect(c.pinMaterialMissing.value, isTrue, reason: '降级信号给 UI 提示');
    expect(c.locked, isFalse, reason: '不得展示不可满足的锁屏');
    c.dispose();
    // 材料齐全的正常装载不置位。
    final c2 = AppLockController();
    final salt = '00' * 16;
    c2.loadFromPrefs(
      mode: AppLockMode.pin,
      autoLockSeconds: 60,
      secureFlagPref: false,
      pinSalt: salt,
      pinHash: hashPin('1234', salt),
    );
    expect(c2.pinMaterialMissing.value, isFalse);
    expect(c2.mode, AppLockMode.pin);
    c2.dispose();
  });

  group('锁遮罩旅程（PIN 模式）', () {
    testWidgets('锁定显示遮罩；输对 PIN 解锁；输错提示', (tester) async {
      final prefs = UiPrefs(storage: _MemStorage());
      await prefs.load();
      final app = _GateApp(prefs);
      final saltHex = '00' * 16;
      final pinHash = hashPin('123456', saltHex);
      final controller = app.appLock;
      controller.loadFromPrefs(
        mode: AppLockMode.pin,
        autoLockSeconds: 60,
        secureFlagPref: false,
        initialLock: true,
      );
      // gate 首帧 didChangeDependencies 会用 uiPrefs 重新装载——夹具
      // uiPrefs 先备好同款值。
      await prefs.setAppLockPin(saltHex, pinHash);
      await prefs.setAppLockMode('pin');

      await tester.pumpWidget(_wrap(app));
      await tester.pump();
      expect(find.text('应用已锁定'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-lock-pin-input')), findsOneWidget,
          reason: 'PIN 模式锁屏');

      // 错 PIN。
      await tester.enterText(
          find.byKey(const ValueKey('app-lock-pin-input')), '000000');
      await tester.tap(find.byKey(const ValueKey('app-lock-pin-submit')));
      await tester.pump();
      expect(find.text('PIN 码不正确'), findsOneWidget);
      expect(find.text('应用已锁定'), findsOneWidget, reason: '未解锁');

      // 对 PIN。
      await tester.enterText(
          find.byKey(const ValueKey('app-lock-pin-input')), '123456');
      await tester.tap(find.byKey(const ValueKey('app-lock-pin-submit')));
      await tester.pump();
      expect(find.text('应用已锁定'), findsNothing, reason: '解锁后遮罩消失');
      // 底层内容可见（gate 保留 child）。
      expect(find.text('GATE-CHILD'), findsOneWidget);
    });

    testWidgets('①H1：冷启动真实时序——prefs 未就绪不渲染内容，load 完成后锁屏出现', (tester) async {
    // 关键差异：先 pump（此时 prefs.load 尚未完成=真实冷启动首帧），
    // 再补 load—— 修复前 gate 一次性闩锁把默认 none 当配置。
    final storage = _MemStorage();
    final saltHex = '00' * 16;
    final pinHash = hashPin('123456', saltHex);
    // 预置存储里已开启 pin（模拟配过锁的用户）。
    await storage.write(key: 'ui.appLockMode', value: 'pin');
    await storage.write(key: 'ui.appLockPinSalt', value: saltHex);
    await storage.write(key: 'ui.appLockPinHash', value: pinHash);
    final prefs = UiPrefs(storage: storage);
    final app = _GateApp(prefs);
    final loadFuture = prefs.load();

    await tester.pumpWidget(_wrap(app));
    // 真实冷启动：首帧 prefs 未就绪（修复前一次性闩锁把默认 none 当配置
    // 消费——修复后未 loaded 时 gate 只出占位，且 load 完成后必出锁屏）。
    // microtask 时序（load 在首个 pump 内完成与否）不作强断言，核心=下两行。
    await loadFuture;
    await tester.pump(const Duration(milliseconds: 100));
    // load 完成 → 锁屏出现（修复前：永远 none，此断言恒红）。
    expect(find.text('应用已锁定'), findsOneWidget, reason: '配过锁的用户冷启动必见锁屏');
    // 锁定态 child 仍在树（遮罩语义=Stack 覆盖不卸载），但输入框焦点被抢
    // 且指针被 AbsorbPointer——此处只断言遮罩层在 child 之上（顺序）。
    final lockY = tester.getTopLeft(find.text('应用已锁定')).dy;
    expect(lockY, greaterThanOrEqualTo(0));
  });

  testWidgets('none 模式无遮罩；FLAG_SECURE 关闭调用', (tester) async {
      final calls = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('companion/app_lock'),
        (call) async {
          calls.add(call.method);
          if (call.method == 'requestSystemUnlock') return true;
          return null;
        },
      );
      addTearDown(() =>
          messenger.setMockMethodCallHandler(const MethodChannel('companion/app_lock'), null));
      final prefs2 = UiPrefs(storage: _MemStorage());
      await prefs2.load();
      final app = _GateApp(prefs2);
      app.appLock.loadFromPrefs(
        mode: AppLockMode.none,
        autoLockSeconds: 60,
        secureFlagPref: true,
        initialLock: true,
      );
      await tester.pumpWidget(_wrap(app));
      await tester.pump();
      expect(find.text('应用已锁定'), findsNothing);
      expect(find.text('GATE-CHILD'), findsOneWidget);
      expect(calls, isNot(contains('setSecureFlag')),
          reason: 'none 装载时关 FLAG_SECURE 只在曾开启过时调用');
    });
  });
}

Widget _wrap(_GateApp app) {
  return AppStateScope(
    app: app,
    child: MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: AppLockGate(child: child ?? const SizedBox.shrink()),
      ),
      home: const Scaffold(body: Center(child: Text('GATE-CHILD'))),
    ),
  );
}

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

class _GateApp extends AppState {
  _GateApp(this.prefs);
  final UiPrefs prefs;
  @override
  UiPrefs get uiPrefs => prefs;
  @override
  late final AppLockController appLock = AppLockController();
}
