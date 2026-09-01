/// 账号与用户态仓储（F-AUTH / F-SUB P0 数据访问层）。
library;

import 'api_client.dart';
import 'endpoints.dart';
import 'order_models.dart';
import 'models.dart';

class XboardGuestRepository {
  XboardGuestRepository(this._client);

  final XboardApiClient _client;

  /// 商店套餐列表（免登录；sell=false 的体验套餐服务端已过滤）。
  Future<List<XboardPlan>> plans() async {
    final data = await _client.get<List<dynamic>>(
      XboardEndpoints.guestPlanFetch,
      parse: (data) => data as List<dynamic>,
    );
    return (data ?? [])
        .whereType<Map<String, dynamic>>()
        .map(XboardPlan.fromJson)
        .toList();
  }

  /// 面板公共配置（域名健康探测也复用此端点）。
  Future<void> commConfig() async {
    await _client.get<dynamic>(XboardEndpoints.guestCommConfig);
  }
}

class XboardOrderRepository {
  XboardOrderRepository(this._client);

  final XboardApiClient _client;

  Future<List<XboardPaymentMethod>> getPaymentMethods() async {
    final data = await _client.get<List<dynamic>>(
      XboardEndpoints.orderGetPaymentMethod,
      parse: (data) => data as List<dynamic>,
    );
    return (data ?? [])
        .whereType<Map<String, dynamic>>()
        .map(XboardPaymentMethod.fromJson)
        .toList();
  }

  /// 下单，返回 trade_no。
  ///
  /// 响应 data 形态随部署版本而异：新版为对象 `{trade_no}`，
  /// 部分发布版直接为字符串 trade_no（实测）——两种都兼容。
  Future<String> saveOrder({
    required int planId,
    required String period,
    String? couponCode,
  }) async {
    final data = await _client.post<Map<String, dynamic>>(
      XboardEndpoints.orderSave,
      body: {
        'plan_id': planId,
        'period': period,
        if (couponCode != null && couponCode.isNotEmpty) 'coupon_code': couponCode,
      },
      parse: (data) {
        if (data is Map<String, dynamic>) {
          return data;
        }
        return {'trade_no': data?.toString() ?? ''};
      },
    );
    return data!['trade_no'] as String;
  }

  /// 收银：0=二维码内容 / 1=跳转URL / -1=免费单已支付。
  Future<XboardCheckoutResult> checkout({
    required String tradeNo,
    required int method,
  }) async {
    final data = await _client.post<Map<String, dynamic>>(
      XboardEndpoints.orderCheckout,
      body: {'trade_no': tradeNo, 'method': method},
      parse: (data) => Map<String, dynamic>.from(data as Map),
    );
    return XboardCheckoutResult.fromJson(data!);
  }

  Future<XboardOrderCheckResult> checkOrder(String tradeNo) async {
    final data = await _client.get<dynamic>(
      XboardEndpoints.orderCheck,
      query: {'trade_no': tradeNo},
      parse: (data) => data,
    );
    return XboardOrderCheckResult.fromJson(data);
  }

  Future<List<XboardOrder>> fetchOrders() async {
    final data = await _client.get<List<dynamic>>(
      XboardEndpoints.orderFetch,
      parse: (data) => data as List<dynamic>,
    );
    return (data ?? [])
        .whereType<Map<String, dynamic>>()
        .map(XboardOrder.fromJson)
        .toList();
  }

  Future<void> cancelOrder(String tradeNo) async {
    await _client.post<void>(
      XboardEndpoints.orderCancel,
      body: {'trade_no': tradeNo},
    );
  }
}

class XboardAuthRepository {
  XboardAuthRepository(this._client);

  final XboardApiClient _client;

  /// 发送邮箱验证码（60s 限频由服务端控制，见 PRD §5.3）。
  Future<void> sendEmailVerify(String email) async {
    await _client.post<void>(XboardEndpoints.sendEmailVerify, body: {'email': email});
  }

  /// 注册（email_verify 开启时 [emailCode] 必填；invite_force 关闭时 [inviteCode] 可空）。
  Future<XboardAuthResult> register({
    required String email,
    required String password,
    required String emailCode,
    String? inviteCode,
  }) async {
    final data = await _client.post<Map<String, dynamic>>(
      XboardEndpoints.register,
      body: {
        'email': email,
        'password': password,
        'email_code': emailCode,
        if (inviteCode != null && inviteCode.isNotEmpty) 'invite_code': inviteCode,
      },
      parse: (data) => Map<String, dynamic>.from(data as Map),
    );
    return XboardAuthResult.fromJson(data!);
  }

  Future<XboardAuthResult> login({
    required String email,
    required String password,
  }) async {
    final data = await _client.post<Map<String, dynamic>>(
      XboardEndpoints.login,
      body: {'email': email, 'password': password},
      parse: (data) => Map<String, dynamic>.from(data as Map),
    );
    return XboardAuthResult.fromJson(data!);
  }

  /// 找回密码（email_verify 开启时需先 sendEmailVerify）。
  Future<void> forget({
    required String email,
    required String emailCode,
    required String password,
  }) async {
    await _client.post<void>(
      XboardEndpoints.forget,
      body: {'email': email, 'email_code': emailCode, 'password': password},
    );
  }
}

class XboardUserRepository {
  XboardUserRepository(this._client);

  final XboardApiClient _client;

  Future<XboardUserInfo> info() async {
    final data = await _client.get<Map<String, dynamic>>(
      XboardEndpoints.userInfo,
      parse: (data) => Map<String, dynamic>.from(data as Map),
    );
    return XboardUserInfo.fromJson(data!);
  }

  /// 无套餐时服务端返回业务失败（源码行为），由调用方以 [XboardException] 兜底。
  Future<XboardSubscribeInfo> getSubscribe() async {
    final data = await _client.get<Map<String, dynamic>>(
      XboardEndpoints.userGetSubscribe,
      parse: (data) => Map<String, dynamic>.from(data as Map),
    );
    return XboardSubscribeInfo.fromJson(data!);
  }

  Future<String> resetSecurity() async {
    final data = await _client.get<String>(
      XboardEndpoints.userResetSecurity,
      parse: (data) => data as String,
    );
    return data!;
  }

  /// 会话有效性检查（401 → 静默登出）。
  Future<void> checkLogin() async {
    await _client.get<dynamic>(XboardEndpoints.userCheckLogin);
  }
}
