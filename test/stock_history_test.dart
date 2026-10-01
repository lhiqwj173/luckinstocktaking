import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_history_page.dart';
import 'package:luckinstocktaking/main.dart';

Map<String, dynamic> record({String title = '人民路店 2026-09-30'}) => {
  'schemaVersion': 1,
  'id': '12345678-1234-1234-1234-123456789abc',
  'title': title,
  'createdAt': '2026-10-01T02:30:00Z',
  'imageName': '12345678-1234-1234-1234-123456789abc.png',
  'lines': [
    {
      'cells': ['椰乳', '01.20', '盒'],
      'confidence': .72,
    },
    {
      'cells': ['椰乳', '01.20', '盒'],
      'confidence': .91,
    },
  ],
  'reviewed': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
  );
  tearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('com.luckinstocktaking/catalog'),
      null,
    ),
  );

  testWidgets('快捷指令导入后自动打开校对页并保存修改', (tester) async {
    final png = await tester.runAsync(() async {
      final picture = ui.PictureRecorder();
      final canvas = Canvas(picture);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = Colors.white,
      );
      final image = await picture.endRecording().toImage(1, 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    });
    var consumed = false;
    var startChecks = 0;
    Map<String, dynamic>? saved;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.luckinstocktaking/catalog'),
      (call) async => call.method == 'diagnostics'
          ? {'version': '1.4.2', 'appBundleId': 'test'}
          : '[]',
    );
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      switch (call.method) {
        case 'pendingStart':
          startChecks++;
          return null;
        case 'pending':
          if (consumed) return null;
          consumed = true;
          return jsonEncode(record());
        case 'image':
          return png!;
        case 'save':
          saved = jsonDecode(call.arguments as String) as Map<String, dynamic>;
          return null;
        default:
          throw StateError('意外的平台请求：${call.method}');
      }
    });
    await tester.pumpWidget(const StocktakingApp());
    await tester.pumpAndSettle();
    expect(find.text('盘点单详情'), findsOneWidget);
    tester.binding.channelBuffers.push(
      StockHistoryStore.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('historyReady'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(startChecks, 2, reason: '查看历史时仍应响应新的录屏快捷指令');
    await tester.enterText(find.byType(TextField).first, '已校对的盘点单');
    await tester.ensureVisible(find.text('保存修改并标记已校对'));
    await tester.tap(find.text('保存修改并标记已校对'));
    await tester.pumpAndSettle();
    expect(saved!['title'], '已校对的盘点单');
    expect(saved!['reviewed'], true);
    expect((saved!['lines'] as List).length, 2);
    expect(find.text('盘点单详情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('往返保留重复行、原始数量、置信度及导入时间', () {
    final document = StockDocument.fromJson(record());
    final decoded = StockDocument.fromJson(
      jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.lines.length, 2);
    expect(decoded.lines[0].cells, ['椰乳', '01.20', '盒']);
    expect(decoded.lines[0].confidence, .72);
    expect(decoded.createdAt, document.createdAt);
    expect(decoded.reviewed, false);
    final edited = decoded.edited(' 修正单据 ', [
      StockLine(cells: ['椰乳', '1.3', '盒'], confidence: 1),
    ]);
    expect(edited.id, document.id);
    expect(edited.title, '修正单据');
    expect(edited.reviewed, true);
  });

  test('全文搜索覆盖单据和数字，多关键词必须同时命中', () {
    final document = StockDocument.fromJson(record());
    expect(document.matches('人民路 椰乳 01.20'), true);
    expect(document.matches('人民路 牛奶'), false);
    expect(document.matches('  '), true);
  });

  test('拒绝损坏历史版本、路径、空行和非法置信度', () {
    for (final broken in [
      {...record(), 'schemaVersion': 2},
      {...record(), 'imageName': '../other.png'},
      {...record(), 'title': ' '},
      {...record(), 'lines': []},
      {
        ...record(),
        'lines': [
          {
            'cells': ['椰乳'],
            'confidence': 1.01,
          },
        ],
      },
      {
        ...record(),
        'lines': [
          {
            'cells': [' '],
            'confidence': .8,
          },
        ],
      },
    ]) {
      expect(() => StockDocument.fromJson(broken), throwsFormatException);
    }
  });

  test('空历史是合法初始状态，平台缺失响应不能当作空历史', () async {
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => '[]',
    );
    expect(await StockHistoryStore().load(), isEmpty);
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => null,
    );
    await expectLater(StockHistoryStore().load(), throwsStateError);
  });

  test('自动录屏启动传递固定裁剪配置，失败必须向调用方报错', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      received = call;
      return null;
    });
    await StockHistoryStore().startCapture(top: .22, bottom: .08);
    expect(received!.method, 'startCapture');
    expect(received!.arguments, {'top': .22, 'bottom': .08});
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async =>
          throw PlatformException(code: 'HISTORY_ERROR', message: '已有录屏正在进行'),
    );
    await expectLater(
      StockHistoryStore().startCapture(top: .22, bottom: .08),
      throwsA(isA<PlatformException>()),
    );
  });

  testWidgets('自动录屏入口不调用相册选择或手动导入', (tester) async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      methods.add(call.method);
      if (call.method == 'list') return '[]';
      if (call.method == 'startCapture') return null;
      throw StateError('意外的平台请求：${call.method}');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始自动录屏'));
    await tester.pumpAndSettle();
    expect(methods, ['list', 'startCapture']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('历史加载拒绝重复标识，系统选择器取消不创建记录', () async {
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'import') return null;
      return jsonEncode([record(), record()]);
    });
    await expectLater(StockHistoryStore().load(), throwsFormatException);
    expect(
      await StockHistoryStore().pick(video: true, top: .18, bottom: .1),
      isNull,
    );
  });

  testWidgets('历史页面按品名搜索并明确显示读取失败', (tester) async {
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => jsonEncode([
        record(),
        {
          ...record(title: '另一张单据'),
          'id': '22345678-1234-1234-1234-123456789abc',
          'imageName': '22345678-1234-1234-1234-123456789abc.png',
          'lines': [
            {
              'cells': ['牛奶', '3'],
              'confidence': 1,
            },
          ],
        },
      ]),
    );
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '椰乳');
    await tester.pumpAndSettle();
    expect(find.text('人民路店 2026-09-30'), findsOneWidget);
    expect(find.text('另一张单据'), findsNothing);
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => throw PlatformException(code: 'BROKEN', message: '原图损坏'),
    );
    await tester.tap(find.byTooltip('刷新历史'));
    await tester.pumpAndSettle();
    expect(find.text('原图损坏'), findsOneWidget);
  });
}
