// issue #13（首份外部用户报告）：纯 Start Plan 账号用量页死锁——
// 默认档硬编码 individual-coding-plan 且查询失败整页吞掉档位切换入口。
// 修复三处：初始档从活跃会话推导（inferEntPlanKind 同源）+错误态保留
// 切换行（切档即按新档重查）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/companion_client.dart' show BridgeSession;
import 'package:zcode_pocket/ui/conversation_page.dart' show inferEntPlanKind;
import 'package:zcode_pocket/ui/usage_page.dart';

class _StartPlanApp extends AppState {
  @override
  bool get loaded => true;
  // bridge=null → _loadPlan 走"未连接电脑"快速错误路径（真实 AppState 的
  // bridge 非 null 会挂到 12s 超时）。
  @override
  BridgeSession? get bridge => null;
}

void main() {
  test('首载推导映射：provider 含 start-plan → start-plan 档（inferEntPlanKind）', () {
    // issue #13 修复的数据源：_deriveFamily 首载 seed 用同一映射。
    expect(
      inferEntPlanKind(allProviders: ['bigmodel-start-plan']),
      'start-plan',
      reason: '纯 Start Plan 账号活跃会话应推导出 start-plan 档',
    );
    expect(inferEntPlanKind(allProviders: ['bigmodel-individual']), 'individual-coding-plan');
    expect(inferEntPlanKind(allProviders: []), 'individual-coding-plan',
        reason: '无会话回默认档');
    expect(inferEntPlanKind(currentProvider: 'zai-start-plan'), 'start-plan');
  });

  testWidgets('错误态保留档位切换行（切换入口不再被吞）', (tester) async {
    // 测试环境未 mock 的 MethodChannel 其 Future 永不完成——
    // readDeviceTimeZone 挂住则 _loadPlan 永不执行（loading 恒转圈）。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'), null));
    final app = _StartPlanApp();
    app.uiPrefs.debugMarkLoadedForTest();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(home: UsagePage()),
      ),
    );
    // 无 entitlement 数据（假 app）→ 查询失败 → 错误态。
    await tester.pump(const Duration(seconds: 1));
    // 等待 12s 页面级超时跳过——直接 pump 到错误出现（假 app 立即失败）。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      if (find.byKey(const ValueKey('plan-kind-error-start-plan')).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(const ValueKey('plan-kind-error-start-plan')),
      findsOneWidget,
      reason: '错误态必须有 Start Plan 切换 chip（issue #13 死锁根因）',
    );
    expect(find.byKey(const ValueKey('plan-kind-error-individual-coding-plan')),
        findsOneWidget);
    // 切到 Start Plan：按新档发起查询（错误态可自愈）。
    await tester.tap(find.byKey(const ValueKey('plan-kind-error-start-plan')));
    await tester.pump(const Duration(milliseconds: 200));
  });
}
