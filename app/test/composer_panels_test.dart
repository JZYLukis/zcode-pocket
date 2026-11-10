import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';
import 'package:zcode_pocket/transport/conversation.dart';

void main() {
  group('activeCompletionToken', () {
    test('起始斜杠无空格 → slash 补全', () {
      expect(activeCompletionToken('/'), (type: 'slash', token: ''));
      expect(activeCompletionToken('/rea'), (type: 'slash', token: 'rea'));
    });

    test('斜杠后出现空格即不再是命令补全', () {
      expect(activeCompletionToken('/read x'), isNull);
    });

    test('末尾 @token → file 补全', () {
      expect(activeCompletionToken('看看 @agen'), (type: 'file', token: 'agen'));
      expect(activeCompletionToken('@'), (type: 'file', token: ''));
    });

    test('正文无 token → null', () {
      expect(activeCompletionToken('普通消息'), isNull);
      expect(activeCompletionToken('邮箱 a@b.com 后面还有字'), isNull);
    });
  });

  group('filterSlashCommands', () {
    final commands = [
      SlashCommand.fromMap({'name': 'read', 'description': '读取文件'}),
      SlashCommand.fromMap({'name': 'remember', 'description': '记忆'}),
      SlashCommand.fromMap({'name': 'exit', 'description': ''}),
    ];
    test('前缀/包含过滤 + 截断到 12', () {
      expect(filterSlashCommands(commands, 'rea').map((c) => c['name']), [
        'read',
      ]);
      expect(filterSlashCommands(commands, 're').map((c) => c['name']), [
        'read',
        'remember',
      ]);
      expect(filterSlashCommands(commands, 'zzz'), isEmpty);
      final many = List.generate(
        30,
        (i) => SlashCommand.fromMap({'name': 'cmd$i', 'description': ''}),
      );
      expect(filterSlashCommands(many, 'cmd').length, 12);
    });
  });
  /// ②（2026-10-19 真机反馈）：候选面板必须有不依赖"选择/输入变化"的
  /// 关闭出口——「选择能力」打开后空输入时无法收起的实锤回归防护。
  group('ComposerPanels 关闭出口', () {
    testWidgets('头部关闭钮在位且回调触发', (tester) async {
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComposerPanels(
              slashCandidates: const [
                {'kind': 'command', 'name': 'read', 'description': ''},
              ],
              fileCandidates: const [],
              onPick: (_) {},
              onClose: () => closed++,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('composer-panel-close')), findsOneWidget);
      expect(find.text('命令 · 能力'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('composer-panel-close')));
      await tester.pump();
      expect(closed, 1);
    });
  });

}
