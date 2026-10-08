import 'dart:convert';

/// 只接受同次检查式启动动作的明确成功回执，不代表VPN完成。
Future<bool> confirmListenerStart({
  required String requestId,
  required Future<String> Function(String) invoke,
}) => _confirmListenerAction(
  requestId: requestId,
  method: 'startListener',
  invoke: invoke,
);

/// 只接受同次检查式停止动作的明确成功回执。
Future<bool> confirmListenerStop({
  required String requestId,
  required Future<String> Function(String) invoke,
}) => _confirmListenerAction(
  requestId: requestId,
  method: 'stopListener',
  invoke: invoke,
);

Future<bool> _confirmListenerAction({
  required String requestId,
  required String method,
  required Future<String> Function(String) invoke,
}) async {
  final response = await invoke(
    jsonEncode({'id': requestId, 'method': method, 'data': null}),
  );
  try {
    final result = jsonDecode(response);
    return result is Map<String, dynamic> &&
        result['id'] == requestId &&
        result['method'] == method &&
        result['code'] is int &&
        result['code'] == 0 &&
        result['data'] == true;
  } on FormatException {
    return false;
  }
}
