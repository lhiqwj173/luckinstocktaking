import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import 'stock_history.dart';
import 'stock_inventory.dart';
import 'stock_product.dart';
import 'stock_ocr.dart';

/// 调试数据保留原始输入与最终结果，不替用户确认或改写盘点单。
Map<String, dynamic> stockDebugReport(
  StockDocument document,
  List<StockProduct> products,
) {
  document.validate();
  validateProducts(products);
  return {
    'schemaVersion': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'matchingPolicy': {
      'revision': 'generic-edit-distance-v3',
      'goods': '准确唯一货号；相似度至少85%，或至少4字符文本仅差1字符；规格冲突阻断',
      'prepared': '相似度至少90%；唯一精确匹配或领先第二候选至少10个百分点',
      'inventory': '完整读数至少三次一致；分区漏读且已读值一致为弃权；存在异读时至少五票且占有效票80%；仍校验单位、分区完整性与合计',
      'revalidation': '自动确认行重新使用原始 OCR 名称核验；人工搜索支持名称、别名和货号片段，不自动确认',
    },
    'currentDocument': document.toJson(),
    'products': products.map((product) => product.toJson()).toList(),
    'summary': {
      'rows': document.lines.length,
      'pending': document.lines.where((line) => !line.ready).length,
      'automatic': document.lines
          .where((line) => line.ready && line.autoConfirmed)
          .length,
    },
    'rows': [
      for (var i = 0; i < document.lines.length; i++)
        _rowReport(i, document.lines[i], products),
    ],
  };
}

Map<String, dynamic> _rowReport(
  int index,
  StockLine line,
  List<StockProduct> products,
) {
  if (line.cells.length != 2) {
    return {
      'rowNumber': index + 1,
      'line': line.toJson(),
      'analysisStatus': '旧格式尚未整理为两列，保留原始字段，不推断库存',
    };
  }
  final raw = line.sourceCells;
  final proof = line.inventoryEvidence;
  return {
    'rowNumber': index + 1,
    'line': line.toJson(),
    'ready': line.ready,
    'pendingReason': line.ready ? null : line.pendingReason,
    'reviewIssue': line.reviewIssue,
    'inventoryParsed': {
      'needsReview': line.inventory.needsReview,
      'reviewStatus': line.inventory.reviewStatus,
      'parts': {
        for (final part in line.inventory.parts.entries)
          part.key: {
            'raw': part.value.raw,
            'uncertain': part.value.uncertain,
            'amounts': {
              for (final amount in part.value.amounts.entries)
                amount.key: amount.value.format(),
            },
          },
      },
    },
    'rawCandidates': [
      for (final candidate in matchProducts(raw[0], line.category, products))
        {
          'productId': candidate.product.id,
          'product': candidate.product.toJson(),
          'textSimilarity': candidate.score,
          'editDistance': candidate.edits,
          'exactCode': candidate.exactCode,
          'conflict': candidate.conflict,
        },
    ],
    'inventoryEvidence': {
      'supporting': proof.supporting,
      'abstentions': proof.abstentions,
      'conflicting': proof.conflicting,
      'sufficient': proof.sufficient,
      'partialReadings': line.inventoryReadings
          .where(
            (reading) => StockInventory.partialReading(line.cells[1], reading),
          )
          .length,
      'decisiveVotes': proof.supporting + proof.conflicting,
      'readings': [
        for (final reading in line.inventoryReadings)
          {
            'raw': reading,
            'normalized': StockInventory.normalizeFormat(reading),
            'signature': StockInventory.readingSignature(reading),
            'sameAsCurrent': StockInventory.sameReading(line.cells[1], reading),
            'unrelatedText': StockInventory.noiseVariant(
              line.cells[1],
              reading,
            ),
            'extraFragments': StockInventory.contaminatedVariant(
              line.cells[1],
              reading,
            ),
          },
      ],
    },
  };
}

Uint8List _encodeDebugZip(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    if (entry.key.startsWith('/') ||
        entry.key.contains('..') ||
        entry.key.contains('\\') ||
        entry.value.isEmpty) {
      throw FormatException('诊断包文件无效：${entry.key}');
    }
    final file = ArchiveFile(entry.key, entry.value.length, entry.value);
    if (entry.key.endsWith('.png') || entry.key.endsWith('.original')) {
      file.compress = false;
    }
    archive.addFile(file);
  }
  final bytes = ZipEncoder().encode(archive);
  if (bytes == null || bytes.isEmpty) throw StateError('诊断包生成失败');
  return Uint8List.fromList(bytes);
}

Future<void> shareStockDebug(
  StockHistoryStore store, {
  StockDocument? document,
  List<StockProduct> products = const [],
}) async {
  final context = await StockHistoryStore.channel
      .invokeMapMethod<String, dynamic>('debugContext', document?.id);
  if (context == null ||
      context['metadata'] is! String ||
      context['files'] is! Map) {
    throw const FormatException('原生诊断数据缺失或无效');
  }
  final metadata = (jsonDecode(context['metadata'] as String) as Map)
      .cast<String, dynamic>();
  if (metadata['documentId'] != document?.id) {
    throw const FormatException('诊断数据单据标识不一致');
  }
  final files = <String, Uint8List>{
    'manifest.json': Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(metadata)),
    ),
  };
  for (final entry in (context['files'] as Map).entries) {
    if (entry.key is! String ||
        entry.value is! Uint8List ||
        files.containsKey(entry.key)) {
      throw const FormatException('诊断文件类型或名称无效');
    }
    files[entry.key as String] = entry.value as Uint8List;
  }
  if (document != null) {
    files['analysis.json'] = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ')
            .convert(stockDebugReport(document, products)),
      ),
    );
    for (final engine in StockOCREngine.values) {
      final raw = files['ocr-run-${engine.id}.json'];
      if (raw == null) continue; // 未评估的模型在原生清单中明确标记缺失。
      final run = StockOCRRun.fromJson(
        (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>(),
      );
      if (run.document.id != document.id) {
        throw const FormatException('模型调试记录单据标识不一致');
      }
      final interpreted = run.document.edited(
        run.document.title,
        run.document.lines
            .map((line) => reconcileStockLine(line, products))
            .toList(),
      );
      final report = stockDebugReport(interpreted, products);
      report['compatibleWithCurrentInput'] =
          run.metrics['imageSHA256'] == metadata['imageSHA256'] &&
          run.metrics['policyRevision'] == metadata['recognitionRevision'];
      report['evaluatedAt'] = run.evaluatedAt.toUtc().toIso8601String();
      report['latestEvaluationFailed'] = files.containsKey(
        'ocr-error-${engine.id}.json',
      );
      files['model-analysis/${engine.id}.json'] = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(report)),
      );
    }
  }
  final bytes = await compute(_encodeDebugZip, files);
  await store.shareBytes(
    name: 'stock-debug-${document?.id ?? 'latest'}.zip',
    bytes: bytes,
  );
}
