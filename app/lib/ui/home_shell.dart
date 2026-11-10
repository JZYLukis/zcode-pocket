import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'pairing_page.dart';
import 'task_center_page.dart';

/// 根入口：无任何档案 → 全屏配对页；有档案 → 任务中心（档案切换在
/// 任务中心顶栏一级入口，D4 裁决）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 换页打点只报一次（18088 黑屏取证：bootstrap 首配对瞬间的主线程
  /// 负载定位）。
  bool _announcedSwap = false;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.loaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (app.profiles.isEmpty && app.phase == LinkPhase.offline) {
          _announcedSwap = false;
          return const PairingPage();
        }
        if (!_announcedSwap) {
          _announcedSwap = true;
          debugPrint('[pairing-perf] home shell -> TaskCenterPage');
        }
        return const TaskCenterPage();
      },
    );
  }
}
