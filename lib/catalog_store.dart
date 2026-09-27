import 'dart:convert';

import 'package:flutter/services.dart';

import 'category.dart';

class CatalogStore {
  static const _channel = MethodChannel('com.luckinstocktaking/catalog');

  Future<List<Category>> load() async {
    final json = await _channel.invokeMethod<String>('load');
    if (json == null) throw StateError('无法读取共享品类数据');
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
