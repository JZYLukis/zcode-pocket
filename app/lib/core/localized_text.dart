import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as material show Text;

import 'l10n.dart';

export 'l10n.dart' show tr;

/// 数据内容保持原文的作用域：用户消息、任务标题、文件内容等不得随界面
/// 语言切换被改写；界面 chrome 默认仍可翻译。
class L10nScope extends InheritedWidget {
  final bool enabled;
  const L10nScope({super.key, required this.enabled, required super.child});

  static bool of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<L10nScope>()?.enabled ??
        true;
  }

  @override
  bool updateShouldNotify(L10nScope oldWidget) => enabled != oldWidget.enabled;
}

InlineSpan _localizeSpan(InlineSpan span) {
  if (span is! TextSpan) return span;
  // 透传全部构造参数（ P1 P3-11：此前漏 semanticsIdentifier；
  // 本 SDK TextSpan 无 onTap 字段——recognizer/mouseCursor 已覆盖点击语义）。
  return TextSpan(
    text: span.text == null ? null : tr(span.text!),
    children: span.children?.map(_localizeSpan).toList(),
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel == null
        ? null
        : tr(span.semanticsLabel!),
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

/// 与 material.Text 构造参数兼容的本地化文本。常量先保存中文源文案，
/// build 时再翻译，因此现有 const 组件不需要为英文版拆解。
class Text extends StatelessWidget {
  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final double? textScaleFactor;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final ui.TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;
  final bool translate;

  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.translate = true,
  }) : textSpan = null,
       assert(
         textScaler == null || textScaleFactor == null,
         'textScaleFactor cannot be specified with textScaler.',
       );

  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.translate = true,
  }) : data = null,
       assert(
         textScaler == null || textScaleFactor == null,
         'textScaleFactor cannot be specified with textScaler.',
       );

  @override
  Widget build(BuildContext context) {
    // P3 P3-4：显式原文（translate:false，用户内容大量使用）
    // 不订阅语言变更——语言切换时全 app Text 重建的放大只保留给会翻译
    // 的子集（L10nScope 依赖仍注册，作用域翻转照常触发重建）。
    if (!translate) {
      return _buildText(context, enabled: false);
    }
    return ListenableBuilder(
      listenable: L10n.changes,
      builder: (context, _) => _buildText(
        context,
        enabled: L10nScope.of(context),
      ),
    );
  }

  Widget _buildText(BuildContext context, {required bool enabled}) {
    // P2 P3-3/P3 P3-6：key 原样透传会让外层 State element 与
    // 内层 material.Text 同挂一个 GlobalKey（Duplicate keys 运行时异常）
    // ——GlobalKey 只留给外层，本地 key 照常透传（保元素复用语义）。
    final Key? innerKey = key is GlobalKey ? null : key;
    final label = semanticsLabel == null || !enabled
        ? semanticsLabel
        : tr(semanticsLabel!);
    if (data != null) {
      return material.Text(
        enabled ? tr(data!) : data!,
        key: innerKey,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        // ignore: deprecated_member_use
        textScaleFactor: textScaleFactor,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: label,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return material.Text.rich(
      enabled ? _localizeSpan(textSpan!) : textSpan!,
      key: innerKey,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      // ignore: deprecated_member_use
      textScaleFactor: textScaleFactor,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: label,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
