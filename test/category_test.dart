import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/category.dart';

void main() {
  const box = Category(
    name: 'aa大福',
    aliases: ['红豆大福'],
    type: WeighingType.portionBox,
    singleServingGrams: 100,
  );
  const clip = Category(
    name: 'bb大福',
    aliases: ['奶油大福'],
    type: WeighingType.openedClip,
    singleServingGrams: 80,
  );

  test('两种容器重均计算 0～1 份，结果保留一位小数', () {
    expect(box.calculate(250), '0.0');
    expect(box.calculate(275), '0.3');
    expect(box.calculate(350), '1.0');
    expect(clip.calculate(20), '0.0');
    expect(clip.calculate(60), '0.5');
    expect(clip.calculate(100), '1.0');
  });

  test('原始结果超出 0～1 即报错，不先四舍五入或截断', () {
    for (final weight in [249.99, 350.01, double.nan, double.infinity]) {
      expect(() => box.calculate(weight), throwsFormatException);
    }
    expect(() => clip.calculate(100.01), throwsFormatException);
    expect(() => clip.calculate(19.99), throwsFormatException);
  });

  test('名称和别名模糊查找，精确结果优先', () {
    expect(findCategories([clip, box], '大福').map((e) => e.name), [
      'aa大福',
      'bb大福',
    ]);
    expect(findCategories([box, clip], ' 奶油大福 ').first.name, 'bb大福');
    expect(findCategories([box, clip], '未知'), isEmpty);
  });

  test('同名品类不能跨称重类别重复，别名也不能冲突', () {
    expect(() => validateCatalog([box, clip]), returnsNormally);
    expect(() => validateCatalog([box, box]), throwsFormatException);
    expect(
      () => validateCatalog([
        box,
        const Category(
          name: '其他',
          aliases: ['红豆大福'],
          type: WeighingType.openedClip,
          singleServingGrams: 20,
        ),
      ]),
      throwsFormatException,
    );
  });
}
