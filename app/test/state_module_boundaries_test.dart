import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('ComputerStack 不再反向依赖 AppState，基础符号从独立文件导出', () {
    final stack = _read('lib/state/computer_stack.dart');
    final app = _read('lib/state/app_state.dart');
    expect(stack.contains("import 'app_state.dart'"), isFalse);
    expect(stack.contains("import 'link_phase.dart'"), isTrue);
    expect(stack.contains("import 'session_errors.dart'"), isTrue);
    expect(app.contains("export 'link_phase.dart'"), isTrue);
    expect(app.contains("export 'session_errors.dart'"), isTrue);
    expect(
      app.contains("export '../transport/project_tree.dart' show workspaceKeyOf"),
      isTrue,
    );
  });

  test('状态层基础文件不使用 part/part of 假拆分', () {
    for (final path in [
      'lib/state/app_state.dart',
      'lib/state/computer_stack.dart',
      'lib/state/link_phase.dart',
      'lib/state/session_errors.dart',
      'lib/state/conversation_registry.dart',
      'lib/state/device_stack_registry.dart',
      'lib/state/task_catalog.dart',
      'lib/state/workspace_controller.dart',
    ]) {
      final source = _read(path);
      expect(RegExp(r'^\s*part\s+', multiLine: true).hasMatch(source), isFalse,
          reason: path);
      expect(RegExp(r'^\s*part\s+of\s+', multiLine: true).hasMatch(source),
          isFalse,
          reason: path);
    }
  });

  test('四个状态模块依赖方向正确且真实接入唯一组合点', () {
    final stack = _read('lib/state/computer_stack.dart');
    final app = _read('lib/state/app_state.dart');
    for (final path in [
      'lib/state/conversation_registry.dart',
      'lib/state/task_catalog.dart',
      'lib/state/workspace_controller.dart',
    ]) {
      final source = _read(path);
      expect(source.contains("import 'app_state.dart'"), isFalse, reason: path);
      expect(source.contains("import 'computer_stack.dart'"), isFalse,
          reason: path);
    }
    expect(
      _read('lib/state/device_stack_registry.dart')
          .contains("import 'app_state.dart'"),
      isFalse,
    );
    expect(
      _read('lib/state/conversation_registry.dart')
          .contains("import 'workspace_controller.dart'"),
      isFalse,
    );
    expect(
      _read('lib/state/task_catalog.dart')
          .contains("import 'workspace_controller.dart'"),
      isFalse,
    );
    for (final symbol in [
      "import 'conversation_registry.dart'",
      "import 'task_catalog.dart'",
      "import 'workspace_controller.dart'",
    ]) {
      expect(stack.contains(symbol), isTrue, reason: symbol);
    }
    expect(stack.contains('ConversationRegistry('), isTrue);
    expect(stack.contains('TaskCatalog('), isTrue);
    expect(stack.contains('WorkspaceController('), isTrue);
    expect(app.contains("import 'device_stack_registry.dart'"), isTrue);
    expect(app.contains('DeviceStackRegistry('), isTrue);
  });

  test('组合门面不保留已迁状态的第二份真值', () {
    final stack = _read('lib/state/computer_stack.dart');
    final app = _read('lib/state/app_state.dart');
    for (final old in [
      'final Map<String, ConversationSubscription> _conversations',
      'final Map<String, Future<ConversationSubscription>> _pendingConversations',
      'final Map<String, SessionCacheWriter> _cacheWriters',
      'TaskListModel? _taskList;',
      'TasksIndexSubscription? _tasksIndex;',
    ]) {
      expect(stack.contains(old), isFalse, reason: old);
    }
    expect(app.contains('final Map<String, ComputerStack> _stacks ='), isFalse);
    expect(app.contains('List<DeviceProfile> profiles ='), isFalse);
    // 对抗审查 （双盲乙）：批次证据 negative 声明的 _failureBySid
    // 第二份真值此前无守卫覆盖——补齐断言（账与测对齐）。
    expect(app.contains('_failureBySid'), isFalse);
  });
}
