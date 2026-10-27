import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/category.dart';
import 'package:luckinstocktaking/catalog_file.dart';
import 'package:luckinstocktaking/catalog_tsv.dart';
import 'package:luckinstocktaking/main.dart';
import 'package:luckinstocktaking/recent_weighing.dart';

void main() {
  const category = Category(
    name: '净重原料',
    aliases: [],
    type: WeighingType.other,
    singleServingGrams: 100,
    customTareGrams: 0.3,
    returnNetWeight: true,
  );

  test('净重按十进制精确相减，无份数下限或上限', () {
    expect(category.calculate(0.3), '0 g');
    expect(category.calculate(0.3001), '0.0001 g');
    expect(category.calculate(125.425), '125.125 g');
    expect(category.calculate(0.4), '0.1 g');
    expect(() => category.calculate(0.2), throwsFormatException);
    expect(() => category.calculate(double.nan), throwsFormatException);
    expect(() => category.calculate(double.infinity), throwsFormatException);
  });

  test('净重设置在 JSON、TSV、克隆中保留，旧规则默认份数', () {
    for (final restored in [
      Category.fromJson(category.toJson()),
      importCatalogFile(exportCatalogFile([category])).single,
      importCatalogTsv(exportCatalogTsv([category])).single,
      cloneCategory([category], category),
    ]) {
      expect(restored.returnNetWeight, isTrue);
      expect(restored.calculate(0.4), '0.1 g');
    }
    final old = category.toJson()..remove('returnNetWeight');
    expect(Category.fromJson(old).returnNetWeight, isFalse);
    expect(
      () => importCatalogTsv(
        exportCatalogTsv([category]).replaceFirst(RegExp(r'是$'), '未知'),
      ),
      throwsFormatException,
    );
  });

  test('净重历史保留单位及复制结果，禁止份数格式混入', () {
    final json = <String, dynamic>{
      'id': 'net-record',
      'createdAt': 0,
      'categoryName': '净重原料',
      'weightGrams': 325.125,
      'tareGrams': 300,
      'singleServingGrams': 100,
      'typeLabel': '份盒称重',
      'result': '25.125 g',
      'source': 'shortcut',
      'allowMultiple': false,
      'returnNetWeight': true,
    };
    expect(WeighingRecord.fromJson(json).copyText, '净重原料：25.125 g');
    expect(
      () => WeighingRecord.fromJson({...json, 'result': '0.2（0.251）'}),
      throwsFormatException,
    );
    expect(
      () => WeighingRecord.fromJson({...json, 'returnNetWeight': false}),
      throwsFormatException,
    );
  });

  testWidgets('新增净重品类无需填写单份重量', (tester) async {
    Category? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<Category>(
                  context: context,
                  builder: (_) => const CategoryDialog(),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '品类名称'), '净重原料');
    await tester.tap(find.text('返回净重（g）'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '单份原料重量（克）'), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.returnNetWeight, isTrue);
    expect(saved!.calculate(325.125), '25.125 g');
  });
}
