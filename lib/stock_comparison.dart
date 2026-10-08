import 'stock_history.dart';
import 'stock_inventory.dart';

class StockDifference {
  StockDifference(this.section, this.unit, this.amount);
  final String section;
  final String unit;
  final StockAmount amount;
  String get display =>
      '${section == '库存' ? '' : '$section '}${amount.format(signed: true)}$unit';
}

class StockComparisonRow {
  StockComparisonRow(
    this.code,
    this.baseline,
    this.target,
    this.differences,
    this.unitMismatch,
  );
  final String code;
  final StockLine baseline;
  final StockLine target;
  final List<StockDifference> differences;
  final bool unitMismatch;
  bool get changed =>
      unitMismatch ||
      differences.any((difference) => !difference.amount.isZero);
}

class StockComparison {
  StockComparison._(this.rows, this.excluded);
  final List<StockComparisonRow> rows;
  final int excluded;

  factory StockComparison(StockDocument baseline, StockDocument target) {
    if (baseline.id == target.id ||
        baseline.schemaVersion != 2 ||
        target.schemaVersion != 2) {
      throw const FormatException('请选择两张不同的两列盘点单');
    }
    Map<String, StockLine> index(StockDocument document) {
      final result = <String, StockLine>{};
      for (final line in document.lines) {
        // 无 GS 编码的预制物料单独展示和导出，不进入按货号比较的货物索引。
        if (line.isPrepared) continue;
        if (line.inventory.hasValue && !line.ready) {
          throw FormatException('「${document.title}」存在未确认的货物或库存，请先对照原图校对');
        }
        if (!line.inventory.hasValue) continue;
        final codes = RegExp(
          r'(?<![A-Za-z0-9])[Gg][Ss]\d{4,8}[-－—]\d{2,3}(?![A-Za-z0-9])',
        ).allMatches(line.cells[0]).toList();
        if (codes.length != 1) {
          throw FormatException(
            '「${document.title}」货号无法匹配，请先校对：${line.cells[0]}',
          );
        }
        final code = codes.single
            .group(0)!
            .toUpperCase()
            .replaceAll(RegExp('[－—]'), '-');
        if (result.containsKey(code)) {
          throw FormatException('「${document.title}」货号 $code 重复，请先核对原图');
        }
        result[code] = line;
      }
      return result;
    }

    final a = index(baseline);
    final b = index(target);
    final shared = a.keys.toSet().intersection(b.keys.toSet()).toList()..sort();
    final rows = <StockComparisonRow>[];
    var incomparable = 0;
    for (final code in shared) {
      final old = a[code]!.inventory;
      final next = b[code]!.inventory;
      final differences = <StockDifference>[];
      var mismatch = false;
      for (final section in ['库存', '冷藏', '冷冻']) {
        final before = old.parts[section];
        final after = next.parts[section];
        if (before == null ||
            after == null ||
            !before.hasValue ||
            !after.hasValue) {
          continue;
        }
        final units = before.amounts.keys.toSet().intersection(
          after.amounts.keys.toSet(),
        );
        if (units.isEmpty) mismatch = true;
        for (final unit in units) {
          differences.add(
            StockDifference(
              section,
              unit,
              after.amounts[unit]!.subtract(before.amounts[unit]!),
            ),
          );
        }
      }
      if (differences.isEmpty && !mismatch) {
        incomparable++;
        continue;
      }
      rows.add(
        StockComparisonRow(code, a[code]!, b[code]!, differences, mismatch),
      );
    }
    final excluded =
        a.keys.toSet().union(b.keys.toSet()).length -
        shared.length +
        incomparable;
    return StockComparison._(rows, excluded);
  }
}
