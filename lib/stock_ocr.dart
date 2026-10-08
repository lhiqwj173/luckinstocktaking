import 'dart:convert';

import 'stock_history.dart';
import 'stock_inventory.dart';

enum StockOCREngine {
  vision('vision', 'Apple Vision'),
  tiny('paddle_tiny', 'PP-OCRv6 tiny'),
  small('paddle_small', 'PP-OCRv6 small');

  const StockOCREngine(this.id, this.label);
  final String id;
  final String label;
  static StockOCREngine parse(String value) => values.firstWhere(
    (engine) => engine.id == value,
    orElse: () => throw const FormatException('未知识别模型'),
  );
}

class StockOCRRun {
  StockOCRRun(this.engine, this.document, this.metrics, this.evaluatedAt);
  final StockOCREngine engine;
  final StockDocument document;
  final Map<String, dynamic> metrics;
  final DateTime evaluatedAt;
  factory StockOCRRun.fromJson(Map<String, dynamic> json) {
    final engine = StockOCREngine.parse(json['engine'] as String);
    final document = StockDocument.fromJson(
      (json['document'] as Map).cast<String, dynamic>(),
    );
    final metrics = (json['metrics'] as Map).cast<String, dynamic>();
    for (final key in [
      'elapsedMs',
      'modelLoadMs',
      'ocrCalls',
      'processedPixels',
      'modelBytes',
      'residentBytes',
      'policyRevision',
    ]) {
      final value = metrics[key];
      if (value is! num || !value.isFinite || value < 0) {
        throw FormatException('评估指标无效：$key');
      }
    }
    if (document.ocrEngine != engine.id ||
        document.recognitionRevision != metrics['policyRevision'] ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(metrics['imageSHA256'] as String)) {
      throw const FormatException('模型或评估原图标识无效');
    }
    final evaluatedAt = DateTime.parse(json['evaluatedAt'] as String);
    if (document.schemaVersion != 2 ||
        document.reviewed ||
        (metrics['modelLoadMs'] as num) > (metrics['elapsedMs'] as num)) {
      throw const FormatException('评估结果状态或耗时无效');
    }
    return StockOCRRun(engine, document, metrics, evaluatedAt);
  }
}

class StockOCRDifference {
  StockOCRDifference(this.reference, this.actual, this.issue);
  final StockLine? reference;
  final StockLine? actual;
  final String issue;
}

/// 完整参考单为分母，漏行、重复行不能以只比较交集来掩盖。
class StockOCRScore {
  StockOCRScore({
    required List<StockLine> reference,
    required List<StockLine> actual,
  }) {
    if (reference.isEmpty ||
        reference.any((line) => !line.ready) ||
        reference.map((line) => line.productId).toSet().length !=
            reference.length) {
      throw const FormatException('参考单必须逐项核实，且货物标识不能重复');
    }
    total = reference.length;
    final groups = <String, List<StockLine>>{};
    for (final line in actual) {
      if (line.productId != null) (groups[line.productId!] ??= []).add(line);
    }
    final consumed = <StockLine>{};
    for (final expected in reference) {
      final candidates = groups[expected.productId] ?? [];
      if (candidates.length != 1) {
        missing++;
        differences.add(
          StockOCRDifference(
            expected,
            null,
            candidates.isEmpty ? '漏识别或货物未匹配' : '同一货物识别出多行',
          ),
        );
        continue;
      }
      final line = candidates.single;
      consumed.add(line);
      identities++;
      final correct = StockInventory.sameReading(
        expected.cells[1],
        line.cells[1],
      );
      if (correct) inventories++;
      if (!correct) {
        differences.add(StockOCRDifference(expected, line, '库存数量、单位或分区不一致'));
        if (line.ready && line.autoConfirmed) wrongAutomatic++;
      }
    }
    for (final line in actual.where((line) => !consumed.contains(line))) {
      extras++;
      if (line.ready && line.autoConfirmed) wrongAutomatic++;
      differences.add(StockOCRDifference(null, line, '多识别、重复或未匹配的行'));
    }
  }
  late final int total;
  int identities = 0,
      inventories = 0,
      missing = 0,
      extras = 0,
      wrongAutomatic = 0;
  final differences = <StockOCRDifference>[];
  // 额外行也降低准确率，漏行已在参考单分母中。
  double get inventoryAccuracy => inventories / (total + extras);
  double get identityAccuracy => identities / (total + extras);
}

class StockOCRStore {
  final _channel = StockHistoryStore.channel;
  Future<StockOCREngine> selected() async {
    final raw = await _channel.invokeMethod<String>('getOCREngine');
    if (raw == null) throw StateError('未返回识别模型');
    return StockOCREngine.parse(raw);
  }

  Future<void> select(StockOCREngine engine) =>
      _channel.invokeMethod<void>('setOCREngine', engine.id);
  Future<StockOCRRun> evaluate(String id, StockOCREngine engine) async {
    final raw = await _channel.invokeMethod<String>('evaluateModel', {
      'id': id,
      'engine': engine.id,
    });
    if (raw == null) throw StateError('未返回模型评估结果');
    final run = StockOCRRun.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
    if (run.document.id != id || run.engine != engine) {
      throw const FormatException('模型评估结果标识错误');
    }
    return run;
  }

  Future<List<StockOCRRun>> runs(String id) async {
    final raw = await _channel.invokeMethod<String>('loadModelRuns', id);
    if (raw == null) throw StateError('未返回评估缓存');
    final runs = (jsonDecode(raw) as List)
        .map(
          (value) =>
              StockOCRRun.fromJson((value as Map).cast<String, dynamic>()),
        )
        .toList();
    if (runs.any((run) => run.document.id != id) ||
        runs.map((run) => run.engine).toSet().length != runs.length ||
        runs.map((run) => run.metrics['imageSHA256']).toSet().length > 1 ||
        runs.map((run) => run.metrics['policyRevision']).toSet().length > 1) {
      throw const FormatException('评估缓存不属于同一原图和处理规则');
    }
    return runs;
  }

  Future<StockDocument?> reference(String id) async {
    final raw = await _channel.invokeMethod<String>('loadOCRReference', id);
    if (raw == null) return null;
    final doc = StockDocument.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
    if (doc.id != id) throw const FormatException('参考单标识错误');
    StockOCRScore(reference: doc.lines, actual: const []);
    return doc;
  }

  Future<void> saveReference(StockDocument document) async {
    document.validate();
    StockOCRScore(reference: document.lines, actual: const []);
    await _channel.invokeMethod<void>(
      'saveOCRReference',
      jsonEncode(document.toJson()),
    );
  }
}
