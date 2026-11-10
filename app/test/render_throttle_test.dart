// 会话渲染三优化（优化批 #8/#25/#27）行为锁定：
// ①流式渲染节流——窗口首次通知立即渲染、40ms 窗口内后续通知合并为一次
//   尾沿 setState（连续多次 notify 只触发一次整页重建）；
// ②搜索命中词级高亮——搜索激活时助手正文切换为纯文本预览+命中词底色，
//   关闭恢复 markdown 渲染；
// ③轮尾时间标签——今天 HH:mm/今年 M月d日/往年 yyyy/M/d，缺时间戳不显示。
// 另锁：稳定行渲染缓存（_CachedContent）不得吞掉真实变化（末轮流式行
// 文本更新必须照常上屏）。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/localized_text.dart' show Text;
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/conversation_message_cells.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

class _ThrottleSub implements ConversationSubscription {
  _ThrottleSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-throttle';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _ThrottleApp extends AppState {
  _ThrottleApp(this.rows, {this.headerExtra, this.headerState});
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? headerExtra;

  /// 覆写轮状态（默认 completedSuccess；mid-turn 场景传 running——
  /// 运行中轮默认展开，工作区/标记行才渲染）。
  final String? headerState;
  late final sub = _ThrottleSub('s-throttle');

  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
    if (!sub.state.ready) {
      final header = <String, dynamic>{
        'rowId': 1,
        'kind': 'turnHeader',
        'state': headerState ?? 'completedSuccess',
        if (headerExtra != null) ...headerExtra!,
      };
      sub.state.applySeed(
        ConversationSeed(
          rows: [header, ...rows],
          logEpoch: 'e1',
          seq: rows.length + 1,
          firstRowId: 1,
          totalCount: rows.length + 1,
          snapshot: const {
            'title': '渲染节流',
            'control': {'phase': 'idle'},
          },
        ),
      );
    }
    return sub;
  }
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const ConversationPage(sessionId: 's-throttle', title: '渲染节流'),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _upsertAssistant(ConversationState state, int seq, String text) {
  state.applyFrame({
    'fromSeq': seq,
    'toSeq': seq + 1,
    'payload': {
      'kind': 'deltas',
      'deltas': [
        {
          'op': 'row.upserted',
          'row': {
            'rowId': 3,
            'kind': 'assistantText',
            'state': 'complete',
            'text': text,
          },
        },
      ],
    },
  }, onGap: () => fail('不应 gap'));
}

void main() {
  testWidgets('流式节流：窗口首次通知立即渲染，窗口内后续合并为一次尾沿', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '问一个问题'},
      {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '初始正文'},
    ]);
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.textContaining('初始正文'), findsWidgets);

    // 第一次通知：立即渲染（窗口首帧不等待）。
    _upsertAssistant(app.sub.state, 3, '第一版正文');
    await tester.pump();
    expect(find.textContaining('第一版正文'), findsWidgets,
        reason: '窗口首次通知必须立即渲染');

    // 第二次通知（同一 40ms 窗口内）：合并，零时长 pump 后不得上屏。
    _upsertAssistant(app.sub.state, 4, '第二版正文');
    await tester.pump();
    expect(find.textContaining('第二版正文'), findsNothing,
        reason: '窗口内后续通知应合并（未到尾沿不上屏）');
    expect(find.textContaining('第一版正文'), findsWidgets,
        reason: '合并期间保持上一次已渲染内容');

    // 尾沿 flush：越过 40ms 窗口后最新内容上屏。
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('第二版正文'), findsWidgets,
        reason: '窗口尾沿必须补渲染最新状态');
    expect(find.textContaining('第一版正文'), findsNothing);

    // 窗口过期后的下一次通知又回到“立即渲染”档。
    _upsertAssistant(app.sub.state, 5, '第三版正文');
    await tester.pump();
    expect(find.textContaining('第三版正文'), findsWidgets,
        reason: '上一窗口关闭后，新窗口首次通知立即渲染');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('稳定行渲染缓存不吞真实变化：末轮文本更新照常上屏', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '继续'},
      {'rowId': 3, 'kind': 'assistantText', 'state': 'streaming', 'text': '流式前半'},
    ]);
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.textContaining('流式前半'), findsWidgets);

    _upsertAssistant(app.sub.state, 3, '流式完整结论');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('流式完整结论'), findsWidgets,
        reason: '缓存键含文本，变化必须重建');
    expect(find.textContaining('流式前半'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('搜索命中词级高亮：激活切换纯文本预览+命中段底色，关闭恢复', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '找一下'},
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'complete',
        'text': '这里有 needle 一词，再 needle 一次',
      },
    ]);
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    // 非搜索态：markdown 渲染，无预览节点。
    expect(find.byType(MarkdownView), findsWidgets);
    expect(find.byKey(const ValueKey('search-highlight-preview')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'needle',
    );
    await _settle(tester);

    // 搜索态：助手正文切换为纯文本预览（markdown 让位）。
    final previewFinder = find.byKey(const ValueKey('search-highlight-preview'));
    expect(previewFinder, findsWidgets, reason: '搜索激活时正文进预览渲染');
    expect(find.byType(MarkdownView), findsNothing,
        reason: '搜索态助手正文不再走 markdown 渲染');
    final rich = tester.widget<Text>(previewFinder.first);
    final span = rich.textSpan;
    expect(span, isA<TextSpan>());
    final children = (span as TextSpan).children!.cast<TextSpan>();
    // '这里有 ' + [needle] + ' 一词，再 ' + [needle] + ' 一次' = 5 段。
    expect(children.length, 5, reason: '两处命中切成 5 段');
    expect(children[1].text, 'needle');
    expect(children[1].style?.backgroundColor, isNotNull,
        reason: '命中段有底色');
    expect(children[3].text, 'needle');
    expect(children[0].text, '这里有 ');

    // 关闭搜索：恢复 markdown 渲染，预览节点退场。
    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('search-highlight-preview')), findsNothing);
    expect(find.byType(MarkdownView), findsWidgets,
        reason: '关闭搜索恢复 markdown 渲染');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // 搜索开启但关键词为空时页面传 ''（非 null）——
  // AssistantText 缺非空守卫会让全部助手正文从 markdown 降级纯文本
  //（注释契约「关键词为空即恢复 markdown 渲染」与 UserBubble 守卫对齐）。
  testWidgets('搜索开启且关键词为空：助手正文保持 markdown（不降级纯文本）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '找一下'},
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'complete',
        'text': '**加粗** 与 `code` 与 needle',
      },
    ]);
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.byType(MarkdownView), findsWidgets);

    // 打开搜索、不输入：'' 传给 AssistantText——不得切换纯文本预览。
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('search-highlight-preview')),
      findsNothing,
      reason: '空关键词不得激活纯文本预览（修复前每次打开搜索全部正文降级）',
    );
    expect(find.byType(MarkdownView), findsWidgets,
        reason: '空关键词保持 markdown 渲染');

    // 输入真实关键词后正常切换预览（命中高亮路径不受影响）。
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'needle',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('search-highlight-preview')), findsWidgets);

    // 清空关键词恢复 markdown（守卫的另一半语义）。
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      '',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('search-highlight-preview')), findsNothing);
    expect(find.byType(MarkdownView), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // （lane 语义）：mid-turn auto-compact（lane=assistantWork）
  // 的标记行在回合内部渲染（TimelineMarkerDivider），不再顶层分隔线。
  testWidgets('mid-turn compact 标记行段内渲染（lane=assistantWork）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '长回合'},
      {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '前半'},
      {
        'rowId': 4,
        'kind': 'timelineMarker',
        'lane': 'assistantWork',
        'marker': {'type': 'compact', 'origin': 'auto', 'status': 'success'},
      },
      {
        'rowId': 5,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
      },
    ], headerState: 'running'); // mid-turn=运行中轮（默认展开，工作区渲染）
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.text('上下文已自动压缩'), findsOneWidget,
        reason: 'mid-turn compact 标记行按官方 lane 落回合内部渲染');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('轮尾时间标签：createdAt 驱动三档格式，缺时间戳不显示', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
    final app = _ThrottleApp(
      [
        {'rowId': 2, 'kind': 'userInput', 'text': '什么时候'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '结论在此'},
      ],
      // createdAt=今年 3 天前 → 「M月d日」档。
      headerExtra: {
        'createdAt': threeDaysAgo.millisecondsSinceEpoch,
        'entityId': 'ent-1',
      },
    );
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(
      find.text('${threeDaysAgo.month}月${threeDaysAgo.day}日'),
      findsOneWidget,
      reason: '今年非今天=「M月d日」',
    );
    // 今天档与往年档由纯函数锁定（真机时钟夹具不可注入 widget 内部）。

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('轮尾时间标签：无时间戳（旧快照/夹具）不渲染标签', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _ThrottleApp([
      {'rowId': 2, 'kind': 'userInput', 'text': '普通轮'},
      {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '无时间戳轮尾'},
    ]);
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    // 轮尾操作行仍渲染（复制钮在场），但不得有时间格式文本。
    expect(find.byTooltip('复制这条回复'), findsOneWidget);
    final dateLike = RegExp(r'^\d{1,2}月\d{1,2}日$|^\d{4}/\d+/\d+$|^\d{2}:\d{2}$');
    final labeled = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.data != null && dateLike.hasMatch(t.data!))
        .toList();
    expect(labeled, isEmpty, reason: '缺 createdAt 不得显示时间标签');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('纯函数：时间标签/时间戳取值/命中分段', () {
    test('turnTailTimestampLabel 三档+非法值', () {
      final now = DateTime(2026, 10, 31, 15, 0);
      expect(
        turnTailTimestampLabel(
          DateTime(2026, 10, 31, 14, 30).millisecondsSinceEpoch,
          now: now,
        ),
        '14:30',
        reason: '今天=HH:mm',
      );
      expect(
        turnTailTimestampLabel(
          DateTime(2026, 3, 5, 9, 7).millisecondsSinceEpoch,
          now: now,
        ),
        '3月5日',
        reason: '今年=M月d日',
      );
      expect(
        turnTailTimestampLabel(
          DateTime(2024, 12, 1, 8, 0).millisecondsSinceEpoch,
          now: now,
        ),
        '2024/12/1',
        reason: '往年=yyyy/M/d',
      );
      expect(turnTailTimestampLabel(null, now: now), isNull);
      expect(turnTailTimestampLabel(0, now: now), isNull);
      expect(turnTailTimestampLabel(-5, now: now), isNull);
    });

    test('turnHeaderCreatedAt：createdAt 优先，startedAt 兜底，双缺 null', () {
      expect(turnHeaderCreatedAt({'createdAt': 100}), 100);
      expect(turnHeaderCreatedAt({'startedAt': 200}), 200);
      expect(turnHeaderCreatedAt({'createdAt': 0, 'startedAt': 300}), 300);
      expect(turnHeaderCreatedAt(const {}), isNull);
      expect(turnHeaderCreatedAt(null), isNull);
    });

    test('buildSearchHighlightSpans：大小写不敏感分段+非重叠', () {
      const base = TextStyle(fontSize: 14);
      const hit = TextStyle(fontSize: 14, backgroundColor: Color(0x00000000));
      final spans = buildSearchHighlightSpans(
        'Abc needle x NEEDLE y needle',
        'needle',
        base: base,
        hit: hit,
      );
      expect(spans.length, 6, reason: '3 处命中+3 段间隔=6 段');
      final ts = spans.cast<TextSpan>();
      expect(ts[0].text, 'Abc ');
      expect(ts[1].text, 'needle');
      expect(ts[1].style?.backgroundColor, isNotNull);
      expect(ts[2].text, ' x ');
      expect(ts[3].text, 'NEEDLE', reason: '命中段保留原文大小写');
      expect(ts[4].text, ' y ');
      expect(ts[5].text, 'needle');
      expect(ts[5].style?.backgroundColor, isNotNull);

      // 空关键词=整段单 span（不切换预览的安全兜底）。
      final empty = buildSearchHighlightSpans('abc', ' ', base: base, hit: hit);
      expect(empty.length, 1);
      expect((empty[0] as TextSpan).text, 'abc');
    });

    // （三路）：Dart toLowerCase 对
    // U+0130（İ）扩长（1 码元→'i'+U+0307 两码元），折叠串下标切原串
    // 错位/RangeError——修复前 source='İab' 查 'b' 直接越界崩溃。
    test('buildSearchHighlightSpans：İ（U+0130）折叠扩长不崩溃且命中下标在原串坐标系', () {
      const base = TextStyle(fontSize: 14);
      const hit = TextStyle(fontSize: 14, backgroundColor: Color(0x00000000));
      final spans = buildSearchHighlightSpans(
        'İab',
        'b',
        base: base,
        hit: hit,
      );
      final ts = spans.cast<TextSpan>();
      expect(ts.length, 2);
      expect(ts[0].text, 'İa');
      expect(ts[1].text, 'b');
      expect(ts[1].style?.backgroundColor, isNotNull);

      // 漂移点之后的多处命中同样保持原串坐标（段落拼回=原文）。
      final multi = buildSearchHighlightSpans(
        'İx needle y',
        'needle',
        base: base,
        hit: hit,
      ).cast<TextSpan>();
      expect(multi[0].text, 'İx ');
      expect(multi[1].text, 'needle');

      // İ 自身可被 'i' 检索命中（逐码位折叠取首码元）。
      final dotted = buildSearchHighlightSpans(
        'baİd',
        'i',
        base: base,
        hit: hit,
      ).cast<TextSpan>();
      expect(dotted[1].text, 'İ');
      expect(dotted[1].style?.backgroundColor, isNotNull);
    });
  });
}
