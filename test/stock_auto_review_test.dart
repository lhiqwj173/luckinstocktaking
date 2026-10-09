import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_inventory.dart';
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
      true,
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
  test('通用字符对齐允许型号字母误读为数字，真实包装数量冲突仍拒绝', () {
    final activity = StockProduct(
      code: 'GS10819-01',
      name: '9月中旬活动周边',
      specification: 'I202609YN2个/包',
      units: ['个', '包'],
    );
    final cup = StockProduct(
      code: 'GS03779-14',
      name: '12oz双层纸杯-AO热饮杯ZC-',
      specification: '25个/袋*12袋/箱',
      units: ['个', '袋', '箱'],
    );
    StockLine sample(String name) => StockLine(
      cells: [name, '-包0个'],
      confidence: .9,
      inventoryReadings: ['-包0个', '-包0个'],
      inventoryConfidence: .95,
    );
    expect(
      reconcileStockLine(sample('9月中旬活动周边\n1202609YN2个/包\nGS10819-01'), [
        activity,
        cup,
      ]).identityConfirmed,
      true,
    );
    expect(
      reconcileStockLine(sample('120z双层纸杯-AO热饮杯\nZC-25个/袋*12袋/箱\nGS03779-14'), [
        activity,
        cup,
      ]).identityConfirmed,
      true,
    );
    expect(
      reconcileStockLine(sample('12oz双层纸杯-AO热饮杯\nZC-50个/袋*12袋/箱\nGS03779-14'), [
        cup,
      ]).identityConfirmed,
      false,
    );
    final candidates = matchProducts(
      '9月中旬活动周边1202609YN2个/包 GS10819-01',
      'goods',
      [activity, cup],
    );
    expect(candidates.map((candidate) => candidate.product.code), [
      'GS10819-01',
    ]);
    expect(candidates.single.conflict, false);
  });
  test('通用匹配覆盖汉字、字母、任意替换漏字多字，原图证据不改写', () {
    final generic = StockProduct(
      code: 'GS10002-01',
      name: '通用测试商品型号ABCD',
      specification: '500ml*12瓶/箱',
      units: ['瓶', '箱'],
    );
    for (final raw in [
      '通用测式商品型号ABCD500ml*12瓶/箱',
      '通用测试商品型号AXCD500ml*12瓶/箱',
      '通用测试商品型号A8CD500ml*12瓶/箱',
      '通用测试商品型号ACD500ml*12瓶/箱',
      '通用测试商品型号ABXCD500ml*12瓶/箱',
    ]) {
      final source = row(name: '$raw\nGS10002-01', quantity: '1瓶');
      final candidate = matchProducts(source.cells[0], 'goods', [
        generic,
      ]).single;
      expect(candidate.edits, 1, reason: raw);
      expect(candidate.conflict, false, reason: raw);
      final result = reconcileStockLine(source, [generic]);
      expect(result.ready, true, reason: raw);
      expect(result.cells[0], generic.display);
      expect(result.sourceCells, source.cells);
      expect(result.cells[1], source.cells[1]);
    }
    for (final spec in [
      '500ml*13瓶/箱',
      '500ml*1瓶/箱',
      '500ml*112瓶/箱',
      '500ml*12盒/箱',
      '50.0ml*12瓶/箱',
    ]) {
      final source = row(
        name: '${generic.name}$spec\nGS10002-01',
        quantity: '1瓶',
      );
      expect(
        reconcileStockLine(source, [generic]).identityConfirmed,
        false,
        reason: spec,
      );
    }
    final short = StockProduct(
      code: 'GS10003-01',
      name: '测试商品',
      specification: '',
      units: ['盒'],
    );
    expect(
      reconcileStockLine(row(name: '测试商晶 GS10003-01'), [
        short,
      ]).identityConfirmed,
      true,
    );
  });
  test('无货号预制名称用匹配率和领先分差，相近候选不擅自选择', () {
    final first = StockProduct(
      code: '',
      name: '【通用柠檬清洗全国】预处理',
      specification: '',
      units: ['个'],
      category: 'prepared',
    );
    final second = StockProduct(
      code: '',
      name: '【通用柠檬清洗全园】预处理',
      specification: '',
      units: ['个'],
      category: 'prepared',
    );
    StockLine source(String name) => StockLine(
      cells: [name, '7个'],
      confidence: .9,
      category: 'prepared',
      inventoryReadings: ['7个', '7个'],
      inventoryConfidence: .95,
    );
    final raw = '【通用柠檬清冼全国】预处理';
    expect(reconcileStockLine(source(raw), [first]).ready, true);
    expect(
      reconcileStockLine(source(raw), [first, second]).identityConfirmed,
      false,
    );
    expect(reconcileStockLine(source(first.name), [first, second]).ready, true);
  });
  test('预制固定单位只有在另两次完整数量单位读数证实时才恢复无效 ASCII 后缀', () {
    final prepared = StockProduct(
      code: '',
      name: '测试预制',
      specification: '',
      units: ['个'],
      category: 'prepared',
    );
    StockLine sample(List<String> readings) => StockLine(
      cells: [prepared.name, '7TX'],
      category: 'prepared',
      confidence: .9,
      inventoryUncertain: true,
      inventoryReadings: readings,
      inventoryConfidence: .95,
    );
    final result = reconcileStockLine(sample(['7个', '7个', '7TX']), [prepared]);
    expect(result.ready, true);
    expect(result.cells[1], '7个');
    expect(result.sourceCells[1], '7TX');
    expect(result.inventoryReadings, ['7个', '7个', '7TX']);
    expect(reconcileStockLine(sample(['7TX', '7TX']), [prepared]).ready, false);
    expect(
      reconcileStockLine(sample(['7个', '7个', '70TX']), [prepared]).ready,
      false,
    );
    expect(
      reconcileStockLine(sample(['7个', '7个', '7克']), [prepared]).ready,
      false,
    );
  });
  test('废读和漏读不否决三次完整一致读数，独立数字冲突仍阻断', () {
    expect(
      reconcileStockLine(
        row(quantity: '1盒', readings: ['1盒', '季', '1盒', '1盒'], confidence: .4),
        [product],
      ).ready,
      true,
    );
    for (final noise in ['6', '15盒', '-盒', '1瓶', '一盒']) {
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
  test('完整库存旁混入独立片段不算冲突，也不能代替完整支持证据', () {
    for (final pair in [
      ['8.4袋', '26\n8.4袋\n李'],
      ['-盒0个', '6\n-盒0个'],
      ['-袋5个', ''],
    ]) {
      final expected = pair[0], polluted = pair[1];
      final proof = StockInventory.evidence(expected, [
        expected,
        polluted,
        expected,
        expected,
      ], .4);
      expect(proof.supporting, 3);
      expect(proof.abstentions, 1);
      expect(proof.conflicting, 0);
      expect(proof.sufficient, true);
      expect(
        StockInventory.evidence(expected, [expected, polluted], .99).sufficient,
        false,
      );
      expect(
        StockInventory.evidence(expected, [
          expected,
          polluted,
          expected,
          expected,
        ], null).sufficient,
        false,
      );
    }
    for (final conflict in [
      '26个\n8.4袋',
      '84袋',
      '26',
      '冷藏：26\n8.4袋',
      '2.6\n8.4袋',
    ]) {
      expect(
        StockInventory.evidence('8.4袋', [
          '8.4袋',
          conflict,
          '8.4袋',
          '8.4袋',
        ], .99).sufficient,
        false,
        reason: conflict,
      );
    }
    expect(
      reconcileStockLine(
        row(quantity: '1盒', readings: ['1盒', '', '1盒', '1盒'], confidence: .4),
        [product],
      ).ready,
      true,
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
