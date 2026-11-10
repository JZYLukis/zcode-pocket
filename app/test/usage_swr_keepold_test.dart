import 'dart:async';

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
import 'package:zcode_pocket/ui/usage_page.dart';

/// （2026-10-29 批次）：个人套餐强刷失败保留旧图。
/// 修复前红：_callCodingPlanUsage 吞异常返 null 且 reason 为空，
/// 成功分支 `_cp = cp` 直接把已渲染的图表清空。
/// 伴生断言：首载即失败出内联提示（非静默空白）、恢复成功后提示消失。

class _ScriptedChannel extends ChannelClient {
  _ScriptedChannel({required this.cpHealthy}) : super(sendBody: (_) {});

  /// getCodingPlanUsageSnapshot 的脚本：true=返回有效载荷，false=抛异常。
  bool cpHealthy;

  /// getAppUsageSnapshot 的脚本（应用 tab）：true=返回有效载荷，false=抛异常。
  bool appHealthy = true;

  /// 挂起 getAppUsageSnapshot 的回复（应用 tab 重验在飞窗口测试用）。
  Completer<dynamic>? appPending;

  /// getCodingPlanResetStatus 的载荷；null=无机会。
  Map<String, dynamic>? resetStatus;

  /// 挂起 useCodingPlanReset 的回复（重置礼包在飞窗口测试用）。
  Completer<dynamic>? useResetPending;

  Map<String, dynamic> get appPayload => {
    'summary': {'totalTokens': 100, 'activeDays': 2},
    'heatmap': <String, dynamic>{},
  };

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'getCodingPlanUsageSnapshot':
        if (!cpHealthy) throw Exception('usage rpc down');
        return {
          'activity': {'summary': <String, dynamic>{}},
        };
      case 'getAppUsageSnapshot':
        final pending = appPending;
        if (pending != null) return pending.future;
        if (!appHealthy) throw Exception('app rpc down');
        return appPayload;
      case 'getCodingPlanResetStatus':
        return resetStatus ?? <String, dynamic>{};
      case 'useCodingPlanReset':
        final pending = useResetPending;
        if (pending != null) return pending.future;
        return {'used': true};
      default:
        return <String, dynamic>{};
    }
  }
}

class _ScriptedBridge implements BridgeSession {
  _ScriptedBridge({required bool cpHealthy})
    : scripted = _ScriptedChannel(cpHealthy: cpHealthy);
  final _ScriptedChannel scripted;
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
  ChannelClient get channels => scripted;
  @override
  String? get workspaceKey => 'ws-h15';
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

class _H15UsageApp extends AppState {
  _H15UsageApp({required bool cpHealthy})
    : _bridge = _ScriptedBridge(cpHealthy: cpHealthy);
  final _ScriptedBridge _bridge;
  @override
  BridgeSession? get bridge => _bridge;
}

void main() {
  Future<_ScriptedChannel> pumpPage(
    WidgetTester tester, {
    bool cpHealthy = true,
    bool appHealthy = true,
    Map<String, dynamic>? resetStatus,
  }) async {
    // 图表节在 ListView 懒构建视口之下：调高测试表面让全部子项构建。
    await tester.binding.setSurfaceSize(const Size(412, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    final app = _H15UsageApp(cpHealthy: cpHealthy);
    (app.bridge!.channels as _ScriptedChannel).appHealthy = appHealthy;
    (app.bridge!.channels as _ScriptedChannel).resetStatus = resetStatus;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
      ),
    );
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return app.bridge!.channels as _ScriptedChannel;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 把 UsagePage 推在来源页之上（重置弹层收口测试用——误 pop 时可观测
  /// 到"被弹穿回来源页"）。
  Future<_ScriptedChannel> pumpPushedPage(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    final app = _H15UsageApp(cpHealthy: true);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(builder: (_) => const UsagePage()),
                  ),
                  child: const Text('open-usage'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-usage'));
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return app.bridge!.channels as _ScriptedChannel;
  }

  testWidgets('强刷图表失败保留旧图，不出失败提示', (tester) async {
    final channel = await pumpPage(tester);
    expect(find.textContaining('活跃度统计'), findsOneWidget, reason: '基线：首轮成功后图表节渲染');

    channel.cpHealthy = false;
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.textContaining('活跃度统计'), findsOneWidget,
        reason: 'H15-2：强制刷新失败必须保留已渲染的旧图表');
    expect(find.textContaining('图表数据获取失败'), findsNothing,
        reason: '有旧图可退时不出失败提示');
  });

  testWidgets('首载图表失败出内联提示；恢复成功后提示消失', (tester) async {
    final channel = await pumpPage(tester, cpHealthy: false);
    expect(find.textContaining('活跃度统计'), findsNothing);
    expect(find.textContaining('图表数据获取失败'), findsOneWidget,
        reason: '首载即失败要出内联提示而非静默空白');

    channel.cpHealthy = true;
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.textContaining('活跃度统计'), findsOneWidget, reason: '恢复成功后图表回来');
    expect(find.textContaining('图表数据获取失败'), findsNothing,
        reason: '成功后失败提示必须消失');
  });

  testWidgets('应用 tab 重验在飞期保留旧内容（N3 P1-1：SWR 对齐套餐 tab）', (
    tester,
  ) async {
    final channel = await pumpPage(tester);
    await tester.tap(find.text('应用用量'));
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget, reason: '基线：首载成功后统计卡渲染');

    // 重验在飞（_appLoading=true）：修复前 if/else-if 互斥链把已在屏的
    // 全部统计卡替换成一根细进度条——定时器周期==TTL 使约每分钟闪一次。
    channel.appPending = Completer<dynamic>();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('统计指标'), findsOneWidget,
        reason: '重验在飞不得整段替换已在屏内容（进度条内联叠加）');
    channel.appPending!.complete(channel.appPayload);
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget);
  });

  testWidgets('应用 tab 刷新失败错误行内联，不顶掉旧内容（N1/N2/N3）', (
    tester,
  ) async {
    final channel = await pumpPage(tester);
    await tester.tap(find.text('应用用量'));
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget, reason: '基线：首载成功后统计卡渲染');

    channel.appHealthy = false;
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget,
        reason: '刷新失败必须保留 peek 旧值渲染（SWR 对齐 H15-2 套餐 tab）');
    expect(find.textContaining('加载失败'), findsOneWidget,
        reason: '失败事实以内联错误行呈现（含重试钮），而非替换内容');
  });

  testWidgets('应用 tab 首载失败出错误行；恢复成功后内容回来', (tester) async {
    final channel = await pumpPage(tester, appHealthy: false);
    await tester.tap(find.text('应用用量'));
    await settle(tester);
    expect(find.text('统计指标'), findsNothing);
    expect(find.textContaining('加载失败'), findsOneWidget, reason: '首载失败独占错误行');

    channel.appHealthy = true;
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget, reason: '恢复成功后内容回来');
    expect(find.textContaining('加载失败'), findsNothing);
  });

  testWidgets('切档在飞再切回缓存档：_appLoading 复位（红=进度条常驻）', (
    tester,
  ) async {
    final channel = await pumpPage(tester);
    await tester.tap(find.text('应用用量'));
    await settle(tester);
    expect(find.text('统计指标'), findsOneWidget, reason: '基线：30d 首载成功');

    // 7d 首载在飞（挂起回复）→ 首载无旧值占位转圈。
    channel.appPending = Completer<dynamic>();
    await tester.tap(find.byKey(const ValueKey('app-range-7d')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '前置：7d 首载在飞');

    // 立刻切回 30d：TTL 内缓存命中早退——必须复位 loading，否则进度条
    // 常驻（红）且错误行被 `!_appLoading` 掩住。
    await tester.tap(find.byKey(const ValueKey('app-range-30d')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: '缓存命中=本次刷新完成，loading 必须复位（红）');
    expect(find.text('统计指标'), findsOneWidget, reason: '缓存档旧值照常渲染');

    // 迟到的 7d 响应被代际丢弃，也不得把 loading 重新挂起。
    channel.appPending!.complete(channel.appPayload);
    await settle(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重置徽标秒针：退后台暂停、回前台恢复（电量红线）', (tester) async {
    UsagePage.debugResetTickerActive = false;
    addTearDown(() => UsagePage.debugResetTickerActive = false);
    await pumpPage(tester, resetStatus: {
      'availableFiveHourResets': [
        {
          'expireAt': DateTime.now()
              .add(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        },
      ],
    });
    expect(find.byKey(const ValueKey('reset-opportunity-badge')),
        findsOneWidget,
        reason: '前置：礼包徽标在场');
    expect(UsagePage.debugResetTickerActive, isTrue, reason: '前台走表');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(UsagePage.debugResetTickerActive, isFalse,
        reason: '红=旧实现退后台每天仍在每秒醒来（只判生命周期不取消定时器）');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(UsagePage.debugResetTickerActive, isTrue, reason: '回前台恢复走表');
  });

  testWidgets('重置确认框在飞不可点屏障关；成功只收自己的层（N1/N2/N3 P1）', (
    tester,
  ) async {
    final channel = await pumpPushedPage(tester);
    channel.resetStatus = {
      'availableFiveHourResets': [
        {
          'expireAt': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      ],
    };
    // 重新触发状态拉取（开页加载时机会还没注入）。
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.byKey(const ValueKey('reset-opportunity-badge')), findsOneWidget,
        reason: '前置：礼包徽标在场');

    await tester.tap(find.byKey(const ValueKey('reset-opportunity-badge')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('可重置额度'), findsOneWidget, reason: '底部弹层已开');

    // 弹层两行各有一个「重置」钮（周额度 0 次=禁用）——首个=5 小时行。
    await tester.tap(find.widgetWithText(FilledButton, '重置').first);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AlertDialog), findsOneWidget, reason: '确认框已开');

    // RPC 在飞期点屏障不得关闭确认框（修复前 barrierDismissible 默认
    // true，点框外即关→成功回调的 pop 与栈形态错位）。
    channel.useResetPending = Completer<dynamic>();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '重置'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'barrier 点按不得关闭在飞确认框');

    // 系统返回键关掉确认框（barrierDismissible 挡不住返回键）→ 成功回调
    // 只关弹层，不弹穿用量页。
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AlertDialog), findsNothing);

    channel.useResetPending!.complete({'used': true});
    await settle(tester);
    expect(find.byType(UsagePage), findsOneWidget,
        reason: '修复前：无条件双 pop 把弹层+用量页一起弹穿');
    expect(find.text('可重置额度'), findsNothing, reason: '弹层应已收起');
    expect(find.text('open-usage'), findsNothing, reason: '不得弹穿回来源页');
    expect(find.textContaining('重置成功'), findsOneWidget);
  });
}
