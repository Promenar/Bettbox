/// Xboard 数据模型与异常分类（纯 Dart，无 codegen，便于与上游工程隔离）。
///
/// 字段命名与 M0 实测响应一一对应（docs/PRD.md §5）。
library;

/// 业务/连接层错误分类。
///
/// [connection] 为域名切换（F-DOMAIN）的触发信号；[auth] 触发静默登出。
enum XboardErrorType { connection, auth, business, server }

class XboardException implements Exception {
  XboardException(this.type, this.message, {this.statusCode});

  final XboardErrorType type;
  final String message;
  final int? statusCode;

  bool get isConnection => type == XboardErrorType.connection;
  bool get isAuth => type == XboardErrorType.auth;
  bool get isBusiness => type == XboardErrorType.business;

  @override
  String toString() => 'XboardException($type, $message, $statusCode)';
}

/// 注册/登录返回的凭据（实测：`{token, auth_data, is_admin}`）。
///
/// [authData] 自带 `Bearer ` 前缀，请求头原样使用。
class XboardAuthResult {
  const XboardAuthResult({
    required this.token,
    required this.authData,
    required this.isAdmin,
  });

  final String token;
  final String authData;
  final bool isAdmin;

  factory XboardAuthResult.fromJson(Map<String, dynamic> json) {
    return XboardAuthResult(
      token: json['token'] as String? ?? '',
      authData: json['auth_data'] as String? ?? '',
      isAdmin: json['is_admin'] == true || json['is_admin'] == 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'auth_data': authData,
    'is_admin': isAdmin,
  };
}

/// 套餐（getSubscribe 内嵌 plan / guest plan/fetch 元素的公共子集）。
class XboardPlan {
  const XboardPlan({
    required this.id,
    required this.name,
    this.prices = const {},
    this.show = false,
    this.sell = false,
    this.renew = false,
    this.transferEnableGb = 0,
    this.speedLimit,
    this.deviceLimit,
  });

  final int id;
  final String name;

  /// 周期 → 价格（分）；period 枚举见 PRD §5.2。
  final Map<String, num> prices;
  final bool show;
  final bool sell;
  final bool renew;

  /// GB（try_out/前端展示语义，非字节）。
  final num transferEnableGb;
  final int? speedLimit;
  final int? deviceLimit;

  factory XboardPlan.fromJson(Map<String, dynamic> json) {
    final prices = <String, num>{};
    final pricesField = json['prices'];
    if (pricesField is Map) {
      pricesField.forEach((k, v) {
        if (v is num) prices[k.toString()] = v;
      });
    } else {
      // guest/plan/fetch 旧版扁平字段形态（实测）：month_price/year_price/...
      // 键保留原字段名（下单 period 原样回传，匹配 v1 服务端白名单）。
      const legacyFields = [
        'month_price',
        'quarter_price',
        'half_year_price',
        'year_price',
        'two_year_price',
        'three_year_price',
        'onetime_price',
        'reset_price',
      ];
      for (final field in legacyFields) {
        final v = json[field];
        if (v is num) prices[field] = v;
      }
    }
    return XboardPlan(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      prices: prices,
      show: json['show'] == true || json['show'] == 1,
      sell: json['sell'] == true || json['sell'] == 1,
      renew: json['renew'] == true || json['renew'] == 1,
      transferEnableGb: (json['transfer_enable'] as num?) ?? 0,
      speedLimit: (json['speed_limit'] as num?)?.toInt(),
      deviceLimit: (json['device_limit'] as num?)?.toInt(),
    );
  }
}

/// 用户信息（实测 `user/info` 返回；transfer_enable/u/d 单位为字节）。
class XboardUserInfo {
  const XboardUserInfo({
    required this.email,
    required this.transferEnable,
    this.u = 0,
    this.d = 0,
    this.expiredAt = 0,
    this.balance = 0,
    this.commissionBalance = 0,
    this.planId,
    this.uuid,
  });

  final String email;
  final int transferEnable;
  final int u;
  final int d;
  final int expiredAt;
  final int balance;
  final int commissionBalance;
  final int? planId;
  final String? uuid;

  factory XboardUserInfo.fromJson(Map<String, dynamic> json) {
    int? readInt(String key) => (json[key] as num?)?.toInt();
    return XboardUserInfo(
      email: json['email'] as String? ?? '',
      transferEnable: readInt('transfer_enable') ?? 0,
      u: readInt('u') ?? 0,
      d: readInt('d') ?? 0,
      expiredAt: readInt('expired_at') ?? 0,
      balance: readInt('balance') ?? 0,
      commissionBalance: readInt('commission_balance') ?? 0,
      planId: readInt('plan_id'),
      uuid: json['uuid'] as String?,
    );
  }
}

/// 订阅信息（实测 `user/getSubscribe` 返回）。
class XboardSubscribeInfo {
  const XboardSubscribeInfo({
    required this.token,
    required this.subscribeUrl,
    this.plan,
    this.transferEnable = 0,
    this.u = 0,
    this.d = 0,
    this.expiredAt = 0,
    this.deviceLimit,
    this.speedLimit,
    this.nextResetAt,
    this.resetDay,
  });

  final String token;

  /// 服务端为权威来源（含面板 `subscribe_url` 设置或请求 Host 回落）。
  final String subscribeUrl;
  final XboardPlan? plan;
  final int transferEnable;
  final int u;
  final int d;
  final int expiredAt;
  final int? deviceLimit;
  final int? speedLimit;
  final int? nextResetAt;
  final int? resetDay;

  factory XboardSubscribeInfo.fromJson(Map<String, dynamic> json) {
    int? readInt(String key) => (json[key] as num?)?.toInt();
    final planJson = json['plan'];
    return XboardSubscribeInfo(
      token: json['token'] as String? ?? '',
      subscribeUrl: json['subscribe_url'] as String? ?? '',
      plan: planJson is Map<String, dynamic>
          ? XboardPlan.fromJson(planJson)
          : null,
      transferEnable: readInt('transfer_enable') ?? 0,
      u: readInt('u') ?? 0,
      d: readInt('d') ?? 0,
      expiredAt: readInt('expired_at') ?? 0,
      deviceLimit: readInt('device_limit'),
      speedLimit: readInt('speed_limit'),
      nextResetAt: readInt('next_reset_at'),
      resetDay: readInt('reset_day'),
    );
  }
}

/// 响应包络解析结果（实测存在两种形态，见 PRD §5.1）。
class XboardEnvelope {
  const XboardEnvelope({required this.success, required this.message, this.data});

  final bool success;
  final String message;
  final dynamic data;

  /// 形态一：`{"status":"success"|"fail","message":...,"data":...,"error":...}`；
  /// 形态二（部分失败端点）：无 `status` 键，视为失败。
  static XboardEnvelope parse(dynamic body) {
    if (body is! Map<String, dynamic>) {
      return XboardEnvelope(
        success: false,
        message: 'unexpected response body',
      );
    }
    final status = body['status'];
    final message = body['message'] as String? ?? '';
    if (status == null) {
      return XboardEnvelope(success: false, message: message, data: body['data']);
    }
    return XboardEnvelope(
      success: status == 'success' || status == true,
      message: message,
      data: body['data'],
    );
  }
}
