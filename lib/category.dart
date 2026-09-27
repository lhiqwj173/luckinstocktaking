class Category {
  const Category({
    required this.name,
    required this.aliases,
    required this.tareGrams,
    required this.referenceGrams,
    required this.referenceQuantity,
    required this.decimals,
  });

  final String name;
  final List<String> aliases;
  final double tareGrams;
  final double referenceGrams;
  final double referenceQuantity;
  final int decimals;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    name: json['name'] as String,
    aliases: (json['aliases'] as List<dynamic>).cast<String>(),
    tareGrams: (json['tareGrams'] as num).toDouble(),
    referenceGrams: (json['referenceGrams'] as num).toDouble(),
    referenceQuantity: (json['referenceQuantity'] as num).toDouble(),
    decimals: json['decimals'] as int,
  )..validate();

  Map<String, dynamic> toJson() => {
    'name': name,
    'aliases': aliases,
    'tareGrams': tareGrams,
    'referenceGrams': referenceGrams,
    'referenceQuantity': referenceQuantity,
    'decimals': decimals,
  };

  void validate() {
    if (name.trim().isEmpty || aliases.any((e) => e.trim().isEmpty)) {
      throw const FormatException('品类名称和别名不能为空');
    }
    if (!tareGrams.isFinite ||
        tareGrams < 0 ||
        !referenceGrams.isFinite ||
        referenceGrams <= 0 ||
        !referenceQuantity.isFinite ||
        referenceQuantity <= 0 ||
        decimals < 0 ||
        decimals > 3) {
      throw const FormatException('计算规则无效');
    }
  }

  String calculate(double weightGrams) {
    validate();
    if (!weightGrams.isFinite || weightGrams < 0) {
      throw const FormatException('称重必须为非负有限数');
    }
    if (weightGrams < tareGrams) throw const FormatException('称重不能小于容器重');
    final result =
        (weightGrams - tareGrams) / referenceGrams * referenceQuantity;
    if (!result.isFinite) throw const FormatException('计算结果超出范围');
    return result.toStringAsFixed(decimals);
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
