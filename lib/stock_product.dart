import 'dart:convert';

import 'package:flutter/services.dart';

import 'stock_history.dart';

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
  );
  final StockProduct product;
  final double score;
  final bool exactCode;
  final bool conflict;
}

/// 编辑距离只用于候选排序，不自动纠正数字、规格或库存。
double _similarity(String left, String right) {
  if (left.isEmpty || right.isEmpty) return 0;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var i = 1; i <= left.length; i++) {
    final next = List<int>.filled(right.length + 1, i);
    for (var j = 1; j <= right.length; j++) {
      final insert = next[j - 1] + 1;
      final delete = previous[j] + 1;
      final replace = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1);
      next[j] = [insert, delete, replace].reduce((a, b) => a < b ? a : b);
    }
    previous = next;
  }
  return 1 -
      previous.last / (left.length > right.length ? left.length : right.length);
}

List<ProductCandidate> matchProducts(
  String raw,
  String category,
  List<StockProduct> products,
) {
  validateProducts(products);
  final codes = _codePattern
      .allMatches(raw)
      .map((match) => productKey(match.group(0)!).toUpperCase())
      .toSet();
  final query = productKey(raw.replaceAll(_codePattern, ''));
  final numbers = RegExp(r'\d+(?:\.\d+)?')
      .allMatches(query)
      .map((m) => m.group(0)!)
      .toList();
  final candidates = <ProductCandidate>[];
  for (final product in products.where(
    (product) => product.category == category,
  )) {
    final readings = [product.name + product.specification, ...product.aliases];
    final score = readings
        .map((value) => _similarity(query, productKey(value)))
        .reduce((a, b) => a > b ? a : b);
    final exactCode = codes.length == 1 && codes.single == product.code;
    final expectedNumbers = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(productKey(product.name + product.specification))
        .map((m) => m.group(0)!)
        .toList();
    final conflict =
        (codes.isNotEmpty && !exactCode) ||
        (numbers.isNotEmpty &&
            expectedNumbers.isNotEmpty &&
            numbers.join('|') != expectedNumbers.join('|'));
    if (exactCode || score >= 0.35) {
      candidates.add(ProductCandidate(product, score, exactCode, conflict));
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

/// 自动通过只使用货物身份和实际复读证据，不根据档案补数字。
StockLine reconcileStockLine(StockLine line, List<StockProduct> products) {
  validateProducts(products);
  if (line.cells.length != 2) return line;
  StockProduct? matched;
  if (line.identityConfirmed) {
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
    if (line.isPrepared) {
      final exact = products
          .where(
            (p) =>
                p.category == 'prepared' &&
                productKey(p.name) == productKey(line.cells[0]),
          )
          .toList();
      if (exact.length == 1) matched = exact.single;
    } else {
      // 自动匹配必须有唯一、准确的货号；模糊候选只在用户打开复核时计算。
      final codes = _codePattern.allMatches(line.cells[0]).toList();
      if (codes.length != 1) return line;
      final code = productKey(codes.single.group(0)!).toUpperCase();
      final exact = products
          .where((p) => p.category == line.category && p.code == code)
          .toList();
      if (exact.isEmpty) return line;
      final first = matchProducts(line.cells[0], line.category, exact).single;
      final raw = line.cells[0].replaceAll(_codePattern, '');
      List<String> numbers(String value) =>
          RegExp(r'\d+(?:\.\d+)?')
              .allMatches(productKey(value))
              .map((m) => m.group(0)!)
              .toList();
      if (first.exactCode &&
          !first.conflict &&
          first.score >= .70 &&
          numbers(raw).join('|') ==
              numbers(first.product.name + first.product.specification)
                  .join('|')) {
        matched = first.product;
      }
    }
  }
  if (matched == null) return line;
  final inventory = line.inventory;
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
  if (line.identityConfirmed && !unitsValid) return line.invalidateIdentity();
  final quantityValid =
      unitsValid &&
      !inventory.needsReview &&
      inventory.reviewStatus != '总库存与冷藏、冷冻合计不一致';
  String readingKey(String value) => value
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('：', ':')
      .replaceAll('．', '.');
  final agreed =
      line.inventoryReadings.length == 2 &&
      line.inventoryReadings.every(
        (value) =>
            value.trim().isNotEmpty &&
            readingKey(value) == readingKey(line.cells[1]),
      ) &&
      line.inventoryConfidence != null &&
      line.inventoryConfidence! >= .8;
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
  final completeSections =
      (!inventory.parts.containsKey('冷藏') &&
          !inventory.parts.containsKey('冷冻')) ||
      sections.every(inventory.parts.containsKey) &&
          sections.every(
            (section) =>
                inventory.parts[section]!.hasValue &&
                inventory.parts[section]!.amounts.keys.toSet().length ==
                    inventory.parts['库存']!.amounts.length &&
                inventory.parts[section]!.amounts.keys.toSet().containsAll(
                  inventory.parts['库存']!.amounts.keys,
                ),
          );
  final quantityConfirmed =
      quantityValid &&
      (line.inventoryConfirmed ||
          (agreed &&
              noDuplicateAmounts &&
              ((hasCompleteTotal && completeSections) || explicitlyBlank)));
  return StockLine(
    cells: [matched.display, line.cells[1]],
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
    inventoryUncertain: line.inventoryUncertain,
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
  final reconciled = lines
      .map((line) => reconcileStockLine(line, products))
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
