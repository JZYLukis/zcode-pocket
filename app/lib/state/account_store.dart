import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 多账号凭据存储（2026-10-25 多账号批）：
/// 每账号一组键（`account.<id>.jwt/provider`）+ 有序列表（`account.list`，
/// 首项=最近使用）。旧单账号键（`account.jwt`/`account.provider`）首访问
/// 时迁移为一条账号记录后删除。
///
/// 账号 id 三层推导（18086 真机事故修正）：
/// ①JWT payload 标准 claim（sub/uid/user_id/open_id 首个非空）；
/// ②官方页 `oauth:<provider>:user_info` 的 `id`（UserInfo{id,username,
///   displayName}——与 token 同步写入，登录页收割时顺带读取）；
/// ③内容哈希兜底。
/// 实证：bigmodel 的 zcode JWT **零标准 claim**——18086 前仅有③兜底，
/// save 的"同 provider 唯一兜底账号覆盖"启发式把添加第二账号变成
/// **删除原账号换新账号**（凭据键被清→活跃连接 auth-required→黑屏/
/// 转圈/账号身份错乱全链条）。②落地后同账号重登天然同 id 去重，
/// 该启发式已废除——无身份的兜底形态宁可并存重复也不毁库。
///
/// 实测注（2026-10-21 生产探针）：JWT payload 无 exp 字段——不做本地
/// 预判过期，401（auth-required）是唯一失效信号。
class StoredAccount {
  const StoredAccount({
    required this.id,
    required this.provider,
    this.label = '',
  });
  final String id;
  final String provider;

  /// 本地备注名（multi-account-ux-1 批1，2026-11-04 用户拍板）：如
  /// 「公司订阅」/「个人号」——仅本机存储，不外发不上传。
  final String label;

  /// 显示名（徽标/顶栏统一入口）：备注名优先，未设置回退短码标签。
  String get displayName => label.trim().isEmpty ? shortLabel : label.trim();

  /// UI 短标签（不含敏感信息，可进普通展示）：provider 前 2 + id 前 4。
  String get shortLabel {
    final p = provider.trim();
    final i = id.trim();
    return '${p.isEmpty ? '?' : p.substring(0, p.length < 2 ? p.length : 2)}'
        '·${i.length <= 4 ? i : i.substring(0, 4)}';
  }
}

/// 从 JWT payload 派生稳定账号 id（纯函数供单测）。[identity] 为登录页
/// 收割的官方 user_info.id（无 JWT claim 时它才是区分不同账号的关键）。
String deriveAccountId(String jwt, {String? identity}) {
  String claim() {
    final parts = jwt.split('.');
    if (parts.length != 3) return '';
    try {
      final s = parts[1];
      final normalized = base64Url.decode(
        s.length % 4 == 0 ? s : s + '=' * (4 - s.length % 4),
      );
      final payload = jsonDecode(utf8.decode(normalized));
      if (payload is! Map) return '';
      for (final k in const ['sub', 'uid', 'user_id', 'open_id']) {
        final v = '${payload[k] ?? ''}'.trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  final c = claim();
  if (c.isNotEmpty) return c;
  final ident = identity?.trim() ?? '';
  if (ident.isNotEmpty) return ident;
  // 兜底：FNV 风格内容哈希（无标准 claim 且未收割到 user_info.id 的
  // 形态），16 hex=展示友好且去重足够。
  final bytes = utf8.encode(jwt);
  var h1 = 0xcbf29ce4;
  var h2 = 0x84222325;
  for (final b in bytes) {
    h1 = ((h1 ^ b) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 + b) * 31) & 0xFFFFFFFF;
  }
  // K1-P3-6：逐组件补零——toRadixString 去前导零使两组件在
  // 拼接后边界丢失（不同 (h1,h2) 可拼出同一 id）。注：拼接形态变化对
  // 存量兜底账号会在下次重登时落新条目（"宁可并存重复也不毁库"拍板，
  // 旧条目可手动删）。
  return h1.toRadixString(16).padLeft(8, '0') + h2.toRadixString(16).padLeft(8, '0');
}

class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _legacyJwtKey = 'account.jwt';
  static const _legacyProviderKey = 'account.provider';
  static const _listKey = 'account.list';
  static const _lastKey = 'account.last';
  static const _jwtPrefix = 'account.';
  static const _jwtSuffix = '.jwt';
  static const _providerSuffix = '.provider';

  Future<String?> _read(String k) => _storage.read(key: k);
  Future<void> _write(String k, String v) =>
      _storage.write(key: k, value: v);
  Future<void> _delete(String k) => _storage.delete(key: k);

  Future<void> _migrate() async {
    final legacy = await _read(_legacyJwtKey);
    if (legacy == null || legacy.isEmpty) return;
    final provider = await _read(_legacyProviderKey) ?? 'unknown';
    final id = deriveAccountId(legacy);
    // 迁移幂等：列表已含同 id（迁移中断过）则只补 jwt 键。
    final list = await _readListRaw();
    if (!list.any((a) => a.id == id)) {
      list.insert(0, StoredAccount(id: id, provider: provider));
      await _writeListRaw(list);
    }
    await _write('$_jwtPrefix$id$_jwtSuffix', legacy);
    await _write('$_jwtPrefix$id$_providerSuffix', provider);
    if (list.length == 1) await _write(_lastKey, id);
    await _delete(_legacyJwtKey);
    await _delete(_legacyProviderKey);
  }

  Future<void>? _migrated;

  Future<void> _ensureMigrated() async {
    _migrated ??= _migrate();
    try {
      await _migrated;
    } catch (_) {
      _migrated = null; // 允许下次重试
      rethrow;
    }
  }

  Future<List<StoredAccount>> _readListRaw() async {
    final raw = await _read(_listKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map)
            StoredAccount(
              id: '${e['id'] ?? ''}'.trim(),
              provider: '${e['provider'] ?? 'unknown'}',
              label: '${e['label'] ?? ''}'.trim(),
            ),
      ].where((a) => a.id.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeListRaw(List<StoredAccount> list) => _write(
        _listKey,
        jsonEncode([
          for (final a in list)
            {'id': a.id, 'provider': a.provider, if (a.label.isNotEmpty) 'label': a.label},
        ]),
      );

  // ------------------------------------------------------ B3 串行队列
  // （ K1 P2-1/K2 P2-2）：本 store 的读-改-写此前不经任何
  // 队列——登录页 save 与 auth-required 自动 clearAccount 并发交错可丢
  // 更新/复活已删账号（幽灵条目：列表在、凭据键已删；或孤儿凭据键）。
  // 照搬 ProfileStore._serialized 同款范式；公开方法只包一层，内部互调
  // 走 Raw（重入 _serialized 会自锁——队列尾部在等自己）。
  Future<void> _tail = Future.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    // 尾巴吞错：单个操作失败不阻塞后续排队者；错误由调用方收到。
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  // ------------------------------------------------------------- 公开 API

  /// 账号清单（首项=最近使用）。
  Future<List<StoredAccount>> listAccounts() async {
    await _ensureMigrated();
    return _readListRaw();
  }

  Future<bool> get hasAccount async => (await listAccounts()).isNotEmpty;

  /// 最近保存/最近使用的账号（multi-account-ux-1 批2 配套）：批2 起
  /// save 不再改 lastUsed，「换账号重连」「登录接回」无法再用 lastUsed
  /// 识别"刚登录的账号"——列表首项恰是最近 save/续期的账号（_saveRaw
  /// insert(0)）；空列表即无账号，返回 null（lastUsed 同为空，此前注释
  /// 所称"回退 lastUsed"是死分支）。
  Future<String?> get mostRecentAccountId async {
    final list = await listAccounts();
    return list.isNotEmpty ? list.first.id : null;
  }

  /// 最近使用账号 id（无账号=null）。
  Future<String?> get lastUsedAccountId async {
    await _ensureMigrated();
    final list = await _readListRaw();
    if (list.isEmpty) return null;
    final last = await _read(_lastKey);
    if (last != null && list.any((a) => a.id == last)) return last;
    return list.first.id;
  }

  /// 单账号兼容：读取最近使用账号的 JWT（测试与旧调用面使用）。
  Future<String?> readJwt() => readJwtFor(null);

  /// 设置/清除本地备注名（空串=清除）。不动 lastUsed、不动凭据。
  Future<void> renameAccount(String accountId, String label) =>
      _serialized(() => _renameAccountRaw(accountId, label));

  Future<void> _renameAccountRaw(String accountId, String label) async {
    await _ensureMigrated();
    final list = await _readListRaw();
    final trimmed = label.trim();
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final a = list[i];
      if (a.id != accountId) continue;
      if (a.label == trimmed) return;
      list[i] = StoredAccount(id: a.id, provider: a.provider, label: trimmed);
      changed = true;
      break;
    }
    if (changed) await _writeListRaw(list);
  }

  Future<String?> readJwtFor(String? accountId) async {
    await _ensureMigrated();
    final id = accountId ?? await lastUsedAccountId;
    if (id == null) return null;
    return _read('$_jwtPrefix$id$_jwtSuffix');
  }

  // 单账号兼容层：作用于最近使用账号。
  // （ K1-P3-8：readProvider/readProviderFor 生产零调用方，
  // 死代码已删；readJwt 保留——单账号兼容断言在测试中使用。）

  /// 保存/续期一个账号（同 id 续期：jwt/provider 覆盖、条目同步 provider
  /// 并移回首位——"首项=最近使用"不变式， K1-P3-7/K2-P3-2）；
  /// 设为最近使用。返回账号 id。[identity]=登录页收割的官方 user_info.id
  /// ——bigmodel 的 zcode JWT 零标准 claim，没有它两个不同账号会全部
  /// 落入内容哈希兜底（旧版"同 provider 覆盖"启发式据此把添加第二账号
  /// 变成删 A 换 B，18086 真机事故全链条根因——启发式已废除，同账号
  /// 重登靠 identity 同 id 天然去重）。
  /// [setActive]：是否把该账号设为「当前账号」。
  /// - null（默认，multi-account-ux-1 批2 新语义）：**仅当当前还没有
  ///   lastUsed**（首账号登录）才设——此后添加第二/第三个账号不再静默
  ///   抢走当前账号（旧行为是"加账号=换账号"错觉的主源）；
  /// - true：显式切换（内部/迁移用）；
  /// - false：绝不改 lastUsed（登录页收割用）。
  Future<String> save({
    required String jwt,
    required String provider,
    String? identity,
    bool? setActive,
  }) => _serialized(() => _saveRaw(
        jwt: jwt,
        provider: provider,
        identity: identity,
        setActive: setActive,
      ));

  Future<String> _saveRaw({
    required String jwt,
    required String provider,
    String? identity,
    bool? setActive,
  }) async {
    await _ensureMigrated();
    final id = deriveAccountId(jwt, identity: identity);
    final list = await _readListRaw();
    // K1-P2-2：列表先落、凭据后写（对齐 _migrate 写序）——
    // 此前 jwt 键先落、列表后落，两写之间被杀会留下 clear()/remove
    // Account 都按列表枚举而清不掉的孤儿凭据键（明文 JWT 永久残留）；
    // 反序的中间态（列表有 id 凭据缺）可经重删/重登自愈。
    final existingLabel = list
        .where((a) => a.id == id)
        .map((a) => a.label)
        .fold('', (prev, e) => prev.isEmpty ? e : prev);
    list.removeWhere((a) => a.id == id);
    list.insert(
      0,
      StoredAccount(id: id, provider: provider, label: existingLabel),
    );
    await _writeListRaw(list);
    await _write('$_jwtPrefix$id$_jwtSuffix', jwt);
    await _write('$_jwtPrefix$id$_providerSuffix', provider);
    // 批2：默认不再无脑写 lastUsed——首账号（lastUsed 尚空）才自动设为
    // 当前；setActive=true 强制、false 不切。
    final existingLast = await _read(_lastKey);
    final shouldActivate = setActive ?? (existingLast == null || existingLast.isEmpty);
    if (shouldActivate) await _write(_lastKey, id);
    return id;
  }

  /// 删除一个账号（其凭据键一并清；不动电脑档案——绑定处置归调用方）。
  Future<void> removeAccount(String accountId) =>
      _serialized(() => _removeAccountRaw(accountId));

  Future<void> _removeAccountRaw(String accountId) async {
    await _ensureMigrated();
    final list = await _readListRaw();
    list.removeWhere((a) => a.id == accountId);
    await _delete('$_jwtPrefix$accountId$_jwtSuffix');
    await _delete('$_jwtPrefix$accountId$_providerSuffix');
    await _writeListRaw(list);
    final last = await _read(_lastKey);
    if (last == accountId) {
      await _delete(_lastKey);
      if (list.isNotEmpty) await _write(_lastKey, list.first.id);
    }
  }

  /// 设为最近使用账号（账号管理「设为当前」；配对/设备列表跟随）。
  Future<void> setLastUsed(String accountId) =>
      _serialized(() => _setLastUsedRaw(accountId));

  Future<void> _setLastUsedRaw(String accountId) async {
    await _ensureMigrated();
    final list = await _readListRaw();
    if (!list.any((a) => a.id == accountId)) return;
    await _write(_lastKey, accountId);
    // 列表序=最近使用在前（listAccounts 的展示序随动）。
    final target = list.firstWhere((a) => a.id == accountId);
    list.removeWhere((a) => a.id == accountId);
    list.insert(0, target);
    await _writeListRaw(list);
  }

  //按账号清（auth-required 收窄用）。（K1 P2-3//
  //）：accountId=null **不再**隐式全清——旧契约把"未绑定档案的
  /// 401"放大成清光全部账号凭据（「auth-required 只清失败账号」
  /// 被击穿）；全清回登录门必须显式调 [clear]。null=no-op（调用方
  /// device_stack_registry 侧已回落 lastUsed 精确点名）。
  Future<void> clearAccount(String? accountId) async {
    if (accountId == null) return;
    await removeAccount(accountId);
  }

  /// 全清（回登录门/测试用）。
  Future<void> clear() => _serialized(_clearRaw);

  Future<void> _clearRaw() async {
    _migrated = _migrate(); // 幂等：旧键若仍在先吸收
    // K2-P3-1：迁移失败时复位 _migrated 再抛——残留失败 future
    // 会让下一次访问先吃一次假失败+重试周期。
    try {
      await _migrated;
    } on Object {
      _migrated = null;
      rethrow;
    }
    for (final a in await _readListRaw()) {
      await _delete('$_jwtPrefix${a.id}$_jwtSuffix');
      await _delete('$_jwtPrefix${a.id}$_providerSuffix');
    }
    await _delete(_listKey);
    await _delete(_lastKey);
    await _delete(_legacyJwtKey);
    await _delete(_legacyProviderKey);
    _migrated = null;
  }
}
