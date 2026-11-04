import 'package:flutter/material.dart';

import 'app_state.dart';

/// AppState 的 widget 树注入点。展开/折叠切换时状态保持
/// （docs/ui-references.md §2.1：状态在 provider 层，不随 Widget 树重建丢失）。
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState app, required super.child})
    : super(notifier: app);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}
