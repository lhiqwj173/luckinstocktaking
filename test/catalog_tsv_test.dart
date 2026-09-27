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

  test('五列表格可更新同名品类的类别和单份重量', () {
    final imported = importCatalogTsv(
      '$catalogTsvHeader\r\n'
      '开封夹称重\taa大福\t新别名\t80\t\r\n'
      '其他\tbb大福\t奶油、芝麻\t120\t35\r\n',
    );
    final merged = mergeCatalog(existing, imported);
    expect(merged.length, 2);
    expect(merged.first.type, WeighingType.openedClip);
    expect(merged.first.calculate(60), '0.5');
    expect(merged.last.aliases, ['奶油', '芝麻']);
    expect(merged.last.tareGrams, 35);
    expect(merged.last.calculate(95), '0.5');
    expect(importCatalogTsv(exportCatalogTsv(merged)).length, 2);
  });

  test('拒绝未知类别、无效重量和跨品类别名冲突', () {
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n未知\taa大福\t\t80\t'),
      throwsFormatException,
    );
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n份盒称重\taa大福\t\t0\t'),
      throwsFormatException,
    );
    final conflicting = importCatalogTsv(
      '$catalogTsvHeader\n开封夹称重\tbb大福\t旧别名\t80\t',
    );
    expect(() => mergeCatalog(existing, conflicting), throwsFormatException);
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n其他\tcc大福\t\t80\t'),
      throwsFormatException,
    );
    expect(
      () => importCatalogTsv('$catalogTsvHeader\n份盒称重\tcc大福\t\t80\t25'),
      throwsFormatException,
    );
  });
}
