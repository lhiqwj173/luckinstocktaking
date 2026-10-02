import 'package:flutter/material.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_comparison.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_inventory.dart';
import 'package:luckinstocktaking/stock_inventory_view.dart';
import 'package:luckinstocktaking/stock_comparison_page.dart';
import 'package:luckinstocktaking/stock_history_page.dart';

StockLine line(String code, String inventory, {bool uncertain = false}) =>
    StockLine(
      cells: ['测试货物\n$code', inventory],
      confidence: .9,
      inventoryUncertain: uncertain,
    );
StockDocument document(String prefix, List<StockLine> lines) => StockDocument(
  id: '${prefix}2345678-1234-1234-1234-123456789abc',
  title: prefix == '1' ? '基准盘点单' : '对照盘点单',
  createdAt: DateTime.utc(2026, 10, 2),
  imageName: '${prefix}2345678-1234-1234-1234-123456789abc.png',
  lines: lines,
  reviewed: true,
  schemaVersion: 2,
);

void main() {
  test('占位符和空库存合法且不同于明确零值', () {
    for (final text in ['', '-袋', '-袋-根', '－盒－个', '总库存:-个\n冷藏:-盒-个\n冷冻:-盒-个']) {
      expect(StockInventory.parse(text).hasValue, false);
      expect(StockInventory.parse(text).needsReview, false);
      final entry = line('GS08291-01', text);
      expect(StockLine.fromJson(entry.toJson()).cells[1], text);
      expect(entry.reviewIssue, isNull);
    }
    expect(StockInventory.parse('0袋').hasValue, true);
    expect(StockInventory.parse('13').parts['库存']!.display, '13');
    expect(StockInventory.parse('-箱13包').parts['库存']!.display, '13包');
    expect(
      StockInventory.parse('I3包').hasValue,
      false,
      reason: '不能把漏识别的 I3 当作 3',
    );
    expect(StockInventory.parse('I3包').needsReview, true);
    final empty = document('1', [line('GS08291-01', '')]);
    expect(() => empty.validate(), returnsNormally);
  });

  test('仅比较双方有值的货号，零值参加比较，单边和未知项排除', () {
    final a = document('1', [
      line('GS08291-01', '14个'),
      line('GS09137-01', '-袋'),
      line('GS09637-02', '0个'),
      line('GS10454-01', '2袋'),
    ]);
    final b = document('2', [
      line('GS08291-01', '17个'),
      line('GS09137-01', '3袋'),
      line('GS09637-02', '2个'),
      line('GS10454-01', '', uncertain: true),
    ]);
    final comparison = StockComparison(a, b);
    expect(comparison.rows.length, 2);
    expect(comparison.excluded, 2);
    expect(comparison.rows[0].differences.single.display, '+3个');
    expect(comparison.rows[1].differences.single.display, '+2个');
  });

  test('冷藏冷冻位置分别对比，不将单边未填写的位置当零', () {
    final a = document('1', [line('GS08291-01', '总库存:14个\n冷藏:2个\n冷冻:12个')]);
    final b = document('2', [line('GS08291-01', '总库存:17个\n冷藏:-个\n冷冻:17个')]);
    final row = StockComparison(a, b).rows.single;
    expect(row.differences.map((e) => e.display), ['+3个', '冷冻 +5个']);
  });

  test('小数精确计算，单位不猜测换算，重复货号明确拒绝', () {
    final a = document('1', [line('GS08291-01', '0.1袋')]);
    final b = document('2', [line('GS08291-01', '0.3袋')]);
    expect(
      StockComparison(a, b).rows.single.differences.single.display,
      '+0.2袋',
    );
    expect(
      StockComparison(b, a).rows.single.differences.single.display,
      '-0.2袋',
    );
    expect(
      StockComparison(
        a,
        document('2', [line('GS08291-01', '1盒')]),
      ).rows.single.unitMismatch,
      true,
    );
    expect(
      () => StockComparison(
        a,
        document('2', [line('GS08291-01', '1袋'), line('GS08291-01', '2袋')]),
      ),
      throwsFormatException,
    );
  });

  testWidgets('库存以总数和冷藏冷冻标签展示，空值显示未填写', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockInventoryView(
            inventory: StockInventory.parse('总库存:5盒\n冷藏:2盒\n冷冻:3盒'),
          ),
        ),
      ),
    );
    expect(find.text('5盒'), findsOneWidget);
    expect(find.text('冷藏 2盒'), findsOneWidget);
    expect(find.text('冷冻 3盒'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockInventoryView(inventory: StockInventory.parse('-袋')),
        ),
      ),
    );
    expect(find.text('未填写'), findsOneWidget);
  });

  testWidgets('差异页默认只看差异，可以显示相同项目', (tester) async {
    final a = document('1', [
      line('GS08291-01', '1盒'),
      line('GS09137-01', '3袋'),
    ]);
    final b = document('2', [
      line('GS08291-01', '2盒'),
      line('GS09137-01', '3袋'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: StockComparisonPage(
          baseline: a,
          target: b,
          comparison: StockComparison(a, b),
        ),
      ),
    );
    expect(find.text('增加 1盒'), findsOneWidget);
    expect(find.text('库存相同'), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('库存相同'), findsOneWidget);
  });

  testWidgets('历史页选择两份单据后进入差异页', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final a = document('1', [line('GS08291-01', '1盒')]);
    final b = document('2', [line('GS08291-01', '2盒')]);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method != 'list') throw StateError('已校对单据不应重新识别');
      return jsonEncode([
        a.toJson(),
        {...b.toJson(), 'createdAt': '2026-10-03T00:00:00Z'},
      ]);
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对比盘点单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看差异'));
    await tester.pumpAndSettle();
    expect(find.text('库存差异'), findsOneWidget);
    expect(find.text('增加 1盒'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
