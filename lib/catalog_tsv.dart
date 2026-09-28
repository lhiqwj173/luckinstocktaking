import 'category.dart';

const catalogTsvHeader = '称重类别\t品类\t别名\t单份重量(克)\t皮重(克)\t允许多份';
const _legacyCatalogTsvHeader = '称重类别\t品类\t别名\t单份重量(克)\t皮重(克)';

String exportCatalogTsv(List<Category> categories) {
  validateCatalog(categories);
  final rows = <String>[catalogTsvHeader];
  for (final category in categories) {
    final columns = [
      category.type.label,
      category.name,
      category.aliases.join('、'),
      category.singleServingGrams.toString(),
      category.customTareGrams?.toString() ?? '',
      category.allowMultiple ? '是' : '否',
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
  if (lines.isEmpty ||
      (lines.first != catalogTsvHeader &&
          lines.first != _legacyCatalogTsvHeader)) {
    throw const FormatException('表格首行必须为五列旧格式，或增加“允许多份”的六列新格式');
  }
  if (lines.length < 2) throw const FormatException('表格没有品类数据');
  final legacy = lines.first == _legacyCatalogTsvHeader;
  final categories = <Category>[];
  for (var index = 1; index < lines.length; index++) {
    final columns = lines[index].split('\t');
    if (columns.length != (legacy ? 5 : 6)) {
      throw FormatException('第 ${index + 1} 行必须有 ${legacy ? 5 : 6} 列');
    }
    final type = switch (columns[0].trim()) {
      '份盒称重' => WeighingType.portionBox,
      '开封夹称重' => WeighingType.openedClip,
      '其他' => WeighingType.other,
      _ => throw FormatException('第 ${index + 1} 行的称重类别无效'),
    };
    final grams = double.tryParse(columns[3].trim());
    if (grams == null) throw FormatException('第 ${index + 1} 行的单份重量不是有效数字');
    final tareInput = columns[4].trim();
    if (type == WeighingType.other && tareInput.isEmpty) {
      throw FormatException('第 ${index + 1} 行“其他”类别必须填写皮重');
    }
    if (type != WeighingType.other && tareInput.isNotEmpty) {
      throw FormatException('第 ${index + 1} 行固定称重类别的皮重必须留空');
    }
    final tare = tareInput.isEmpty ? null : double.tryParse(tareInput);
    if (tareInput.isNotEmpty && tare == null) {
      throw FormatException('第 ${index + 1} 行的皮重不是有效数字');
    }
    final allowMultiple = legacy
        ? false
        : switch (columns[5].trim()) {
            '是' => true,
            '否' => false,
            _ => throw FormatException('第 ${index + 1} 行的“允许多份”必须为“是”或“否”'),
          };
    final category = Category(
      name: columns[1].trim(),
      aliases: columns[2]
          .split(RegExp(r'[,，、;；]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      type: type,
      singleServingGrams: grams,
      customTareGrams: tare,
      allowMultiple: allowMultiple,
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
