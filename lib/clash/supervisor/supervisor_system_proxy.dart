import 'supervisor_codec.dart';

const _maximumChannelInteger = 0x7fffffffffffffff;

Map<String, dynamic> _object(Object? raw, Set<String> fields) {
  if (raw is! Map ||
      raw.length != fields.length ||
      !raw.keys.every(fields.contains)) {
    throw protocolFailure;
  }
  return Map<String, dynamic>.from(raw);
}

int _integer(
  Object? raw, {
  int minimum = 0,
  int maximum = _maximumChannelInteger,
}) {
  if (raw is! int || raw < minimum || raw > maximum) throw protocolFailure;
  return raw;
}

// 回包值只描述可信会话的专用入口；不能代替原生Ticket/proof授权。
final class OwnedHttpEndpoint {
  const OwnedHttpEndpoint._(this.generation, this.listenerEpoch, this.port);

  factory OwnedHttpEndpoint.fromReply(Object? raw, {required int generation}) {
    final value = _object(raw, {
      'generation',
      'listenerEpoch',
      'host',
      'port',
      'state',
    });
    final actualGeneration = _integer(value['generation'], minimum: 1);
    if (actualGeneration != generation ||
        value['host'] != '127.0.0.1' ||
        value['state'] != 'active') {
      throw protocolFailure;
    }
    return OwnedHttpEndpoint._(
      actualGeneration,
      _integer(value['listenerEpoch'], minimum: 1),
      _integer(value['port'], minimum: 1, maximum: 65535),
    );
  }

  final int generation;
  final int listenerEpoch;
  final int port;

  Map<String, Object> toNativeArguments() => {
    'generation': generation,
    'listenerEpoch': listenerEpoch,
    'host': '127.0.0.1',
    'port': port,
    'state': 'active',
  };
}

enum SystemProxyStatus {
  idle,
  applied,
  restored,
  cancelled,
  conflict,
  permissionDenied,
  busy,
  invalidInput,
  noServices,
  unsupportedAuthenticatedProxy,
  unsupportedSOCKSProxy,
  failedRolledBack,
  recoveryRequired,
}

final class SystemProxyResult {
  const SystemProxyResult._(
    this.status,
    this.transactionGeneration,
    this.changedGroups,
    this.unresolvedGroups,
  );

  factory SystemProxyResult.fromReply(Object? raw) {
    final value = _object(raw, {
      'status',
      'transactionGeneration',
      'changedGroups',
      'unresolvedGroups',
    });
    final status = SystemProxyStatus.values
        .where((candidate) => candidate.name == value['status'])
        .firstOrNull;
    if (status == null) throw protocolFailure;
    return SystemProxyResult._(
      status,
      _integer(value['transactionGeneration']),
      _integer(value['changedGroups'], maximum: 1536),
      _integer(value['unresolvedGroups'], maximum: 1536),
    );
  }

  final SystemProxyStatus status;
  final int transactionGeneration;
  final int changedGroups;
  final int unresolvedGroups;

  // 仅明确恢复/无记录允许释放入口；取消或失败不是恢复完成证据。
  bool get permitsEndpointRelease =>
      (status == SystemProxyStatus.idle ||
          status == SystemProxyStatus.restored) &&
      unresolvedGroups == 0;
}
