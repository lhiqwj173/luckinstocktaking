import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_latest.dart';
import 'package:luckinstocktaking/stock_latest_page.dart';
import 'package:luckinstocktaking/stock_product.dart';

final coconut = StockProduct(
  code: 'GS10001-01',
  name: '椰乳',
  specification: '1L*12盒/箱',
  units: ['盒', '箱'],
  aliases: ['椰奶'],
);
final milk = StockProduct(
  code: 'GS10002-01',
  name: '牛奶',
  specification: '1L*12盒/箱',
  units: ['盒', '箱'],
);

StockLine line(
  StockProduct product,
  String quantity, {
  bool confirmed = true,
}) => StockLine(
  cells: [product.display, quantity],
  confidence: .95,
  category: product.category,
  productId: product.id,
  identityConfirmed: true,
  inventoryConfirmed: confirmed,
);

StockDocument document(int number, List<StockLine> lines, {int? day}) {
  final id = '12345678-1234-1234-1234-${number.toString().padLeft(12, '0')}';
  return StockDocument(
    id: id,
    title: '盘点单$number',
    createdAt: DateTime.utc(2026, 10, day ?? number),
    imageName: '$id.png',
    lines: lines,
    reviewed: lines.every((line) => line.ready),
    schemaVersion: 2,
  );
}

void main() {
  test('各品类独立选择最近录入单据，列表顺序不影响结果', () {
    final older = document(1, [line(coconut, '8盒'), line(milk, '5盒')]);
    final newer = document(2, [line(coconut, '3盒')]);
    for (final documents in [
      [older, newer],
      [newer, older],
    ]) {
      final records = latestStockRecords(documents, [coconut, milk]);
      expect(
        records.singleWhere((r) => r.product!.id == coconut.id).document.id,
        newer.id,
      );
      expect(
        records.singleWhere((r) => r.product!.id == milk.id).document.id,
        older.id,
      );
    }
  });

  test('零库存、未填写和未确认均保留最新记录，不回退到旧库存', () {
    for (final quantity in ['0盒', '', '—', '2盒']) {
      final newer = document(2, [line(coconut, quantity, confirmed: false)]);
      final record = latestStockRecords(
        [
          document(1, [line(coconut, '8盒')]),
          newer,
        ],
        [coconut],
      ).single;
      expect(record.document.id, newer.id);
      expect(record.lines.single.cells[1], quantity);
      expect(record.confirmed, isFalse);
    }
  });

  test('最新行有准确货号但身份或规格待确认时仍阻断更早库存', () {
    final pending = StockLine(
      cells: ['椰乳 2L*12盒/箱 ${coconut.code}', '4盒'],
      confidence: .8,
    );
    final record = latestStockRecords(
      [
        document(1, [line(coconut, '8盒')]),
        document(2, [pending]),
      ],
      [coconut],
    ).single;
    expect(record.document.title, '盘点单2');
    expect(record.confirmed, isFalse);
  });

  test('同单重复不相加，最新时间相同的来源全部展示', () {
    final records = latestStockRecords(
      [
        document(1, [line(coconut, '3盒'), line(coconut, '4盒')], day: 3),
        document(2, [line(coconut, '5盒')], day: 3),
      ],
      [coconut],
    );
    expect(records, hasLength(2));
    expect(records.every((record) => record.sameTimestamp), isTrue);
    expect(records.first.lines, hasLength(2));
    expect(records.first.confirmed, isFalse);
  });

  test('不同规格和预制物料分别查询，支持别名与货号', () {
    final other = StockProduct(
      code: 'GS10001-02',
      name: '椰乳',
      specification: '500ml*12盒/箱',
      units: ['盒', '箱'],
    );
    final prepared = StockProduct(
      code: '',
      name: '椰乳',
      specification: '',
      units: ['份'],
      category: 'prepared',
    );
    final records = latestStockRecords(
      [
        document(1, [
          line(coconut, '3盒'),
          line(other, '2盒'),
          line(prepared, '1份'),
        ]),
      ],
      [coconut, other, prepared],
    );
    expect(records, hasLength(3));
    expect(records.where((r) => r.matches('椰奶 1L')), hasLength(1));
    expect(records.where((r) => r.matches('gs10001-02')), hasLength(1));
    expect(records.where((r) => r.category == 'prepared'), hasLength(1));
  });

  test('旧格式和重复单据标识立即报错，不能产出不完整结果', () {
    final current = document(1, [line(coconut, '3盒')]);
    expect(
      () => latestStockRecords([current, current], [coconut]),
      throwsFormatException,
    );
    final legacy = StockDocument.fromJson({
      ...current.toJson(),
      'schemaVersion': 1,
    });
    expect(
      () => latestStockRecords([legacy], [coconut]),
      throwsFormatException,
    );
  });

  testWidgets('独立页面查询别名、展示来源、刷新后移除已删除记录', (tester) async {
    final documents = [
      document(1, [line(coconut, '3盒')]),
    ];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      switch (call.method) {
        case 'loadProducts':
          return jsonEncode([coconut.toJson()]);
        case 'list':
          return jsonEncode(documents.map((d) => d.toJson()).toList());
        default:
          throw StateError('意外的平台请求：${call.method}');
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await tester.pumpWidget(const MaterialApp(home: LatestStockPage()));
    await tester.pumpAndSettle();
    expect(find.text('3盒'), findsOneWidget);
    expect(find.text('来源：盘点单1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '椰奶');
    await tester.pump();
    expect(find.text('3盒'), findsOneWidget);
    documents.clear();
    await tester.tap(find.byTooltip('刷新库存'));
    await tester.pumpAndSettle();
    expect(find.text('3盒'), findsNothing);
    expect(find.text('暂无盘点记录，请先录入盘点单。'), findsOneWidget);
  });
}
