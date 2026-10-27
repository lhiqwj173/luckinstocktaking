import 'dart:convert';

import 'category.dart';

const _catalogFormat = 'luckinstocktaking.catalog';

String exportCatalogFile(List<Category> categories) {
  validateCatalog(categories);
  return const JsonEncoder.withIndent('  ').convert({
    'format': _catalogFormat,
    'version': 1,
    'categories': categories.map((category) => category.toJson()).toList(),
  });
}

List<Category> importCatalogFile(String input) {
  final decoded = jsonDecode(
    input.startsWith('\uFEFF') ? input.substring(1) : input,
  );
  if (decoded is! Map<String, dynamic> ||
      decoded['format'] != _catalogFormat ||
      decoded['version'] is! int ||
      decoded['version'] != 1 ||
      decoded['categories'] is! List) {
    throw const FormatException('请选择本应用导出的品类规则文件（版本 1）');
  }
  final categories = <Category>[];
  for (final entry in decoded['categories'] as List) {
    if (entry is! Map<String, dynamic> ||
        entry['name'] is! String ||
        entry['aliases'] is! List ||
        (entry['aliases'] as List).any((alias) => alias is! String) ||
        entry['type'] is! String ||
        entry['singleServingGrams'] is! num ||
        (entry['customTareGrams'] != null &&
            entry['customTareGrams'] is! num) ||
        entry['allowMultiple'] is! bool ||
        (entry.containsKey('returnNetWeight') &&
            entry['returnNetWeight'] is! bool)) {
      throw FormatException('第 ${categories.length + 1} 项品类规则字段缺失或类型错误');
    }
    categories.add(Category.fromJson(entry));
  }
  validateCatalog(categories);
  return categories;
}
