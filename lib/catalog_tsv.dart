import 'category.dart';

const catalogTsvHeader = '称重类别\t品类\t别名\t单份重量(克)';

String exportCatalogTsv(List<Category> categories) {
  validateCatalog(categories);
  final rows = <String>[catalogTsvHeader];
  for (final category in categories) {
    final columns = [
      category.type.label,
      category.name,
      category.aliases.join('、'),
      category.singleServingGrams.toString(),
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
    throw const FormatException('表格首行必须为：称重类别、品类、别名、单份重量(克)');
  }
  if (lines.length < 2) throw const FormatException('表格没有品类数据');
  final categories = <Category>[];
  for (var index = 1; index < lines.length; index++) {
    final columns = lines[index].split('\t');
    if (columns.length != 4) throw FormatException('第 ${index + 1} 行必须有 4 列');
    final type = switch (columns[0].trim()) {
      '份盒称重' => WeighingType.portionBox,
      '开封夹称重' => WeighingType.openedClip,
      _ => throw FormatException('第 ${index + 1} 行的称重类别无效'),
    };
    final grams = double.tryParse(columns[3].trim());
    if (grams == null) throw FormatException('第 ${index + 1} 行的单份重量不是有效数字');
    final category = Category(
      name: columns[1].trim(),
      aliases: columns[2]
          .split(RegExp(r'[,，、;；]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      type: type,
      singleServingGrams: grams,
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
