import 'category.dart';

const catalogTsvHeader = '品类\t别名\t容器重(克)\t参考重量(克)\t参考数量\t小数位';

String exportCatalogTsv(List<Category> categories) {
  validateCatalog(categories);
  final rows = <String>[catalogTsvHeader];
  for (final category in categories) {
    final columns = [
      category.name,
      category.aliases.join('、'),
      category.tareGrams.toString(),
      category.referenceGrams.toString(),
      category.referenceQuantity.toString(),
      category.decimals.toString(),
    ];
    if (columns.any(
      (value) =>
          value.contains('\t') || value.contains('\n') || value.contains('\r'),
    )) {
      throw const FormatException('品类数据含制表符或换行，无法导出表格');
    }
    rows.add(columns.join('\t'));
  }
  return rows.join('\n');
}

List<Category> importCatalogTsv(String input) {
  final lines = input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (lines.isEmpty || lines.first != catalogTsvHeader) {
    throw const FormatException('表格首行必须为：品类、别名、容器重(克)、参考重量(克)、参考数量、小数位');
  }
  if (lines.length < 2) throw const FormatException('表格没有品类数据');
  final categories = <Category>[];
  for (var index = 1; index < lines.length; index++) {
    final columns = lines[index].split('\t');
    if (columns.length != 6) throw FormatException('第 ${index + 1} 行必须有 6 列');
    final tare = double.tryParse(columns[2].trim());
    final grams = double.tryParse(columns[3].trim());
    final quantity = double.tryParse(columns[4].trim());
    final decimals = int.tryParse(columns[5].trim());
    if (tare == null || grams == null || quantity == null || decimals == null) {
      throw FormatException('第 ${index + 1} 行的计算规则不是有效数字');
    }
    final category = Category(
      name: columns[0].trim(),
      aliases: columns[1]
          .split(RegExp(r'[,，、;；]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      tareGrams: tare,
      referenceGrams: grams,
      referenceQuantity: quantity,
      decimals: decimals,
    );
    category.validate();
    categories.add(category);
  }
  validateCatalog(categories);
  return categories;
}

List<Category> mergeCatalog(List<Category> existing, List<Category> imported) {
  validateCatalog(existing);
  validateCatalog(imported);
  final merged = [...existing];
  final positions = {
    for (var index = 0; index < existing.length; index++)
      normalizeName(existing[index].name): index,
  };
  for (final category in imported) {
    final key = normalizeName(category.name);
    final position = positions[key];
    if (position == null) {
      positions[key] = merged.length;
      merged.add(category);
    } else {
      merged[position] = category;
    }
  }
  validateCatalog(merged);
  return merged;
}
