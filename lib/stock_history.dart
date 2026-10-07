import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'stock_inventory.dart';

class StockLine {
  StockLine({
    required this.cells,
    required this.confidence,
    this.inventoryUncertain = false,
    this.category = 'goods',
  });
  final List<String> cells;
  final double confidence;
  final bool inventoryUncertain;
  final String category;
  bool get isPrepared => category == 'prepared';
  String get categoryLabel => isPrepared ? '预制物料' : '货物';
  StockInventory get inventory =>
      StockInventory.parse(cells[1], uncertain: inventoryUncertain);
  String get text => cells.join(' · ');

  String? get reviewIssue {
    if (cells.length != 2) return null;
    final name = cells[0];
    if (RegExp(r'(?:^|\n)\s*[01]20\d{4}[A-Z]+\d').hasMatch(name)) {
      return '活动规格首字母可能被识别成数字，请对照原图';
    }
    if (name
            .split('\n')
            .any(
              (part) => RegExp(r'^[\u4e00-\u9fff]$').hasMatch(part.trim()),
            ) ||
        name.split('\n').any((part) => part.trim().endsWith('/'))) {
      return '名称或规格可能不完整，请对照原图';
    }
    if (!isPrepared &&
        RegExp(r'饮料|饮品|咖啡豆|调味酱|蛋糕|面包').hasMatch(name) &&
        !RegExp(r'\d(?:\.\d+)?\s*(?:kg|KG|g|ml|mL|L|升|克)').hasMatch(name)) {
      return '规格可能漏识别，请对照原图';
    }
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
      category: _category(json['category']),
    );
  }
  Map<String, dynamic> toJson() => {
    'cells': cells,
    'confidence': confidence,
    'inventoryUncertain': inventoryUncertain,
    'category': category,
  };

  static String _category(dynamic value) {
    if (value == null) return 'goods';
    if (value != 'goods' && value != 'prepared') {
      throw const FormatException('盘点行物料类别无效');
    }
    return value as String;
  }
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
    // 列表顺序由平台按用户调整结果返回，这里不再按导入时间重排。
    return documents;
  }

  /// 按传入的完整列表顺序持久化，平台要求覆盖全部历史盘点单。
  Future<void> reorder(List<StockDocument> documents) async {
    if (documents.length < 2) {
      throw ArgumentError.value(
        documents.length,
        'documents',
        '至少需要两张盘点单才能调整顺序',
      );
    }
    await channel.invokeMethod<void>('reorder', [
      for (final document in documents) document.id,
    ]);
    changes.value++;
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

  /// 把导出内容写入临时文件并拉起系统分享面板，由用户选微信等目标应用。
  /// 平台只负责呈现，取消分享属于正常路径，不会作为失败抛出。
  Future<void> shareBytes({
    required String name,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) throw StateError('导出内容为空');
    await channel.invokeMethod<void>('shareBytes', {
      'name': name,
      'bytes': bytes,
    });
  }

  /// 直接分享长图原件，不在临时目录另存副本，避免重复占用磁盘。
  Future<void> shareImage(StockDocument document) async {
    await channel.invokeMethod<void>('shareImage', document.id);
  }

  /// 导出最近一次识别任务的诊断日志，用于解析失败时定位 OCR 问题。
  /// 没有日志时平台明确报错，不会分享空文件。
  Future<void> shareDiagnostics() async {
    await channel.invokeMethod<void>('shareDiagnostics');
  }
}
