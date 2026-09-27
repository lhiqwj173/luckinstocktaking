import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/catalog_tsv.dart';
import 'package:luckinstocktaking/category.dart';

void main() {
  test('Excel 表格批量更新同名规则并增加品类', () {
    const existing = [
      Category(
        name: '咖啡豆',
        aliases: ['豆'],
        tareGrams: 20,
        referenceGrams: 100,
        referenceQuantity: 10,
        decimals: 0,
      ),
    ];
    final imported = importCatalogTsv(
      '$catalogTsvHeader\r\n'
      '咖啡豆\t豆子\t30\t100\t10\t1\r\n'
      '糖浆\t果糖、糖水\t0\t50\t1\t2\r\n',
    );
    final merged = mergeCatalog(existing, imported);
    expect(merged.length, 2);
    expect(merged.first.calculate(130), '10.0');
    expect(merged.last.aliases, ['果糖', '糖水']);
    expect(importCatalogTsv(exportCatalogTsv(merged)).length, 2);
  });

  test('批量导入拒绝与现有品类冲突的别名', () {
    const existing = [
      Category(
        name: '咖啡豆',
        aliases: ['豆子'],
        tareGrams: 0,
        referenceGrams: 100,
        referenceQuantity: 1,
        decimals: 0,
      ),
    ];
    final imported = importCatalogTsv('$catalogTsvHeader\n糖浆\t豆子\t0\t50\t1\t0');
    expect(() => mergeCatalog(existing, imported), throwsFormatException);
  });
}
