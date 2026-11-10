import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/localized_text.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/diff_viewer_page.dart';
import 'package:zcode_pocket/ui/device_list_page.dart';
import 'package:zcode_pocket/ui/goal_panel.dart';
import 'package:zcode_pocket/ui/inline_diff_preview.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';
import 'package:zcode_pocket/ui/login_page.dart';
import 'package:zcode_pocket/ui/notify_guide_page.dart';
import 'package:zcode_pocket/ui/profiles_sheet.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/subagent_list_sheet.dart';
import 'package:zcode_pocket/ui/voice_input_sheet.dart';

class _DiffApp extends AppState {
  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async {
    return {'items': const []};
  }
}

class _SubagentApp extends AppState {
  @override
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async {
    return {
      'running': const [],
      'ended': {'items': const [], 'total': 0},
    };
  }
}

void _expectNoMissing(String label) {
  expect(
    L10n.missingTranslations,
    isEmpty,
    reason: '$label 英文未命中：${L10n.missingTranslations.join(' | ')}',
  );
  L10n.resetForTest();
}

void main() {
  tearDown(L10n.resetForTest);

  testWidgets('英文·DeviceListPage 加载态无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      AppStateScope(
        app: AppState()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const DeviceListPage(),
        ),
      ),
    );
    await tester.pump();
    _expectNoMissing('DeviceListPage');
  });

  testWidgets('英文·LoginPage 降级态无未翻译项', (tester) async {
    LoginPage.debugDisableWebView = true;
    addTearDown(() => LoginPage.debugDisableWebView = false);
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      AppStateScope(
        app: AppState()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const LoginPage(),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('LoginPage');
  });

  testWidgets('英文·ProfilesSheet 空清单无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      AppStateScope(
        app: AppState()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProfilesSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('ProfilesSheet');
  });

  testWidgets('英文·GoalPanel 无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    final state = ConversationState()
      ..snapshot = {
        'goal': {
          'objective': '示例目标',
          'status': 'active',
          'iteration': 1,
          'timeUsedSeconds': 60,
        },
      };
    await tester.pumpWidget(
      AppStateScope(
        app: AppState()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: GoalPanel(state: state, sessionId: 's1')),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('GoalPanel');
  });

  testWidgets('英文·DiffViewerPage 空态无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      AppStateScope(
        app: _DiffApp()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const DiffViewerPage(sessionId: 's1'),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('DiffViewerPage');
  });

  testWidgets('英文·NotifyGuidePage 无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const NotifyGuidePage()),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('NotifyGuidePage');
  });

  testWidgets('英文·VoiceInputSheet 失败降级无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('VoiceInputSheet');
  });

  testWidgets('英文·SubagentListSheet 空态无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      AppStateScope(
        app: _SubagentApp()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSubagentListSheet(
                context,
                sessionId: 's1',
                openSession: (context, {required sessionId, required title, required readOnly}) async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConversationPage(
                        sessionId: sessionId,
                        title: title,
                        readOnly: readOnly,
                      ),
                    ),
                  );
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _expectNoMissing('SubagentListSheet');
  });

  testWidgets('英文·InteractionBanner 的 AI 提问保持原文', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    final state = ConversationState()
      ..snapshot = {
        'pendingInteractions': [
          {
            'interactionId': 'q1',
            'payload': {
              'kind': 'userInput',
              'questions': [
                {
                  'header': '设置',
                  'question': '设置',
                  'multiSelect': false,
                  'options': [
                    {'label': '设置', 'value': '设置', 'description': '设置'},
                  ],
                },
              ],
            },
          },
        ],
      };
    await tester.pumpWidget(
      AppStateScope(
        app: AppState()..loaded = true,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: InteractionBanner(state: state, sessionId: 's1')),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('设置', findRichText: true), findsNWidgets(2));
    expect(find.text('设置  设置', findRichText: true), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    _expectNoMissing('InteractionBanner');
  });

  testWidgets('英文·InlineDiffPreview 代码保持原文', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: InlineDiffPreview(
            display: {
              'filePath': 'lib/example.dart',
              'structuredPatch': [
                {
                  'lines': ['@@ -1 +1 @@', '-旧内容', '+新内容'],
                },
              ],
            },
          ),
        ),
      ),
    );
    _expectNoMissing('InlineDiffPreview');
  });
}
