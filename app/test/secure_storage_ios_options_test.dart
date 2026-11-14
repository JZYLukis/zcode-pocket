// secure storage iOS Keychain 定档守卫（ios-adaptation-3）：三个存储
// 构造点（account/profile/ui_prefs）必须统一带
// first_unlock_this_device（可读性=首次解锁后，E 批通知场景不因锁屏读
// 挂；this_device=条目不随 iCloud/迁移恢复到其他设备，对齐
// allowBackup=false 口径）。静态源码断言（channel_contract 同族先例）——
// 运行时行为在 iOS 模拟器集成测试覆盖。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const stores = [
    'lib/state/account_store.dart',
    'lib/state/profile_store.dart',
    'lib/state/ui_prefs.dart',
  ];

  test('三个存储默认构造均带 first_unlock_this_device', () {
    for (final path in stores) {
      final src = File(path).readAsStringSync();
      expect(
        src.contains('KeychainAccessibility.first_unlock_this_device'),
        isTrue,
        reason: '$path 缺 iOS Keychain 定档——新增存储点须同档（防跨设备'
            '备份恢复与锁屏读挂）',
      );
    }
  });

  test('全库无裸 FlutterSecureStorage() 默认构造（新点必须带 iOptions）', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      expect(
        src.contains('const FlutterSecureStorage()'),
        isFalse,
        reason: '${entity.path} 存在裸构造——iOS 将落到默认 accessibility'
            '（unlocked）且可随备份迁移，与定档不一致',
      );
    }
  });
}
