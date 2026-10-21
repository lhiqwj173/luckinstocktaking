import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/catalog_file.dart';
import 'package:luckinstocktaking/category.dart';
import 'package:luckinstocktaking/main.dart';
import 'package:luckinstocktaking/stock_history.dart';

const _categories = [
  Category(
    name: '份盒',
    aliases: ['带、分隔符的别名'],
    type: WeighingType.portionBox,
    singleServingGrams: 100,
  ),
  Category(
    name: '开封',
    aliases: [],
    type: WeighingType.openedClip,
    singleServingGrams: 80,
  ),
  Category(
    name: '自定义',
    aliases: ['别名'],
    type: WeighingType.other,
    singleServingGrams: 12.5,
    customTareGrams: 0,
    allowMultiple: true,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('规则文件往返完整保留三种称重规则、特殊别名和多份设置', () {
    final restored = importCatalogFile(
      '\uFEFF${exportCatalogFile(_categories)}',
    );
    expect(restored.map((e) => e.toJson()), _categories.map((e) => e.toJson()));
    expect(importCatalogFile(exportCatalogFile([])), isEmpty);
  });

  test('拒绝损坏文件、未知版本、错误字段、无效重量和名称冲突', () {
    for (final input in [
      '{',
      '[]',
      '{}',
      '{"format":"other","version":1,"categories":[]}',
    ]) {
      expect(() => importCatalogFile(input), throwsFormatException);
    }
    final valid =
        jsonDecode(exportCatalogFile(_categories)) as Map<String, dynamic>;
    expect(
      () => importCatalogFile(jsonEncode({...valid, 'version': 2})),
      throwsFormatException,
    );
    final category = _categories.first.toJson();
    for (final invalid in [
      {...category, 'name': null},
      {
        ...category,
        'aliases': [1],
      },
      {...category, 'type': 'unknown'},
      {...category, 'singleServingGrams': 0},
      {...category, 'singleServingGrams': '100'},
      {...category, 'allowMultiple': '是'},
      {...category, 'customTareGrams': 10},
    ]) {
      expect(
        () => importCatalogFile(
          jsonEncode({
            ...valid,
            'categories': [invalid],
          }),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => importCatalogFile(
        jsonEncode({
          ...valid,
          'categories': [category, category],
        }),
      ),
      throwsFormatException,
    );
  });

  const channel = MethodChannel('com.luckinstocktaking/catalog');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String? picked;
  late List<String> saves;
  late Map<dynamic, dynamic>? shared;

  setUp(() {
    picked = exportCatalogFile(_categories);
    saves = [];
    shared = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'diagnostics':
          return {'version': 'test', 'appBundleId': 'test'};
        case 'load':
          return jsonEncode([_categories.first.toJson()]);
        case 'importFile':
          return picked;
        case 'save':
          saves.add(call.arguments as String);
          return null;
        default:
          throw StateError('未预期的品类调用：${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'pending') return null;
      if (call.method == 'shareBytes') {
        shared = call.arguments as Map;
        return null;
      }
      throw StateError('未预期的历史调用：${call.method}');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, null);
  });

  Future<void> openAction(WidgetTester tester, String action) async {
    await tester.pumpWidget(const StocktakingApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('导入导出品类规则'));
    await tester.tap(find.byTooltip('导入导出品类规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  testWidgets('文件导入先预览，确认后一次保存合并结果', (tester) async {
    await openAction(tester, '导入规则文件');
    expect(find.textContaining('新增 2 个品类，更新 1 个同名品类'), findsOneWidget);
    expect(saves, isEmpty);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saves, hasLength(1));
    expect(
      jsonDecode(saves.single),
      _categories.map((e) => e.toJson()).toList(),
    );
  });

  testWidgets('取消确认不保存', (tester) async {
    await openAction(tester, '导入规则文件');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saves, isEmpty);
  });

  testWidgets('取消选文件不显示预览也不保存', (tester) async {
    picked = null;
    await openAction(tester, '导入规则文件');
    expect(find.text('确认导入'), findsNothing);
    expect(saves, isEmpty);
  });

  testWidgets('非法文件不保存并显示错误', (tester) async {
    picked = '{}';
    await openAction(tester, '导入规则文件');
    expect(find.text('确认导入'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('请选择本应用导出的'),
      ),
      findsOneWidget,
    );
    expect(saves, isEmpty);
  });

  testWidgets('导出通过系统分享传递可再次导入的 UTF-8 文件', (tester) async {
    await openAction(tester, '导出规则文件');
    expect(shared!['name'], '品类规则.json');
    final restored = importCatalogFile(
      utf8.decode(shared!['bytes'] as List<int>),
    );
    expect(restored.single.toJson(), _categories.first.toJson());
    expect(saves, isEmpty);
  });
}
