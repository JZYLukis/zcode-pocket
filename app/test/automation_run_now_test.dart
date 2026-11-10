import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/automation_page.dart';

//（O2 P2-4/O3 P1-1）：automation「立即运行」是本页唯一
/// 未包 `_runActions` 错误处理的写操作——runNow 是 15s 超时的通道 RPC，
/// 断网/超时异常逃逸成未处理异步错误且零反馈。锁：失败=SnackBar 人话
/// +无异常逃逸；成功=按 status 分档提示+列表刷新（成功路径不被收窄）。

class _RunNowChannel extends ChannelClient {
  _RunNowChannel({this.runNowError}) : super(sendBody: (_) {});

  final Object? runNowError;
  int listCalls = 0;
  int runNowCalls = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'listAllAutomations':
        listCalls++;
        return [
          {
            'automationId': 'a1',
            'title': '巡检',
            'enabled': true,
            'lifecycleStatus': 'active',
            'workspacePath': 'G:/Demo App',
            'workspaceIdentity': 'ws1',
          },
        ];
      case 'runAutomationNow':
        runNowCalls++;
        if (runNowError != null) throw runNowError!;
        return {'status': 'queued'};
    }
    return null;
  }
}

class _AutomationBridge implements BridgeSession {
  _AutomationBridge(this.channel);

  final _RunNowChannel channel;

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
  String? get workspaceKey => 'ws1';
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

class _AutoApp extends AppState {
  _AutoApp(this.channel);

  final _RunNowChannel channel;

  @override
  BridgeSession? get bridge => _AutomationBridge(channel);
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': 'G:/Demo App',
    'workspaceIdentity': 'ws1',
  };
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const AutomationPage(),
  ),
);

/// 列表加载 → ⋮ 菜单 → 立即运行；固定推进（不 pumpAndSettle——会把
/// SnackBar 寿命推完消失，同 move_task_test 口径）。
Future<void> _runNowViaMenu(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(_host(app));
  await tester.pump(const Duration(milliseconds: 100));
  expect(find.text('巡检'), findsOneWidget, reason: '列表加载完成');
  await tester.tap(find.byKey(const ValueKey('automation-menu-a1')));
  await tester.pump();
  // 菜单入场动画完成后再点（动画期 tap 落在过渡层的 IgnorePointer 上）。
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('立即运行'));
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('立即运行失败：人话 SnackBar + 无异常逃逸（修复前红=静默无反馈）',
      (tester) async {
    final channel = _RunNowChannel(
      runNowError: TimeoutException(
        'bridge 恢复超时: degraded',
        const Duration(seconds: 15),
      ),
    );
    await _runNowViaMenu(tester, _AutoApp(channel));
    expect(tester.takeException(), isNull,
        reason: '修复前：runNow 抛出的异常从 onTap 逃逸成未处理异步错误');
    expect(find.text('操作失败：网络不佳，请稍后再试'), findsOneWidget,
        reason: '失败必须走人话映射（friendlyError）给用户反馈');
    expect(channel.runNowCalls, 1);
  });

  testWidgets('立即运行成功：按 status 分档提示 + 刷新列表（包裹不改成功路径）',
      (tester) async {
    final channel = _RunNowChannel();
    await _runNowViaMenu(tester, _AutoApp(channel));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('正在运行「巡检」'), findsOneWidget);
    expect(channel.runNowCalls, 1);
    expect(channel.listCalls, 2, reason: 'initState 首载 + 成功后 _load 刷新');
  });
}
