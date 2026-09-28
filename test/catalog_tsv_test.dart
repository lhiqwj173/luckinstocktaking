import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/catalog_tsv.dart';
import 'package:luckinstocktaking/category.dart';

void main() {
  const existing = [
    Category(
      name: 'aa大福',
      aliases: ['旧别名'],
      type: WeighingType.portionBox,
      singleServingGrams: 100,
    ),
  ];

  test('六列表格可更新同名品类并保留多份设置', () {
    final imported = importCatalogTsv(
      '$catalogTsvHeader\r\n'
      '开封夹称重\taa大福\t新别名\t80\t\t否\r\n'
      '其他\tbb大福\t奶油、芝麻\t120\t35\t是\r\n',
    );
    final merged = mergeCatalog(existing, imported);
    expect(merged.length, 2);
    expect(merged.first.type, WeighingType.openedClip);
    expect(merged.first.calculate(60), '0.5');
    expect(merged.last.aliases, ['奶油', '芝麻']);
    expect(merged.last.tareGrams, 35);
    expect(merged.last.calculate(95), '0.5');
    expect(merged.last.calculate(275), '2.0');
    final roundTrip = importCatalogTsv(exportCatalogTsv(merged));
    expect(roundTrip.length, 2);
    expect(roundTrip.last.allowMultiple, isTrue);
  });

  test('旧五列表格导入后默认不允许多份', () {
    final imported = importCatalogTsv(
      '称重类别\t品类\t别名\t单份重量(克)\t皮重(克)\n'
      '份盒称重\t旧品类\t\t100\t',
    );
    expect(imported.single.allowMultiple, isFalse);
    expect(imported.single.calculate(350), '0.9');
  });

  test('拒绝未知类别、无效重量和跨品类别名冲突', () {
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n未知\taa大福\t\t80\t\t否'),
      throwsFormatException,
    );
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n份盒称重\taa大福\t\t0\t\t否'),
      throwsFormatException,
    );
    final conflicting = importCatalogTsv(
      '$catalogTsvHeader\n开封夹称重\tbb大福\t旧别名\t80\t\t否',
    );
    expect(() => mergeCatalog(existing, conflicting), throwsFormatException);
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n其他\tcc大福\t\t80\t\t否'),
      throwsFormatException,
    );
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n份盒称重\tcc大福\t\t80\t25\t否'),
      throwsFormatException,
    );
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n份盒称重\tcc大福\t\t80\t\t未知'),
      throwsFormatException,
    );
  });
}
