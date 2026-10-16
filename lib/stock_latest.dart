import 'stock_history.dart';
import 'stock_product.dart';

/// 同一品类在一张单据上的原始记录；重复行保留供核对，不相加。
class LatestStockRecord {
  LatestStockRecord(this.document, this.product, List<StockLine> lines)
    : lines = List.unmodifiable(lines);

  final StockDocument document;
  final StockProduct? product;
  final List<StockLine> lines;
  bool _sameTimestamp = false;
  bool get sameTimestamp => _sameTimestamp;

  String get category => lines.first.category;
  String get name => product?.name ?? lines.first.cells[0];
  bool get confirmed => lines.length == 1 && lines.single.ready;

  bool matches(String query) {
    final text = productKey(
      [
        name,
        if (product != null) ...[
          product!.code,
          product!.specification,
          ...product!.aliases,
        ],
        ...lines.map((line) => line.cells[0]),
      ].join(' '),
    );
    return query
        .trim()
        .split(RegExp(r'\s+'))
        .every((word) => text.contains(productKey(word)));
  }
}

/// 按录入时间逐品类选择，列表拖动及旧单校对不会改变时间。
/// 同时录入的不同单据全部保留，避免任意选取其中一份。
List<LatestStockRecord> latestStockRecords(
  List<StockDocument> documents,
  List<StockProduct> products,
) {
  validateProducts(products);
  final catalog = {for (final product in products) product.id: product};
  final latest = <String, List<LatestStockRecord>>{};
  final documentIds = <String>{};
  for (final document in documents) {
    document.validate();
    if (!documentIds.add(document.id)) {
      throw const FormatException('历史盘点单标识重复');
    }
    if (document.schemaVersion != 2) {
      throw const FormatException('请先将历史盘点单整理为两列表格');
    }
    final groups = <String, List<StockLine>>{};
    final groupProducts = <String, StockProduct?>{};
    for (final line in reconcileStockLines(document.lines, products)) {
      final codes = RegExp(
        r'(?<![A-Za-z0-9])[Gg][Ss]\d{4,8}[-－—]\d{2,3}(?![A-Za-z0-9])',
      ).allMatches(line.cells[0]).toList();
      final exactCode = !line.isPrepared && codes.length == 1
          ? productKey(codes.single.group(0)!).toUpperCase()
          : null;
      // 未确认的已有标识也占据最新记录，不能让更早的库存冒充最新。
      final id = line.productId ?? exactCode;
      final key = id != null
          ? '${line.category}:id:$id'
          : '${line.category}:text:${productKey(line.cells[0])}';
      (groups[key] ??= []).add(line);
      groupProducts[key] = catalog[id];
    }
    for (final group in groups.entries) {
      final previous = latest[group.key];
      final record = LatestStockRecord(
        document,
        groupProducts[group.key],
        group.value,
      );
      if (previous == null ||
          document.createdAt.isAfter(previous.first.document.createdAt)) {
        latest[group.key] = [record];
      } else if (document.createdAt.isAtSameMomentAs(
        previous.first.document.createdAt,
      )) {
        record._sameTimestamp = true;
        for (final existing in previous) {
          existing._sameTimestamp = true;
        }
        previous.add(record);
      }
    }
  }
  return latest.values.expand((records) => records).toList()..sort((a, b) {
    final category = a.category.compareTo(b.category);
    if (category != 0) return category;
    final name = a.name.compareTo(b.name);
    if (name != 0) return name;
    return a.document.id.compareTo(b.document.id);
  });
}
