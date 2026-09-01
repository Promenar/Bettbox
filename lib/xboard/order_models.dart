/// 订单/支付模型（M2，字段对齐 Xboard v1 实测与源码契约，见 docs/PRD.md §5.2）。
library;

/// 支付方式（order/getPaymentMethod 元素）。
class XboardPaymentMethod {
  const XboardPaymentMethod({
    required this.id,
    required this.name,
    this.icon,
  });

  final int id;
  final String name;
  final String? icon;

  factory XboardPaymentMethod.fromJson(Map<String, dynamic> json) {
    return XboardPaymentMethod(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String?,
    );
  }
}

/// 订单（order/fetch 元素 / order/detail）。
class XboardOrder {
  const XboardOrder({
    required this.tradeNo,
    required this.status,
    this.totalAmount = 0,
    this.period,
    this.planId,
    this.createdAt = 0,
  });

  final String tradeNo;

  /// 0 待支付 1 开通中 2 已取消 3 已完成 4 已折抵（服务端约定）。
  final int status;
  final int totalAmount;
  final String? period;
  final int? planId;
  final int createdAt;

  bool get isPending => status == 0;

  factory XboardOrder.fromJson(Map<String, dynamic> json) {
    int? readInt(String key) => (json[key] as num?)?.toInt();
    return XboardOrder(
      tradeNo: json['trade_no'] as String? ?? '',
      status: readInt('status') ?? 0,
      totalAmount: readInt('total_amount') ?? 0,
      period: json['period'] as String?,
      planId: readInt('plan_id'),
      createdAt: readInt('created_at') ?? 0,
    );
  }
}

/// checkout 结果（契约已源码核验：0=二维码内容 / 1=跳转URL / -1=免费单已支付）。
enum XboardCheckoutType { qrcode, redirect, paid, unknown }

class XboardCheckoutResult {
  const XboardCheckoutResult({required this.type, this.data});

  final XboardCheckoutType type;
  final String? data;

  factory XboardCheckoutResult.fromJson(Map<String, dynamic> json) {
    final raw = json['type'];
    final data = json['data']?.toString();
    final type = switch (raw) {
      0 || '0' => XboardCheckoutType.qrcode,
      1 || '1' => XboardCheckoutType.redirect,
      -1 || '-1' => XboardCheckoutType.paid,
      _ => XboardCheckoutType.unknown,
    };
    return XboardCheckoutResult(type: type, data: data);
  }
}

/// 订单支付状态轮询结果（order/check）。
class XboardOrderCheckResult {
  const XboardOrderCheckResult({required this.paid, this.raw});

  final bool paid;
  final dynamic raw;

  factory XboardOrderCheckResult.fromJson(dynamic data) {
    // 服务端 check 返回 data: []（未支付）或 data: [订单对象]（已支付/已取消）
    if (data is List && data.isNotEmpty && data.first is Map) {
      final order = data.first as Map;
      return XboardOrderCheckResult(
        paid: order['status'] != null && (order['status'] as num).toInt() != 0,
        raw: order,
      );
    }
    return XboardOrderCheckResult(paid: false, raw: data);
  }
}

/// 轮询退避计算：3s → 5s → 之后每 10s，上限 [maxAttempts] 次。
List<Duration> checkoutPollSchedule({int maxAttempts = 40}) {
  final schedule = <Duration>[];
  for (var i = 0; i < maxAttempts; i++) {
    schedule.add(Duration(seconds: switch (i) {
      0 => 3,
      1 => 5,
      _ => 10,
    }));
  }
  return schedule;
}
