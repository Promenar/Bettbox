import 'dart:convert';

import 'package:bett_box/clash/listener_stop_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只确认同次Go动作成功回执并发送检查式停止动作', () async {
    expect(await confirmListenerStop(requestId: 'public-stop', invoke: (request) async {
      expect(jsonDecode(request), {'id': 'public-stop', 'method': 'stopListener', 'data': null});
      return jsonEncode({'id': 'public-stop', 'method': 'stopListener', 'code': 0, 'data': true, 'Port': 0});
    }), isTrue);
  });

  test('失败、迟到异次、错误方法、缺字段及畸形回执不能确认停止', () async {
    final valid = {'id': 'public-stop', 'method': 'stopListener', 'code': 0, 'data': true};
    final cases = [
      {...valid, 'data': false},
      {...valid, 'id': 'older-stop'},
      {...valid, 'method': 'startListener'},
      {...valid, 'code': -1},
      {...valid, 'code': 0.0},
      {...valid, 'data': 'true'},
      {'id': 'public-stop', 'method': 'stopListener', 'data': true},
      {'code': 0, 'data': true},
      null,
      [],
    ];
    for (final response in cases) {
      expect(await confirmListenerStop(requestId: 'public-stop', invoke: (_) async => jsonEncode(response)), isFalse);
    }
    expect(await confirmListenerStop(requestId: 'public-stop', invoke: (_) async => '公开畸形JSON'), isFalse);
  });

  test('停止传输错误不转换为成功', () async {
    await expectLater(confirmListenerStop(requestId: 'public-stop', invoke: (_) async => throw StateError('公开传输异常')), throwsStateError);
  });
}
