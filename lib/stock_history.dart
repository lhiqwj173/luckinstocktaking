import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class StockLine {
  StockLine({required this.cells, required this.confidence});
  final List<String> cells;
  final double confidence;
  String get text => cells.join(' · ');

  factory StockLine.fromJson(Map<String, dynamic> json) {
    final cells = (json['cells'] as List).cast<String>();
    final confidence = (json['confidence'] as num).toDouble();
    if (cells.isEmpty ||
        cells.any((cell) => cell.trim().isEmpty) ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1) {
      throw const FormatException('盘点单文字行格式无效');
    }
    return StockLine(cells: cells, confidence: confidence);
  }
  Map<String, dynamic> toJson() => {'cells': cells, 'confidence': confidence};
}

class StockDocument {
  StockDocument({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.imageName,
    required this.lines,
    required this.reviewed,
  });
  final String id;
  final String title;
  final DateTime createdAt;
  final String imageName;
  final List<StockLine> lines;
  final bool reviewed;

  factory StockDocument.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
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
    );
    document.validate();
    return document;
  }

  void validate() {
    if (!RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id) ||
        title.trim().isEmpty ||
        imageName != '$id.png' ||
        lines.isEmpty) {
      throw const FormatException('盘点单元数据无效');
    }
    for (final line in lines) {
      StockLine.fromJson(line.toJson());
    }
  }

  StockDocument edited(String title, List<StockLine> lines) => StockDocument(
    id: id,
    title: title.trim(),
    createdAt: createdAt,
    imageName: imageName,
    lines: lines,
    reviewed: true,
  );

  bool matches(String query) {
    final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final content = '$title ${lines.map((line) => line.text).join(' ')}'
        .toLowerCase();
    return words.every(content.contains);
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
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
  Future<void> startCapture({
    required double top,
    required double bottom,
  }) async {
    await channel.invokeMethod<void>('startCapture', {
      'top': top,
      'bottom': bottom,
    });
  }

  Future<void> openPendingCapture() async {
    await channel.invokeMethod<void>('pendingStart');
  }

  Future<void> clearCaptureFailures() async {
    await channel.invokeMethod<void>('clearCaptureFailures');
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

  Future<StockDocument?> pick({
    required bool video,
    required double top,
    required double bottom,
  }) async {
    final json = await channel.invokeMethod<String>('import', {
      'video': video,
      'top': top,
      'bottom': bottom,
    });
    // 空值只代表用户主动取消系统选择器。
    if (json == null) return null;
    return StockDocument.fromJson(
      (jsonDecode(json) as Map).cast<String, dynamic>(),
    );
  }

  Future<void> save(StockDocument document) async {
    document.validate();
    await channel.invokeMethod<void>('save', jsonEncode(document.toJson()));
  }

  Future<Uint8List> image(StockDocument document) async {
    final bytes = await channel.invokeMethod<Uint8List>('image', document.id);
    if (bytes == null || bytes.isEmpty) throw StateError('无法读取盘点单原图');
    return bytes;
  }
}
