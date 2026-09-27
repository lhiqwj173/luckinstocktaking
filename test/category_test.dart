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
  const other = Category(
    name: 'cc大福',
    aliases: ['抹茶大福'],
    type: WeighingType.other,
    singleServingGrams: 100,
    customTareGrams: 35,
  );

  test('两种容器重均计算 0.1～0.9 份，结果保留一位小数', () {
    expect(box.calculate(250), '0.1');
    expect(box.calculate(254), '0.1');
    expect(box.calculate(275), '0.3');
    expect(box.calculate(345), '0.9');
    expect(box.calculate(350), '0.9');
    expect(clip.calculate(20), '0.1');
    expect(clip.calculate(60), '0.5');
    expect(clip.calculate(100), '0.9');
  });

  test('其他类别使用自定义皮重，允许 0 克皮重', () {
    expect(other.calculate(35), '0.1');
    expect(other.calculate(85), '0.5');
    expect(other.calculate(135), '0.9');
    expect(() => other.calculate(135.01), throwsFormatException);
    expect(
      const Category(
        name: '零皮重',
        aliases: [],
        type: WeighingType.other,
        singleServingGrams: 40,
        customTareGrams: 0,
      ).calculate(20),
      '0.5',
    );
  });

  test('自定义皮重仅适用于其他类别且必须有限、非负', () {
    for (final tare in <double?>[null, -1, double.nan, double.infinity]) {
      expect(
        () => Category(
          name: '错误',
          aliases: [],
          type: WeighingType.other,
          singleServingGrams: 100,
          customTareGrams: tare,
        ).validate(),
        throwsFormatException,
      );
    }
    expect(
      () => const Category(
        name: '错误',
        aliases: [],
        type: WeighingType.portionBox,
        singleServingGrams: 100,
        customTareGrams: 250,
      ).validate(),
      throwsFormatException,
    );
  });

  test('JSON 往返保留其他类别皮重，固定类别旧数据仍可读取', () {
    final restored = Category.fromJson(other.toJson());
    expect(restored.customTareGrams, 35);
    expect(restored.calculate(85), '0.5');
    expect(Category.fromJson(box.toJson()).calculate(300), '0.5');
  });

  test('原始称重超出皮重至一份重量范围仍报错', () {
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
