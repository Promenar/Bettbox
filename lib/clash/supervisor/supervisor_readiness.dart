// 就绪判断仅供应用请求使用，不授予原生身份或系统代理权限。
Future<bool> awaitSupervisorReady({
  Future<void>? initial,
  required Future<void>? Function() pending,
  required bool Function() ready,
}) async {
  try {
    await initial;
  } catch (_) {}
  while (true) {
    final current = pending();
    if (current == null) break;
    try {
      await current;
    } catch (_) {}
    if (identical(current, pending())) break;
  }
  return ready();
}
