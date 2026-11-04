import 'package:flutter/material.dart';

/// 响应式断点（docs/ui-references.md §2.1）：
/// compact <600（折叠态单栏） / medium 600-840（展开态图标轨+内容） /
/// expanded ≥840（三栏，平板/横屏预留）。
enum AppFormFactor { compact, medium, expanded }

AppFormFactor formFactorOf(Size size) {
  if (size.width >= 840) return AppFormFactor.expanded;
  if (size.width >= 600) return AppFormFactor.medium;
  return AppFormFactor.compact;
}

/// 折叠屏双形态（docs/PROJECT_PLAN.md 折叠屏适配章节）：
/// 展开/折叠实时切换时布局连续过渡、状态保持（状态在 provider 层，
/// 不随 Widget 树重建丢失）。
class FormFactorBuilder extends StatelessWidget {
  final Widget Function(BuildContext, AppFormFactor, Size) builder;

  const FormFactorBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return builder(context, formFactorOf(size), size);
      },
    );
  }
}
