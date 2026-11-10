// 关于页「清除本地缓存」动作——清
// LocalCacheStore 全部快照 + 通知台账，带二次确认与完成反馈；草稿/
// 队列/账号/偏好不在范围（各自独立存储，本页不触）。
// 旅程用内存桩（testWidgets fake-async 区真文件 IO 永不完成），
// 磁盘真往返在纯逻辑组覆盖。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/ui/about_page.dart';

class _StubCacheStore extends LocalCacheStore {
  _StubCacheStore() : super(Directory('about-clear-cache-stub'));

  int clearCalls = 0;
  int? lastCleared;

  @override
  Future<int> clearAll() async {
    clearCalls++;
    return lastCleared = 2;
  }
}

void main() {
  testWidgets('清除本地缓存：确认后调用清理 + 完成提示；取消不清', (tester) async {
    final cache = _StubCacheStore();
    final app = AppState(cacheStore: cache);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(home: AboutZcodePocketPage(versionOverride: '1.0.2')),
      ),
    );
    await tester.pump();
    addTearDown(app.dispose);

    final row = find.byKey(const ValueKey('about-clear-cache'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    // 披露句在场（明文缓存如实告知）。
    expect(find.textContaining('明文 JSON'), findsOneWidget);

    // 取消路径：不触发清理。
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除草稿'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(cache.clearCalls, 0, reason: '取消不得触发清理');

    // 确认路径：弹窗消失 + 清理被调 + 完成提示（确认键=统一封装的
    // FilledButton 红键统一形态）。
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cache.clearCalls, 1, reason: '确认后应清除一次');
    expect(find.text('已清除本地缓存'), findsOneWidget);
  });

  test('LocalCacheStore.clearAll 真文件往返：sessions/device 两根整删并计数',
      () async {
    final tmp =
        await Directory.systemTemp.createTemp('local_cache_clearall_test');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final store = LocalCacheStore(tmp);
    final sep = Platform.pathSeparator;
    final sessDir = Directory('${tmp.path}${sep}sessions${sep}dev-1');
    await sessDir.create(recursive: true);
    await File('${sessDir.path}${sep}s-1.json').writeAsString('{}');
    await File('${sessDir.path}${sep}s-2.json').writeAsString('{}');
    final devRoot = Directory('${tmp.path}${sep}device');
    await devRoot.create(recursive: true);
    await File('${devRoot.path}${sep}dev-1.json').writeAsString('{}');

    final removed = await store.clearAll();
    expect(removed, 3, reason: '两个会话缓存 + 一个设备快照');
    expect(
      Directory('${tmp.path}${sep}sessions').existsSync(), isFalse,
      reason: 'sessions 根应被整目录清除');
    expect(
      Directory('${tmp.path}${sep}device').existsSync(), isFalse,
      reason: 'device 根应被整目录清除');
    // 幂等：空目录再清不炸、计零。
    expect(await store.clearAll(), 0);
  });
}
