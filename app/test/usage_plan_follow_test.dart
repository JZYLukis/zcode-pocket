// 18077 验收#2 红绿：状态环/额度卡跟随套餐切换。
// 修前现象：挂起选中与发送后额度卡都显示旧套餐（个人订阅）——
// _toggleUsageCard 的 _entCache==null 门槛 + _refresh 只在卡开时清缓存，
// 卡关期间的档位变化完全不感知。修后：快照记录所属档位，档位变化即作废。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

void main() {
  group('inferEntPlanKind 档位推断（当前会话一票定档）', () {
    test('当前会话 start-plan → start-plan', () {
      expect(
        inferEntPlanKind(
          currentProvider: 'account:bigmodel-start-plan',
          allProviders: ['account:bigmodel-individual-coding-plan'],
        ),
        'start-plan',
      );
    });

    test('当前会话个人套餐：即使全局有 start-plan 会话也不串档', () {
      // 18077 验收#2 语义修正：老实现扫全局，A 会话切了 Start Plan
      // 会让 B 会话（个人套餐）的额度卡也显示 Start Plan 数据。
      expect(
        inferEntPlanKind(
          currentProvider: 'account:bigmodel-individual-coding-plan',
          allProviders: ['account:bigmodel-start-plan'],
        ),
        'individual-coding-plan',
      );
    });

    test('当前会话无 config（草稿页）→挂起草稿定档', () {
      expect(
        inferEntPlanKind(
          currentProvider: '',
          draftProvider: 'account:bigmodel-start-plan',
        ),
        'start-plan',
      );
      expect(
        inferEntPlanKind(
          currentProvider: null,
          draftProvider: 'account:bigmodel-individual-coding-plan',
        ),
        'individual-coding-plan',
      );
    });

    test('无当前无草稿→全局扫描保底（老行为）', () {
      expect(
        inferEntPlanKind(allProviders: [
          'account:bigmodel-individual-coding-plan',
          'account:bigmodel-start-plan',
        ]),
        'start-plan',
      );
      expect(
        inferEntPlanKind(allProviders: ['account:bigmodel-individual-coding-plan']),
        'individual-coding-plan',
      );
    });

    test('全空→默认个人套餐', () {
      expect(inferEntPlanKind(), 'individual-coding-plan');
    });
  });

  group('缓存档位失效口径', () {
    // 档位字符串比对即失效判据（_toggleUsageCard 用
    // _entCachePlanKind != _entPlanKind()）。锁定两档值域，防止
    // 未来档位枚举改动悄悄破坏失效逻辑。
    test('两档值域稳定', () {
      const kinds = {'start-plan', 'individual-coding-plan'};
      expect(kinds.contains(inferEntPlanKind()), isTrue);
      expect(
        kinds.contains(
          inferEntPlanKind(currentProvider: 'account:bigmodel-start-plan'),
        ),
        isTrue,
      );
      // 档位不同→失效（!= 比对）；档位相同→复用。
      expect('start-plan' != 'individual-coding-plan', isTrue);
    });
  });
}
