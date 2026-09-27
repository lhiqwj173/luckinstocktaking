enum WeighingType {
  portionBox('份盒称重', 250),
  openedClip('开封夹称重', 20),
  other('其他', null);

  const WeighingType(this.label, this.tareGrams);
  final String label;
  final double? tareGrams;
  static WeighingType fromKey(String key) => WeighingType.values.firstWhere(
    (type) => type.name == key,
    orElse: () => throw FormatException('未知称重类别：$key'),
  );
}

class Category {
  const Category({
    required this.name,
    required this.aliases,
    required this.type,
    required this.singleServingGrams,
    this.customTareGrams,
  });
  final String name;
  final List<String> aliases;
  final WeighingType type;
  final double singleServingGrams;
  final double? customTareGrams;
  double get tareGrams =>
      type == WeighingType.other ? customTareGrams! : type.tareGrams!;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    name: json['name'] as String,
    aliases: (json['aliases'] as List<dynamic>).cast<String>(),
    type: WeighingType.fromKey(json['type'] as String),
    singleServingGrams: (json['singleServingGrams'] as num).toDouble(),
    customTareGrams: (json['customTareGrams'] as num?)?.toDouble(),
  )..validate();

  Map<String, dynamic> toJson() => {
    'name': name,
    'aliases': aliases,
    'type': type.name,
    'singleServingGrams': singleServingGrams,
    if (customTareGrams != null) 'customTareGrams': customTareGrams,
  };

  void validate() {
    if (name.trim().isEmpty || aliases.any((e) => e.trim().isEmpty)) {
      throw const FormatException('品类名称和别名不能为空');
    }
    if (!singleServingGrams.isFinite || singleServingGrams <= 0) {
      throw const FormatException('单份重量必须大于 0 克');
    }
    if (type == WeighingType.other) {
      if (customTareGrams == null ||
          !customTareGrams!.isFinite ||
          customTareGrams! < 0) {
        throw const FormatException('“其他”类别必须填写不小于 0 克的皮重');
      }
    } else if (customTareGrams != null) {
      throw const FormatException('固定称重类别不能自定义皮重');
    }
    if (!(tareGrams + singleServingGrams).isFinite) {
      throw const FormatException('皮重与单份重量之和超出有效范围');
    }
  }

  String calculate(double weightGrams) {
    validate();
    if (!weightGrams.isFinite || weightGrams < 0) {
      throw const FormatException('请输入有效的称重（克）');
    }
    final netGrams = weightGrams - tareGrams;
    if (netGrams < 0 || netGrams > singleServingGrams) {
      throw FormatException(
        '称重超出 ${type.label} 的合理范围（$tareGrams～${tareGrams + singleServingGrams} 克），请检查输入重量',
      );
    }
    final tenths = (netGrams / singleServingGrams * 10 + 0.5).floor();
    return '${tenths ~/ 10}.${tenths % 10}';
  }
}

String normalizeName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

List<Category> findCategories(Iterable<Category> categories, String query) {
  final key = normalizeName(query);
  if (key.isEmpty) return [];
  final matches = <(int, Category)>[];
  for (final category in categories) {
    final names = [category.name, ...category.aliases].map(normalizeName);
    var score = 0;
    for (final name in names) {
      if (name == key) {
        score = 2;
        break;
      }
      if (name.contains(key)) score = 1;
    }
    if (score > 0) matches.add((score, category));
  }
  matches.sort((a, b) {
    final rank = b.$1.compareTo(a.$1);
    return rank != 0 ? rank : a.$2.name.compareTo(b.$2.name);
  });
  return matches.map((e) => e.$2).toList();
}

void validateCatalog(List<Category> categories) {
  final keys = <String>{};
  for (final category in categories) {
    category.validate();
    for (final name in [category.name, ...category.aliases]) {
      if (!keys.add(normalizeName(name))) {
        throw FormatException('名称或别名重复：$name');
      }
    }
  }
}
