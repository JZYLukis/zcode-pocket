// 2026-11-08 批：
// #6（中）切电脑自动退出是一次性的——旧实现先推进 _ownerDeviceSid 再看
// 能否 pop，被弹层/子页压顶（isTop=false）时 pop 不执行且待退标记永久
// 丢失；修复=pop 成功才推进，非栈顶保留 500ms 重试。
// #16（低）从子代理页返回不重报查看态——子页 dispose 已 reportTaskView
// (null)，返回本页必须重报，否则桌面端仍按"未查看"处理。
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

/// 附件选择器桩（file_picker 13 的 PlatformFile 是抽象基类，测试自实现）。
base class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this.name);
  @override
  final String name;
  @override
  Uri get uri => Uri.file('/tmp/$name');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => 1;
  @override
  Future<int?> length() async => 1;
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([65]);
  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList([65]));
}

class _Sub implements ConversationSubscription {
  _Sub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-$sessionId';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LifecycleApp extends AppState {
  _LifecycleApp() {
    activeProfile = _profile('device-a');
  }

  static AccountV2Profile _profile(String deviceSid) => AccountV2Profile(
    deviceSid: deviceSid,
    accountId: 'account-a',
    label: '测试电脑',
    addedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  void switchDevice(String deviceSid) {
    activeProfile = _profile(deviceSid);
  }

  /// #16：查看态上报记录（按调用序）。
  final reportTaskViews = <String?>[];

  @override
  LinkPhase get phase => LinkPhase.online;

  final subs = <String, _Sub>{};

  _Sub subFor(String id) => subs.putIfAbsent(id, () => _Sub(id));

  @override
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    Object? seedCacheEntry,
  }) async {
    final sub = subFor(sessionId);
    sub.state.applySeed(
      ConversationSeed(
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '主会话提问'},
          {
            'rowId': 2,
            'kind': 'turnHeader',
            'state': 'completedSuccess',
            'createdAt': 1,
          },
          {
            'rowId': 3,
            'kind': 'assistantText',
            'state': 'complete',
            'text': '主会话回答',
          },
        ],
        logEpoch: 'e1',
        seq: 3,
        firstRowId: 1,
        totalCount: 3,
        snapshot: const {
          'control': {'phase': 'idle'},
        },
      ),
    );
    return sub;
  }

  @override
  void reportTaskView(String? taskId) {
    reportTaskViews.add(taskId);
    super.reportTaskView(taskId);
  }
}

Widget _host(AppState app, Widget home) => AppStateScope(
  app: app,
  child: MaterialApp(theme: buildAppTheme(), home: home),
);

Future<void> _pump(WidgetTester tester, [int frames = 15]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('切电脑自动退出：被子页压顶时保留待退，路由恢复后补 pop（#6）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _LifecycleApp();
    await tester.pumpWidget(
      _host(
        app,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('push-conv'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ConversationPage(
                      sessionId: 's-main',
                      title: '主会话',
                    ),
                  ),
                ),
                child: const Text('打开会话'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('push-conv')));
    await _pump(tester);
    expect(find.byType(ConversationPage), findsOneWidget);

    // 子页压顶（isTop=false 的那一帧）。
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('盖层')),
      ),
    );
    await _pump(tester, 6);
    expect(find.text('盖层'), findsOneWidget);

    // 切电脑（旧实现此处 pop 被跳过且待退标记永久丢失）。
    app.switchDevice('device-b');
    app.notifyListeners();
    await _pump(tester, 15);
    expect(find.byType(ConversationPage, skipOffstage: false),
        findsOneWidget, reason: '被压顶时不得误关子页/主页');

    // 路由恢复栈顶 → 500ms 重试窗口内自动退出旧电脑会话页。
    nav.pop();
    await _pump(tester, 15);
    expect(find.byType(ConversationPage, skipOffstage: false), findsNothing,
        reason: '路由恢复后补 pop（旧实现永久停留旧电脑会话）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('从子代理会话返回：重报本会话查看态（#16）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _LifecycleApp();
    await tester.pumpWidget(
      _host(app, const ConversationPage(sessionId: 's-main', title: '主会话')),
    );
    await _pump(tester); // 订阅完成（固定三行）
    // 子代理行自带 childSessionId=可下钻。
    app.subFor('s-main').state.applySeed(
      ConversationSeed(
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '派个子代理'},
          {'rowId': 2, 'kind': 'turnHeader', 'state': 'running', 'createdAt': 1},
          {
            'rowId': 3,
            'kind': 'subagent',
            'summaryText': '子任务跑一下',
            'status': 'running',
            'childSessionId': 's-child',
          },
        ],
        logEpoch: 'e1',
        seq: 3,
        firstRowId: 1,
        totalCount: 3,
        snapshot: const {
          'control': {'phase': 'running'},
        },
      ),
    );
    app.subFor('s-main').state.notifyListeners();
    await _pump(tester, 6);
    expect(app.reportTaskViews, contains('s-main'));

    await tester.tap(find.textContaining('子任务跑一下'));
    await _pump(tester);
    expect(app.reportTaskViews.last, 's-child', reason: '子页上报自己的查看态');

    await tester.pageBack();
    await _pump(tester);
    expect(app.reportTaskViews.last, 's-main',
        reason: '返回父页必须重报（子页 dispose 已上报退出查看态）');
    expect(app.viewingSessionId, 's-main');
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件选择 await 期间退页：不 setState-after-dispose（#17）',
      (tester) async {
    final gate = Completer<List<PlatformFile>>();
    ConversationPage.debugPickFiles = () => gate.future;
    addTearDown(() => ConversationPage.debugPickFiles = null);
    final app = _LifecycleApp();
    await tester.pumpWidget(
      _host(app, const ConversationPage(sessionId: null, title: '草稿')),
    );
    await _pump(tester, 6);
    await tester.tap(find.byKey(const ValueKey('add-trigger')));
    await _pump(tester, 6);
    await tester.tap(find.byKey(const ValueKey('add-attachment')));
    await _pump(tester, 4);

    // 系统选择器在途退页（回包时页面已销毁）。
    await tester.pumpWidget(const SizedBox());
    gate.complete([_FakePlatformFile('a.txt')]);
    await _pump(tester, 6);
    expect(tester.takeException(), isNull,
        reason: '回包后不得向已销毁页面 setState（旧实现崩）');
  });
}
