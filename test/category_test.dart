import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/category.dart';

void main() {
  const coffee = Category(
    name: '咖啡豆',
    aliases: ['豆子'],
    tareGrams: 20,
    referenceGrams: 50,
    referenceQuantity: 10,
    decimals: 1,
  );
  const tea = Category(
    name: '茶叶',
    aliases: ['红茶'],
    tareGrams: 0,
    referenceGrams: 30,
    referenceQuantity: 6,
    decimals: 0,
  );

  test('按净重和参考规则计算，并按位数输出', () {
    expect(coffee.calculate(145), '25.0');
    expect(tea.calculate(45), '9');
  });

  test('拒绝称重小于容器重和无效规则', () {
    expect(() => coffee.calculate(19), throwsFormatException);
    expect(() => coffee.calculate(double.nan), throwsFormatException);
    expect(
      () => const Category(
        name: '坏规则',
        aliases: [],
        tareGrams: 0,
        referenceGrams: 0,
        referenceQuantity: 1,
        decimals: 0,
      ).validate(),
      throwsFormatException,
    );
  });

  test('全名与别名优先于包含匹配', () {
    expect(findCategories([tea, coffee], ' 豆子 ').first.name, '咖啡豆');
    expect(findCategories([tea, coffee], '咖啡').single.name, '咖啡豆');
    expect(findCategories([tea, coffee], '未知'), isEmpty);
  });

  test('拒绝跨品类别名重复', () {
    final duplicate = Category(
      name: '茶叶',
      aliases: ['豆子'],
      tareGrams: 0,
      referenceGrams: 1,
      referenceQuantity: 1,
      decimals: 0,
    );
    expect(() => validateCatalog([coffee, duplicate]), throwsFormatException);
  });
}
