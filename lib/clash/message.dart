import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/foundation.dart';
import 'supervisor/supervisor_events.dart';
import 'supervisor/supervisor_codec.dart';

class ClashMessage {
  final controller = StreamController<Map<String, Object?>>.broadcast();

  ClashMessage._() {
    controller.stream.listen((message) {
      dispatch(message);
    });
  }

  // macOS专用通道同步消费事件，避免额外异步队列持有原始载荷。
  SupervisorEventBatch dispatch(Map<String, Object?> message) {
    if (message.isEmpty) return SupervisorEventBatch(const []);
    final m = AppMessage.fromJson(message);
    final work = <Future<void>>[];
    for (final listener in _listeners.toList()) {
      try {
        final task = switch (m.type) {
          AppMessageType.log => listener.onLog(Log.fromJson(m.data)),
          AppMessageType.delay => listener.onDelay(Delay.fromJson(m.data)),
          AppMessageType.request => listener.onRequest(
            TrackerInfo.fromJson(m.data),
          ),
          AppMessageType.loaded => listener.onLoaded(m.data),
        };
        if (task is Future<void>) work.add(task);
      } catch (_) {
        work.add(Future<void>.error(const SupervisorFailure('事件监听器拒绝')));
        break;
      }
    }
    return SupervisorEventBatch(work);
  }

  static final ClashMessage instance = ClashMessage._();

  final ObserverList<AppMessageListener> _listeners =
      ObserverList<AppMessageListener>();

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void addListener(AppMessageListener listener) {
    if (_listeners.length >= 32) throw const SupervisorFailure('事件监听器已满');
    _listeners.add(listener);
  }

  void removeListener(AppMessageListener listener) {
    _listeners.remove(listener);
  }
}

final clashMessage = ClashMessage.instance;
