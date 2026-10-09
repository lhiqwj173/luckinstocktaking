import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_export.dart';
import 'package:luckinstocktaking/stock_comparison.dart';
import 'package:luckinstocktaking/stock_product.dart';

StockProduct product(String code, String spec) => StockProduct(
  code: code,
  name: '测试椰乳',
  specification: spec,
  units: ['盒', '箱'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('人工初始档案字段有效、货号唯一且每条可追溯，不携带库存数量', () {
    final seed = jsonDecode(
      File('assets/stock_products_seed.json').readAsStringSync(encoding: utf8),
    ) as Map<String, dynamic>;
    expect(seed['schemaVersion'], 1);
    expect(seed['verification'], 'manual_visual');
    expect(seed['version'], isNotEmpty);
    final reviewed = (seed['reviewedImages'] as List).cast<String>();
    expect(reviewed.toSet().length, reviewed.length);
    final rows = (seed['products'] as List).cast<Map<String, dynamic>>();
    expect(rows, isNotEmpty);
    validateProducts(rows.map(StockProduct.fromJson).toList());
    final allowedFields = {
      'id',
      'code',
      'name',
      'specification',
      'units',
      'aliases',
      'category',
      'sourceImages',
    };
    for (final row in rows) {
      expect(row.keys.toSet().difference(allowedFields), isEmpty);
      final sources = (row['sourceImages'] as List).cast<String>();
      expect(sources, isNotEmpty);
      expect(sources.toSet().length, sources.length);
      expect(sources.every(reviewed.contains), true);
    }
  });
  test('装载时提供经过验证的种子，保存仍只传用户档案', () async {
    const channel = MethodChannel('com.luckinstocktaking/history');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final maintained = product('GS10001-01', '用户维护的规格');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadProducts') {
        final arguments = (call.arguments as Map).cast<String, dynamic>();
        expect(arguments['seedVersion'], isNotEmpty);
        final seed = (arguments['seedProducts'] as List)
            .map(
              (row) =>
                  StockProduct.fromJson((row as Map).cast<String, dynamic>()),
            )
            .toList();
        validateProducts(seed);
        expect(seed, isNotEmpty);
        return jsonEncode([maintained.toJson()]);
      }
      if (call.method == 'saveProducts') {
        final rows = jsonDecode(call.arguments as String) as List;
        expect(rows.single['specification'], maintained.specification);
        return null;
      }
      throw StateError('意外的平台请求：${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = StockProductStore();
    final loaded = await store.load();
    expect(loaded.single.specification, maintained.specification);
    await store.save(loaded);
  });
  test('同名不同规格独立，冲突货号和规格不被模糊匹配隐藏', () {
    final products = [
      product('GS10001-01', '1L*12盒/箱'),
      product('GS10001-02', '250ml*24盒/箱'),
    ];
    final matches = matchProducts(
      '测试椰乳250ml*24盒/箱 GS10001-01',
      'goods',
      products,
    );
    expect(matches.first.exactCode, true);
    expect(matches.first.conflict, true);
    expect(matches, hasLength(1));
    expect(matches.single.product.code, 'GS10001-01');
    expect(products[0].id, isNot(products[1].id));
  });
  test('缺货号仍有名称候选，空读数不能补出商品', () {
    final products = [product('GS10001-01', '1L*12盒/箱')];
    expect(
      matchProducts('测试椰奶1L*12盒/箱', 'goods', products).first.exactCode,
      false,
    );
    expect(matchProducts('', 'goods', products), isEmpty);
    expect(
      matchProducts(products.single.display, 'prepared', products),
      isEmpty,
    );
  });
  test('档案导入拒绝重复货号和无效字段，库存不进入档案', () {
    const header = '货号\t名称\t规格\t库存单位\t别名\t类别';
    const row = 'GS10001-01\t测试椰乳\t1L*12盒/箱\t盒、箱\t\t货物';
    final products = importProducts('$header\n$row');
    expect(products.single.units, ['盒', '箱']);
    expect(products.single.toJson().containsKey('inventory'), false);
    expect(() => importProducts('$header\n$row\n$row'), throwsFormatException);
    expect(
      () => importProducts('$header\nGS10001-01\t测试\t\t\t\t货物'),
      throwsFormatException,
    );
    expect(
      StockProduct.fromJson(products.single.toJson()).id,
      products.single.id,
    );
  });
  test('OCR 高评分仍是草稿，手工确认不修改原始评分和库存证据', () {
    final original = StockLine(
      cells: ['模糊品名', '0.9盒'],
      confidence: 1,
      sourceTop: 100,
      sourceBottom: 200,
    );
    expect(original.ready, false);
    expect(
      () => buildConfirmedStockExportTable('测试', [original]),
      throwsFormatException,
    );
    final confirmed = original.confirmed(
      cells: ['正确名称\nGS10001-01', '0.9盒'],
      productId: 'GS10001-01',
      allowedUnits: ['盒'],
    );
    expect(confirmed.ready, true);
    expect(confirmed.sourceCells, original.cells);
    expect(confirmed.confidence, 1);
    final restored = StockLine.fromJson(
      jsonDecode(jsonEncode(confirmed.toJson())) as Map<String, dynamic>,
    );
    expect(restored.ready, true);
    expect(restored.sourceTop, 100);
    expect(restored.invalidateIdentity().ready, false);
    expect(restored.invalidateIdentity().inventoryConfirmed, true);
    final table = buildConfirmedStockExportTable('测试', [restored]);
    expect(table.textAt(0, stockExportRawHeader), '0.9盒');
    StockDocument document(String prefix, StockLine line) => StockDocument(
      id: '${prefix}2345678-1234-1234-1234-123456789abc',
      title: '测试',
      createdAt: DateTime.utc(2026),
      imageName: '${prefix}2345678-1234-1234-1234-123456789abc.png',
      lines: [line],
      reviewed: false,
      schemaVersion: 2,
    );
    expect(
      () => StockComparison(document('1', original), document('2', restored)),
      throwsFormatException,
    );
  });
  test('确认与零值、空白、无效数字分开，不推测未知库存', () {
    StockLine line(String quantity) =>
        StockLine(cells: ['测试', quantity], confidence: .3).confirmed(
          cells: ['测试\nGS10001-01', quantity],
          productId: 'GS10001-01',
          allowedUnits: ['盒'],
        );
    expect(line('0盒').ready, true);
    expect(line('').ready, true);
    expect(line('').inventory.hasValue, false);
    expect(() => line('7TX'), throwsFormatException);
    expect(() => line('总库存3盒 冷藏1盒 冷冻1盒'), throwsFormatException);
    expect(
      () => StockLine(
        cells: ['测试', '1盒'],
        confidence: .9,
        identityConfirmed: true,
      ),
      throwsFormatException,
    );
    expect(
      () => StockLine(
        cells: ['测试', '1盒'],
        confidence: .9,
        sourceTop: 10,
        sourceBottom: 5,
      ),
      throwsFormatException,
    );
  });
}
