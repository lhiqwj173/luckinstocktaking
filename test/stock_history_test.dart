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
    var pendingChecks = 0;
    var automaticRecognitions = 0;
    Map<String, dynamic>? saved;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.luckinstocktaking/catalog'),
      (call) async => call.method == 'diagnostics'
          ? {'version': '1.4.2', 'appBundleId': 'test'}
          : '[]',
    );
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      switch (call.method) {
        case 'pending':
          pendingChecks++;
          if (consumed) return null;
          consumed = true;
          return jsonEncode(record());
        case 'table':
          automaticRecognitions++;
          final table = record();
          table['schemaVersion'] = 2;
          table['recognitionRevision'] = 1;
          table['lines'] = [
            {
              'cells': ['椰乳', '01.30盒'],
              'confidence': .72,
            },
            {
              'cells': ['椰乳', '01.20盒'],
              'confidence': .91,
            },
          ];
          return jsonEncode(table);
        case 'imageTiles':
          return [png!];
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
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('货物规格名称'), findsOneWidget);
    expect(find.text('实盘总库存'), findsOneWidget);
    expect(find.text('查看长图'), findsOneWidget);
    expect(find.text('需重点核对'), findsNothing);
    expect(find.text('库存数字待确认'), findsNothing);
    tester.binding.channelBuffers.push(
      StockHistoryStore.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('historyReady'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(pendingChecks, 2, reason: '查看历史时仍应响应拼接快捷指令完成通知');
    expect(find.byTooltip('优化识别'), findsNothing);
    expect(automaticRecognitions, 1);
    expect(find.text('1.3盒'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '单据名称（可填写日期 / 门店 / 单号）'),
      '已校对的盘点单',
    );
    await tester.ensureVisible(find.text('保存修改并标记已校对'));
    await tester.tap(find.text('保存修改并标记已校对'));
    await tester.pumpAndSettle();
    expect(saved!['title'], '已校对的盘点单');
    expect(saved!['reviewed'], true);
    expect(saved!['recognitionRevision'], 1);
    expect((saved!['lines'] as List).length, 2);
    expect(find.text('盘点单详情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('识别失败仍能按原比例查看长图分段并放大', (tester) async {
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 192, 1800),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(192, 1800);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'imageTiles') return [png!, png];
      if (call.method == 'table') {
        throw PlatformException(code: 'OCR_FAILED', message: '库存识别失败');
      }
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StockDocumentPage(document: StockDocument.fromJson(record())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('库存识别失败'), findsOneWidget);
    expect(find.textContaining('等待整理货物表'), findsOneWidget);
    expect(find.textContaining('2 项货物'), findsNothing);
    expect(find.textContaining('识别结果已自动保存'), findsNothing);
    await tester.ensureVisible(find.text('查看长图'));
    await tester.tap(find.text('查看长图'));
    await tester.pumpAndSettle();
    final tile = find.byType(Image).first;
    await tester.runAsync(
      () =>
          precacheImage(tester.widget<Image>(tile).image, tester.element(tile)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(tile);
    final size = tester.getSize(tile);
    expect(size.height / size.width, closeTo(1800 / 192, .001));
    await tester.tapAt(tester.getTopLeft(tile) + const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('放大查看'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('低置信度品名不标记为错误，库存零值及混合单位均保留', () {
    for (final inventory in ['0个', '14个', '2捆-个', '-箱13包']) {
      final line = StockLine(
        cells: ['CURTA塑料冷水壶\nGS00712-01', inventory],
        confidence: .2,
      );
      expect(line.reviewIssue, isNull);
      expect(line.confidence, .2);
    }
  });

  test('只为货号和库存中的明确数字字符疑点提示原因', () {
    expect(
      StockLine(cells: ['冷水壶\nGS007I2-01', '14个'], confidence: .9).reviewIssue,
      '货号中有易混淆字符',
    );
    expect(
      StockLine(
        cells: ['冷水壶\nGS00712-01', '总库存：O个\n冷藏：0个'],
        confidence: .9,
      ).reviewIssue,
      '库存数字待确认',
    );
    expect(
      StockLine(cells: ['冷水壶\nGS00712-01', 'O个'], confidence: .9).reviewIssue,
      '库存数字待确认',
    );
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

  test('未校对历史自动检查算法版本，已校对内容直接保留', () async {
    final data = {
      ...record(),
      'schemaVersion': 2,
      'lines': [
        {
          'cells': ['奶油', '13包'],
          'confidence': .5,
        },
      ],
    };
    var requests = 0;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      expect(call.method, 'table');
      requests++;
      return jsonEncode({...data, 'recognitionRevision': 1});
    });
    final upgraded = await StockHistoryStore().table(
      StockDocument.fromJson(data),
    );
    expect(requests, 1);
    expect(upgraded.recognitionRevision, 1);
    expect(
      upgraded.edited('已校对', upgraded.lines).toJson()['recognitionRevision'],
      1,
    );
    final reviewed = StockDocument.fromJson({...data, 'reviewed': true});
    expect(await StockHistoryStore().table(reviewed), same(reviewed));
    expect(requests, 1);
  });

  test('全文搜索覆盖单据和数字，多关键词必须同时命中', () {
    final document = StockDocument.fromJson(record());
    expect(document.matches('人民路 椰乳 01.20'), true);
    expect(document.matches('人民路 牛奶'), false);
    expect(document.matches('  '), true);
  });

  test('两列表格保留多行名称库存并拒绝缺列', () {
    final data = {
      ...record(),
      'schemaVersion': 2,
      'lines': [
        {
          'cells': ['奶油 0.5L\nGS00147-01', '总库存：7个\n冷藏：2个\n冷冻：5个'],
          'confidence': .8,
        },
      ],
    };
    final document = StockDocument.fromJson(data);
    expect(document.schemaVersion, 2);
    expect(document.edited('已校对', document.lines).toJson()['schemaVersion'], 2);
    expect(document.matches('GS00147 冷冻'), true);
    expect(
      () => StockDocument.fromJson({
        ...data,
        'lines': [
          {
            'cells': ['仅有名称'],
            'confidence': .8,
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('拒绝损坏历史版本、路径、空行和非法置信度', () {
    for (final broken in [
      {...record(), 'schemaVersion': 3},
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

  testWidgets('拼接录屏选择用户录制的视频且不启动录屏', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      calls.add(call);
      if (call.method == 'list') return '[]';
      if (call.method == 'import') return null;
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    expect(find.text('开始自动录屏'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('拼接录屏'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method).toList(), ['list', 'import']);
    expect(calls.last.arguments, {'video': true});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('截图组入口调用批量导入，取消后不创建历史', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      calls.add(call);
      if (call.method == 'list') return '[]';
      if (call.method == 'importScreenshots') return null;
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拼接截图组'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), ['list', 'importScreenshots']);
    expect(find.text('盘点单详情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('历史加载拒绝重复标识，系统选择器取消不创建记录', () async {
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'import') return null;
      return jsonEncode([record(), record()]);
    });
    await expectLater(StockHistoryStore().load(), throwsFormatException);
    expect(await StockHistoryStore().pick(video: true), isNull);
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

  testWidgets('删除需确认，失败保留记录，成功只删除指定单据', (tester) async {
    final remaining = [
      record(),
      {
        ...record(title: '另一张单据'),
        'id': '22345678-1234-1234-1234-123456789abc',
        'imageName': '22345678-1234-1234-1234-123456789abc.png',
      },
    ];
    final deleted = <String>[];
    var failDelete = true;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'list') return jsonEncode(remaining);
      if (call.method == 'delete') {
        if (failDelete) {
          throw PlatformException(code: 'DELETE_FAILED', message: '删除失败');
        }
        deleted.add(call.arguments as String);
        remaining.removeWhere((item) => item['id'] == call.arguments);
        return null;
      }
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    final button = find.byTooltip('删除盘点单').first;
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除失败'), findsOneWidget);
    expect(find.text('人民路店 2026-09-30'), findsOneWidget);
    failDelete = false;
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, ['12345678-1234-1234-1234-123456789abc']);
    expect(find.text('人民路店 2026-09-30'), findsNothing);
    expect(find.text('另一张单据'), findsOneWidget);
    expect(find.text('历史记录 · 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
