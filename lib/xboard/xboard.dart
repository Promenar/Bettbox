/// Bettbox 商业化模块（网穿云/CloudBreach，对接 Xboard 面板）。
///
/// 与上游工程代码物理隔离：本目录不使用 codegen（freezed/riverpod_generator），
/// 模型为手写纯 Dart，便于上游 rebase。
library;

export 'api_client.dart';
export 'binding.dart';
export 'bootstrap.dart';
export 'domain_manager.dart';
export 'domain_scheduler.dart';
export 'endpoints.dart';
export 'error_map.dart';
export 'models.dart';
export 'order_models.dart';
export 'region_catalog.dart';
export 'repositories.dart';
export 'secure_store.dart';
export 'session.dart';
