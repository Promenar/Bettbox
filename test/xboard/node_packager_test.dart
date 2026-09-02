import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/xboard/node_packager.dart';

void main() {
  group('resolveRegion', () {
    test('emoji 旗帜 / 中文 / 缩写均可识别', () {
      expect(resolveRegion('🇭🇰 香港 IEPL 01')?.regionCode, 'HK');
      expect(resolveRegion('香港 02')?.regionCode, 'HK');
      expect(resolveRegion('HK-IPLC-03')?.regionCode, 'HK');
      expect(resolveRegion('JP 东京 BGP')?.regionCode, 'JP');
      expect(resolveRegion('🇸🇬 狮城 专线')?.regionCode, 'SG');
      expect(resolveRegion('美国 Los Angeles 01')?.regionCode, 'US');
      expect(resolveRegion('台湾 Hinet')?.regionCode, 'TW');
      expect(resolveRegion('Korea Seoul')?.regionCode, 'KR');
    });

    test('长尾地区（含上游常见单节点国家）可识别', () {
      expect(resolveRegion('🇵🇭 菲律宾 01')?.regionCode, 'PH');
      expect(resolveRegion('🇹🇷 土耳其 01')?.regionCode, 'TR');
      expect(resolveRegion('🇷🇺 俄罗斯 01')?.regionCode, 'RU');
      expect(resolveRegion('🇺🇦 乌克兰 01')?.regionCode, 'UA');
      expect(resolveRegion('🇨🇭 瑞士 01')?.regionCode, 'CH');
      expect(resolveRegion('🇦🇪 阿联酋 01')?.regionCode, 'AE');
      expect(resolveRegion('🇳🇬 尼日利亚 01')?.regionCode, 'NG');
      expect(resolveRegion('🇿🇦 南非 01')?.regionCode, 'ZA');
      expect(resolveRegion('🇮🇶 伊拉克 01')?.regionCode, 'IQ');
      expect(resolveRegion('🇨🇦 加拿大 01')?.regionCode, 'CA');
      // 无地区语义的节点名归入兜底
      expect(resolveRegion('🦥 懒人 01A'), isNull);
    });

    test('缩写不误伤普通单词', () {
      // "SHOULD"/"HOUSE" 这类含 US/HK 字母串不应命中
      expect(resolveRegion('House Node')?.regionCode, isNot('US'));
      expect(resolveRegion('unknown-region-xyz'), isNull);
    });
  });

  group('packageNodes', () {
    final proxies = [
      {'name': '香港 IEPL 01', 'type': 'ss', 'server': '1.1.1.1'},
      {'name': 'HK BGP 02', 'type': 'ss', 'server': '1.1.1.2'},
      {'name': '🇯🇵 日本 01', 'type': 'ss', 'server': '1.1.1.3'},
      {'name': 'US Los Angeles 01', 'type': 'ss', 'server': '1.1.1.4'},
      {'name': '神秘节点', 'type': 'ss', 'server': '1.1.1.5'},
    ];

    test('生成地域组与顶层选择器', () {
      final result = packageNodes({'proxies': proxies})!;
      final groupNames = result.proxyGroups.map((g) => g['name']).toList();
      expect(groupNames[0], kAutoRegionGroupName);
      expect(groupNames[1], kSelectorGroupName);
      expect(groupNames, contains('🇭🇰 香港 HK'));
      expect(groupNames, contains('🇯🇵 日本 JP'));
      expect(groupNames, contains('🇺🇸 美国 US'));
      expect(groupNames, contains('🌐 优选'));
    });

    test('节点名脱敏为地域代号-序号，且保留原始名映射', () {
      final result = packageNodes({'proxies': proxies})!;
      final names = result.proxies.map((p) => p['name']).toList();
      expect(names, contains('HK-01'));
      expect(names, contains('HK-02'));
      expect(names, contains('JP-01'));
      expect(names, contains('US-01'));
      expect(names, contains('XX-01'));
      expect(names.every((n) => !n.toString().contains('IEPL')), isTrue);
      expect(result.groupOf['香港 IEPL 01'], 'HK-01');
      // 自动组聚合各地域组
      final auto = result.proxyGroups.first;
      expect((auto['proxies'] as List).length, 4, reason: 'HK/JP/US/XX 四个地域组');
      final selector = result.proxyGroups[1];
      expect((selector['proxies'] as List).first, kAutoRegionGroupName);
    });

    test('空 proxies 返回 null', () {
      expect(packageNodes({'proxies': []}), isNull);
      expect(packageNodes({}), isNull);
    });
  });

group('regionStatusForDelay', () {
  test('F-NODE-2 档位映射', () {
    expect(regionStatusForDelay(null), XboardRegionStatus.congested);
    expect(regionStatusForDelay(0), XboardRegionStatus.congested);
    expect(regionStatusForDelay(-1), XboardRegionStatus.congested);
    expect(regionStatusForDelay(45), XboardRegionStatus.fluent);
    expect(regionStatusForDelay(149), XboardRegionStatus.fluent);
    expect(regionStatusForDelay(150), XboardRegionStatus.normal);
    expect(regionStatusForDelay(399), XboardRegionStatus.normal);
    expect(regionStatusForDelay(400), XboardRegionStatus.congested);
    expect(regionStatusForDelay(1200), XboardRegionStatus.congested);
  });
});
}
