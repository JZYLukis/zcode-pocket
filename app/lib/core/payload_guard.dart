/// 协议载荷安全读取守卫（批C 组3 铺满方针，单源）。
///
/// 威胁模型（turn_model.dart 2026-10 对抗审查 B2 首立，本批铺满全库
/// build/投影路径）：协议 zod 保证 number，但服务端形态漂移（数字字段
/// 变 String、List 变 Map、字段缺失）时，裸 `as num?`/`as Map?`/
/// `as List?` 强转直接 TypeError——发生在 build 期即整页灰屏（release
/// 无自愈）。统一走本守卫：畸形形态安全兜底（默认值/跳过），正常路径
/// 行为与显示零变化；String 数字（"3"）按形态漂移容忍解析，显示不退档。
///
/// 用法约定：build/投影/解析路径禁止裸强转——
/// - `(v as num?)?.toInt() ?? 0`   → `intOrZero(v)`
/// - `(v as num?)?.toInt()`        → `intOf(v)`
/// - `(v as num?) ?? 0`            → `numOf(v) ?? 0`
/// - `(v as Map?)?.cast<..>()`     → `mapOf(v)`
/// - `(v as List?)`                → `listOf(v)`
/// - `(list as List?)?.cast<String>()` → `listOf(v)?.whereType<String>()`
///   （cast 是懒转换，异常推迟到元素访问处=paint 期崩，禁用）。
library;

/// num 安全读取：num 直取；String 数字（形态漂移）容忍解析；其余 null。
num? numOf(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// [numOf] 的 int 化版（与旧 `(v as num?)?.toInt()` 语义一致，含取整）。
int? intOf(dynamic v) => numOf(v)?.toInt();

/// [intOf] 的 0 兜底版。
int intOrZero(dynamic v) => intOf(v) ?? 0;

/// Map 安全读取：非 Map 返回 null。
/// P3-2（D-8 批4）：不再返回懒 `cast` 视图——键/值类型异常会推迟到访问处
/// （paint/build 期崩溃），与本文件"铺满守卫"的目标相反；`from` 立即转换，
/// 畸形表降级 null。
Map<String, dynamic>? mapOf(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is! Map) return null;
  try {
    return Map<String, dynamic>.from(v);
  } catch (_) {
    return null;
  }
}

/// List 安全读取：非 List 返回 null。
List? listOf(dynamic v) => v is List ? v : null;
