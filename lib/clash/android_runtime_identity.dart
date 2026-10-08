import 'dart:convert';

/// 比对真实FFI动作与JNI状态的公开实例身份；不确认配置或VPN启动完成。
Future<bool> confirmAndroidRuntimeIdentity({
  required String requestId,
  required Future<String> Function(String) invokeGo,
  required Future<bool?> Function(int) invokeNative,
  Duration timeout = const Duration(seconds: 5),
}) async {
  const method = 'getAndroidOwnedConfigStatus';
  const maxEpoch = 9007199254740991;
  final clock = Stopwatch()..start();
  final budget = timeout;
  if (budget <= Duration.zero) return false;
  try {
    final response = await invokeGo(
      jsonEncode({'id': requestId, 'method': method, 'data': null}),
    ).timeout(budget);
    if (response.length > 17 * 1024 * 1024) return false;
    final frame = jsonDecode(response);
    if (frame is! Map<String, dynamic> ||
        frame['id'] != requestId ||
        frame['method'] != method ||
        frame['code'] is! int ||
        frame['code'] != 0 ||
        frame['data'] is! String) {
      return false;
    }
    final status = jsonDecode(frame['data'] as String);
    if (status is! Map<String, dynamic> ||
        status['blocked'] != false ||
        !const ['applied', 'staged', 'rejected'].contains(status['outcome'])) {
      return false;
    }
    final epoch = status['epoch'];
    if (epoch is! int || epoch <= 1 || epoch > maxEpoch) return false;
    final remaining = budget - clock.elapsed;
    if (remaining <= Duration.zero) return false;
    return await invokeNative(epoch).timeout(remaining) == true;
  } catch (_) {
    return false;
  }
}
