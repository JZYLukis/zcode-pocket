import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/conversation_search.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

List<Map<String, dynamic>> _rows() => [
  {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
  {'rowId': 2, 'kind': 'userInput', 'text': 'Needle needle'},
  {'rowId': 3, 'kind': 'reasoning', 'text': 'needle must not be indexed'},
  {
    'rowId': 4,
    'kind': 'toolCall',
    'toolName': 'Bash',
    'status': 'success',
    'input': {'command': 'echo needle'},
    'output': {'text': 'needle in output'},
  },
  {'rowId': 5, 'kind': 'assistantText', 'text': 'Alpha NEEDLE'},
];

void main() {
  test('提问/回复/工具输入输出计数，思考不搜，匹配保持原文与稳定锚点', () {
    final matches = buildConversationSearchMatches(
      buildChatItems(_rows()),
      'needle',
    );
    expect(matches, hasLength(5));
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.user),
      hasLength(2),
    );
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.tool),
      hasLength(2),
    );
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.assistant),
      hasLength(1),
    );
    expect(matches.last.sourceText, 'Alpha NEEDLE');
    expect(matches.last.anchorKey, 'turn-h1');
    expect(matches.map((m) => m.identity).toSet(), hasLength(5));
    expect(matches.first.snippet, contains('Needle needle'));
  });

  test('字面匹配非重叠，空查询不索引，大小写不敏感', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'AaAa'},
    ];
    final items = buildChatItems(rows);
    expect(buildConversationSearchMatches(items, 'aa'), hasLength(2));
    expect(buildConversationSearchMatches(items, '  '), isEmpty);
    expect(buildConversationSearchMatches(items, 'a.a'), isEmpty);
  });

  // B2-P2-4/D2-08：toLowerCase 对 İ（U+0130）扩长（1 码元→
  // 'i'+U+0307 两码元），折叠串下标漂移——命中 start/end 必须落在原串
  // 坐标系（snippet 切 sourceText 不越界不错位）。
  test('İ（U+0130）折叠扩长：命中区间与 snippet 落在原串坐标系', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'İabc needle'},
    ];
    final items = buildChatItems(rows);
    final matches = buildConversationSearchMatches(items, 'needle');
    expect(matches, hasLength(1));
    final m = matches.single;
    expect(m.sourceText.substring(m.start, m.end), 'needle',
        reason: '命中区间切原文恰为关键词');
    expect(m.snippet, contains('İabc'),
        reason: 'snippet 上下文不错位（İ 保持原文）');

    // 漂移点之后命中的极端尾沿：substring/snippet 均不越界。
    final tail = buildConversationSearchMatches(
      buildChatItems([
        {'rowId': 1, 'kind': 'userInput', 'text': 'İneedle'},
      ]),
      'needle',
    );
    expect(tail, hasLength(1));
    expect(tail.single.start, 1, reason: 'İ 折叠为单码元 i，原串下标=1');
    expect(tail.single.sourceText.substring(tail.single.start, tail.single.end),
        'needle');
  });

  test('历史前插后按行与出现序号重锚当前匹配', () {
    final oldMatches = buildConversationSearchMatches(
      buildChatItems(_rows()),
      'needle',
    );
    final previous = oldMatches.last.identity;
    final older = [
      {'rowId': 90, 'kind': 'userInput', 'text': 'older needle'},
      ..._rows(),
    ];
    final matches = buildConversationSearchMatches(
      buildChatItems(older),
      'needle',
    );
    final index = reanchorConversationSearchMatch(matches, previous, 0);
    expect(matches[index].rowId, 5);
    expect(matches[index].kind, ConversationSearchKind.assistant);
  });

  test('工具错误与 bash display 输出可搜，隐藏 outputPreview 不冒充完成输出', () {
    final rows = [
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'error',
        'error': {'message': 'permission needle'},
        'outputPreview': {'fullText': 'hidden needle'},
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'output': {
          'display': {'kind': 'bash_output', 'output': 'terminal needle'},
        },
      },
    ];
    final matches = buildConversationSearchMatches(
      buildChatItems(rows),
      'needle',
    );
    expect(matches.map((m) => m.rowId), containsAll([2, 3]));
    expect(
      matches.where((m) => m.sourceText.contains('hidden needle')),
      isEmpty,
    );
  });
}
