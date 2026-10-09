import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_debug.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_product.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final product = StockProduct(
    code: 'GS10001-01',
    name: '测试商品',
    specification: '500g*12袋/箱',
    units: ['袋', '箱'],
  );
  final rawLine = StockLine(
    cells: ['测式商品500g*12袋/箱 GS10001-01', '8.4袋'],
    confidence: .9,
    inventoryConfidence: .8,
    inventoryReadings: ['8.4袋', '26\n8.4袋\n李', '8.4袋', '8.4袋'],
  );
  StockDocument document(List<StockLine> lines) => StockDocument(
    id: '12345678-1234-1234-1234-123456789abc',
    title: '未保存标题',
    createdAt: DateTime.utc(2026, 10, 9),
    imageName: '12345678-1234-1234-1234-123456789abc.png',
    lines: lines,
    reviewed: false,
    schemaVersion: 2,
    recognitionRevision: 23,
  );
  test('调试报告同时保留原始读数、当前结果、匹配依据和污染分类', () {
    final line = reconcileStockLine(rawLine, [product]);
    final report = stockDebugReport(document([line]), [product]);
    final row = (report['rows'] as List).single as Map;
    final candidate = (row['rawCandidates'] as List).single as Map;
    expect(candidate['editDistance'], 1);
    expect(candidate['exactCode'], true);
    expect(candidate['textSimilarity'], greaterThan(.85));
    final evidence = row['inventoryEvidence'] as Map;
    expect(evidence['supporting'], 3);
    expect(evidence['conflicting'], 0);
    expect((evidence['readings'] as List)[1]['extraFragments'], true);
    expect((evidence['readings'] as List)[1]['raw'], '26\n8.4袋\n李');
    expect(row['line']['sourceCells'], rawLine.cells);
    expect(row['line']['cells'][0], product.display);
    expect(report['currentDocument']['title'], '未保存标题');
    expect(jsonEncode(report), contains('8.4袋'));
  });
  test('ZIP 导出保留图片字节和独立日志，包含当前修改与模型逐行分析', () async {
    final doc = document([rawLine]);
    final model = {
      'engine': 'vision',
      'evaluatedAt': '2026-10-09T10:00:00Z',
      'document': doc.toJson(),
      'metrics': {
        'elapsedMs': 100,
        'modelLoadMs': 0,
        'ocrCalls': 2,
        'processedPixels': 1000,
        'modelBytes': 0,
        'residentBytes': 100,
        'policyRevision': 23,
        'imageSHA256': 'a' * 64,
      },
    };
    final source = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map? share;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'debugContext') {
        expect(call.arguments, doc.id);
        return {
          'metadata': jsonEncode({
            'documentId': doc.id,
            'imageSHA256': 'a' * 64,
            'recognitionRevision': 23,
            'missingFiles': ['ocr-log-paddle_small.log'],
          }),
          'files': {
            'source.png': source,
            'parse.log': Uint8List.fromList(utf8.encode('首次解析日志')),
            'ocr-log-vision.log': Uint8List.fromList(
              utf8.encode('Vision 专属日志'),
            ),
            'ocr-run-vision.json': Uint8List.fromList(
              utf8.encode(jsonEncode(model)),
            ),
          },
        };
      }
      if (call.method == 'shareBytes') {
        share = call.arguments as Map;
        return null;
      }
      throw StateError('非预期调用 ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await shareStockDebug(
      StockHistoryStore(),
      document: doc,
      products: [product],
    );
    expect(share!['name'], 'stock-debug-${doc.id}.zip');
    final archive = ZipDecoder().decodeBytes(share!['bytes'] as Uint8List);
    expect(archive.findFile('source.png')!.content, source);
    expect(
      utf8.decode(archive.findFile('parse.log')!.content as List<int>),
      '首次解析日志',
    );
    final analysis = jsonDecode(
      utf8.decode(archive.findFile('analysis.json')!.content as List<int>),
    );
    expect(analysis['currentDocument']['title'], '未保存标题');
    final evaluation = jsonDecode(
      utf8.decode(
        archive.findFile('model-analysis/vision.json')!.content as List<int>,
      ),
    );
    expect(evaluation['compatibleWithCurrentInput'], true);
    expect(evaluation['summary']['automatic'], 1);
  });
  test('拒绝其他单据的诊断数据，不打开分享面板', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'debugContext') {
        return {'metadata': '{"documentId":"other"}', 'files': {}};
      }
      throw StateError('错误数据不应导出');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await expectLater(
      shareStockDebug(StockHistoryStore(), document: document([rawLine])),
      throwsFormatException,
    );
  });
}
