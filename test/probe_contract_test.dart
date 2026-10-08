import 'package:flutter_test/flutter_test.dart';
import '../integration_test/probe_contract.dart';

Map<String, Object> valid(int generation) => {
  'id': 'g$generation-r1',
  'method': 'getIsInit',
  'data': false,
  'code': 0,
  'Port': 0,
};

void main() {
  test('严格接受每代固定五键回包', () {
    expect(acceptsProbeResult(valid(1), 1), isTrue);
    expect(acceptsProbeResult(valid(2), 2), isTrue);
    expect(acceptsProbeResult(valid(1), 2), isFalse);
  });
  test('拒绝缺键、额外键、宽松数值和初始化状态污染', () {
    final missing = valid(1)..remove('Port');
    for (final value in [
      missing,
      {...valid(1), 'extra': 0},
      {...valid(1), 'code': 0.0},
      {...valid(1), 'Port': '0'},
      {...valid(1), 'data': true},
      {...valid(1), 'method': 'initClash'},
      null,
      '原始字符串',
    ]) {
      expect(acceptsProbeResult(value, 1), isFalse);
    }
  });
}
