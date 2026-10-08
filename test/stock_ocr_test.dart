import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_ocr.dart';
import 'package:luckinstocktaking/stock_ocr_page.dart';

StockLine row(String id, String inventory, {bool automatic = false}) =>
    StockLine(
      cells: [id, inventory],
      confidence: .9,
      productId: id,
      identityConfirmed: true,
      inventoryConfirmed: true,
      autoConfirmed: automatic,
    );
StockDocument doc(List<StockLine> lines, {String engine = 'vision'}) =>
    StockDocument(
      id: '12345678-1234-1234-1234-123456789abc',
      title: '评估单',
      createdAt: DateTime.utc(2026, 10, 8),
      imageName: '12345678-1234-1234-1234-123456789abc.png',
      lines: lines,
      reviewed: false,
      schemaVersion: 2,
      recognitionRevision: 22,
      ocrEngine: engine,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('库存准确率计入漏行和额外行，错误自动通过单独计数', () {
    final score = StockOCRScore(
      reference: [row('a', '1.5袋'), row('b', '0盒'), row('c', '2桶')],
      actual: [
        row('a', '15袋', automatic: true),
        row('b', '0.0盒', automatic: true),
        row('d', '1袋', automatic: true),
      ],
    );
    expect(score.total, 3);
    expect(score.inventories, 1);
    expect(score.identities, 2);
    expect(score.missing, 1);
    expect(score.extras, 1);
    expect(score.inventoryAccuracy, .25);
    expect(score.identityAccuracy, .5);
    expect(score.wrongAutomatic, 2);
    expect(score.differences.length, 3);
  });
  test('重复识别不任选正确的一条；空白、零和分区必须分开', () {
    final duplicated = StockOCRScore(
      reference: [row('a', '1袋')],
      actual: [row('a', '1袋'), row('a', '3袋')],
    );
    expect(duplicated.inventoryAccuracy, 0);
    expect(duplicated.missing, 1);
    expect(duplicated.extras, 2);
    final blank = StockOCRScore(
      reference: [row('a', '-袋'), row('b', '总库存2盒\n冷藏1盒\n冷冻1盒')],
      actual: [row('a', '0袋'), row('b', '2盒')],
    );
    expect(blank.inventories, 0);
  });
  test('未核实或重复的参考单被拒绝，旧单默认 Vision，模型信息往返保存', () {
    expect(
      () => StockOCRScore(
        reference: [
          StockLine(cells: ['a', '1袋'], confidence: .9),
        ],
        actual: [],
      ),
      throwsFormatException,
    );
    expect(
      () => StockOCRScore(
        reference: [row('a', '1袋'), row('a', '1袋')],
        actual: [],
      ),
      throwsFormatException,
    );
    final json = doc([row('a', '1袋')]).toJson()..remove('ocrEngine');
    expect(StockDocument.fromJson(json).ocrEngine, 'vision');
    final tiny = doc([row('a', '1袋')], engine: 'paddle_tiny');
    expect(
      StockDocument.fromJson(tiny.edited('新标题', tiny.lines).toJson()).ocrEngine,
      'paddle_tiny',
    );
    expect(() => StockOCREngine.parse('unknown'), throwsFormatException);
  });
  testWidgets('模型选择持久化；加载失败明确显示，不假切换', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var selected = 'vision';
    var failSmall = false;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'getOCREngine') return selected;
      if (call.method == 'setOCREngine') {
        if (failSmall && call.arguments == 'paddle_small') {
          throw PlatformException(code: 'missing_model', message: '模型文件缺失');
        }
        selected = call.arguments as String;
        return null;
      }
      throw StateError('非预期调用 ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await tester.pumpWidget(const MaterialApp(home: StockOCRPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PP-OCRv6 tiny'));
    await tester.pumpAndSettle();
    expect(selected, 'paddle_tiny');
    failSmall = true;
    await tester.tap(find.text('PP-OCRv6 small'));
    await tester.pumpAndSettle();
    expect(selected, 'paddle_tiny');
    expect(find.textContaining('模型文件缺失'), findsOneWidget);
  });
  test('评估响应验证模型、策略版本、原图哈希和数值', () {
    final json = {
      'engine': 'paddle_tiny',
      'evaluatedAt': '2026-10-08T10:00:00Z',
      'document': doc([row('a', '1袋')], engine: 'paddle_tiny').toJson(),
      'metrics': {
        'elapsedMs': 100.0,
        'modelLoadMs': 10.0,
        'ocrCalls': 2,
        'processedPixels': 1000,
        'modelBytes': 100,
        'residentBytes': 1000,
        'policyRevision': 22,
        'imageSHA256': 'a' * 64,
      },
    };
    expect(StockOCRRun.fromJson(json).engine, StockOCREngine.tiny);
    final wrong = (jsonDecode(jsonEncode(json)) as Map).cast<String, dynamic>();
    (wrong['metrics'] as Map)['elapsedMs'] = -1;
    expect(() => StockOCRRun.fromJson(wrong), throwsFormatException);
    json['engine'] = 'vision';
    expect(() => StockOCRRun.fromJson(json), throwsFormatException);
  });
}
