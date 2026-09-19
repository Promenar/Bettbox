/// 地域目录（F-NODE-6/7）。
///
/// 运营侧下发“面板地域目录”（全部地区 + 套餐映射），客户端据此区分
///「可连接 / 受限 / 不存在」三态。通道①为 Xboard 插件实时端点，通道②为
/// 引导源 `region_catalog` 静态字段（PRD §6.3）。本文件为通道②的解析与
/// 受限判定逻辑，通道①后续复用同一模型。
library;

import 'node_packager.dart';

class XboardRegionCatalogEntry {
  const XboardRegionCatalogEntry({
    required this.code,
    required this.name,
    this.planIds = const [],
  });

  final String code;
  final String name;
  final List<int> planIds;

  factory XboardRegionCatalogEntry.fromJson(Map<String, dynamic> json) {
    final code = json['code']?.toString().trim().toUpperCase() ?? '';
    final name = json['name']?.toString().trim() ?? code;
    final rawIds = json['plan_ids'];
    final ids = <int>[];
    if (rawIds is List) {
      for (final v in rawIds) {
        final n = v is num ? v.toInt() : int.tryParse(v.toString());
        if (n != null) ids.add(n);
      }
    }
    return XboardRegionCatalogEntry(code: code, name: name, planIds: ids);
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'plan_ids': planIds,
      };
}

class XboardRegionCatalog {
  const XboardRegionCatalog(this.entries);

  final List<XboardRegionCatalogEntry> entries;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  /// 解析引导源 `region_catalog` 字段；非列表或空列表返回空目录（不视为错误）。
  static XboardRegionCatalog tryParse(dynamic raw) {
    if (raw is! List) return const XboardRegionCatalog([]);
    final list = <XboardRegionCatalogEntry>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final entry = XboardRegionCatalogEntry.fromJson(item);
      if (entry.code.isEmpty || seen.contains(entry.code)) continue;
      seen.add(entry.code);
      list.add(entry);
    }
    return XboardRegionCatalog(List.unmodifiable(list));
  }

  /// 指定套餐是否有权访问该地域；`planIds` 为空表示全量开放。
  bool isAllowed(String code, int? planId) {
    final entry = _find(code);
    if (entry == null) return false;
    if (entry.planIds.isEmpty) return true;
    if (planId == null) return false;
    return entry.planIds.contains(planId);
  }

  XboardRegionCatalogEntry? _find(String code) {
    for (final e in entries) {
      if (e.code == code) return e;
    }
    return null;
  }

  /// 旗标与本地化名：优先取目录下发的 name，否则回退到 kRegionRules。
  String displayName(String code) {
    final entry = _find(code);
    if (entry != null && entry.name.isNotEmpty) return entry.name;
    for (final r in kRegionRules) {
      if (r.code == code) return r.name;
    }
    return code;
  }

  String flag(String code) {
    for (final r in kRegionRules) {
      if (r.code == code) return r.flag;
    }
    return '🌐';
  }
}

/// 受限判定（F-NODE-6）：面板存在但当前套餐无权限 → 展示为锁定态。
/// [availableCodes] 来自订阅包装后的实际地域组（如 HK/JP），[catalog] 为全量目录。
List<XboardRegionCatalogEntry> lockedEntries({
  required XboardRegionCatalog catalog,
  required Set<String> availableCodes,
  required int? planId,
}) {
  if (catalog.isEmpty) return const [];
  final locked = <XboardRegionCatalogEntry>[];
  for (final entry in catalog.entries) {
    if (availableCodes.contains(entry.code)) continue;
    // 未在订阅中出现，且当前套餐无权 → 受限
    // 若 planIds 为空则视为开放，不应列为受限（已在 available 中才会可连）
    locked.add(entry);
  }
  // 仅保留当前套餐无权的（若将来要区分“不存在”则在调用方过滤）
  return locked.where((e) => !catalog.isAllowed(e.code, planId)).toList();
}
