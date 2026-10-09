import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_inventory.dart';
import 'package:luckinstocktaking/stock_product.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/stock_vote_debug.json')
        .readAsStringSync(encoding: utf8),
  ) as Map<String, dynamic>;
  final products = (fixture['products'] as List)
      .map((p) => StockProduct.fromJson((p as Map).cast<String, dynamic>()))
      .toList();
  final rows = (fixture['rows'] as List).cast<Map<String, dynamic>>();
  final product = StockProduct(
    code: 'GS10001-01',
    name: '投票测试',
    specification: '1L*12盒/箱',
    units: ['盒', '箱'],
  );
  StockLine row(String current, List<String> readings) => StockLine(
    cells: [product.display, current],
    confidence: .5,
    inventoryConfidence: .3,
    inventoryReadings: readings,
  );

  test('新调试包14行原有证据即可解除9行阻断，不改数量原文', () {
    const recovered = {21, 26, 34, 49, 51, 54, 79, 180, 184};
    for (final entry in rows) {
      final source = StockLine.fromJson(
        (entry['line'] as Map).cast<String, dynamic>(),
      );
      final result = reconcileStockLine(source, products);
      expect(
        result.ready,
        recovered.contains(entry['rowNumber']),
        reason: '行 ${entry['rowNumber']}',
      );
      expect(result.cells, source.cells);
      expect(result.sourceCells, source.sourceCells);
      expect(result.inventoryReadings, source.inventoryReadings);
      expect(reconcileStockLine(result, products).ready, result.ready);
    }
  });
  test('三次完整一致可覆盖低评分，两次低评分仍待复核', () {
    expect(
      reconcileStockLine(row('1盒', ['1盒', '1盒', '1盒']), [product]).ready,
      true,
    );
    expect(reconcileStockLine(row('1盒', ['1盒', '1盒']), [product]).ready, false);
  });
  test('少数真实异读须至少五票且80%，选中完整胜者并保留原始异读', () {
    final readings = ['15盒', '1盒', '1盒', '1盒', '1盒', '1盒'];
    final result = reconcileStockLine(row('15盒', readings), [product]);
    expect(result.ready, true);
    expect(result.cells[1], '1盒');
    expect(result.sourceCells[1], '15盒');
    expect(result.inventoryReadings, readings);
    expect(result.inventoryEvidence.supporting, 5);
    expect(result.inventoryEvidence.conflicting, 1);
    expect(
      reconcileStockLine(row('1盒', ['1盒', '1盒', '1盒', '15盒']), [product]).ready,
      false,
    );
    expect(
      reconcileStockLine(
        row('1盒', ['1盒', '1盒', '1盒', '1盒', '1盒', '15盒', '15盒']),
        [product],
      ).ready,
      false,
    );
  });
  test('漏掉完整分区弃权，已读分区数量或占位符变化仍算冲突', () {
    const full = '总库存：3盒\n冷藏：1盒\n冷冻：2盒';
    expect(StockInventory.partialReading(full, '总库存：3盒\n冷藏：1盒'), true);
    expect(StockInventory.partialReading(full, '总库存：3盒\n冷藏：2盒'), false);
    expect(StockInventory.partialReading(full, '总库存：3盒\n冷藏：-盒'), false);
    final result = reconcileStockLine(
      row(full, [full, full, '总库存：3盒\n冷藏：1盒', full]),
      [product],
    );
    expect(result.ready, true);
    expect(result.inventoryEvidence.abstentions, 1);
    expect(result.inventoryEvidence.conflicting, 0);
  });
  test('不能拼接各分区投票，也不能以局部胜者丢弃已发现分区', () {
    const full = '总库存：3盒\n冷藏：1盒\n冷冻：2盒';
    expect(
      reconcileStockLine(
        row(full, [
          '总库存：3盒\n冷藏：1盒',
          '总库存：3盒\n冷藏：1盒',
          '总库存：3盒\n冷藏：1盒',
          '总库存：3盒\n冷冻：2盒',
        ]),
        [product],
      ).ready,
      false,
    );
  });
  test('多数票仍校验单位、重复数字及分区合计，空白不能投成零', () {
    for (final invalid in ['1瓶', '1盒1盒', '总库存：4盒\n冷藏：1盒\n冷冻：2盒']) {
      expect(
        reconcileStockLine(row(invalid, List.filled(6, invalid)), [
          product,
        ]).ready,
        false,
      );
    }
    expect(
      StockInventory.evidence('-盒', [
        '-盒',
        '-盒',
        '-盒',
        '-盒',
        '-盒',
        '1盒',
      ], .5).sufficient,
      false,
    );
    final mixed = products.singleWhere((p) => p.code == 'GS09520-01');
    const wrongTotal = '总库存：9个\n冷藏：-包2个\n冷冻：1包0个';
    expect(
      reconcileStockLine(
        StockLine(
          cells: [mixed.display, wrongTotal],
          confidence: .5,
          inventoryConfidence: .5,
          inventoryReadings: List.filled(4, wrongTotal),
        ),
        [mixed],
      ).ready,
      false,
    );
  });
  test('模拟疑点行六次额外成功复读可形成共识，实际旧包不伪造新票', () {
    for (final entry in rows.where(
      (r) => [27, 75, 76, 86, 182].contains(r['rowNumber']),
    )) {
      final source = StockLine.fromJson(
        (entry['line'] as Map).cast<String, dynamic>(),
      );
      final valid = entry['rowNumber'] == 182 ? '7个' : source.cells[1];
      final result = reconcileStockLine(
        StockLine(
          cells: source.cells,
          sourceCells: source.sourceCells,
          category: source.category,
          confidence: source.confidence,
          inventoryReadings: [
            ...source.inventoryReadings,
            ...List.filled(6, valid),
          ],
          inventoryConfidence: source.inventoryConfidence,
          inventoryUncertain: source.inventoryUncertain,
        ),
        products,
      );
      expect(result.ready, true, reason: '行 ${entry['rowNumber']}');
      expect(result.cells[1], valid);
      expect(result.sourceCells, source.sourceCells);
    }
  });
}
