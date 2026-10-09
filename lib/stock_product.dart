import 'dart:convert';

import 'package:flutter/services.dart';

import 'stock_history.dart';
import 'stock_inventory.dart';

String productKey(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('×', '*')
    .replaceAll('－', '-')
    .replaceAll('—', '-');

final _codePattern = RegExp(
  r'(?<![A-Za-z0-9])[Gg][Ss]\d{4,8}[-－—]\d{2,3}(?![A-Za-z0-9])',
);

/// 盘点货物档案，与称重品类独立；规格不同的货物不能合并。
class StockProduct {
  StockProduct({
    required this.code,
    required this.name,
    required this.specification,
    required this.units,
    this.aliases = const [],
    this.category = 'goods',
  });

  final String code;
  final String name;
  final String specification;
  final List<String> units;
  final List<String> aliases;
  final String category;

  /// 仅从已核实规格的连续包装链提取换算；克数、长度不作库存单位推断。
  Map<String, BigInt> get inventoryUnitFactors {
    final spec = productKey(specification).replaceFirst(RegExp(r'（新）$'), '');
    final slash = spec.split('/');
    if (slash.length != 2 || !units.contains(slash.last)) return {};
    final unitPattern =
        (units.toList()..sort((a, b) => b.length.compareTo(a.length)))
            .map(RegExp.escape)
            .join('|');
    final tokens = RegExp('(?:^|[*x])([1-9][0-9]*)($unitPattern)(?=[*x]|\$)')
        .allMatches(slash.first)
        .toList();
    if (tokens.isEmpty) return {};
    final suffix = slash.first
        .substring(tokens.first.start)
        .replaceFirst(RegExp(r'^[*x]'), '');
    if (suffix !=
            tokens
                .map((token) => '${token.group(1)}${token.group(2)}')
                .join('*') &&
        suffix.replaceAll('x', '*') !=
            tokens
                .map((token) => '${token.group(1)}${token.group(2)}')
                .join('*')) {
      return {};
    }
    final factors = <String, BigInt>{};
    var factor = BigInt.one;
    for (final token in tokens) {
      final unit = token.group(2)!;
      if (factors.containsKey(unit)) return {};
      factors[unit] = factor;
      factor *= BigInt.parse(token.group(1)!);
    }
    if (factors.containsKey(slash.last)) return {};
    factors[slash.last] = factor;
    return factors;
  }

  String get id => category == 'goods' ? code : 'prepared:${productKey(name)}';
  String get display => [
    name,
    if (specification.isNotEmpty) specification,
    if (code.isNotEmpty) code,
  ].join('\n');

  void validate() {
    if (name.trim().isEmpty ||
        !['goods', 'prepared'].contains(category) ||
        units.isEmpty ||
        units.any((unit) => unit.trim().isEmpty) ||
        units.toSet().length != units.length ||
        aliases.any((alias) => alias.trim().isEmpty) ||
        (category == 'goods' &&
            !RegExp(r'^GS\d{4,8}-\d{2,3}$').hasMatch(code)) ||
        (category == 'prepared' && code.isNotEmpty)) {
      throw const FormatException('货物档案须填写准确的名称、货号和库存单位');
    }
  }

  factory StockProduct.fromJson(Map<String, dynamic> json) {
    final product = StockProduct(
      code: json['code'] as String,
      name: json['name'] as String,
      specification: json['specification'] as String,
      units: (json['units'] as List).cast<String>(),
      aliases: (json['aliases'] as List).cast<String>(),
      category: json['category'] as String,
    );
    product.validate();
    if (json['id'] != product.id) throw const FormatException('货物档案标识不一致');
    return product;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'name': name,
    'specification': specification,
    'units': units,
    'aliases': aliases,
    'category': category,
  };
}

void validateProducts(List<StockProduct> products) {
  final ids = <String>{};
  for (final product in products) {
    product.validate();
    if (!ids.add(product.id)) throw FormatException('货物档案重复：${product.id}');
  }
}

/// 从已核实的 Excel 复制六列：货号、名称、规格、库存单位、别名、类别。
List<StockProduct> importProducts(String text) {
  final lines = text.replaceAll('\r\n', '\n').trim().split('\n');
  if (lines.length < 2 || lines.first != '货号\t名称\t规格\t库存单位\t别名\t类别') {
    throw const FormatException('请粘贴含表头的六列档案：货号、名称、规格、库存单位、别名、类别');
  }
  final products = <StockProduct>[];
  for (var index = 1; index < lines.length; index++) {
    final parts = lines[index].split('\t');
    if (parts.length != 6) throw FormatException('第 ${index + 1} 行必须有六列');
    final category = switch (parts[5].trim()) {
      '货物' => 'goods',
      '预制物料' => 'prepared',
      _ => throw FormatException('第 ${index + 1} 行类别须为货物或预制物料'),
    };
    products.add(
      StockProduct(
        code: parts[0].trim().toUpperCase(),
        name: parts[1].trim(),
        specification: parts[2].trim(),
        units: parts[3].split(RegExp('[、,，]')).map((s) => s.trim()).toList(),
        aliases: parts[4].trim().isEmpty
            ? []
            : parts[4].split(RegExp('[、,，]')).map((s) => s.trim()).toList(),
        category: category,
      ),
    );
  }
  validateProducts(products);
  return products;
}

class ProductCandidate {
  const ProductCandidate(
    this.product,
    this.score,
    this.exactCode,
    this.conflict,
    this.edits,
  );
  final StockProduct product;
  final double score;
  final bool exactCode;
  final bool conflict;
  final int edits;
}

/// 通用字符对齐：任意字符的替换、漏字和多字均进入匹配率。
/// 数字之间的替换、数字增删是规格冲突，不因整体文本很长而被稀释。
({double score, bool numericConflict, int edits}) _textMatch(
  String left,
  String right,
) {
  if (left.isEmpty || right.isEmpty) {
    return (score: 0, numericConflict: true, edits: left.length + right.length);
  }
  final matrix = List.generate(
    left.length + 1,
    (i) => List<int>.generate(
      right.length + 1,
      (j) => i == 0 ? j : (j == 0 ? i : 0),
    ),
  );
  for (var i = 1; i <= left.length; i++) {
    for (var j = 1; j <= right.length; j++) {
      matrix[i][j] = [
        matrix[i][j - 1] + 1,
        matrix[i - 1][j] + 1,
        matrix[i - 1][j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1),
      ].reduce((a, b) => a < b ? a : b);
    }
  }
  bool digit(String character) => RegExp(r'^[0-9]$').hasMatch(character);
  bool decimalPoint(String text, int index) =>
      text[index] == '.' &&
      index > 0 &&
      index + 1 < text.length &&
      digit(text[index - 1]) &&
      digit(text[index + 1]);
  var i = left.length, j = right.length;
  var conflict = false;
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        matrix[i][j] ==
            matrix[i - 1][j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)) {
      if (left[i - 1] != right[j - 1] &&
          ((digit(left[i - 1]) && digit(right[j - 1])) ||
              decimalPoint(left, i - 1) ||
              decimalPoint(right, j - 1))) {
        conflict = true;
      }
      i--;
      j--;
    } else if (i > 0 && matrix[i][j] == matrix[i - 1][j] + 1) {
      conflict = conflict || digit(left[i - 1]) || decimalPoint(left, i - 1);
      i--;
    } else {
      conflict = conflict || digit(right[j - 1]) || decimalPoint(right, j - 1);
      j--;
    }
  }
  // 两边均读出完整数量单位时，单位变化也是实质冲突。
  final units = RegExp(
    r'\d+(?:\.\d+)?(毫升|个|包|袋|箱|盒|瓶|桶|卷|捆|克|斤|升|米|ml|kg|oz|g|l)',
  );
  final leftUnits = units.allMatches(left).map((m) => m[1]).toList();
  final rightUnits = units.allMatches(right).map((m) => m[1]).toList();
  if (leftUnits.length == rightUnits.length &&
      leftUnits.isNotEmpty &&
      leftUnits.join('|') != rightUnits.join('|')) {
    conflict = true;
  }
  return (
    score:
        1 -
        matrix.last.last /
            (left.length > right.length ? left.length : right.length),
    numericConflict: conflict,
    edits: matrix.last.last,
  );
}

List<ProductCandidate> matchProducts(
  String raw,
  String category,
  List<StockProduct> products,
) {
  validateProducts(products);
  return _matchProducts(raw, category, products);
}

List<ProductCandidate> _matchProducts(
  String raw,
  String category,
  List<StockProduct> products,
) {
  if (!['goods', 'prepared'].contains(category)) {
    throw ArgumentError.value(category, 'category', '未知货物类别');
  }
  final codes = _codePattern
      .allMatches(raw)
      .map((match) => productKey(match.group(0)!).toUpperCase())
      .toSet();
  final query = productKey(raw.replaceAll(_codePattern, ''));
  final hasKnownCode =
      codes.length == 1 &&
      products.any((p) => p.category == category && p.code == codes.single);
  final candidates = <ProductCandidate>[];
  for (final product in products.where(
    (product) => product.category == category,
  )) {
    final exactCode = codes.length == 1 && codes.single == product.code;
    if (hasKnownCode && !exactCode) continue;
    final readings = [product.name + product.specification, ...product.aliases];
    final comparisons = readings
        .map((value) => _textMatch(query, productKey(value)))
        .toList();
    final canonicalConflict = comparisons.first.numericConflict;
    comparisons.sort((a, b) => b.score.compareTo(a.score));
    final best = comparisons.first;
    final score = best.score;
    final conflict =
        (codes.isNotEmpty && !exactCode) ||
        best.numericConflict ||
        canonicalConflict;
    if (exactCode || score >= 0.35) {
      candidates.add(
        ProductCandidate(product, score, exactCode, conflict, best.edits),
      );
    }
  }
  candidates.sort((a, b) {
    final code = (b.exactCode ? 1 : 0).compareTo(a.exactCode ? 1 : 0);
    if (code != 0) return code;
    final score = b.score.compareTo(a.score);
    return score != 0 ? score : a.product.id.compareTo(b.product.id);
  });
  return candidates.take(5).toList();
}

/// 人工搜索允许名称、别名和货号片段；搜索排名不作为自动确认的证据。
List<ProductCandidate> searchProducts(
  String raw,
  String category,
  List<StockProduct> products,
) {
  validateProducts(products);
  final evidence = _matchProducts(raw, category, products);
  final key = productKey(raw);
  if (key.isEmpty) return [];
  final ranked = <(int, double, ProductCandidate)>[];
  for (final product in products.where((p) => p.category == category)) {
    final names = [product.name, ...product.aliases].map(productKey);
    final code = productKey(product.code);
    final exact = names.contains(key) || (code.isNotEmpty && code == key);
    final contains =
        names.any((name) => name.contains(key)) ||
        (code.isNotEmpty && code.contains(key));
    final fuzzy = names
        .map((name) => _textMatch(key, name).score)
        .reduce((a, b) => a > b ? a : b);
    final existing = evidence.where((c) => c.product.id == product.id).toList();
    if (!contains && fuzzy < .5 && existing.isEmpty) continue;
    // 展示的相似度仍对应完整 OCR 文本，避免将关键词命中伪装成规格核验通过。
    final candidate = existing.isNotEmpty ? existing.single : null;
    final comparison = _textMatch(
      productKey(raw.replaceAll(_codePattern, '')),
      productKey(product.name + product.specification),
    );
    ranked.add((
      exact ? 3 : (contains ? 2 : 1),
      fuzzy,
      candidate ??
          ProductCandidate(
            product,
            comparison.score,
            false,
            comparison.numericConflict,
            comparison.edits,
          ),
    ));
  }
  ranked.sort((a, b) {
    final rank = b.$1.compareTo(a.$1);
    if (rank != 0) return rank;
    final score = b.$2.compareTo(a.$2);
    return score != 0 ? score : a.$3.product.id.compareTo(b.$3.product.id);
  });
  return ranked.map((entry) => entry.$3).toList();
}

/// 自动通过只使用货物身份和实际复读证据，不根据档案补数字。
StockLine reconcileStockLine(StockLine line, List<StockProduct> products) {
  validateProducts(products);
  return _reconcileStockLine(line, products);
}

StockLine _reconcileStockLine(StockLine line, List<StockProduct> products) {
  if (line.cells.length != 2) return line;
  StockProduct? matched;
  if (line.identityConfirmed && !line.autoConfirmed) {
    final existing = products
        .where(
          (p) =>
              p.id == line.productId &&
              p.category == line.category &&
              p.display == line.cells[0],
        )
        .toList();
    if (existing.length == 1) matched = existing.single;
    if (matched == null) return line.invalidateIdentity();
  } else {
    // 未确认身份始终从原文匹配，撤销后也不能借已替换的档案名称再次通过。
    final rawName = line.sourceCells[0];
    if (line.isPrepared) {
      final candidates = _matchProducts(rawName, line.category, products);
      if (candidates.isNotEmpty &&
          !candidates.first.conflict &&
          candidates.first.score >= .90 &&
          (candidates.length == 1 ||
              (candidates.first.score == 1 && candidates[1].score < 1) ||
              candidates.first.score - candidates[1].score >= .10)) {
        matched = candidates.first.product;
      }
    } else {
      // 唯一准确货号定位档案，通用编辑距离核验文本；真实规格数字差异仍阻断。
      final codes = _codePattern.allMatches(rawName).toList();
      if (codes.length != 1) {
        return line.autoConfirmed ? line.invalidateIdentity() : line;
      }
      final code = productKey(codes.single.group(0)!).toUpperCase();
      final exact = products
          .where((p) => p.category == line.category && p.code == code)
          .toList();
      if (exact.isEmpty) {
        return line.autoConfirmed ? line.invalidateIdentity() : line;
      }
      final first = _matchProducts(rawName, line.category, exact).single;
      if (first.exactCode &&
          !first.conflict &&
          (first.score >= .85 ||
              (first.edits == 1 &&
                  productKey(first.product.name + first.product.specification)
                          .length >=
                      4))) {
        matched = first.product;
      }
    }
  }
  if (matched == null) {
    return line.autoConfirmed ? line.invalidateIdentity() : line;
  }
  final fixedUnit = line.isPrepared && matched.units.length == 1
      ? matched.units.single
      : null;
  var quantityText = line.cells[1];
  if (!line.inventoryConfirmed || line.autoConfirmed) {
    final requireSections = [
      quantityText,
      ...line.inventoryReadings,
    ].any((value) => RegExp(r'冷藏|冷冻').hasMatch(value));
    final winner = StockInventory.consensus(
      line.inventoryReadings,
      line.inventoryConfidence,
      fixedUnit: fixedUnit,
      allowedUnits: matched.units,
      requireSections: requireSections,
    );
    if (winner != null && !StockInventory.sameReading(quantityText, winner)) {
      quantityText = winner;
    }
  }
  if (fixedUnit != null && !line.inventoryConfirmed) {
    final complete = line.inventoryReadings.where((value) {
      final parsed = StockInventory.parse(value);
      return !parsed.needsReview &&
          parsed.parts.length == 1 &&
          parsed.parts['库存']!.amounts.keys.toList().join() == fixedUnit &&
          StockInventory.readingSignature(value) != null;
    }).toList();
    if (complete.length >= 2) {
      final candidate = complete.first;
      final proof = StockInventory.evidence(
        candidate,
        line.inventoryReadings,
        line.inventoryConfidence,
        fixedUnit: fixedUnit,
      );
      if (proof.sufficient &&
          StockInventory.sameFixedUnitNumber(
            candidate,
            quantityText,
            fixedUnit,
          )) {
        quantityText = StockInventory.parse(candidate).parts['库存']!.display;
      }
    }
  }
  final proof = StockInventory.evidence(
    quantityText,
    line.inventoryReadings,
    line.inventoryConfidence,
    fixedUnit: fixedUnit,
  );
  final inventory = StockInventory.parse(
    quantityText,
    uncertain: line.inventoryUncertain && !proof.sufficient,
  );
  final unitsValid =
      inventory.parts.values
          .expand((p) => p.amounts.keys)
          .every(matched.units.contains) &&
      inventory.parts.values.every(
        (part) =>
            RegExp(r'[-－—一]+([\u4e00-\u9fff]{1,3}|[A-Za-z]{1,3})')
                .allMatches(part.raw)
                .every((match) => matched!.units.contains(match.group(1))),
      );
  // 数量单位异常只阻断库存确认，不能撤销已核实的名称和货号。
  final quantityValid =
      unitsValid &&
      !inventory.needsReview &&
      inventory.reviewStatus != '总库存与冷藏、冷冻合计不一致';
  final agreed = proof.sufficient;
  // 重复同单位的数字片段不允许通过解析器相加后掩盖 OCR 重复。
  final noDuplicateAmounts = inventory.parts.values.every(
    (part) =>
        RegExp(r'\d+(?:\.\d+)?').allMatches(part.raw).length ==
        part.amounts.length,
  );
  final hasCompleteTotal = inventory.parts['库存']?.hasValue == true;
  final sections = ['库存', '冷藏', '冷冻'];
  // 两读均明确显示占位符时确认「原图未填写」，保留空值，绝不转换成零。
  final explicitlyBlank =
      inventory.parts.containsKey('库存') &&
      (inventory.parts.length == 1 ||
          sections.every(inventory.parts.containsKey)) &&
      inventory.parts.values.every(
        (part) =>
            part.amounts.isEmpty &&
            RegExp(r'^(?:[-－—]+(?:[\u4e00-\u9fff]{1,3}|[A-Za-z]{1,3})?)+$')
                .hasMatch(part.raw.replaceAll(RegExp(r'\s+'), '')),
      );
  bool explicitPlaceholder(StockQuantity part) =>
      part.amounts.isEmpty &&
      RegExp(r'^(?:[-－—]+(?:[\u4e00-\u9fff]{1,3}|[A-Za-z]{1,3})?)+$')
          .hasMatch(part.raw);
  final hasSections =
      inventory.parts.containsKey('冷藏') || inventory.parts.containsKey('冷冻');
  final completeSections =
      !hasSections ||
      sections.every(inventory.parts.containsKey) &&
          sections.every(
            (section) =>
                inventory.parts[section]!.hasValue ||
                explicitPlaceholder(inventory.parts[section]!),
          );
  final factors = matched.inventoryUnitFactors;
  StockAmount? converted(StockQuantity part) {
    if (part.amounts.isEmpty) return null; // 未填写保持未填写，不补零参与换算。
    var value = StockAmount(BigInt.zero, 0);
    for (final entry in part.amounts.entries) {
      if (entry.value.isZero) continue;
      final factor = factors[entry.key];
      if (factor == null) return null;
      value = value.add(entry.value.multiply(factor));
    }
    return value;
  }

  var sectionSumValid = true;
  if (hasSections && completeSections && hasCompleteTotal) {
    final total = converted(inventory.parts['库存']!);
    final chilled = converted(inventory.parts['冷藏']!);
    final frozen = converted(inventory.parts['冷冻']!);
    final sameUnits =
        sections
            .map(
              (section) =>
                  inventory.parts[section]!.amounts.keys.toList()..sort(),
            )
            .map((keys) => keys.join('|'))
            .toSet()
            .length ==
        1;
    sectionSumValid = total != null && chilled != null && frozen != null
        ? total.subtract(chilled.add(frozen)).isZero
        : sameUnits && inventory.reviewStatus != '总库存与冷藏、冷冻合计不一致';
  }
  final explicitTotalBlank =
      inventory.parts['库存'] != null &&
      explicitPlaceholder(inventory.parts['库存']!);
  final quantityConfirmed =
      quantityValid &&
      ((line.inventoryConfirmed && !line.autoConfirmed) ||
          (agreed &&
              noDuplicateAmounts &&
              completeSections &&
              sectionSumValid &&
              (hasCompleteTotal || explicitlyBlank || explicitTotalBlank)));
  return StockLine(
    cells: [matched.display, quantityText],
    confidence: line.confidence,
    category: line.category,
    productId: matched.id,
    identityConfirmed: true,
    inventoryConfirmed: quantityConfirmed,
    autoConfirmed:
        quantityConfirmed &&
        (!line.identityConfirmed ||
            !line.inventoryConfirmed ||
            line.autoConfirmed),
    inventoryUncertain: inventory.uncertain,
    sourceCells: line.sourceCells,
    sourceTop: line.sourceTop,
    sourceBottom: line.sourceBottom,
    inventoryReadings: line.inventoryReadings,
    inventoryConfidence: line.inventoryConfidence,
  );
}

List<StockLine> reconcileStockLines(
  List<StockLine> lines,
  List<StockProduct> products,
) {
  validateProducts(products);
  final reconciled = lines
      .map((line) => _reconcileStockLine(line, products))
      .toList();
  final counts = <String, int>{};
  for (final line in reconciled) {
    if (line.productId != null) {
      counts.update(line.productId!, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return reconciled
      .map(
        (line) => line.autoConfirmed && counts[line.productId]! > 1
            ? line.invalidateIdentity()
            : line,
      )
      .toList();
}

class StockProductStore {
  static const _channel = MethodChannel('com.luckinstocktaking/history');
  Future<List<StockProduct>> load() async {
    final bytes = await rootBundle.load('assets/stock_products_seed.json');
    final seed = jsonDecode(
      utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      ),
    ) as Map<String, dynamic>;
    if (seed['schemaVersion'] != 1 ||
        seed['verification'] != 'manual_visual' ||
        seed['version'] is! String ||
        (seed['version'] as String).isEmpty) {
      throw const FormatException('内置货物档案版本无效');
    }
    final seedProducts = (seed['products'] as List)
        .map(
          (entry) =>
              StockProduct.fromJson((entry as Map).cast<String, dynamic>()),
        )
        .toList();
    validateProducts(seedProducts);
    if (seedProducts.isEmpty) throw const FormatException('内置货物档案不能为空');
    // 原生端将档案及已应用版本一次性原子写入；已有记录优先，删除后不复种。
    final json = await _channel.invokeMethod<String>('loadProducts', {
      'seedVersion': seed['version'],
      'seedProducts': seedProducts.map((p) => p.toJson()).toList(),
    });
    if (json == null) throw StateError('无法读取货物档案');
    final products = (jsonDecode(json) as List)
        .map(
          (entry) =>
              StockProduct.fromJson((entry as Map).cast<String, dynamic>()),
        )
        .toList();
    validateProducts(products);
    return products;
  }

  Future<void> save(List<StockProduct> products) async {
    validateProducts(products);
    await _channel.invokeMethod<void>(
      'saveProducts',
      jsonEncode(products.map((p) => p.toJson()).toList()),
    );
  }
}
