import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';

/// 表格手机端优化（2026-10-20 用户真机反馈"表格没针对手机优化"）：
/// Markdown 渲染器在 tableColumnWidth=IntrinsicColumnWidth 时自动给
/// 表格包横向 SingleChildScrollView+Scrollbar（builder.dart:515-533）——
/// 宽表滚动看、窄表原样，列不再被 FlexColumnWidth 压扁。
/// 多机型批（6.1）：测试屏宽常量化（原 360 写死）。
const kTestPhoneW = 360.0;

void main() {
  Future<void> pumpMd(WidgetTester tester, String data) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: kTestPhoneW,
            child: MarkdownView(data: data),
          ),
        ),
      ),
    );
  }

  testWidgets('宽表：横向滚动容器在位（列宽随内容不压扁）', (tester) async {
    await pumpMd(
      tester,
      '| 阶段 | 交付内容 | 验证方式 | 状态 | 备注 |\n'
      '| --- | --- | --- | --- | --- |\n'
      '| 批次0 | 对齐清单补账 | 文档评审 | 完成 | 无代码 |\n'
      '| 批次1 | 六个可见bug修复 | 单测+E2E | 完成 | 全绿 |\n',
    );
    final scrollables = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((w) => w.scrollDirection == Axis.horizontal)
        .toList();
    expect(scrollables, isNotEmpty, reason: '宽表必须包横向滚动容器');
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('窄表：正常渲染无异常', (tester) async {
    await pumpMd(
      tester,
      '| 项 | 值 |\n| --- | --- |\n| 版本 | 10012 |\n| 大小 | 69.6MB |\n',
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('69.6MB'), findsOneWidget);
  });

  testWidgets('无表格正文不受影响', (tester) async {
    await pumpMd(tester, '普通段落文本，含 **加粗** 与 `code`。');
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('普通段落文本'), findsOneWidget);
  });

  testWidgets('表头装饰钉透明（换 plus 后默认会回退成 card 底色）', (tester) async {
    // flutter_markdown_plus 新增 tableHeadCellsDecoration，默认回退
    // tableCellsDecoration——不显式钉透明，表头会从旧包的"透明"变成
    // card 底色（A/B 实测 5.44%→0.88% 像素差的来源之一）。此例锁住
    // "依赖替换不夹带设计变更"的既有观感。
    await pumpMd(
      tester,
      '| 项 | 值 |\n| --- | --- |\n| 甲 | 1 |\n| 乙 | 2 |\n',
    );
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, isNotEmpty);
    final header = table.children.first.decoration;
    expect(header, isA<BoxDecoration>());
    expect((header as BoxDecoration).color, isNull,
        reason: '表头必须保持旧包透明观感');
    final evenRow = table.children[2].decoration as BoxDecoration?;
    expect(evenRow?.color, isNotNull, reason: '偶数数据行斑马纹照旧着色');
  });
}
