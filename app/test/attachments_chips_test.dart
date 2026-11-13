import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/attachments_compose.dart';

/// 回填律：附件区两轮真机反馈——
/// ①（2026-10-22 反馈③）两行竖排堆高被键盘挡 → 单行 chip+限高滚动；
/// ②（2026-10-22 验收⑩）竖向叠加观感差 → 图片改 3 列方形缩略图网格
/// （微信/Telegram 范式），非图片文件保留官方 inline 单行 chip。
PendingAttachment _file(String id, {double progress = 1}) => PendingAttachment(
      id: id,
      fileName: 'log-$id-很长的文件名用于验证截断.txt',
      mime: 'text/plain',
      bytes: Uint8List(2048),
      progress: progress,
      uploaded: progress >= 1 ? {'ref': 'r-$id'} : null,
    );

PendingAttachment _img(String id,
    {double progress = 1, String? error}) => PendingAttachment(
      id: id,
      fileName: 'shot-$id.png',
      mime: 'image/png',
      bytes: Uint8List(4096),
      progress: progress,
      error: error,
      uploaded: error == null && progress >= 1 ? {'ref': 'r-$id'} : null,
    );

Widget _host(List<PendingAttachment> atts, {void Function(String)? onRetry}) =>
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: kTestPhoneW,
            child: PendingAttachmentChips(
              attachments: atts,
              onRemove: (_) {},
              onRetry: onRetry ?? (_) {},
            ),
          ),
        ),
      ),
    );

/// 多机型批（6.1）：测试屏宽常量化（原 360 写死）。
const kTestPhoneW = 360.0;

void main() {
  testWidgets('8 个文件 chip：单行 chip+限高滚动（≤336）', (tester) async {
    await tester.pumpWidget(
      _host([for (var i = 0; i < kMaxChatAttachments; i++) _file('$i')]),
    );
    expect(find.byKey(const ValueKey('早前批次')), findsOneWidget);
    final size = tester.getSize(find.byType(PendingAttachmentChips));
    expect(size.height, lessThanOrEqualTo(336));
    // 文件名与状态同行（chip 后缀）。
    expect(find.textContaining(' · 2 KB'), findsWidgets);
  });

  testWidgets('图片=3 列方形缩略图网格；单元格含移除角标', (tester) async {
    await tester.pumpWidget(
      _host([for (var i = 0; i < 5; i++) _img('$i')]),
    );
    // 5 张图全部渲染为 Image 缩略图。
    expect(find.byType(Image), findsNWidgets(5));
    // 方形单元格。
    final cell = tester.getSize(
      find.byKey(const ValueKey('早前批次')),
    );
    expect(cell.width, cell.height);
    // 移除角标在场。
    expect(
      find.byKey(const ValueKey('早前批次')),
      findsOneWidget,
    );
    // 3 列：第 4 张图换行（y 更大）。
    final a = tester.getTopLeft(
      find.byKey(const ValueKey('早前批次')),
    );
    final d = tester.getTopLeft(
      find.byKey(const ValueKey('早前批次')),
    );
    expect(d.dy, greaterThan(a.dy));
  });

  testWidgets('上传中显示百分比；失败态点缩略图重试', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _host(
        [_img('up', progress: 0.5), _img('bad', error: 'boom')],
        onRetry: (_) => retried = true,
      ),
    );
    expect(find.textContaining('50%'), findsOneWidget);
    expect(find.textContaining('上传失败'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('pending-attachment-retry-bad')),
    );
    expect(retried, isTrue);
  });
}
