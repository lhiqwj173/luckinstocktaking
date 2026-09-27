import 'dart:convert';

import 'package:flutter/services.dart';

import 'category.dart';

class CatalogDiagnostics {
  const CatalogDiagnostics({
    required this.version,
    required this.appBundleId,
  });

  final String version;
  final String appBundleId;

  factory CatalogDiagnostics.fromMap(Map<dynamic, dynamic> value) =>
      CatalogDiagnostics(
        version: value['version'] as String,
        appBundleId: value['appBundleId'] as String,
      );
}

class CatalogStore {
  static const _channel = MethodChannel('com.luckinstocktaking/catalog');

  Future<CatalogDiagnostics> diagnostics() async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'diagnostics',
    );
    if (value == null) throw StateError('无法读取 iOS 安装诊断信息');
    return CatalogDiagnostics.fromMap(value);
  }

  Future<List<Category>> load() async {
    final json = await _channel.invokeMethod<String>('load');
    if (json == null) throw StateError('无法读取本地品类数据');
    final categories = (jsonDecode(json) as List<dynamic>)
        .map(
          (entry) => Category.fromJson((entry as Map).cast<String, dynamic>()),
        )
        .toList();
    validateCatalog(categories);
    return categories;
  }

  Future<void> save(List<Category> categories) async {
    validateCatalog(categories);
    await _channel.invokeMethod<void>(
      'save',
      jsonEncode(categories.map((e) => e.toJson()).toList()),
    );
  }
}
