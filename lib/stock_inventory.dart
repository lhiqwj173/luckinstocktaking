class StockAmount {
  StockAmount(this.coefficient, this.scale);
  final BigInt coefficient;
  final int scale;

  factory StockAmount.parse(String text) {
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text)) {
      throw FormatException('库存数字无效：$text');
    }
    final parts = text.split('.');
    return StockAmount(
      BigInt.parse(parts.join()),
      parts.length == 2 ? parts[1].length : 0,
    );
  }
  StockAmount subtract(StockAmount other) {
    final digits = scale > other.scale ? scale : other.scale;
    return StockAmount(
      coefficient * BigInt.from(10).pow(digits - scale) -
          other.coefficient * BigInt.from(10).pow(digits - other.scale),
      digits,
    );
  }

  StockAmount add(StockAmount other) {
    return subtract(StockAmount(-other.coefficient, other.scale));
  }

  StockAmount multiply(BigInt factor) =>
      StockAmount(coefficient * factor, scale);

  bool get isZero => coefficient == BigInt.zero;
  String format({bool signed = false}) {
    final digits = coefficient.abs().toString().padLeft(scale + 1, '0');
    var value = scale == 0
        ? digits
        : '${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
    if (value.contains('.')) {
      value = value
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return '${coefficient.isNegative
        ? '-'
        : signed && !isZero
        ? '+'
        : ''}$value';
  }
}

class StockQuantity {
  StockQuantity(this.raw, this.amounts, {this.uncertain = false});
  final String raw;
  final Map<String, StockAmount> amounts;
  final bool uncertain;
  bool get hasValue => !uncertain && amounts.isNotEmpty;
  String get display => uncertain
      ? raw
      : amounts.entries.map((e) => '${e.value.format()}${e.key}').join(' ');

  factory StockQuantity.parse(String raw) {
    final text = StockInventory.normalizeFormat(raw);
    final tokens = RegExp(
      r'(\d+(?:\.\d+)?)([\u4e00-\u9fff]{1,3}|[A-Za-z]{1,3})?|[-－—一]+([\u4e00-\u9fff]{0,3}|[A-Za-z]{0,3})',
    );
    if (text.isEmpty) return StockQuantity(raw, {});
    if (RegExp(r'[-－—一]\d').hasMatch(text)) {
      return StockQuantity(raw, {}, uncertain: true);
    }
    final matches = tokens.allMatches(text).toList();
    final residue = text.replaceAll(tokens, '');
    if (residue.isNotEmpty) return StockQuantity(raw, {}, uncertain: true);
    final amounts = <String, StockAmount>{};
    for (final match in matches) {
      if (match.group(1) == null) continue;
      final unit = match.group(2) ?? '';
      final amount = StockAmount.parse(match.group(1)!);
      amounts[unit] = amounts.containsKey(unit)
          ? amounts[unit]!.add(amount)
          : amount;
    }
    return StockQuantity(raw, amounts);
  }
}

class StockInventory {
  StockInventory(this.parts, {this.uncertain = false});
  final Map<String, StockQuantity> parts;
  final bool uncertain;

  /// 仅统一字形和排版，不将汉字、负号或疑似小数改造成数字。
  static String normalizeFormat(String raw) => String.fromCharCodes(
    raw.runes.map(
      (rune) => rune >= 0xff10 && rune <= 0xff19 ? rune - 0xfee0 : rune,
    ),
  ).replaceAll(RegExp(r'\s+'), '').replaceAll('．', '.').replaceAll('：', ':');

  /// 比较真实数量、单位、分区；不把 OCR 重复数字相加后当作一致。
  static bool sameReading(String left, String right) {
    final first = readingSignature(left);
    return first != null && first == readingSignature(right);
  }

  static String? readingSignature(String raw) {
    raw = normalizeFormat(raw);
    final parsed = StockInventory.parse(raw);
    if (parsed.needsReview || RegExp(r'[-－—一]\s*\d').hasMatch(raw)) {
      return null;
    }
    final sections = parsed.parts.keys.toList()..sort();
    final result = <String>[];
    for (final section in sections) {
      final part = parsed.parts[section]!;
      final text = part.raw.replaceAll(RegExp(r'\s+'), '').replaceAll('．', '.');
      if (text.isEmpty ||
          RegExp(r'\d+(?:\.\d+)?').allMatches(text).length !=
              part.amounts.length) {
        return null;
      }
      final units = part.amounts.keys.toList()..sort();
      final blanks =
          RegExp(r'[-－—一]+(?:[\u4e00-\u9fff]{0,3}|[A-Za-z]{0,3})')
              .allMatches(text)
              .map(
                (match) => match.group(0)!.replaceAll(RegExp(r'[-－—一]+'), '-'),
              )
              .toList()
            ..sort();
      result.add(
        '$section:${units.map((unit) => '$unit=${part.amounts[unit]!.format()}').join(',')};${blanks.join(',')}',
      );
    }
    return result.join('|');
  }

  static StockReadingEvidence evidence(
    String expected,
    List<String> readings,
    double? confidence,
  ) {
    final signature = readingSignature(expected);
    var supporting = 0;
    var abstentions = 0;
    var conflicting = 0;
    for (final raw in readings) {
      final actual = readingSignature(raw);
      if (signature != null && actual == signature) {
        supporting++;
      } else if (noiseVariant(expected, raw)) {
        abstentions++;
      } else if (actual == null &&
          !RegExp(r'[0-9〇零一二三四五六七八九十]').hasMatch(normalizeFormat(raw))) {
        abstentions++;
      } else {
        conflicting++; // 包含数字的残缺读数也不能作为无意义噪声删除。
      }
    }
    final allAgree =
        signature != null &&
        supporting >= 2 &&
        conflicting == 0 &&
        abstentions == 0;
    final sufficient =
        confidence != null &&
        confidence > 0 &&
        conflicting == 0 &&
        signature != null &&
        ((allAgree && (confidence >= .8 || supporting >= 4)) ||
            (supporting >= 3 &&
                abstentions > 0 &&
                readings.every((raw) => normalizeFormat(raw).isNotEmpty)));
    return StockReadingEvidence(
      supporting,
      abstentions,
      conflicting,
      allAgree,
      sufficient,
    );
  }

  /// 保留所有数字、标点、数量单位、分区词和汉字数词，仅识别附着的无关汉字。
  /// 此读数仍属无效证据，只有另三次完整读数一致才可能解除阻断。
  static bool noiseVariant(String expected, String raw) {
    const meaningful =
        '总库存冷藏冻零〇一二三四五六七八九十百千万个盒包袋箱瓶桶卷捆组支克斤升米张片根份罐把提条套副只抽毫厘分两磅吨枚粒杯勺剂页台枝束扎盆';
    final normalized = normalizeFormat(raw);
    final cleaned = normalized.replaceAllMapped(
      RegExp(r'[\u4e00-\u9fff]'),
      (match) => meaningful.contains(match[0]!) ? match[0]! : '',
    );
    return cleaned != normalized && sameReading(expected, cleaned);
  }

  bool get hasValue => !uncertain && parts.values.any((part) => part.hasValue);
  bool get needsReview =>
      uncertain || parts.values.any((part) => part.uncertain);
  bool get totalMissing => parts.containsKey('库存') && !parts['库存']!.hasValue;
  String get reviewStatus {
    if (uncertain || parts.values.any((part) => part.uncertain)) {
      return totalMissing ? '总库存缺失或无法识别，需核对原图' : '库存数字待确认';
    }
    if (totalMissing) return '原图总库存未填写';
    if (parts.isEmpty || !hasValue) return '原图库存未填写';
    final total = parts['库存'];
    final chilled = parts['冷藏'];
    final frozen = parts['冷冻'];
    if (total != null &&
        chilled != null &&
        frozen != null &&
        total.amounts.keys.toSet().containsAll(chilled.amounts.keys) &&
        total.amounts.keys.toSet().containsAll(frozen.amounts.keys) &&
        chilled.amounts.keys.toSet().containsAll(total.amounts.keys) &&
        frozen.amounts.keys.toSet().containsAll(total.amounts.keys)) {
      for (final unit in total.amounts.keys) {
        if (!total.amounts[unit]!
            .subtract(chilled.amounts[unit]!.add(frozen.amounts[unit]!))
            .isZero) {
          return '总库存与冷藏、冷冻合计不一致';
        }
      }
    }
    return '已解析';
  }

  factory StockInventory.parse(String raw, {bool uncertain = false}) {
    raw = normalizeFormat(raw);
    final labels = RegExp(r'(总库存|冷藏|冷冻)\s*[:：·;；]?');
    final matches = labels.allMatches(raw).toList();
    final parts = <String, StockQuantity>{};
    if (matches.isEmpty) {
      parts['库存'] = StockQuantity.parse(raw);
    } else {
      if (raw.substring(0, matches.first.start).trim().isNotEmpty) {
        return StockInventory({
          '库存': StockQuantity(raw, {}, uncertain: true),
        }, uncertain: true);
      }
      for (var index = 0; index < matches.length; index++) {
        final label = matches[index].group(1) == '总库存'
            ? '库存'
            : matches[index].group(1)!;
        if (parts.containsKey(label)) {
          return StockInventory({
            '库存': StockQuantity(raw, {}, uncertain: true),
          }, uncertain: true);
        }
        final end = index + 1 < matches.length
            ? matches[index + 1].start
            : raw.length;
        parts[label] = StockQuantity.parse(
          raw.substring(matches[index].end, end),
        );
      }
    }
    return StockInventory(parts, uncertain: uncertain);
  }
}

class StockReadingEvidence {
  const StockReadingEvidence(
    this.supporting,
    this.abstentions,
    this.conflicting,
    this.allAgree,
    this.sufficient,
  );
  final int supporting, abstentions, conflicting;
  final bool allAgree, sufficient;
}
