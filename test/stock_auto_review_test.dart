import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_product.dart';

void main() {
  final product = StockProduct(
    code: 'GS10001-01',
    name: '测试椰乳',
    specification: '1L*12盒/箱',
    units: ['盒', '箱'],
  );
  StockLine row({
    String? name,
    String quantity = '12盒',
    List<String>? readings,
    double? confidence = .95,
  }) => StockLine(
    cells: [name ?? product.display, quantity],
    confidence: .7,
    inventoryReadings: readings ?? [quantity, quantity],
    inventoryConfidence: confidence,
    sourceTop: 100,
    sourceBottom: 200,
  );
  test('货号规格准确且库存两次实际读数一致，自动通过并保留源证据', () {
    final source = row();
    final result = reconcileStockLine(source, [product]);
    expect(result.ready, true);
    expect(result.autoConfirmed, true);
    expect(result.cells[1], source.cells[1]);
    expect(result.sourceCells, source.cells);
    final restored = StockLine.fromJson(result.toJson());
    expect(restored.ready, true);
    expect(restored.autoConfirmed, true);
    expect(restored.inventoryReadings, ['12盒', '12盒']);
    expect(restored.inventoryConfidence, .95);
    expect(restored.sourceTop, 100);
  });
  test('评分很高不能代替复读，读数冲突、空读数及低库存评分仅确认货物', () {
    for (final source in [
      row(readings: ['12盒']),
      row(readings: ['12盒', '1盒']),
      row(readings: ['12盒', '']),
      row(confidence: .79),
      row(confidence: null),
    ]) {
      final result = reconcileStockLine(source, [product]);
      expect(result.identityConfirmed, true);
      expect(result.inventoryConfirmed, false);
      expect(result.ready, false);
      expect(result.cells[1], source.cells[1]);
    }
  });
  test('规格冲突、缺货号和未知货物不能自动匹配', () {
    for (final name in [
      '测试椰乳250ml*24盒/箱 GS10001-01',
      '测试椰乳1L*12盒/箱',
      '测试椰乳1L*12盒/箱 GS99999-01',
    ]) {
      expect(
        reconcileStockLine(row(name: name), [product]).identityConfirmed,
        false,
      );
    }
  });
  test('评分偏低不能单独放行，批次与局部四读一致才通过', () {
    final source = row(
      quantity: '1.5盒',
      readings: ['1.5盒', '1.5盒', '1.5盒', '1.5盒'],
      confidence: .5,
    );
    final result = reconcileStockLine(source, [product]);
    expect(result.ready, true);
    expect(result.cells[1], '1.5盒');
    expect(StockLine.fromJson(result.toJson()).inventoryReadings.length, 4);
    expect(
      reconcileStockLine(
        row(
          quantity: '1.5盒',
          readings: ['1.5盒', '15盒', '1.5盒', '1.5盒'],
          confidence: .5,
        ),
        [product],
      ).ready,
      false,
    );
    expect(
      reconcileStockLine(
        row(readings: ['12盒', '12盒', '12盒', ''], confidence: .5),
        [product],
      ).ready,
      false,
    );
    expect(
      reconcileStockLine(
        row(readings: ['12盒', '12盒', '12盒', '12盒'], confidence: 0),
        [product],
      ).ready,
      false,
    );
  });
  test('格式差异按数量单位分区比较，重复数字和真实冲突不算一致', () {
    final source = row(quantity: '1盒', readings: ['总库存：1.0盒', '1盒']);
    expect(reconcileStockLine(source, [product]).ready, true);
    expect(
      reconcileStockLine(row(quantity: '2盒', readings: ['1盒1盒', '2盒']), [
        product,
      ]).ready,
      false,
    );
    expect(
      reconcileStockLine(row(quantity: '1盒', readings: ['1箱', '1盒']), [
        product,
      ]).ready,
      false,
    );
    expect(
      reconcileStockLine(row(quantity: '1盒', readings: ['-1盒', '1盒']), [
        product,
      ]).ready,
      false,
    );
    expect(
      reconcileStockLine(row(quantity: '1盒', readings: ['1盒', '冷藏1盒']), [
        product,
      ]).ready,
      false,
    );
  });
  test('单位异常、重复数字、缺总量、分区漏项或合计冲突不能自动通过', () {
    for (final quantity in [
      '12瓶',
      '1盒2盒',
      '冷藏12盒',
      '总库存12盒 冷藏12盒',
      '总库存12盒 冷藏2盒 冷冻9盒',
      '',
    ]) {
      expect(
        reconcileStockLine(row(quantity: quantity), [
          product,
        ]).inventoryConfirmed,
        false,
        reason: quantity,
      );
    }
  });
  test('明确零值、小数及可核算分区合计自动通过', () {
    for (final quantity in [
      '0盒',
      '7.1盒',
      '总库存12盒 冷藏2盒 冷冻10盒',
      '总库存1箱 冷藏6盒 冷冻6盒',
    ]) {
      expect(
        reconcileStockLine(row(quantity: quantity), [product]).ready,
        true,
        reason: quantity,
      );
    }
  });
  test('两读明确未填写的占位符自动通过但不生成零库存', () {
    for (final quantity in ['-箱-盒', '总库存-盒 冷藏-盒 冷冻-盒']) {
      final result = reconcileStockLine(row(quantity: quantity), [product]);
      expect(result.ready, true);
      expect(result.inventory.hasValue, false);
      expect(result.cells[1], quantity);
    }
    expect(
      reconcileStockLine(row(quantity: '总库存-盒 冷藏0盒 冷冻0盒'), [product]).ready,
      true,
    );
    expect(reconcileStockLine(row(quantity: '-瓶12盒'), [product]).ready, false);
  });
  test('预制名称精确匹配与库存双读一致可自动通过', () {
    final prepared = StockProduct(
      code: '',
      name: '测试预制',
      specification: '',
      units: ['个'],
      category: 'prepared',
    );
    final source = StockLine(
      cells: ['测试预制', '2个'],
      confidence: .9,
      category: 'prepared',
      inventoryReadings: ['2个', '2个'],
      inventoryConfidence: .9,
    );
    expect(reconcileStockLine(source, [prepared]).ready, true);
  });
  test('重复货号的识别行不能同时自动通过', () {
    expect(
      reconcileStockLines(
        [row(), row()],
        [product],
      ).every((line) => !line.ready),
      true,
    );
  });
  test('已人工确认的库存无需重新复读', () {
    final confirmed = row(readings: []).confirmed(
      cells: [product.display, '12盒'],
      productId: product.id,
      allowedUnits: product.units,
    );
    final restored = reconcileStockLine(confirmed, [product]);
    expect(restored.ready, true);
    expect(restored.autoConfirmed, false);
  });
  test('库存证据评分必须有效且不可修改', () {
    expect(() => row(confidence: double.nan), throwsFormatException);
    expect(() => row(confidence: 1.1), throwsFormatException);
    expect(() => row().inventoryReadings.add('1盒'), throwsUnsupportedError);
  });
  test('无数字废读数不否决三次完整一致读数，数字冲突和漏读仍阻断', () {
    expect(
      reconcileStockLine(
        row(quantity: '1盒', readings: ['1盒', '季', '1盒', '1盒'], confidence: .4),
        [product],
      ).ready,
      true,
    );
    for (final noise in ['6', '15盒', '-盒', '', '1瓶', '一盒']) {
      expect(
        reconcileStockLine(
          row(
            quantity: '1盒',
            readings: ['1盒', noise, '1盒', '1盒'],
            confidence: .4,
          ),
          [product],
        ).ready,
        false,
        reason: noise,
      );
    }
    expect(
      reconcileStockLine(
        row(quantity: '1盒', readings: ['1盒', '季'], confidence: .99),
        [product],
      ).ready,
      false,
    );
    expect(
      reconcileStockLine(
        row(
          quantity: '1盒',
          readings: ['1盒', '季', '1盒', '1盒'],
          confidence: null,
        ),
        [product],
      ).ready,
      false,
    );
  });
  test('全角数字与排版等价，但不丢单位、小数点和占位符', () {
    final result = reconcileStockLine(
      row(quantity: '1.5盒', readings: ['总 库 存：１．５０ 盒', '1.5盒']),
      [product],
    );
    expect(result.ready, true);
    expect(result.inventoryReadings.first, '总 库 存：１．５０ 盒');
    for (final noise in ['1盒季', '季1盒']) {
      expect(
        reconcileStockLine(
          row(
            quantity: '1盒',
            readings: ['1盒', noise, '1盒', '1盒'],
            confidence: .4,
          ),
          [product],
        ).ready,
        true,
      );
    }
    final unitConflict = StockLine(
      cells: ['测试', '1升'],
      confidence: .9,
      inventoryReadings: ['1升', '1毫升', '1升', '1升'],
      inventoryConfidence: .9,
    );
    expect(unitConflict.inventoryEvidenceSufficient, false);
  });
  test('固定规格包装链可验证不同单位的冷热合计，不改写原始数量', () {
    final packed = StockProduct(
      code: 'GS10535-01',
      name: '测试司康',
      specification: '80g*7个*6包/箱',
      units: ['个', '包', '箱'],
    );
    expect(packed.inventoryUnitFactors, {
      '个': BigInt.one,
      '包': BigInt.from(7),
      '箱': BigInt.from(42),
    });
    StockLine packedRow(String quantity) => StockLine(
      cells: [packed.display, quantity],
      confidence: .9,
      inventoryReadings: List.filled(4, quantity),
      inventoryConfidence: .5,
    );
    const valid = '总库存：7个\n冷藏：-包0个\n冷冻：1包0个';
    final result = reconcileStockLine(packedRow(valid), [packed]);
    expect(result.ready, true);
    expect(result.cells[1], valid);
    expect(
      reconcileStockLine(packedRow(valid.replaceFirst('7个', '8个')), [
        packed,
      ]).ready,
      false,
    );
    final unknown = StockProduct(
      code: packed.code,
      name: packed.name,
      specification: '特殊包装',
      units: packed.units,
    );
    final unknownLine = StockLine(
      cells: [unknown.display, valid],
      confidence: .9,
      inventoryReadings: List.filled(4, valid),
      inventoryConfidence: .5,
    );
    expect(reconcileStockLine(unknownLine, [unknown]).ready, false);
  });
  test('总库存明确未填写、冷热零库存一致可通过，保留空值不推算总量', () {
    const quantity = '总库存：-盒\n冷藏：-箱0盒\n冷冻：-箱0盒';
    final result = reconcileStockLine(row(quantity: quantity), [product]);
    expect(result.ready, true);
    expect(result.inventory.totalMissing, true);
    expect(result.inventory.parts['库存']!.amounts, isEmpty);
    expect(result.cells[1], quantity);
    expect(
      reconcileStockLine(row(quantity: '总库存：\n冷藏：0盒\n冷冻：0盒'), [product]).ready,
      false,
    );
  });
}
