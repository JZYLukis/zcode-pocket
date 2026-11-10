// 设计守卫测试（渲染层，2026-10-20 首版报告模式；同日批次修复后转正为
// 断言闸门）
//
// 机制来源：impeccable 的"确定性检测+改动即触发"思路（refs-scan.md §G）。
// 在折叠态 375×806 + 字号放大 1.3 倍下真实构建守卫范围内的页面/组件，
// 用代码遍历断言两类规则：可点元素命中区域 ≥48dp、布局溢出。
//
// 断言闸门纪律（design-audit-2026-10-20.md §六/§七）：
// - 批次 0 修订了测量口径（真实命中区，跳过框架垫层内部件）并清洗了
//   假阳性基线后，本文件从"只报告"转为"发现即失败"。
// - 合法小目标的豁免走 _touchExemptions（场景 → 理由），新增豁免须在
//   audit 文档留痕，禁止通过注释断言来临时放行。
// - 发现明细仍写 tools/logs/design-guard-findings.txt 供排障。
//
// 范围说明：会话页依赖连接栈（ConversationState）无法在测试环境独立
// 搭建——本轮守卫范围=设置页族/用量页/任务中心/归档页/台账页/自动化页/
// 子代理页 + 纯组件（MarkdownView/QuotaBanner/ComposerPanels）。会话页
// 族的渲染层守卫待组件可测性改造后补。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/archived_tasks_page.dart';
import 'package:zcode_pocket/ui/automation_page.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';
import 'package:zcode_pocket/ui/notify_ledger_page.dart';
import 'package:zcode_pocket/ui/quota_banner.dart';
import 'package:zcode_pocket/ui/settings_conversation_page.dart';
import 'package:zcode_pocket/ui/settings_notifications_page.dart';
import 'package:zcode_pocket/ui/settings_page.dart';
import 'package:zcode_pocket/ui/settings_voice_page.dart';
import 'package:zcode_pocket/ui/subagents_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

const _minTouch = 48.0; // Material 触控下限（安卓）
const _textScale = 1.3; // 华为大字体常见档
const _compact = Size(375, 806); // 折叠屏折叠态外屏

/// 已裁决豁免（触控目标：label 关键字 → 理由）。新增须在
/// 留痕（2026-10-24 归档后豁免
/// 留痕仍落该文件），禁止注释断言临时放行。
/// - ModelSheet 行 40dp：用户 2026-10-26 真机验收两轮拍板紧凑布局
///   （参考同类 AI 应用→二轮再收紧）；40 低于 44 触控下限，豁免留痕
/// →0051。
const Map<String, String> _touchExemptions = {
  '[触控<48.0] ModelSheet': '模型行 40dp 紧凑二档（用户 2026-10-26 两轮拍板，ADR 0049/0051）',
};

final _findings = <String>[];

void main() {
  tearDownAll(() {
    if (_findings.isEmpty) return;
    final f = File('../tools/logs/design-guard-findings.txt');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      '# design_guard 发现明细（报告模式，${DateTime.now()}）\n'
      '${_findings.map((e) => '- $e').join('\n')}\n',
    );
    // ignore: avoid_print
    print('[design_guard] ${_findings.length} 条发现已写入 ${f.path}');
  });

  testWidgets('守卫·设置页', (tester) async {
    await _guard(tester, 'SettingsPage', const SettingsPage());
  });

  testWidgets('守卫·设置-对话子页', (tester) async {
    await _guard(
        tester, 'SettingsConversationPage', const SettingsConversationPage());
  });

  testWidgets('守卫·设置-通知子页', (tester) async {
    await _guard(
        tester, 'SettingsNotificationsPage', const SettingsNotificationsPage());
  });

  testWidgets('守卫·设置-语音子页', (tester) async {
    await _guard(
        tester, 'SettingsVoicePage', const SettingsVoicePage());
  });

  testWidgets('守卫·用量页', (tester) async {
    await _guard(tester, 'UsagePage', const UsagePage());
  });

  testWidgets('守卫·任务中心', (tester) async {
    await _guard(tester, 'TaskCenterPage', const TaskCenterPage());
  });

  testWidgets('守卫·归档任务页', (tester) async {
    await _guard(tester, 'ArchivedTasksPage', const ArchivedTasksPage());
  });

  testWidgets('守卫·通知台账页', (tester) async {
    await _guard(tester, 'NotifyLedgerPage', const NotifyLedgerPage());
  });

  testWidgets('守卫·自动化页', (tester) async {
    await _guard(tester, 'AutomationPage', const AutomationPage());
  });

  testWidgets('守卫·子代理页', (tester) async {
    await _guard(tester, 'SubagentsPage', const SubagentsPage());
  });

  testWidgets('守卫·MarkdownView（含宽表格/代码块/长段落）', (tester) async {
    await _guard(
        tester, 'MarkdownView', const MarkdownView(data: _markdownSample));
  });

  testWidgets('守卫·QuotaBanner（低额度态）', (tester) async {
    await _guard(
      tester,
      'QuotaBanner',
      QuotaBanner(
        state: const QuotaBannerState(
          exhausted: false,
          bucketId: 'guard',
          periodStart: 1,
          periodEnd: 2,
          ratio: 0.08,
        ),
        dismissedKeys: const {},
        onDismiss: () {},
      ),
    );
  });

  testWidgets('守卫·ComposerPanels（候选面板）', (tester) async {
    await _guard(
      tester,
      'ComposerPanels',
      ComposerPanels(
        slashCandidates: const [
          {'kind': 'command', 'name': 'read', 'description': '读取文件'},
          {'kind': 'command', 'name': 'remember', 'description': '记忆'},
        ],
        fileCandidates: const [],
        onPick: (_) {},
        onClose: null,
      ),
    );
  });

  testWidgets('守卫·模型弹层（竖向列表行，H14 扩面 2026-10-25）', (tester) async {
    await _guardSheetLike(tester, 'ModelSheet', (context) async {
      await showModelSheet(
        context,
        sessionId: null,
        state: ConversationState(),
      );
    }, app: _GuardCatalogApp());
  });

  testWidgets('守卫·任务中心（「任务」内联分支，H13/H14 扩面 2026-10-25）',
      (tester) async {
    await _guardSheetLike(
      tester,
      'TaskCenterUnclassified',
      null,
      page: const TaskCenterPage(),
      app: _GuardTasksApp(),
    );
  });

  for (final entry in <String, Widget>{
    'SettingsPage': const SettingsPage(),
    'SettingsConversationPage': const SettingsConversationPage(),
    'SettingsNotificationsPage': const SettingsNotificationsPage(),
    'SettingsVoicePage': const SettingsVoicePage(),
    'UsagePage': const UsagePage(),
    'TaskCenterPage': const TaskCenterPage(),
    'ArchivedTasksPage': const ArchivedTasksPage(),
    'NotifyLedgerPage': const NotifyLedgerPage(),
    'AutomationPage': const AutomationPage(),
    'SubagentsPage': const SubagentsPage(),
  }.entries) {
    testWidgets('英文·${entry.key} 无未翻译项', (tester) async {
      L10n.resetForTest();
      L10n.setTestLocale('en-US');
      L10n.collectMissing = true;
      await _guard(tester, entry.key, entry.value);
      _expectNoMissing(entry.key);
    });
  }

  testWidgets('英文·MarkdownView 保持正文原文且无未翻译项', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await _guard(tester, 'MarkdownView', const MarkdownView(data: _markdownSample));
    _expectNoMissing('MarkdownView');
  });

  testWidgets('英文·QuotaBanner 无未翻译项', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await _guard(
      tester,
      'QuotaBanner',
      QuotaBanner(
        state: const QuotaBannerState(
          exhausted: false,
          bucketId: 'guard',
          periodStart: 1,
          periodEnd: 2,
          ratio: 0.08,
        ),
        dismissedKeys: const {},
        onDismiss: () {},
      ),
    );
    _expectNoMissing('QuotaBanner');
  });

  testWidgets('英文·ComposerPanels 无未翻译项', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await _guard(
      tester,
      'ComposerPanels',
      ComposerPanels(
        slashCandidates: const [
          {'kind': 'command', 'name': 'read', 'description': '读取文件'},
          {'kind': 'command', 'name': 'remember', 'description': '记忆'},
        ],
        fileCandidates: const [],
        onPick: (_) {},
        onClose: null,
      ),
    );
    _expectNoMissing('ComposerPanels');
  });

  testWidgets('英文·ModelSheet 无未翻译项', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await _guardSheetLike(tester, 'ModelSheet', (context) async {
      await showModelSheet(context, sessionId: null, state: ConversationState());
    }, app: _GuardCatalogApp());
    _expectNoMissing('ModelSheet');
  });

  testWidgets('英文·TaskCenterUnclassified 无未翻译项', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    await _guardSheetLike(
      tester,
      'TaskCenterUnclassified',
      null,
      page: const TaskCenterPage(),
      app: _GuardTasksApp(),
    );
    _expectNoMissing('TaskCenterUnclassified');
  });
}

void _expectNoMissing(String label) {
  expect(
    L10n.missingTranslations,
    isEmpty,
    reason: '$label 英文未命中：${L10n.missingTranslations.join(' | ')}',
  );
  L10n.resetForTest();
}
/// [open] 非空=点按钮开弹层；否则直接守卫 [page]。
Future<void> _guardSheetLike(
  WidgetTester tester,
  String label,
  Future<void> Function(BuildContext context)? open, {
  Widget? page,
  AppState? app,
}) async {
  tester.view.physicalSize = _compact;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final theApp = app ?? (AppState()..loaded = true);
  addTearDown(theApp.dispose);

  final errors = <FlutterErrorDetails>[];
  final before = _findings.length;
  final original = FlutterError.onError;
  FlutterError.onError = errors.add;
  await tester.pumpWidget(
    AppStateScope(
      app: theApp,
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_textScale),
          ),
          child: child!,
        ),
        home: open == null
            ? Scaffold(body: page!)
            : Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('guard-open'),
                  onPressed: () => open(context),
                  child: const Text('开'),
                ),
              ),
      ),
    ),
  );
  if (open != null) {
    await tester.tap(find.byKey(const ValueKey('guard-open')));
  }
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  _collectTouchTargets(tester, label);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  FlutterError.onError = original;
  for (final e in errors) {
    final s = e.exceptionAsString();
    if (s.contains('overflow') || s.contains('Overflow')) {
      _findings.add('[溢出] $label：$s');
    } else {
      _findings.add('[布局异常·观察] $label：$s');
    }
  }
  final added = _findings
      .sublist(before)
      .where((f) => !_touchExemptions.keys.any(f.contains))
      .toList();
  expect(added, isEmpty,
      reason: '设计守卫发现：\n${added.join('\n')}');
}

/// 模型弹层目录夹具（H14 扩面）：真 AppState 无栈时目录为空，守卫会
/// 空转——覆写目录源保证行真实构建。
class _GuardCatalogApp extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
        ConfigOption.fromMap({
          'id': 'model',
          'name': 'Model',
          'options': [
            for (var i = 0; i < 6; i++)
              {
                'value': 'prov/guard-$i',
                'name': 'Guard $i',
                'modelProviderId': 'prov',
              },
          ],
        }),
      ];

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async =>
      const <String, dynamic>{};
}

/// 「任务」内联分支夹具（H13/H14 扩面）：伪项目选中+两卡数据。
class _GuardTasksApp extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  String? get activeProjectId => conversationsPseudoProjectId;

  @override
  List<Map<String, dynamic>> get unclassifiedTasks => [
        {
          'taskId': 'g1',
          'title': '守卫任务一',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'displayStatus': 'idle',
          'workspacePath': r'C:\guard',
        },
        {
          'taskId': 'g2',
          'title': '守卫任务二',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'displayStatus': 'running',
          'workspacePath': r'C:\guard',
        },
      ];
}

/// 单页守卫流程：折叠态尺寸 + 1.3 字号构建 → 收集溢出异常与触控目标。
Future<void> _guard(WidgetTester tester, String label, Widget page) async {
  tester.view.physicalSize = _compact;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final app = AppState()..loaded = true;
  addTearDown(app.dispose);

  final errors = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  final findingsBeforeGuard = _findings.length;
  FlutterError.onError = errors.add;
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_textScale),
          ),
          child: child!,
        ),
        home: Scaffold(body: page),
      ),
    ),
  );
  // 有界泵循环（页面可能有异步加载；不用 pumpAndSettle——运行中动画
  // 是无限循环会让它超时）。
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  // 页面确实建起来了（守卫有效性前提）——须在拆树之前断言。
  expect(find.byWidget(page), findsOneWidget);

  _collectTouchTargets(tester, label);

  // 收尾：拆树让页面 State.dispose 走到（取消其计时器，防挂尾断言）。
  // 捕获窗口保持到拆树之后（批次 0：拆树期溢出也入账）。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  FlutterError.onError = original;

  for (final e in errors) {
    final s = e.exceptionAsString();
    if (s.contains('overflow') || s.contains('Overflow')) {
      _findings.add('[溢出] $label：$s');
    } else {
      _findings.add('[布局异常·观察] $label：$s');
    }
  }

  // 断言闸门（批次修复后转正）：本场景新增发现（豁免外）必须为零。
  final added = _findings
      .sublist(findingsBeforeGuard)
      .where((f) => !_touchExemptions.keys.any(f.contains))
      .toList();
  expect(added, isEmpty, reason: '设计守卫发现（详见 tools/logs/design-guard-findings.txt）：\n'
      '${added.join('\n')}');
}

/// 遍历已构建的可点元素，命中区域短边 <48dp 记录。
///
/// 测量口径（2026-10-20 批次 0 修订，依据外部复审 design-audit §六）：
/// 量元素自身 renderBox 只对"app 自己的命中层"成立；框架提供增大
/// 命中机制的内部件（按钮内部 40×40 视觉盒外面套着 _InputPadding 48
/// 垫层——盒内任意落点强制转发子盒中心，SDK button_style_button.dart
/// hitTest；SwitchListTile/ListTile 的整行命中）必须跳过，否则系统性
/// 假阳性。按钮自身（IconButton/TextButton 等）与整行命中分别由
/// 各自的候选条目把关——被 tight 约束压缩的按钮（如 44/36）仍会由
/// 按钮条目如实报告。
void _collectTouchTargets(WidgetTester tester, String label) {
  for (final element in tester.allElements) {
    final widget = element.widget;
    final description = _tapDescription(widget);
    if (description == null) continue;
    if (_coveredByFrameworkHitPadding(element)) continue;
    final ro = element.renderObject;
    if (ro is! RenderBox) continue;
    final size = ro.size;
    if (size.isEmpty) continue;
    final shortSide = size.shortestSide;
    if (shortSide < _minTouch) {
      _findings.add(
        '[触控<$_minTouch] $label：$description 实测 ${size.width.toStringAsFixed(1)}'
        '×${size.height.toStringAsFixed(1)}',
      );
    }
  }
}

/// 该元素是否处于框架的增大命中机制内部（其真实命中区由外层提供）。
/// - 按钮内部件（InkWell/GestureDetector 在 ButtonStyleButton/IconButton
///   之内）：命中区=按钮整体的 _InputPadding 盒，由按钮条目测量；
/// - SwitchListTile / 有 onTap 的 ListTile 之内：整行命中。
bool _coveredByFrameworkHitPadding(Element element) {
  var hit = false;
  element.visitAncestorElements((ancestor) {
    final w = ancestor.widget;
    if (w is IconButton || w is ButtonStyleButton) {
      hit = true;
      return false;
    }
    if (w is SwitchListTile) {
      hit = true;
      return false;
    }
    if (w is ListTile && w.onTap != null) {
      hit = true;
      return false;
    }
    return !hit;
  });
  return hit;
}

/// 返回可点元素的描述；非（本守卫口径下的）可点元素返回 null。
String? _tapDescription(Widget widget) {
  if (widget is IconButton) return 'IconButton(${widget.tooltip ?? widget.icon})';
  if (widget is FloatingActionButton) return 'FloatingActionButton';
  if (widget is FilledButton ||
      widget is ElevatedButton ||
      widget is OutlinedButton) {
    return widget.runtimeType.toString();
  }
  if (widget is TextButton) return 'TextButton';
  if (widget is PopupMenuButton) return 'PopupMenuButton';
  if (widget is InkWell) {
    if (widget.onTap == null && widget.onLongPress == null) return null;
    return 'InkWell';
  }
  if (widget is GestureDetector) {
    // 无 tap 类回调的壳（键盘收起 onDrag 等）不算可点目标
    if (widget.onTap == null &&
        widget.onLongPress == null &&
        widget.onDoubleTap == null) {
      return null;
    }
    return 'GestureDetector';
  }
  return null;
}

const _markdownSample = '''
# 标题一

正常段落文字，包含中文与 English mix，以及一段非常长的用来测折行压力的句子，重复：这是一段用于守卫测试的长文本折行样本。

## 标题二

| 列一 | 列二 | 列三 | 列四 |
|---|---|---|---|
| 值值值值值 | 12345 | long-content-here | x |
| 另一行 | 67890 | more | y |

```dart
final answer = 42; // 代码块守卫样本
```

- 列表项一
- 列表项二

> 引用块样本文字。
''';
