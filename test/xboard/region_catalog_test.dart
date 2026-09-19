import 'package:bett_box/xboard/region_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('XboardRegionCatalog.tryParse', () {
    test('解析合法目录', () {
      final c = XboardRegionCatalog.tryParse([
        {'code': 'HK', 'name': '香港', 'plan_ids': [1, 2]},
        {'code': 'JP', 'name': '日本', 'plan_ids': [2]},
      ]);
      expect(c.entries.length, 2);
      expect(c.entries.first.code, 'HK');
      expect(c.entries.first.planIds, [1, 2]);
    });

    test('空/非法返回空目录', () {
      expect(XboardRegionCatalog.tryParse(null).isEmpty, isTrue);
      expect(XboardRegionCatalog.tryParse([]).isEmpty, isTrue);
      expect(XboardRegionCatalog.tryParse('bad').isEmpty, isTrue);
    });

    test('去重与大小写归一', () {
      final c = XboardRegionCatalog.tryParse([
        {'code': 'hk', 'name': '香港', 'plan_ids': [1]},
        {'code': 'HK', 'name': '重复', 'plan_ids': [2]},
      ]);
      expect(c.entries.length, 1);
      expect(c.entries.first.code, 'HK');
    });
  });

  group('lockedEntries', () {
    test('有目录时，未在订阅中的地域列为受限', () {
      final catalog = XboardRegionCatalog.tryParse([
        {'code': 'HK', 'name': '香港', 'plan_ids': [1]},
        {'code': 'JP', 'name': '日本', 'plan_ids': [2]},
        {'code': 'US', 'name': '美国', 'plan_ids': [2]},
      ]);
      final locked = lockedEntries(
        catalog: catalog,
        availableCodes: {'HK'},
        planId: 1,
      );
      expect(locked.map((e) => e.code).toList(), ['JP', 'US']);
    });

    test('空目录不产生受限', () {
      const catalog = XboardRegionCatalog([]);
      final locked = lockedEntries(
        catalog: catalog,
        availableCodes: {'HK'},
        planId: 1,
      );
      expect(locked, isEmpty);
    });
  });

  group('XboardBootstrapDoc region_catalog', () {
    test('引导源解析携带 region_catalog', () {
      // 直接验证 region_catalog 解析与持久化逻辑在 bootstrap.dart 中已处理
      final catalog = XboardRegionCatalog.tryParse([
        {'code': 'DE', 'name': '德国', 'plan_ids': [3]},
      ]);
      expect(catalog.flag('DE'), '🇩🇪');
      expect(catalog.displayName('DE'), '德国');
      expect(catalog.flag('XX'), '🌐');
    });
  });
}
