import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/xboard/models.dart';

void main() {
  group('XboardEnvelope.parse', () {
    test('成功包络（M0 实测形态）', () {
      final envelope = XboardEnvelope.parse({
        'status': 'success',
        'message': '操作成功',
        'data': {'token': 't'},
        'error': null,
      });
      expect(envelope.success, isTrue);
      expect(envelope.message, '操作成功');
    });

    test('失败包络', () {
      final envelope = XboardEnvelope.parse({
        'status': 'fail',
        'message': '邮箱验证码有误',
        'data': null,
        'error': null,
      });
      expect(envelope.success, isFalse);
      expect(envelope.message, '邮箱验证码有误');
    });

    test('无 status 变体（order/save 周期错误实测）视为失败', () {
      final envelope = XboardEnvelope.parse({'message': '套餐周期参数有误'});
      expect(envelope.success, isFalse);
      expect(envelope.message, '套餐周期参数有误');
    });

    test('非 Map body 视为失败', () {
      expect(XboardEnvelope.parse('oops').success, isFalse);
    });
  });

  group('XboardAuthResult', () {
    test('M0 实测字段', () {
      final result = XboardAuthResult.fromJson({
        'token': 'abc',
        'auth_data': 'Bearer xyz',
        'is_admin': false,
      });
      expect(result.token, 'abc');
      expect(result.authData, 'Bearer xyz');
      expect(result.isAdmin, isFalse);
    });
  });

  group('XboardUserInfo / XboardSubscribeInfo', () {
    test('user/info 实测字段', () {
      final info = XboardUserInfo.fromJson({
        'email': 'm0tester@cloudbreach.test',
        'transfer_enable': 1073741824,
        'u': 1,
        'd': 2,
        'expired_at': 1788092917,
        'balance': 0,
        'commission_balance': 0,
        'plan_id': 1,
        'uuid': '1957a899',
      });
      expect(info.transferEnable, 1073741824);
      expect(info.planId, 1);
      expect(info.expiredAt, 1788092917);
    });

    test('getSubscribe 实测字段（含嵌套 plan 与 subscribe_url）', () {
      final sub = XboardSubscribeInfo.fromJson({
        'plan_id': 1,
        'token': 'subtoken',
        'expired_at': 1788092917,
        'transfer_enable': 1073741824,
        'speed_limit': 100,
        'next_reset_at': 1788192000,
        'plan': {
          'id': 1,
          'name': '体验套餐',
          'prices': [],
          'show': 1,
          'sell': 0,
          'renew': 0,
          'transfer_enable': 1,
        },
        'subscribe_url': 'https://cloud.example.top:8443/api/v1/client/subscribe?token=subtoken',
        'reset_day': 2,
      });
      expect(sub.token, 'subtoken');
      expect(sub.plan?.name, '体验套餐');
      expect(sub.plan?.sell, isFalse);
      expect(sub.speedLimit, 100);
      expect(sub.subscribeUrl, contains('client/subscribe'));
    });
  });
}
