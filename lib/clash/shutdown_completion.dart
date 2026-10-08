import 'dart:async';

/// 关闭未确认时保留引擎，确认后等待引擎销毁回执。
Future<bool> completeShutdown({
  required Future<bool> Function() close,
  required FutureOr<bool> Function() destroy,
}) async {
  if (!await close()) return false;
  return await destroy();
}
