import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'stock_inventory.dart';

class StockLine {
  StockLine({
    required this.cells,
    required this.confidence,
    this.inventoryUncertain = false,
  });
  final List<String> cells;
  final double confidence;
  final bool inventoryUncertain;
  StockInventory get inventory =>
      StockInventory.parse(cells[1], uncertain: inventoryUncertain);
  String get text => cells.join(' · ');

  String? get reviewIssue {
    if (cells.length != 2) return null;
    final codes = RegExp(r'[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}')
        .allMatches(cells[0]);
    if (codes.any(
      (match) => RegExp(r'[OoIl]').hasMatch(match.group(0)!.substring(2)),
    )) {
      return '货号中有易混淆字符';
    }
    final rawInventory = cells[1];
    if (inventory.needsReview ||
        RegExp(
          r'(?:^|[:：\s])[OoIl]+(?=\s*(?:个|盒|包|箱|瓶|袋|支|份))',
          multiLine: true,
        ).hasMatch(rawInventory)) {
      return '库存数字待确认';
    }
    return null;
  }

  factory StockLine.fromJson(Map<String, dynamic> json) {
    final cells = (json['cells'] as List).cast<String>();
    final confidence = (json['confidence'] as num).toDouble();
    if (cells.isEmpty ||
        cells.asMap().entries.any(
          (entry) =>
              entry.value.trim().isEmpty &&
              !(cells.length == 2 && entry.key == 1),
        ) ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1) {
      throw const FormatException('盘点单文字行格式无效');
    }
    return StockLine(
      cells: cells,
      confidence: confidence,
      inventoryUncertain: (json['inventoryUncertain'] as bool?) ?? false,
    );
  }
  Map<String, dynamic> toJson() => {
    'cells': cells,
    'confidence': confidence,
    'inventoryUncertain': inventoryUncertain,
  };
}

class StockDocument {
  StockDocument({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.imageName,
    required this.lines,
    required this.reviewed,
    this.schemaVersion = 1,
    this.recognitionRevision = 0,
  });
  final String id;
  final String title;
  final DateTime createdAt;
  final String imageName;
  final List<StockLine> lines;
  final bool reviewed;
  final int schemaVersion;
  final int recognitionRevision;

  factory StockDocument.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 && json['schemaVersion'] != 2) {
      throw const FormatException('不支持的盘点单数据版本');
    }
    final document = StockDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      imageName: json['imageName'] as String,
      lines: (json['lines'] as List)
          .map(
            (line) => StockLine.fromJson((line as Map).cast<String, dynamic>()),
          )
          .toList(),
      reviewed: json['reviewed'] as bool,
      schemaVersion: json['schemaVersion'] as int,
      recognitionRevision: (json['recognitionRevision'] as int?) ?? 0,
    );
    document.validate();
    return document;
  }

  void validate() {
    if ((schemaVersion != 1 && schemaVersion != 2) ||
        recognitionRevision < 0 ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id) ||
        title.trim().isEmpty ||
        imageName != '$id.png' ||
        lines.isEmpty) {
      throw const FormatException('盘点单元数据无效');
    }
    for (final line in lines) {
      StockLine.fromJson(line.toJson());
      if (schemaVersion == 2 && line.cells.length != 2) {
        throw const FormatException('盘点表必须包含货物规格名称和实盘总库存两列');
      }
    }
  }

  StockDocument edited(String title, List<StockLine> lines) => StockDocument(
    id: id,
    title: title.trim(),
    createdAt: createdAt,
    imageName: imageName,
    lines: lines,
    reviewed: true,
    schemaVersion: schemaVersion,
    recognitionRevision: recognitionRevision,
  );

  bool matches(String query) {
    final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final content = '$title ${lines.map((line) => line.text).join(' ')}'
        .toLowerCase();
    return words.every(content.contains);
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'recognitionRevision': recognitionRevision,
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'imageName': imageName,
    'lines': lines.map((line) => line.toJson()).toList(),
    'reviewed': reviewed,
  };
}

class StockHistoryStore {
  static const channel = MethodChannel('com.luckinstocktaking/history');
  static final changes = ValueNotifier<int>(0);
  Future<StockDocument> table(StockDocument document) async {
    if (document.schemaVersion == 2 && document.reviewed) return document;
    final json = await channel.invokeMethod<String>('table', document.id);
    if (json == null) throw StateError('无法整理盘点表');
    final result = StockDocument.fromJson(
      (jsonDecode(json) as Map).cast<String, dynamic>(),
    );
    if (result.id != document.id || result.schemaVersion != 2) {
      throw const FormatException('整理后的盘点表标识或版本无效');
    }
    return result;
  }

  Future<StockDocument?> pending() async {
    final json = await channel.invokeMethod<String>('pending');
    if (json == null) return null;
    return StockDocument.fromJson(
      (jsonDecode(json) as Map).cast<String, dynamic>(),
    );
  }

  Future<List<StockDocument>> load() async {
    final json = await channel.invokeMethod<String>('list');
    if (json == null) throw StateError('无法读取历史盘点单');
    final documents = (jsonDecode(json) as List)
        .map(
          (value) =>
              StockDocument.fromJson((value as Map).cast<String, dynamic>()),
        )
        .toList();
    if (documents.map((document) => document.id).toSet().length !=
        documents.length) {
      throw const FormatException('历史盘点单标识重复');
    }
    documents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return documents;
  }

  Future<StockDocument?> pick({required bool video}) async {
    final json = await channel.invokeMethod<String>('import', {'video': video});
    // 空值只代表用户主动取消系统选择器。
    if (json == null) return null;
    return StockDocument.fromJson(
      (jsonDecode(json) as Map).cast<String, dynamic>(),
    );
  }

  Future<StockDocument?> pickScreenshots() async {
    final json = await channel.invokeMethod<String>('importScreenshots');
    // 空值只代表用户取消选择；排序和拼接失败由平台明确返回异常。
    if (json == null) return null;
    return StockDocument.fromJson(
      (jsonDecode(json) as Map).cast<String, dynamic>(),
    );
  }

  Future<void> save(StockDocument document) async {
    document.validate();
    await channel.invokeMethod<void>('save', jsonEncode(document.toJson()));
  }

  Future<void> delete(StockDocument document) async {
    document.validate();
    await channel.invokeMethod<void>('delete', document.id);
    changes.value++;
  }

  Future<List<Uint8List>> imageTiles(StockDocument document) async {
    final tiles = await channel.invokeListMethod<Uint8List>(
      'imageTiles',
      document.id,
    );
    if (tiles == null || tiles.isEmpty || tiles.any((tile) => tile.isEmpty)) {
      throw StateError('无法读取长图预览');
    }
    return tiles;
  }

  Future<Uint8List> image(StockDocument document) async {
    final bytes = await channel.invokeMethod<Uint8List>('image', document.id);
    if (bytes == null || bytes.isEmpty) throw StateError('无法读取盘点单原图');
    return bytes;
  }
}
