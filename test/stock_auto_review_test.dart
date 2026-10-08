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
  test('单位异常、重复数字、缺总量、分区漏项或合计冲突不能自动通过', () {
    for (final quantity in [
      '12瓶',
      '1盒2盒',
      '冷藏12盒',
      '总库存12盒 冷藏12盒',
      '总库存12盒 冷藏2盒 冷冻9盒',
      '总库存1箱 冷藏6盒 冷冻6盒',
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
    for (final quantity in ['0盒', '7.1盒', '总库存12盒 冷藏2盒 冷冻10盒']) {
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
      false,
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
}
