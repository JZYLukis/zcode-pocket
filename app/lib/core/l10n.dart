import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

part 'official_l10n.g.dart';
part 'custom_l10n.dart';

class _L10nPattern {
  final RegExp source;
  final String target;
  final Map<String, int> groups;
  const _L10nPattern(this.source, this.target, this.groups);

  /// 占位符提取正则提为编译期常量：
  /// 原先每次 apply 现场构造，EN 模式热路径上每条 pattern 各造一个。
  static final RegExp _placeholder = RegExp(r'\{(\w+)\}');

  String? apply(String input) {
    final match = source.firstMatch(input);
    if (match == null) return null;
    return target.replaceAllMapped(_placeholder, (placeholder) {
      final index = groups[placeholder[1]];
      if (index == null || index > match.groupCount) return placeholder[0]!;
      return match.group(index) ?? '';
    });
  }
}

/// 全应用运行时本地化。官方 en-US 为标准术语；手机特有文案单独审校。
class L10n {
  L10n._();

  static String _preference = 'system';
  static String _resolved = 'zh-CN';
  static String Function()? _preferenceReader;
  static String Function()? _systemLocaleReader;
  static VoidCallback? _listener;
  static Listenable? _attached;
  static final _missing = <String>{};
  static final _changes = ValueNotifier<String>('zh-CN');

  static ValueListenable<String> get changes => _changes;

  /// 测试与英文渲染扫描使用；生产默认关闭，避免重复日志。
  static bool collectMissing = false;

  static String get resolvedLocale => _resolved;
  static String get localePreference => _preference;
  static Locale get flutterLocale => _resolved == 'en-US'
      ? const Locale('en', 'US')
      : const Locale('zh', 'CN');
  static Set<String> get missingTranslations => Set.unmodifiable(_missing);

  static void attach({
    required Listenable listenable,
    required String Function() preference,
    required String Function() systemLocale,
  }) {
    detach();
    _attached = listenable;
    _preferenceReader = preference;
    _systemLocaleReader = systemLocale;
    _listener = refresh;
    listenable.addListener(_listener!);
    refresh();
  }

  static void detach() {
    final attached = _attached;
    final listener = _listener;
    if (attached != null && listener != null) {
      attached.removeListener(listener);
    }
    _attached = null;
    _listener = null;
    _preferenceReader = null;
    _systemLocaleReader = null;
  }

  static void refresh() {
    _preference = _preferenceReader?.call() ?? 'system';
    final system = _systemLocaleReader?.call() ?? 'zh-CN';
    _setResolved(switch (_preference) {
      'zh-CN' => 'zh-CN',
      'en-US' => 'en-US',
      _ => system.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en-US',
    });
  }

  static void _setResolved(String locale) {
    if (_resolved == locale) return;
    _resolved = locale;
    // 译文缓存随 locale 整体失效（结果与 locale 绑定，见 tr 注释）。
    _trCache.clear();
    _changes.value = locale;
  }

  static void setTestLocale(String locale) {
    _preference = locale;
    _setResolved(locale);
  }

  static void resetForTest() {
    detach();
    _preference = 'system';
    _setResolved('zh-CN');
    _missing.clear();
    _trCache.clear();
    collectMissing = false;
  }
}

/// CJK 判定：域含 CJK 扩展 A/B 区（\u3400-\u9fff）+
/// CJK 标点（\u3000-\u303F）+ 兼容表意（\uF900-\uFAFF）+ 全角形式
/// （\uFF00-\uFFEF）——纯标点/全角符号串也进入翻译查找（命中词表则译，
/// 未命中保持原文，行为不劣化）。正则提为编译期常量（EN 模式下每个
/// Text build 至少调用一次，原先每次现场构造）。
final RegExp _cjkRe = RegExp(r'[\u3000-\u9fff\uF900-\uFAFF\uFF00-\uFFEF]');

bool hasCjk(String text) => _cjkRe.hasMatch(text);

final RegExp _trailingZerosRe = RegExp(r'\.?0+$');

String _trimNumber(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceAll(_trailingZerosRe, '');
}

String _compactEnglishNumber(double value) {
  // 压缩后复检进位：999999/1000=999.999 →
  // toStringAsFixed(2)="1000.00" → 原实现输出 "1000K" 而非 "1M"。
  // 该分支 value<1000000，商四舍五入到 "1000" 只发生在 999995+ 的进位
  // 边界——命中即升上一档。
  if (value >= 1000000000) return '${_trimNumber(value / 1000000000)}B';
  if (value >= 1000000) {
    final m = _trimNumber(value / 1000000);
    return m == '1000' ? '${_trimNumber(value / 1000000000)}B' : '${m}M';
  }
  if (value >= 1000) {
    final k = _trimNumber(value / 1000);
    return k == '1000' ? '${_trimNumber(value / 1000000)}M' : '${k}K';
  }
  return value.round().toString();
}

final RegExp _wanRe = RegExp(r'^(\d+(?:\.\d+)?)万$');
final RegExp _yiRe = RegExp(r'^(\d+(?:\.\d+)?)亿$');
final RegExp _shortDateRe = RegExp(r'^(\d{1,2})月(\d{1,2})日$');
final RegExp _fullDateRe = RegExp(r'^(\d{4})年(\d{1,2})月(\d{1,2})日$');

String? _englishUnitsAndDates(String source) {
  final wan = _wanRe.firstMatch(source);
  if (wan != null) {
    return _compactEnglishNumber(double.parse(wan[1]!) * 10000);
  }
  final yi = _yiRe.firstMatch(source);
  if (yi != null) {
    return _compactEnglishNumber(double.parse(yi[1]!) * 100000000);
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final shortDate = _shortDateRe.firstMatch(source);
  if (shortDate != null) {
    final month = int.parse(shortDate[1]!);
    if (month >= 1 && month <= 12) {
      return '${months[month - 1]} ${int.parse(shortDate[2]!)}';
    }
  }
  final fullDate = _fullDateRe.firstMatch(source);
  if (fullDate != null) {
    final month = int.parse(fullDate[2]!);
    if (month >= 1 && month <= 12) {
      return '${months[month - 1]} ${int.parse(fullDate[3]!)}, ${fullDate[1]}';
    }
  }
  return null;
}

/// 译文结果缓存：tr 的结果完全由
/// (source, locale) 决定，但每个 Text 的每次 build 都会重调——未命中
/// 词条要重扫 67 条 custom + 760 条 official 正则（滚动列表上每帧重复）。
/// 命中即查表；locale 切换时随 _setResolved 整体清空。
final Map<String, String> _trCache = {};

String tr(String source) {
  if (L10n.resolvedLocale != 'en-US' || source.isEmpty || !hasCjk(source)) {
    return source;
  }
  final cached = _trCache[source];
  if (cached != null) return cached;
  final result = _resolveEn(source);
  // （批5）：无界缓存（动态错误串/插值句持续累积）——到上限
  // 整体清空，词典命中率不受影响。
  if (_trCache.length >= 4096) _trCache.clear();
  _trCache[source] = result;
  return result;
}

String _resolveEn(String source) {
  final custom = _customEn[source];
  if (custom != null) return custom;
  final official = _officialEn[source];
  if (official != null) return official;
  final formatted = _englishUnitsAndDates(source);
  if (formatted != null) return formatted;
  for (final pattern in _customPatterns) {
    final translated = pattern.apply(source);
    if (translated != null) return translated;
  }
  for (final pattern in _officialPatterns) {
    final translated = pattern.apply(source);
    if (translated != null) return translated;
  }
  if (L10n.collectMissing && L10n._missing.add(source)) {
    debugPrint('[l10n] missing: $source');
  }
  return source;
}
