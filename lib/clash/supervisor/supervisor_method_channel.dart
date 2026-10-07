import 'package:flutter/services.dart';
import 'supervisor_native.dart';

class MethodChannelSupervisorNative implements SupervisorNative {
  const MethodChannelSupervisorNative();
  static const channel = MethodChannel('bettbox/core_supervisor');
  @override
  Future<Object?> call(String method, Map<String, Object> arguments) =>
      channel.invokeMethod<Object?>(method, arguments);
}
