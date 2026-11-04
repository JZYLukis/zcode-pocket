import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/usage_charts.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

/// 18074 验收·用量页：环形图命中根因回归（constraints.biggest 在滚动列
/// 里高度无界=∞，中心/半径无穷化后角度退化恒 0——所有点按都命中第一
/// 片，用户实锤"只能点 glm5.3"）。锁：任意扇区点按、清单行点选（薄切片
/// 触控兜底）、环心总量、无界尺寸守卫。

class _ProbeChannel extends ChannelClient {
  _ProbeChannel() : super(sendBody: (_) {});

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'getAppUsageSnapshot':
        return {
          'summary': {'totalTokens': 100, 'activeDays': 2},
          'heatmap': <String, dynamic>{},
          'models': [
            {'modelId': 'glm5.3', 'totalTokens': 46},
            {'modelId': 'glm5.3-air', 'totalTokens': 46},
            {'modelId': 'k3.1-pro', 'totalTokens': 8},
          ],
          'dailyModelUsage': const <Map<String, dynamic>>[],
        };
      default:
        return <String, dynamic>{};
    }
  }
}

class _ProbeBridge implements BridgeSession {
  final _ProbeChannel channel = _ProbeChannel();
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-probe';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _ProbeApp extends AppState {
  @override
  final BridgeSession bridge = _ProbeBridge();
}

Future<void> _pumpUsage(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('companion/timezone'),
    (call) async => 'Asia/Shanghai',
  );
  await tester.pumpWidget(
    AppStateScope(
      app: _ProbeApp(),
      child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
    ),
  );
  await tester.tap(find.text('应用用量'));
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Rect _donutRect(WidgetTester tester) {
  final paint = find.descendant(
    of: find.ancestor(
      of: find.text('模型用量分布'),
      matching: find.byType(Container),
    ),
    matching: find.byType(CustomPaint),
  );
  return tester.getRect(paint);
}

Future<void> _tapAndSettle(WidgetTester tester, Offset p) async {
  await tester.tapAt(p);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('环形图：第二扇区点按命中（修复前所有点按都命中第一片）', (tester) async {
    await _pumpUsage(tester);
    final rect = _donutRect(tester);

    // 12 点方向（slice0=glm5.3）。
    await _tapAndSettle(tester, Offset(rect.center.dx, rect.top + 10));
    expect(find.textContaining('glm5.3 ·'), findsOneWidget);

    // 6 点方向（slice1=glm5.3-air）——修复前：角度退化恒 0 → 回弹成
    // 取消选择（明细回到提示文案）。
    await _tapAndSettle(tester, Offset(rect.center.dx, rect.bottom - 10));
    expect(
      find.textContaining('glm5.3-air ·'),
      findsOneWidget,
      reason: '下半环应命中第二片（修复前所有点按都命中第一片）',
    );

    // 9 点方向仍在 slice1 弧段（165.6°-331.2°）内。
    await _tapAndSettle(tester, Offset(rect.left + 10, rect.center.dy));
    expect(find.textContaining('glm5.3-air ·'), findsOneWidget);
  });

  testWidgets('环形图：清单行点选=薄切片触控兜底；环心总量在场', (tester) async {
    await _pumpUsage(tester);

    // 8% 的薄片直接点环带难命中——清单行可点选（桌面对位清单交互）。
    await _tapAndSettle(
      tester,
      tester.getCenter(
        find.byKey(const ValueKey('donut-legend-2-k3.1-pro')),
      ),
    );
    expect(find.textContaining('k3.1-pro ·'), findsOneWidget);

    // 环心总量（桌面同款中心两行）。
    expect(find.text('100'), findsWidgets);
    expect(find.text('tokens'), findsOneWidget);
  });

  test('donutHitIndex：无界尺寸守卫（滚动列 constraints.biggest 高度 ∞）', () {
    final series = [
      ChartSeries(name: 'a', color: const Color(0xFF0000FF), values: const [46]),
      ChartSeries(name: 'b', color: const Color(0xFF00FF00), values: const [46]),
    ];
    expect(
      donutHitIndex(
        const Offset(175, 75),
        const Size(350, double.infinity),
        series,
      ),
      isNull,
      reason: '修复前：无穷半径让带判定恒 false、角度退化恒 0 → 必返回第一片',
    );
    expect(donutHitIndex(const Offset(1, 1), Size.zero, series), isNull);
  });
}
