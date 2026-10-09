enum WeighingType {
  portionBox('份盒称重', 300),
  openedClip('开封夹称重', 21),
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
    this.allowMultiple = false,
  });
  final String name;
  final List<String> aliases;
  final WeighingType type;
  final double singleServingGrams;
  final double? customTareGrams;
  final bool allowMultiple;
  double get tareGrams =>
      type == WeighingType.other ? customTareGrams! : type.tareGrams!;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    name: json['name'] as String,
    aliases: (json['aliases'] as List<dynamic>).cast<String>(),
    type: WeighingType.fromKey(json['type'] as String),
    singleServingGrams: (json['singleServingGrams'] as num).toDouble(),
    customTareGrams: (json['customTareGrams'] as num?)?.toDouble(),
    allowMultiple: json.containsKey('allowMultiple')
        ? json['allowMultiple'] as bool
        : false,
  )..validate();

  Map<String, dynamic> toJson() => {
    'name': name,
    'aliases': aliases,
    'type': type.name,
    'singleServingGrams': singleServingGrams,
    if (customTareGrams != null) 'customTareGrams': customTareGrams,
    'allowMultiple': allowMultiple,
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
    if (netGrams < 0) {
      throw FormatException('${type.label}的称重不能低于皮重 $tareGrams 克，请检查输入重量');
    }
    final ratio = netGrams / singleServingGrams;
    if (!ratio.isFinite) {
      throw const FormatException('称重与单份重量的比值超出有效范围');
    }
    final int tenths;
    if (!allowMultiple && ratio >= 0.9) {
      tenths = 9;
    } else {
      final scaled = ratio * 10;
      if (!scaled.isFinite) {
        throw const FormatException('称重与单份重量的比值超出有效范围');
      }
      final roundedTenths = scaled.floor();
      tenths = allowMultiple
          ? (roundedTenths < 1 ? 1 : roundedTenths)
          : roundedTenths.clamp(1, 9).toInt();
    }
    return '${tenths ~/ 10}.${tenths % 10}（${ratio.toStringAsFixed(3)}）';
  }
}

Category cloneCategory(List<Category> categories, Category source) {
  validateCatalog(categories);
  if (!categories.contains(source)) throw ArgumentError('待克隆的品类不在当前列表中');
  final occupied = categories
      .expand((category) => [category.name, ...category.aliases])
      .map(normalizeName)
      .toSet();
  final baseName = source.name.replaceFirst(RegExp(r'（副本\d*）$'), '');
  var number = 1;
  late String name;
  do {
    name = '$baseName（副本${number == 1 ? '' : number}）';
    number++;
  } while (occupied.contains(normalizeName(name)));
  return Category(
    name: name,
    aliases: const [],
    type: source.type,
    singleServingGrams: source.singleServingGrams,
    customTareGrams: source.customTareGrams,
    allowMultiple: source.allowMultiple,
  );
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
