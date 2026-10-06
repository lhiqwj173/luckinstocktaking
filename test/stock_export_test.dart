import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_export.dart';
import 'package:luckinstocktaking/stock_history.dart';

StockLine line(String name, String inventory, {bool uncertain = false}) =>
    StockLine(
      cells: [name, inventory],
      confidence: 1,
      inventoryUncertain: uncertain,
    );

/// 打开导出的字节，断言表头、单元格类型和数值。
Sheet decode(StockExportTable table) {
  final excel = Excel.decodeBytes(encodeStockWorkbook(table));
  final name = excel.getDefaultSheet();
  if (name == null) throw StateError('导出的 Excel 缺少默认工作表');
  return excel[name];
}

void main() {
  test('数值列覆盖全表单位且顺序稳定', () {
    final table = buildStockExportTable('门店盘点', [
      line('生椰拿铁（大杯）', '3盒 2瓶'),
      line('冰美式', '冷藏12个'),
      line('抹茶轻乳酪', '冷冻1.5袋'),
    ]);
    // 分区固定按总库存→冷藏→冷冻，同分区内按单位首次出现排序。
    expect(table.headers, [
      '货物规格名称',
      '总库存-盒',
      '总库存-瓶',
      '冷藏-个',
      '冷冻-袋',
      '原始库存文本',
    ]);
    expect(table.numericColumnCount, 4);
    expect(table.textAt(0, '货物规格名称'), '生椰拿铁（大杯）');
    expect(table.textAt(0, '原始库存文本'), '3盒 2瓶');
    expect(table.numberAt(0, '总库存-盒')?.value, 3);
    expect(table.numberAt(0, '总库存-瓶')?.value, 2);
    expect(table.numberAt(0, '冷藏-个'), isNull, reason: '该行没有冷藏库存');
    expect(table.numberAt(1, '冷藏-个')?.value, 12);
    expect(table.numberAt(2, '冷冻-袋')?.value, 1.5);
  });

  test('库存待确认的行不写入数值，仅保留原始文本', () {
    final table = buildStockExportTable('门店盘点', [
      line('冰美式', '12个'),
      line('抹茶轻乳酪', '库存待确认', uncertain: true),
    ]);
    // 无法确认的行不贡献单位列，原始文本列仍是校对依据。
    expect(table.headers, ['货物规格名称', '总库存-个', '原始库存文本']);
    expect(table.numberAt(1, '总库存-个'), isNull);
    expect(table.textAt(1, '原始库存文本'), '库存待确认');
    expect(table.numberAt(0, '总库存-个')?.value, 12);
  });

  test('含易混淆字符的库存不折算成数值', () {
    final table = buildStockExportTable('门店盘点', [line('冰美式', '12O个')]);
    // 12O 无法解析出单位，不能凭猜测写进数值列。
    expect(table.numericColumnCount, 0);
    expect(table.textAt(0, '原始库存文本'), '12O个');
  });

  test('无单位的纯数字单列导出', () {
    final table = buildStockExportTable('门店盘点', [line('补光灯', '2')]);
    expect(table.headers, [
      '货物规格名称',
      '总库存(无单位)',
      '原始库存文本',
    ]);
    expect(table.numberAt(0, '总库存(无单位)')?.value, 2);
  });

  test('导出的工作簿可被重新解析且数值仍是数字', () {
    final table = buildStockExportTable('门店盘点', [
      line('生椰拿铁（大杯）', '3盒 2瓶'),
      line('抹茶轻乳酪', '冷冻1.5袋'),
    ]);
    final sheet = decode(table);
    expect(sheet.sheetName, '门店盘点');
    // 数值列覆盖两个分区，末列固定是原始库存文本。
    expect(table.headers, [
      '货物规格名称',
      '总库存-盒',
      '总库存-瓶',
      '冷冻-袋',
      '原始库存文本',
    ]);
    expect(sheet.rows[0][0]!.value, TextCellValue('货物规格名称'));
    expect(sheet.rows[0][1]!.value, TextCellValue('总库存-盒'));
    expect(sheet.rows[0][4]!.value, TextCellValue('原始库存文本'));
    // 整数用 IntCellValue、小数用 DoubleCellValue，Excel 里才能直接求和。
    expect(sheet.rows[1][1]!.value, IntCellValue(3));
    expect(sheet.rows[1][2]!.value, IntCellValue(2));
    expect(sheet.rows[1][3]?.value, isNull, reason: '未使用的数值列保持空白');
    expect(sheet.rows[2][3]!.value, DoubleCellValue(1.5));
    expect(sheet.rows[1][0]!.value, TextCellValue('生椰拿铁（大杯）'));
  });

  test('工作表名去掉非法字符并截断到 31 字符', () {
    expect(sanitizeSheetName('盘点单:2024/01*02?'), '盘点单 2024 01 02');
    expect(sanitizeSheetName('盘点单:2024//01'), '盘点单 2024 01', reason: '相邻非法字符不留下连续空格');
    final long = sanitizeSheetName('旧盘点单 2024年1月2日 瑞幸咖啡 上海徐汇门店库存核对表终稿版本');
    expect(long.length, 31);
    expect(long, startsWith('旧盘点单 2024年1月2日 瑞幸咖啡 上海徐汇门店库存核对表'));
    expect(sanitizeSheetName('History'), '盘点单 History', reason: '避开 Excel 保留名');
    expect(sanitizeSheetName('history'), '盘点单 history');
    expect(sanitizeSheetName('///'), '盘点单');
  });

  test('文件名按 UTF-8 字节截断，避免中文超限', () {
    expect(sanitizeFileName('盘点<a>:b|c?d*e'), '盘点 a b c d e');
    final long = sanitizeFileName('盘' * 100);
    expect(long.length, 66, reason: '200 字节上限 ÷ 每字 3 字节');
    expect(() => sanitizeFileName('///'), throwsFormatException);
    expect(() => sanitizeFileName('  '), throwsFormatException);
  });

  test('没有货物行时拒绝导出', () {
    expect(
      () => buildStockExportTable('门店盘点', const []),
      throwsFormatException,
    );
  });
}