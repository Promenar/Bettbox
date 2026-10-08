import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'package:bett_box/clash/supervisor/supervisor_system_proxy.dart';

Map<String, Object> endpoint() => {
  'generation': 7,
  'listenerEpoch': 3,
  'host': '127.0.0.1',
  'port': 7890,
  'state': 'active',
};

Map<String, Object> result(String status) => {
  'status': status,
  'transactionGeneration': 9,
  'changedGroups': 2,
  'unresolvedGroups': 0,
};

void main() {
  test('专用入口保留Core代次并仅输出固定loopback字段', () {
    final value = OwnedHttpEndpoint.fromReply(endpoint(), generation: 7);
    expect(value.toNativeArguments(), endpoint());
    expect(value.listenerEpoch, 3);
  });

  test('旧代或任意地址不能变成专用入口', () {
    for (final change in [
      {'generation': 6},
      {'host': 'localhost'},
      {'host': '::1'},
      {'host': 'proxy.example'},
      {'state': 'stopped'},
      {'listenerEpoch': 0},
      {'port': 0},
      {'port': 65536},
      {'port': true},
      {'port': 7890.0},
      {'listenerEpoch': -1},
      {'extra': 'ignored'},
    ]) {
      expect(
        () => OwnedHttpEndpoint.fromReply({
          ...endpoint(),
          ...change,
        }, generation: 7),
        throwsA(isA<SupervisorFailure>()),
      );
    }
  });

  test('入口缺失字段和非字典拒绝', () {
    for (final field in endpoint().keys) {
      final incomplete = endpoint()..remove(field);
      expect(
        () => OwnedHttpEndpoint.fromReply(incomplete, generation: 7),
        throwsA(isA<SupervisorFailure>()),
      );
    }
    expect(
      () => OwnedHttpEndpoint.fromReply([], generation: 7),
      throwsA(isA<SupervisorFailure>()),
    );
  });

  test('取消、回滚和未知状态不许可释放endpoint', () {
    for (final status in SystemProxyStatus.values) {
      final value = SystemProxyResult.fromReply(result(status.name));
      expect(value.transactionGeneration, 9);
      expect(
        value.permitsEndpointRelease,
        status == SystemProxyStatus.idle ||
            status == SystemProxyStatus.restored,
      );
    }
    expect(
      SystemProxyResult.fromReply({
        ...result('restored'),
        'unresolvedGroups': 1,
      }).permitsEndpointRelease,
      false,
    );
  });

  test('恢复回执拒绝未知枚举、额外字段和非整数', () {
    for (final change in [
      {'status': 'success'},
      {'transactionGeneration': true},
      {'transactionGeneration': 1.0},
      {'transactionGeneration': -1},
      {'changedGroups': 1537},
      {'unresolvedGroups': -1},
      {'extra': true},
    ]) {
      expect(
        () => SystemProxyResult.fromReply({...result('idle'), ...change}),
        throwsA(isA<SupervisorFailure>()),
      );
    }
  });
}
