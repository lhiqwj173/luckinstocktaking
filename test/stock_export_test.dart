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
  test('预制物料保留类别、不同单位和明确零值', () {
    final table = buildStockExportTable('2026-10-05 日盘', [
      line('六合蛋糕60g*9个*10盒/箱\nGS08291-01', '总库存:12个\n冷藏:2个\n冷冻:10个'),
      StockLine(
        cells: ['青金桔-预制作', '13个'],
        confidence: .9,
        category: 'prepared',
      ),
      StockLine(
        cells: ['【冷萃咖啡液】-预制作', '1200毫升'],
        confidence: .9,
        category: 'prepared',
      ),
      StockLine(
        cells: ['【巧克力预调液-新】-预制作', '0克'],
        confidence: .9,
        category: 'prepared',
      ),
    ]);
    final sheet = decode(table);
    expect(table.rows.length, 4);
    expect(table.textAt(0, '物料类别'), '货物');
    expect(table.textAt(1, '物料类别'), '预制物料');
    expect(table.numberAt(1, '总库存-个')?.value, 13);
    expect(table.numberAt(2, '总库存-毫升')?.value, 1200);
    expect(table.numberAt(3, '总库存-克')?.value, 0);
    expect(
      sheet.rows[4][table.headers.indexOf('总库存-克')]!.value,
      IntCellValue(0),
    );
    expect(table.numericColumnCount, 5);
  });

  test('总库存缺失不推算为零，校验状态与分区数量同时导出', () {
    final table = buildStockExportTable('日盘', [
      line('鑫国红苹果慕斯蛋糕50g\nGS10691-01', '总库存:-个\n冷藏:-盒0个\n冷冻:-盒0个'),
      line('泰乐源苹果复合果蔬汁饮料1.1kg\nGS06691-13', '总库存:瓶\n冷藏:0瓶\n冷冻:0瓶'),
      line('蛋糕60g\nGS08291-01', '总库存:12个\n冷藏:2个\n冷冻:10个'),
    ]);
    expect(table.numberAt(0, '总库存-个'), isNull);
    expect(table.numberAt(0, '冷藏-个')?.value, 0);
    expect(table.textAt(0, '校验状态'), '原图总库存未填写');
    expect(table.textAt(1, '校验状态'), contains('总库存缺失或无法识别'));
    expect(table.numberAt(1, '冷藏-瓶')?.value, 0);
    expect(table.textAt(2, '校验状态'), '已解析');
  });

  test('确认标志覆盖看似有效的数字，避免未确认库存参与汇总', () {
    final table = buildStockExportTable('日盘', [
      line('GS00001-01', '12个', uncertain: true),
      line('GS00002-01', '3个'),
    ]);
    expect(table.numberAt(0, '总库存-个'), isNull);
    expect(table.numberAt(1, '总库存-个')?.value, 3);
    expect(table.textAt(0, '校验状态'), '库存数字待确认');
    expect(table.textAt(0, '原始库存文本'), '12个');
  });

  test('不猜改活动规格字符，疑点和原始名称一起导出', () {
    final name = '9月中旬活动周边\n1202609YN2个/包\nGS10819-01';
    final table = buildStockExportTable('日盘', [line(name, '0包0个')]);
    expect(table.textAt(0, '货物规格名称'), name);
    expect(table.textAt(0, '校验状态'), contains('首字母'));
    expect(table.numberAt(0, '总库存-个')?.value, 0);
  });
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
    expect(table.headers, ['货物规格名称', '总库存-个', '校验状态', '原始库存文本']);
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
    expect(table.headers, ['货物规格名称', '总库存(无单位)', '原始库存文本']);
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
    expect(table.headers, ['货物规格名称', '总库存-盒', '总库存-瓶', '冷冻-袋', '原始库存文本']);
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
    expect(
      sanitizeSheetName('盘点单:2024//01'),
      '盘点单 2024 01',
      reason: '相邻非法字符不留下连续空格',
    );
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
