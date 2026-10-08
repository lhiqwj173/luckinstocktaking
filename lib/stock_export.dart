import 'dart:convert';

import 'package:excel/excel.dart';

import 'stock_history.dart';
import 'stock_inventory.dart';

/// Excel 表的固定结构，与 `StockInventoryView` 展示库存的顺序一致。
const stockExportNameHeader = '货物规格名称';
const stockExportRawHeader = '原始库存文本';
const stockExportCategoryHeader = '物料类别';
const stockExportReviewHeader = '校验状态';

/// 库存分区按总库存、冷藏、冷冻的顺序排列，与 `StockInventory.parse` 产出的
/// 标签集合一一对应；出现未知标签说明解析层新增了分区，必须显式失败而不是丢列。
const _sections = ['库存', '冷藏', '冷冻'];

/// Excel 工作表名上限为 31 字符；文件系统单文件名为 255 字节，中文每字 3 字节，
/// 因此导出文件名按字节而不是字符截断。
const _sheetNameLimit = 31;
const _fileNameByteLimit = 200;

/// Excel 保留的工作表名，改名后分享出去才能正常打开。
const _reservedSheetNames = {'history'};

/// 一个导出单元格。数值与文本分开建模，保证数值列写入的是 Excel 数字而非文本，
/// 用户可以直接 SUM；同时空单元格必须与「零」区分开。
sealed class StockExportCell {
  const StockExportCell();

  CellValue? toCellValue() => switch (this) {
    StockExportText(:final value) => TextCellValue(value),
    StockExportNumber(:final value) =>
      value is int ? IntCellValue(value) : DoubleCellValue(value.toDouble()),
    StockExportBlank() => null,
  };
}

class StockExportText extends StockExportCell {
  const StockExportText(this.value);
  final String value;
}

/// 整数走 IntCellValue、小数走 DoubleCellValue，两者的默认数字格式不同，
/// 整数才不会在表格里显示成 12.00。
class StockExportNumber extends StockExportCell {
  const StockExportNumber(this.value);
  final num value;
}

class StockExportBlank extends StockExportCell {
  const StockExportBlank();
}

/// 已展开成表格的盘点单。`headers` 的第一项恒为货物名称，最后一项恒为原始库存文本，
/// 中间是按单位拆开的数值列，以及有需要时的物料类别和校验状态。
class StockExportTable {
  const StockExportTable({
    required this.sheetName,
    required this.headers,
    required this.rows,
  });

  final String sheetName;
  final List<String> headers;
  final List<List<StockExportCell>> rows;

  int get numericColumnCount => headers
      .where(
        (header) =>
            header != stockExportNameHeader &&
            header != stockExportRawHeader &&
            header != stockExportCategoryHeader &&
            header != stockExportReviewHeader,
      )
      .length;

  StockExportNumber? numberAt(int row, String header) {
    final column = headers.indexOf(header);
    if (column < 0) throw FormatException('导出表缺少列：$header');
    final cell = rows[row][column];
    return cell is StockExportNumber ? cell : null;
  }

  String textAt(int row, String header) {
    final column = headers.indexOf(header);
    if (column < 0) throw FormatException('导出表缺少列：$header');
    final cell = rows[row][column];
    return cell is StockExportText ? cell.value : '';
  }
}

/// 把盘点单行展开成可导出表格。数值列覆盖全表出现过的所有「分区 + 单位」组合，
/// 列顺序只取决于固定分区顺序和单位首次出现的顺序，因此同一份盘点单多次导出
/// 的表结构完全一致。
StockExportTable buildStockExportTable(String title, List<StockLine> lines) {
  if (lines.isEmpty) throw const FormatException('盘点单没有可导出的货物行');
  final inventories = [for (final line in lines) line.inventory];
  final columns = _numericColumns(inventories);
  final includeCategory = lines.any((line) => line.isPrepared);
  final includeReview =
      lines.any((line) => line.reviewIssue != null) ||
      inventories.any((inventory) => inventory.reviewStatus != '已解析');
  return StockExportTable(
    sheetName: sanitizeSheetName(title),
    headers: [
      stockExportNameHeader,
      for (final column in columns) column.header,
      if (includeCategory) stockExportCategoryHeader,
      if (includeReview) stockExportReviewHeader,
      stockExportRawHeader,
    ],
    rows: [
      for (var index = 0; index < lines.length; index++)
        _buildRow(
          lines[index],
          inventories[index],
          columns,
          includeCategory: includeCategory,
          includeReview: includeReview,
        ),
    ],
  );
}

/// 正式导出入口；草稿解析函数仍可用于预览和规则验证。
StockExportTable buildConfirmedStockExportTable(
  String title,
  List<StockLine> lines,
) {
  if (lines.isEmpty || lines.any((line) => !line.ready)) {
    throw const FormatException('请先完成待复核行的货物和库存校对，再导出盘点单');
  }
  return buildStockExportTable(title, lines);
}

/// 一列数值对应唯一的「分区 + 单位」组合，表头只是它的展示形式。
class _NumericColumn {
  const _NumericColumn(this.section, this.unit);

  final String section;
  final String unit;

  String get header => unit.isEmpty
      ? '${_sectionLabel(section)}(无单位)'
      : '${_sectionLabel(section)}-$unit';

  StockExportCell cellOf(StockInventory inventory) {
    if (inventory.uncertain) return const StockExportBlank();
    final quantity = inventory.parts[section];
    if (quantity == null || quantity.uncertain) return const StockExportBlank();
    final amount = quantity.amounts[unit];
    return amount == null ? const StockExportBlank() : _toNumber(amount);
  }
}

List<_NumericColumn> _numericColumns(List<StockInventory> inventories) {
  final columns = <_NumericColumn>[];
  final seen = <String>{};
  for (final inventory in inventories) {
    for (final label in inventory.parts.keys) {
      if (!_sections.contains(label)) {
        throw FormatException('库存分区超出已知范围：$label');
      }
    }
    if (inventory.uncertain) continue;
    for (final section in _sections) {
      final quantity = inventory.parts[section];
      if (quantity == null) continue;
      for (final unit in quantity.amounts.keys) {
        if (seen.add('$section\u0000$unit')) {
          columns.add(_NumericColumn(section, unit));
        }
      }
    }
  }
  return columns;
}

List<StockExportCell> _buildRow(
  StockLine line,
  StockInventory inventory,
  List<_NumericColumn> columns, {
  required bool includeCategory,
  required bool includeReview,
}) {
  if (line.cells.length != 2) {
    throw const FormatException('导出要求盘点单为两列的货物规格名称与实盘总库存');
  }
  final issues = [
    if (inventory.reviewStatus != '已解析') inventory.reviewStatus,
    if (line.reviewIssue != null && line.reviewIssue != '库存数字待确认')
      line.reviewIssue!,
  ];
  return [
    StockExportText(line.cells[0]),
    for (final column in columns) column.cellOf(inventory),
    if (includeCategory) StockExportText(line.categoryLabel),
    if (includeReview)
      StockExportText(issues.isEmpty ? '已解析' : issues.join('；')),
    // 原始识别文本是校对依据：即使数值齐全也一并保留，识别有误时能追溯原文。
    StockExportText(line.sourceCells[1]),
  ];
}

StockExportNumber _toNumber(StockAmount amount) {
  final value = amount.coefficient / BigInt.from(10).pow(amount.scale);
  if (!value.isFinite) {
    throw FormatException('库存数字无法导出为 Excel 数值：${amount.format()}');
  }
  // 整数范围内保持整数，让 Excel 用通用格式显示并参与整数求和。
  return amount.scale == 0 && value.abs() < 9007199254740992
      ? StockExportNumber(value.toInt())
      : StockExportNumber(value);
}

String _sectionLabel(String section) => section == '库存' ? '总库存' : section;

/// 表名必须能在 Excel 中打开：去掉控制字符与 `: \ / ? * [ ]`，长度截到 31。
String sanitizeSheetName(String title) {
  var name = _collapseSpaces(
    title.replaceAll(RegExp(r'[\x00-\x1f:\\/?*\[\]]'), ' '),
  ).trim();
  if (name.length > _sheetNameLimit) {
    name = name.substring(0, _sheetNameLimit).trim();
  }
  if (name.isEmpty) name = '盘点单';
  if (_reservedSheetNames.contains(name.toLowerCase())) name = '盘点单 $name';
  return name;
}

/// 导出文件名去掉 `: \ / ? * < > | "` 与控制字符，并按 UTF-8 字节截断，
/// 保证中文单据名不会超过文件系统上限。
String sanitizeFileName(String title) {
  final name = _truncateToBytes(
    _collapseSpaces(title.replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), ' '))
        .trim(),
    _fileNameByteLimit,
  );
  if (name.isEmpty || name == '.' || name == '..') {
    throw const FormatException('单据名称无法转换为有效文件名');
  }
  return name;
}

/// 相邻的非法字符会各自替换成空格，折叠后避免文件名里出现连续空格。
String _collapseSpaces(String value) => value.replaceAll(RegExp(r'\s+'), ' ');

String _truncateToBytes(String value, int limit) {
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (bytes + size > limit) break;
    bytes += size;
    buffer.write(char);
  }
  return buffer.toString();
}

/// 生成 .xlsx 字节。首行加粗成表头，数值列写 Excel 数字，可直接求和。
List<int> encodeStockWorkbook(StockExportTable table) {
  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();
  if (defaultSheet == null) throw StateError('新建的 Excel 缺少默认工作表');
  final sheet = excel[defaultSheet];

  sheet.appendRow([for (final header in table.headers) TextCellValue(header)]);
  for (final row in table.rows) {
    sheet.appendRow([for (final cell in row) cell.toCellValue()]);
  }

  final headerStyle = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.fromHexString('#E8EEF7'),
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  for (var column = 0; column < table.headers.length; column++) {
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0))
            .cellStyle =
        headerStyle;
    sheet.setColumnWidth(
      column,
      column == 0 ? 42 : (column == table.headers.length - 1 ? 28 : 12),
    );
  }
  if (table.sheetName != sheet.sheetName) {
    excel.rename(sheet.sheetName, table.sheetName);
  }

  final bytes = excel.save();
  if (bytes == null) throw StateError('无法生成 Excel 文件');
  return bytes;
}
