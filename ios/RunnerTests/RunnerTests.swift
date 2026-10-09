import Flutter
import CoreFoundation
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testDiagnosticSnapshotKeepsTaskLogAndStructuredCoordinates() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try! FileManager.default.removeItem(at: folder) }
    let previous = UserDefaults.standard.bool(forKey: "stock.ocr.debugInputs")
    UserDefaults.standard.set(true, forKey: "stock.ocr.debugInputs")
    defer { UserDefaults.standard.set(previous, forKey: "stock.ocr.debugInputs") }
    StockDiagnostics.begin("单据 A")
    let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
      UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    try StockDiagnostics.ocrCall(XCTUnwrap(image.cgImage), engine: "vision", level: 0,
      minimumTextHeight: 0, elapsedMs: 12, observations: [])
    try StockDiagnostics.cells("inventory-primary", [StockOCRCell(text: "8.4袋", confidence: 0.9,
      box: CGRect(x: 500, y: 120, width: 50, height: 20))])
    let target = folder.appendingPathComponent("parse.log")
    try StockDiagnostics.snapshot(to: target)
    let callFile = target.appendingPathExtension("artifacts").appendingPathComponent("000001.json")
    let call = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: callFile)) as? [String: Any])
    XCTAssertEqual(call["imageCaptured"] as? Bool, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathExtension("artifacts").appendingPathComponent("000001.png").path))
    let first = try String(contentsOf: target, encoding: .utf8)
    XCTAssertTrue(first.contains("单据 A"))
    XCTAssertTrue(first.contains("OCR_CELLS"))
    XCTAssertTrue(first.contains("inventory-primary"))
    XCTAssertTrue(first.contains("8.4袋"))
    StockDiagnostics.begin("单据 B")
    StockDiagnostics.log("新模型的另一份日志")
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), first)
    XCTAssertFalse(first.contains("单据 B"))
  }
  func testPaddleCTCKeepsDecimalAndSeparatesRepeatedCharacters() throws {
    let dictionary = ["", "1", ".", "5", "袋"]
    let ids = [0, 1, 1, 2, 0, 3, 4, 4, 0]
    var values = [Float](repeating: 0.001, count: ids.count * dictionary.count)
    for (step, token) in ids.enumerated() { values[step * dictionary.count + token] = 0.99 }
    let output = try StockPaddleRuntime.decode(values, steps: ids.count, dictionary: dictionary, widthRatio: 1)
    XCTAssertEqual(output.0, "1.5袋")
    XCTAssertEqual(output.2.count, 4)
    XCTAssertLessThan(output.2[0].1, output.2[1].1)
    values[0] = .nan
    XCTAssertThrowsError(try StockPaddleRuntime.decode(values, steps: ids.count, dictionary: dictionary, widthRatio: 1))
    let repeatIds = [1, 1, 0, 1]
    let repeated = repeatIds.flatMap { token in (0..<dictionary.count).map { $0 == token ? Float(0.99) : Float(0.001) } }
    XCTAssertEqual(try StockPaddleRuntime.decode(repeated, steps: repeatIds.count, dictionary: dictionary, widthRatio: 1).0, "11")
  }

  func testPaddleGeometryKeepsTopOriginAndRejectsInvalidProbabilities() throws {
    let width = 120; let height = 60
    var values = [Float](repeating: 0, count: width * height)
    for y in 10..<20 { for x in 20..<90 { values[y * width + x] = 0.95 } }
    let boxes = try StockPaddleGeometry.detect(values, width: width, height: height)
    XCTAssertEqual(boxes.count, 1)
    XCTAssertGreaterThan(boxes[0][0].y, boxes[0][3].y)
    XCTAssertLessThan(boxes[0][0].x, boxes[0][1].x)
    XCTAssertGreaterThan(StockPaddleGeometry.bounds(boxes[0]).midY, 0.5)
    values[0] = -1
    XCTAssertThrowsError(try StockPaddleGeometry.detect(values, width: width, height: height))
  }

  func testBundledPaddleModelsRecognizeSyntheticInventory() throws {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 250, height: 80), format: format).image { context in
      UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 250, height: 80))
      ("1.5袋" as NSString).draw(at: CGPoint(x: 25, y: 16), withAttributes: [
        .font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
    }
    for engine in [StockOCREngine.paddleTiny, .paddleSmall] {
      let (results, context, _) = try StockOCR.withEngine(engine) { try StockOCR.recognize(XCTUnwrap(image.cgImage)) }
      XCTAssertTrue(results.contains { $0.topCandidates(1).first?.string.contains("1.5") == true }, "\(engine.rawValue) 应识别清晰合成库存")
      XCTAssertEqual(context.calls, 1)
      XCTAssertGreaterThan(try StockOCR.modelBytes(engine), 0)
    }
  }
  func testFocusedInventoryReadingsKeepLowScoresAndEarlierConflicts() {
    let original = StockTextLine(cells: ["测试商品", "1.5袋"], confidence: 0.5,
      inventoryReadings: ["1.5袋", "15袋"], inventoryConfidence: 0.5)
    let cell = StockOCRCell(text: "1.5袋", confidence: 0.5,
      box: CGRect(x: 500, y: 120, width: 50, height: 20))
    let result = StockHistoryProcessor.appendFocusedInventoryReadings(original, raw: [cell], clean: [cell])
    XCTAssertEqual(result.inventoryReadings, ["1.5袋", "15袋", "1.5袋", "1.5袋"])
    XCTAssertEqual(result.inventoryConfidence, 0.5)
    XCTAssertEqual(result.cells, original.cells)
    let missing = StockHistoryProcessor.appendFocusedInventoryReadings(original, raw: [], clean: [cell])
    XCTAssertNil(missing.inventoryConfidence)
    XCTAssertEqual(missing.inventoryReadings, ["1.5袋", "15袋", "", "1.5袋"])
  }

  func testInventoryVerificationKeepsActualReadingsInTheirOwnRows() throws {
    let rows = [
      StockTextLine(cells: ["商品A", "12盒"], confidence: 0.9, sourceTop: 100, sourceBottom: 200),
      StockTextLine(cells: ["商品B", "1盒"], confidence: 0.9, sourceTop: 200, sourceBottom: 300)
    ]
    func cell(_ text: String, _ y: CGFloat, _ confidence: Double = 0.95) -> StockOCRCell {
      StockOCRCell(text: text, confidence: confidence, box: CGRect(x: 500, y: y, width: 50, height: 20))
    }
    let result = try StockHistoryProcessor.attachInventoryReadings(rows,
      primary: [cell("12盒", 120), cell("1盒", 220)],
      verification: [cell("1盒", 220, 0.85), cell("12盒", 120)])
    XCTAssertEqual(result[0].inventoryReadings, ["12盒", "12盒"])
    XCTAssertEqual(result[1].inventoryReadings, ["1盒", "1盒"])
    XCTAssertEqual(result[1].inventoryConfidence, 0.85)
    let missing = try StockHistoryProcessor.attachInventoryReadings(rows,
      primary: [cell("12盒", 120)], verification: [cell("1盒", 120)])
    XCTAssertEqual(missing[0].inventoryReadings, ["12盒", "1盒"])
    XCTAssertEqual(missing[1].inventoryReadings, ["", ""])
    XCTAssertNil(missing[1].inventoryConfidence)
    XCTAssertEqual(missing[0].cells[1], "12盒")
    XCTAssertThrowsError(try StockHistoryProcessor.attachInventoryReadings(
      [StockTextLine(cells: ["商品", "12盒"], confidence: 0.9)], primary: [], verification: []))
  }

  func testFocusedReadingsRecoverEvidenceAfterBatchMissWithoutErasingRawReads() {
    let original = StockTextLine(cells: ["测试商品", "-袋5个"], confidence: 0.9,
      inventoryReadings: ["-袋5个", ""], inventoryConfidence: nil)
    let cell = StockOCRCell(text: "-袋5个", confidence: 0.9,
      box: CGRect(x: 500, y: 120, width: 50, height: 20))
    let result = StockHistoryProcessor.appendFocusedInventoryReadings(original, raw: [cell], clean: [cell])
    XCTAssertEqual(result.inventoryReadings, ["-袋5个", "", "-袋5个", "-袋5个"])
    XCTAssertEqual(result.inventoryConfidence, 0.9)
    let different = StockOCRCell(text: "-袋6个", confidence: 0.95, box: cell.box)
    XCTAssertNil(StockHistoryProcessor.appendFocusedInventoryReadings(original, raw: [cell], clean: [different]).inventoryConfidence)
    let noOriginal = StockTextLine(cells: ["测试商品", "-袋5个"], confidence: 0.9,
      inventoryReadings: ["", ""], inventoryConfidence: nil)
    XCTAssertNil(StockHistoryProcessor.appendFocusedInventoryReadings(noOriginal, raw: [cell], clean: [cell]).inventoryConfidence)
  }

  func testProductSeedPreservesUserChangesAndDeletedEntries() throws {
    func product(_ code: String, _ name: String) -> [String: Any] {
      ["id": code, "code": code, "name": name, "specification": "1L*12盒/箱",
        "units": ["盒", "箱"], "aliases": [String](), "category": "goods"]
    }
    let seed = [product("GS10001-01", "内置名称"), product("GS10001-02", "新增货物")]
    let existing = StockProductStorage.Snapshot(
      products: [product("GS10001-01", "用户修改名称")], appliedSeeds: [])
    let initialized = try StockProductStorage.applying(seed, version: "v1", to: existing)
    XCTAssertEqual(initialized.products.count, 2)
    XCTAssertEqual(initialized.products[0]["name"] as? String, "用户修改名称")
    XCTAssertEqual(initialized.appliedSeeds, ["v1"])
    let deleted = StockProductStorage.Snapshot(products: [], appliedSeeds: initialized.appliedSeeds)
    let reloaded = try StockProductStorage.applying(seed, version: "v1", to: deleted)
    XCTAssertTrue(reloaded.products.isEmpty)
    XCTAssertEqual(reloaded.appliedSeeds, ["v1"])
    XCTAssertThrowsError(try StockProductStorage.applying(seed + seed, version: "v2", to: deleted))
    XCTAssertThrowsError(try StockProductStorage.applying(seed, version: "", to: deleted))
  }

  func testProductStorageMigratesLegacyListsAndRejectsCorruption() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    addTeardownBlock { try FileManager.default.removeItem(at: url) }
    let product: [String: Any] = ["id": "GS10001-01", "code": "GS10001-01", "name": "测试货物",
      "specification": "", "units": ["个"], "aliases": [String](), "category": "goods"]
    try JSONSerialization.data(withJSONObject: [product]).write(to: url, options: .atomic)
    let legacy = try StockProductStorage.read(url)
    XCTAssertTrue(legacy.appliedSeeds.isEmpty)
    let initialized = try StockProductStorage.applying([product], version: "v1", to: legacy)
    try StockProductStorage.write(initialized, to: url)
    XCTAssertEqual(try StockProductStorage.read(url).appliedSeeds, ["v1"])
    XCTAssertEqual(try StockProductStorage.read(url).products.count, 1)
    try Data("{损坏的档案".utf8).write(to: url, options: .atomic)
    XCTAssertThrowsError(try StockProductStorage.read(url))
  }

  func testVisualBackgroundRowsPreserveCoordinatesWithoutOCR() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 828, height: 320), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 828, height: 320))
      UIColor(white: 245.0 / 255.0, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 20, width: 828, height: 100))
      context.fill(CGRect(x: 0, y: 220, width: 828, height: 100))
    }
    let bands = try StockHistoryProcessor.visualGoodsRows(XCTUnwrap(image.cgImage), top: 20, bottom: 320)
    XCTAssertEqual(bands.map(\.minY), [20, 120, 220])
    XCTAssertEqual(bands.map(\.height), [100, 100, 100])
  }

  func testVisualRowsSeparateAdjacentSameColorUsingThinRules() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 828, height: 500), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 828, height: 500))
      UIColor(white: 245.0 / 255.0, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 220, width: 828, height: 280))
      UIColor(white: 238.0 / 255.0, alpha: 1).setFill()
      for y in [120, 220, 350] {
        context.fill(CGRect(x: 0, y: CGFloat(y), width: 828, height: 2))
      }
    }
    let bands = try StockHistoryProcessor.visualGoodsRows(XCTUnwrap(image.cgImage), top: 20, bottom: 500)
    XCTAssertEqual(bands.map(\.minY), [20, 120, 220, 350])
    XCTAssertEqual(bands.map(\.maxY), [120, 220, 350, 500])
    func cell(_ text: String, _ x: CGFloat, _ y: CGFloat) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.9, box: CGRect(x: x, y: y, width: 100, height: 15))
    }
    let cells = [cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0)] +
      (0..<4).flatMap { index -> [StockOCRCell] in
        let y = bands[index].midY
        return [cell("货物\(index)", 100, y - 20), cell("GS1000\(index)-01", 100, y),
          cell("\(index + 1)盒", 500, y)]
      }
    let rows = try StockTableParser.rows(cells, rowBands: bands)
    XCTAssertEqual(rows.map { $0.cells[1] }, ["1盒", "2盒", "3盒", "4盒"])
    XCTAssertEqual(rows.map(\.sourceTop), [20, 120, 220, 350])
  }

  func testVisualRowsKeepMissingCodeSeparateFromNextGoodsAndInventory() throws {
    func cell(_ text: String, _ x: CGFloat, _ y: CGFloat) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.9, box: CGRect(x: x, y: y, width: 100, height: 15))
    }
    let cells = [cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("缺货号的椰乳1L", 100, 45), cell("0.9盒", 500, 60),
      cell("另一种椰乳250ml", 100, 150), cell("GS10001-02", 100, 175), cell("9盒", 500, 160)]
    let bands = [CGRect(x: 0, y: 30, width: 828, height: 100),
      CGRect(x: 0, y: 130, width: 828, height: 100)]
    let rows = try StockTableParser.rows(cells, rowBands: bands)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { $0.cells[1] }, ["0.9盒", "9盒"])
    XCTAssertFalse(rows[0].cells[0].contains("GS10001-02"))
    XCTAssertEqual(rows.map(\.sourceTop), [30, 130])
    XCTAssertEqual(rows.map(\.sourceBottom), [130, 230])
    XCTAssertThrowsError(try StockTableParser.rows(cells, rowBands: [bands[0]]))
  }

  func testLowResolutionOCRLayoutScalesBothBlocksAndPixels() throws {
    let narrow = try StockHistoryProcessor.ocrLayout(width: 320)
    XCTAssertEqual(narrow.block, 696)
    XCTAssertEqual(narrow.margin, 46)
    XCTAssertEqual(narrow.scale, 3)
    let daily = try StockHistoryProcessor.ocrLayout(width: 473)
    XCTAssertEqual(daily.block, 1028)
    XCTAssertEqual(daily.margin, 69)
    XCTAssertEqual(daily.scale, 2)
    for width in [828, 1280] {
      let layout = try StockHistoryProcessor.ocrLayout(width: width)
      XCTAssertEqual(layout.block, 1800)
      XCTAssertEqual(layout.margin, 120)
      XCTAssertEqual(layout.scale, 1)
    }
    XCTAssertThrowsError(try StockHistoryProcessor.ocrLayout(width: 0))
    XCTAssertThrowsError(try StockHistoryProcessor.ocrLayout(width: -1))
  }

  func testCombinedHeadersSplitByTextWithoutSplittingProductSpecifications() {
    for name in ["货物规格名称", "预制物料名称", "货 物 规 格 名 称"] {
      let text = "\(name)   实 盘 总 库 存"
      XCTAssertEqual(StockTableParser.headerRanges(text).map { String(text[$0]) },
        [name, "实 盘 总 库 存"])
    }
    let product = "饮料 1L*12盒/箱 GS04465-08 2盒"
    XCTAssertEqual(StockTableParser.headerRanges(product).map { String(product[$0]) }, [product])
  }

  func testHeaderConfusionsFromWeeklyFailureLogRequireCompleteFixedTitles() {
    for (reading, expected) in [("货物规恪名称", "货物规格名称"),
      ("实盘总厍存", "实盘总库存"), ("实盘总厍苻", "实盘总库存"),
      ("买盘总厍存", "实盘总库存"), ("实 盘 总 厍 存", "实盘总库存")] {
      XCTAssertEqual(StockTableParser.canonicalHeader(reading), expected, reading)
    }
    for reading in ["实盘库存", "买盘总厍苻", "货物规格描述", "实盘总厍存饮料",
      "厍存", "2A12个", "7TX", "12个", "", "预制物料信息"] {
      XCTAssertNil(StockTableParser.canonicalHeader(reading), reading)
    }
    let combined = "货物规恪名称  实盘总厍苻"
    XCTAssertEqual(StockTableParser.headerRanges(combined).map { String(combined[$0]) },
      ["货物规恪名称", "实盘总厍苻"], "拆分只恢复真实文字范围，不改写 OCR 原文")
  }

  func testWeeklyFailureLogHeadersRecoverWithTwoAlignedReadingsWithoutRaisingConfidence() throws {
    // 320 像素周盘图、2 倍表头复读的失败日志；原图与增强图均出现形近字。
    let rawName = StockOCRCell(text: "货物规格名称", confidence: 1,
      box: CGRect(x: 14.87, y: 198.26, width: 66.25, height: 13.47))
    let rawStock = StockOCRCell(text: "实盘总厍存", confidence: 0.3,
      box: CGRect(x: 168.93, y: 198.65, width: 56.15, height: 12.71))
    let cleanName = StockOCRCell(text: "货物规恪名称", confidence: 0.3,
      box: CGRect(x: 15, y: 198, width: 66, height: 12))
    let cleanStock = StockOCRCell(text: "实盘总厍苻", confidence: 0.3,
      box: CGRect(x: 168.99, y: 197.94, width: 56, height: 13))
    let raw = [rawName, rawStock]
    let clean = [cleanName, cleanStock]
    XCTAssertNil(StockTableParser.goodsHeaders(raw), "一般解析不允许单次读数纠错")
    let verified = try XCTUnwrap(StockTableParser.verifiedGoodsHeaders(raw: raw, clean: clean))
    XCTAssertEqual(verified.name.text, "货物规格名称")
    XCTAssertEqual(verified.stock.text, "实盘总库存")
    XCTAssertEqual(verified.name.confidence, 0.3)
    XCTAssertEqual(verified.stock.confidence, 0.3)
    XCTAssertEqual(verified.name.box, rawName.box)
    XCTAssertEqual(verified.stock.box, rawStock.box)
    XCTAssertNil(StockTableParser.verifiedGoodsHeaders(raw: raw, clean: [cleanName]))
    XCTAssertNil(StockTableParser.verifiedGoodsHeaders(raw: [rawName], clean: clean))
    let shifted = StockOCRCell(text: cleanStock.text, confidence: 1,
      box: CGRect(x: 250, y: 198, width: 56, height: 13))
    XCTAssertNil(StockTableParser.verifiedGoodsHeaders(raw: raw, clean: [cleanName, shifted]))
    let differentRow = StockOCRCell(text: cleanStock.text, confidence: 1,
      box: CGRect(x: 169, y: 900, width: 56, height: 13))
    XCTAssertNil(StockTableParser.verifiedGoodsHeaders(raw: raw, clean: [cleanName, differentRow]))
  }

  func testGoodsHeadersRejectPreparedHeaderAndDifferentRows() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95,
        box: CGRect(x: x, y: y, width: 80, height: 12))
    }
    let name = cell("货物规格名称", 20, 200)
    let stock = cell("实盘总库存", 230, 201)
    let prepared = [cell("预制物料名称", 20, 900), cell("实盘总库存", 230, 900)]
    XCTAssertNil(StockTableParser.goodsHeaders([name] + prepared))
    XCTAssertNil(StockTableParser.goodsHeaders(prepared))
    XCTAssertNil(StockTableParser.goodsHeaders([name, cell("实盘总库存", 230, 250)]))
    XCTAssertNil(StockTableParser.goodsHeaders([name, cell("实盘总库存", 0, 200)]))
    XCTAssertNil(StockTableParser.goodsHeaders([name, cell("实盘库存", 230, 200)]))
    let headers = try XCTUnwrap(StockTableParser.goodsHeaders(prepared + [stock, name]))
    XCTAssertEqual(headers.stock.box, stock.box)
    XCTAssertThrowsError(try StockTableParser.rows([name] + prepared))
  }

  func testProductCodeCanonicalizationDoesNotInventDigits() {
    XCTAssertEqual(StockOCRRefinement.canonicalProductCode("gs09637－02"), "GS09637-02")
    XCTAssertEqual(StockOCRRefinement.canonicalProductCode(" GS09889-03 "), "GS09889-03")
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("GS09637-O2"))
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("GS09889-O3"))
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("活动周边 O202609YL1"))
  }

  func testGoodsStopAtPreparedHeadersEvenWhenSectionInformationIsMissingOrMisread() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    XCTAssertFalse(StockOCRRefinement.isPreparedSectionLabel("预制物料包装"))
    XCTAssertFalse(StockOCRRefinement.isPreparedSectionLabel("预制物料包装箱"))
    XCTAssertFalse(StockOCRRefinement.isPreparedSectionLabel("【青金桔】-预制作"))
    let goods = [cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("预制物料包装", 80, 60), cell("GS00448-02", 80, 85), cell("2捆", 500, 70)]
    let prepared = [cell("预制物料名称", 20, 200), cell("实盘总库存", 440, 200),
      cell("青金桔-预制作", 20, 260), cell("12个", 500, 260), cell("其他信息", 20, 320)]
    for label in ["", "预制物料信息", "预制物料倌息", "预制物料值息", "预制物料值思", "预制物料倍息"] {
      let cells = goods + (label.isEmpty ? [] : [cell(label, 20, 160)]) + prepared
      let rows = try StockTableParser.rows(Array(cells.reversed()))
      XCTAssertEqual(rows.count, 1, label)
      XCTAssertEqual(rows[0].cells, ["预制物料包装\nGS00448-02", "2捆"], label)
      XCTAssertEqual(StockTableParser.goodsBottom(cells, below: 20), label.isEmpty ? 200 : 160)
    }
    let productAtHeaderLeft = goods + [cell("预制物料包装", 20, 130),
      cell("GS00448-03", 80, 155), cell("3捆", 500, 140)] + prepared
    XCTAssertEqual(try StockTableParser.rows(productAtHeaderLeft).count, 2,
      "即使品名靠近预制表头，只要有对应货号，就不能把它当分节标签")
    let incomplete = goods + [cell("缺少尾部货号的另一商品", 80, 120)] + prepared
    XCTAssertThrowsError(try StockTableParser.rows(incomplete), "分区修复不能隐藏最后一条货物缺货号")
    XCTAssertThrowsError(try StockTableParser.rows(goods +
      [cell("另一商品", 80, 120), cell("G500448-03", 80, 145)] + prepared))
  }

  func testCorruptCodeCandidatesOnlyLocatePixelsAndRequireTwoActualReadings() throws {
    func cell(_ text: String, _ y: Double, confidence: Double = 0.3) -> StockOCRCell {
      StockOCRCell(text: text, confidence: confidence, box: CGRect(x: 42, y: y, width: 68, height: 11))
    }
    for (reading, expected) in [("G500448-02", "GS00448-02"), ("G$00587-10", "GS00587-10"),
      ("007126.02", "GS00716-02"), ("200716002", "GS00716-02")] {
      XCTAssertTrue(StockOCRRefinement.isProductCodeCandidate(reading))
      XCTAssertNil(StockOCRRefinement.canonicalProductCode(reading), "候选文本不能直接变造为货号")
      let name = cell("名称1L*12盒/箱", 60, confidence: 1)
      let wrong = cell(reading, 100)
      let neighbor = cell(expected, 160, confidence: 1)
      let cells = [name, wrong, neighbor]
      let raw = [cell(expected, 100, confidence: 0.8)]
      let clean = [cell(expected, 100, confidence: 0.9)]
      let recovered = try StockHistoryProcessor.mergeVerifiedProductCodes(cells, raw: raw, clean: clean)
      XCTAssertEqual(recovered.map(\.text), [name.text, expected, expected])
      XCTAssertEqual(recovered[1].confidence, wrong.confidence)
      XCTAssertEqual(recovered[2].box, neighbor.box, "同货号的邻行不能被删掉或覆盖")
      XCTAssertEqual(try StockHistoryProcessor.mergeVerifiedProductCodes(cells, raw: raw, clean: []).map(\.text),
        cells.map(\.text))
      XCTAssertEqual(try StockHistoryProcessor.mergeVerifiedProductCodes(cells, raw: raw,
        clean: [neighbor]).map(\.text), cells.map(\.text), "不同位置的读数不能充当一致证据")
      let disagreement = [cell("GS99999-99", 100, confidence: 1)]
      XCTAssertEqual(try StockHistoryProcessor.mergeVerifiedProductCodes(cells, raw: raw,
        clean: disagreement).map(\.text), cells.map(\.text))
      if reading.hasPrefix("G") {
        let repeated = [cell(reading, 100, confidence: 0.8)]
        XCTAssertEqual(try StockHistoryProcessor.mergeVerifiedProductCodes(cells, raw: repeated,
          clean: repeated)[1].text, expected, "固定前缀的两读一致校正必须逐位保留数字")
      }
    }
    for reading in ["G500448-O2", "G$OO587-10", "G5-02", "GS00448-O2"] {
      XCTAssertNil(StockOCRRefinement.productCodeReading(reading), "数字不明确时不能猜测")
    }
    let mixed = cell("名称1L*12盒/箱G$00587-10", 100)
    let actual = [cell("GS00587-10", 100, confidence: 1)]
    XCTAssertEqual(try StockHistoryProcessor.mergeVerifiedProductCodes([mixed], raw: actual,
      clean: actual)[0].text, "名称1L*12盒/箱GS00587-10")
  }

  func testPreparedMaterialsPairWrappedNamesAndKeepMissingAndZeroQuantities() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [
      cell("预制物料名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("青金桔-预制作", 20, 50), cell("13", 500, 50), cell("个", 600, 50),
      cell("【冷萃咖啡液】-预制作", 20, 100), cell("1200毫升", 500, 100),
      cell("【香水柠檬-清洗（全国）】预", 20, 150), cell("处理", 20, 175), cell("6个", 500, 160),
      cell("【鲜橙-清洗（全国）】预处理", 20, 210),
      cell("【巧克力预调液-新】-预制作", 20, 260), cell("0克", 500, 260),
      cell("其他信息", 20, 300), cell("修改", 20, 350), cell("2026-10-05", 500, 350),
    ]
    let rows = try StockTableParser.preparedRows(cells)
    XCTAssertEqual(rows.count, 5)
    XCTAssertTrue(rows.allSatisfy { $0.category == "prepared" })
    XCTAssertEqual(rows[0].cells[1], "13个")
    XCTAssertEqual(rows[1].cells[1], "1200毫升")
    XCTAssertEqual(rows[2].cells[0], "【香水柠檬-清洗（全国）】预\n处理")
    XCTAssertEqual(rows[2].cells[1], "6个")
    XCTAssertTrue(rows[3].inventoryUncertain ?? false)
    XCTAssertEqual(rows[4].cells[1], "0克")
    XCTAssertFalse(rows[4].inventoryUncertain ?? true)
    XCTAssertEqual(try StockTableParser.preparedRows(Array(cells.reversed())).map(\.cells), rows.map(\.cells))
    XCTAssertThrowsError(try StockTableParser.preparedRows(cells.filter { $0.text != "实盘总库存" }))
    XCTAssertThrowsError(try StockTableParser.preparedRows(cells.filter { $0.text != "处理" }))
  }

  func testDiagnosticsLogCapturesLatestRecognitionTaskOnly() throws {
    StockDiagnostics.begin("单元测试任务")
    StockDiagnostics.log("第一条诊断")
    let first = try String(contentsOf: try StockDiagnostics.url(), encoding: .utf8)
    XCTAssertTrue(first.contains("单元测试任务"))
    XCTAssertTrue(first.contains("第一条诊断"))
    StockDiagnostics.begin("第二次任务")
    StockDiagnostics.log("第二条诊断")
    let second = try String(contentsOf: try StockDiagnostics.url(), encoding: .utf8)
    XCTAssertFalse(second.contains("第一条诊断"), "开始新任务必须清掉上一次的日志")
    XCTAssertTrue(second.contains("第二次任务"))
    XCTAssertTrue(second.contains("第二条诊断"))
  }

  func testPreparedRowsTolerateGluedQuantitiesAndMisreadFooterTitle() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    // 青金桔数量框为空时水印数字与名称粘连；「处理7」为折行尾字与数量粘连；
    // 页脚标题可能被读成「其它信息」或「其他信鼻沙」等错字，都不能进入名称流。
    for footer in ["其它信息", "其他信鼻沙"] {
      let cells = [
        cell("预制物料名称", 20, 0), cell("实盘总库存", 440, 0),
        cell("青金桔-预制作412", 20, 50), cell("个", 600, 50),
        cell("【鲜橙-清洗（全国）】预处理", 20, 100), cell("5", 490, 100), cell("个", 600, 100),
        cell("【香水柠檬-清洗（全国）】预", 20, 150), cell("处理7", 20, 175), cell("个", 600, 160),
        cell("【冷萃咖啡液】-预制作", 20, 210), cell("3000", 470, 210), cell("毫升", 600, 210),
        cell("【巧克力预调液-新】-预制作", 20, 260), cell("0", 490, 260), cell("克", 600, 260),
        cell(footer, 20, 320), cell("林弘", 20, 380), cell("修改", 20, 385),
        cell("系统", 20, 440), cell("新建", 20, 445), cell("备注：", 20, 500),
      ]
      let rows = try StockTableParser.preparedRows(cells)
      XCTAssertEqual(rows.count, 5, "页脚标题「\(footer)」不能进入名称流")
      XCTAssertEqual(StockOCRRefinement.compact(rows[0].cells[0]), "青金桔-预制作")
      XCTAssertEqual(rows[2].cells[0], "【香水柠檬-清洗（全国）】预\n处理")
      XCTAssertEqual(StockOCRRefinement.compact(rows[4].cells[0]), "【巧克力预调液-新】-预制作")
      XCTAssertTrue(rows[0].inventoryUncertain ?? false, "空数量框不能被水印数字填充")
    }
  }

  func testPreparedQuantityMixedWithWatermarkCharactersStaysUncertain() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    // 水印数字叠在空输入框上时可能被读成「2A12」；这种读数必须保留原文并标记待确认。
    let cells = [cell("预制物料名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("青金桔-预制作", 20, 50), cell("2A12", 442, 50), cell("个", 600, 50),
      cell("【冷萃咖啡液】-预制作", 20, 100), cell("3000", 470, 100), cell("毫升", 600, 100)]
    let rows = try StockTableParser.preparedRows(cells)
    XCTAssertEqual(StockOCRRefinement.compact(rows[0].cells[1]), "2A12个")
    XCTAssertTrue(rows[0].inventoryUncertain ?? false, "水印误读的数量必须标记待确认")
    XCTAssertFalse(rows[1].inventoryUncertain ?? true)
  }

  func testPreparedQuantityUsesHorizontalOrderDespiteBaselineDifferences() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [cell("预制物料名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("青金桔-预制作", 20, 50), cell("个", 600, 47), cell("13", 500, 53),
      cell("【冷萃咖啡液】-预制作", 20, 100), cell("毫升", 600, 97), cell("1200", 500, 103)]
    let rows = try StockTableParser.preparedRows(cells)
    XCTAssertEqual(StockOCRRefinement.compact(rows[0].cells[1]), "13个")
    XCTAssertEqual(StockOCRRefinement.compact(rows[1].cells[1]), "1200毫升")
    let missing = cells.filter { $0.text != "13" }
    let recovered = try StockTableParser.preparedRows(missing) { start, end, _ in
      start < 50 && end < 100 ? [cell("13", 500, 53), cell("个", 600, 47)] : nil
    }
    XCTAssertEqual(StockOCRRefinement.compact(recovered[0].cells[1]), "13个")
    XCTAssertFalse(recovered[0].inventoryUncertain ?? true)
    XCTAssertTrue(try StockTableParser.preparedRows(missing)[0].inventoryUncertain ?? false)
  }

  func testPreparedRetryUsesItsOwnHeaderAndKeepsNumberLeftOfGoodsColumn() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [cell("货物规格名称", 20, 0), cell("实盘总库存", 500, 0),
      cell("预制物料名称", 20, 200), cell("实盘总库存", 440, 200),
      cell("【冷萃咖啡液】-预制作", 20, 260), cell("毫升", 600, 260),
      cell("其他信息", 20, 320)]
    var calls = 0
    let rows = try StockTableParser.preparedRows(cells) { start, end, left in
      calls += 1
      XCTAssertEqual(left, 420)
      XCTAssertLessThan(left, 464, "不能裁掉 2200 在原图 x=464 处的首位数字")
      XCTAssertEqual(start, 220)
      XCTAssertEqual(end, 320)
      return [cell("2", 464, 260), cell("2", 481, 260), cell("0", 498, 260),
        cell("0", 515, 260), cell("毫升", 600, 258)]
    }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(rows[0].cells[1], "2200毫升")
    XCTAssertFalse(rows[0].inventoryUncertain ?? true)
  }

  func testNameRecoveryRestoresMissingSpecificationWithoutBorrowingAnotherProduct() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("铂馨紫苏蜜桃风味饮料浓浆", 80, 50), cell("GS10623-01", 80, 100), cell("5.3瓶", 500, 75)]
    let recovered = [cell("铂馨紫苏蜜桃风味饮料浓浆", 80, 50),
      cell("1L*12瓶/箱", 80, 75), cell("GS10623-01", 80, 100)]
    let rows = try StockTableParser.rows(cells, retryName: { _, _, _ in recovered })
    XCTAssertTrue(rows[0].cells[0].contains("1L*12瓶/箱"))
    XCTAssertEqual(rows[0].cells[1], "5.3瓶")
    let other = [cell("另一款饮料1L", 80, 50), cell("GS10624-01", 80, 100)]
    XCTAssertFalse(try StockTableParser.rows(cells, retryName: { _, _, _ in other })[0].cells[0].contains("另一款"))
  }

  func testGoodsNamesExcludeThumbnailTextAndRecoverTruncatedPackaging() throws {
    func cell(_ text: String, _ x: Double, _ y: Double, _ width: Double = 100) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: width, height: 20))
    }
    let cells = [cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("新雀巢丝绒风味厚奶1L*12盒", 80, 50), cell("GS04465-10", 80, 100), cell("0盒", 500, 75),
      cell("9月上旬202609-16oz热饮杯", 80, 150), cell("ZC 300个/箱", 80, 175),
      cell("翻", 20, 180, 20), cell("GS00412-218", 80, 200), cell("-袋0个", 500, 175),
      cell("9月中旬活动杯套202609 JH", 80, 250), cell("200个*10把/箱", 80, 275),
      cell("幽國", 20, 280, 40), cell("GS00440-540", 80, 300), cell("-把0个", 500, 275)]
    let recovered = [cell("新雀巢丝绒风味厚奶1L*12盒/箱", 80, 50), cell("GS04465-10", 80, 100)]
    var retries = 0
    let rows = try StockTableParser.rows(cells, retryName: { _, _, left in
      XCTAssertEqual(left, 80)
      retries += 1
      return recovered
    })
    XCTAssertEqual(retries, 1)
    XCTAssertTrue(rows[0].cells[0].contains("12盒/箱"))
    XCTAssertFalse(rows[1].cells[0].contains("翻"))
    XCTAssertFalse(rows[2].cells[0].contains("幽國"))
    XCTAssertEqual(rows.map { $0.cells[1] }, ["0盒", "-袋0个", "-把0个"])
    XCTAssertFalse(StockOCRRefinement.incompletePackaging("食品保鲜膜500米*6卷/\n箱\nGS00197-04"))
    XCTAssertTrue(StockOCRRefinement.incompletePackaging("新雀巢丝绒风味厚奶1L*12盒\nGS04465-10"))
    XCTAssertFalse(StockOCRRefinement.incompletePackaging("鑫国扁扁黄油可颂15g*40个\n*6盒\nGS06813-01"))
  }

  func testOverlappingOCRBlocksDoNotCreateAnExtraProductCodeRow() throws {
    func cell(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: width, height: height))
    }
    let cells = [
      cell("货物规格名称", 20, 0, 180, 20), cell("实盘总库存", 500, 0, 180, 20),
      cell("九宇抹茶粉100g*50袋/箱\nGS10665-02", 20, 1770, 380, 60),
      cell("GS10665-02", 20, 1804, 220, 20),
      cell("1.4袋", 500, 1785, 100, 25),
      cell("鑫国经典提拉米苏杯子蛋糕\nGS10667-01", 20, 1900, 380, 60),
      cell("总库存:5个", 500, 1910, 160, 25),
      cell("总库存:5个", 501, 1911, 160, 25),
      cell("冷藏:0个", 500, 1940, 160, 20),
      cell("冷冻:5个", 500, 1965, 160, 20),
      // 下方真实存在的同货号项目必须保留，不能全表按货号删重。
      cell("九宇抹茶粉100g*50袋/箱\nGS10665-02", 20, 2100, 380, 60),
      cell("2袋", 500, 2115, 100, 25)
    ]
    let rows = try StockTableParser.rows(cells)
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows[0].cells[1], "1.4袋")
    XCTAssertTrue(rows[0].cells[0].contains("九宇抹茶粉"))
    XCTAssertFalse(rows[0].inventoryUncertain ?? true)
    XCTAssertEqual(rows[1].cells[1], "总库存:5个\n冷藏:0个\n冷冻:5个")
    XCTAssertEqual(rows.filter { $0.cells[0].contains("GS10665-02") }.count, 2)
    let reversed = try StockTableParser.rows(Array(cells.reversed()))
    XCTAssertEqual(reversed.map(\.cells), rows.map(\.cells))
  }

  func testDefaultNameUsesOrderDateAndStocktakingKind() throws {
    for (code, kind, title) in [
      ("PD2026092510305", "门店-周盘", "2026-09-25 周盘"),
      ("PD2026091811799", "门店-周盘", "2026-09-18 周盘"),
      ("PD2026093011016", "门店-月盘", "2026-09-30 月盘"),
      ("PD2026100209640", "门店-常规盘点", "2026-10-02 日盘")
    ] {
      XCTAssertEqual(try StockDocumentNaming.title(from: ["工单号", code, "盘点类型", kind]), title)
    }
    XCTAssertEqual(try StockDocumentNaming.title(from: ["PD2024022900001", "日盘"]), "2024-02-29 日盘")
    XCTAssertEqual(try StockDocumentNaming.title(from: ["PD2026022900001", "月盘"]), "日期待确认 月盘")
    XCTAssertEqual(try StockDocumentNaming.title(from: ["门店-周盘", "日盘杯 GS00119-04"]), "日期待确认 周盘")
    XCTAssertThrowsError(try StockDocumentNaming.title(from: ["PD2026092510305", "PD2026093011016", "周盘"]))
    XCTAssertThrowsError(try StockDocumentNaming.title(from: ["门店-周盘", "门店-月盘"]))
    let id = UUID().uuidString
    var record = StockHistoryDocument(schemaVersion: 2, id: id, title: "旧盘点单 2026/10/2, 12:00",
      createdAt: ISO8601DateFormatter().string(from: Date()), imageName: "\(id).png",
      lines: [StockTextLine(cells: ["货物 GS00119-04", "1袋"], confidence: 1)], reviewed: false)
    XCTAssertTrue(record.needsAutomaticTitle)
    record.reviewed = true
    XCTAssertFalse(record.needsAutomaticTitle, "已手动保存的名称必须保留")
  }

  func testShortcutOverweightRuleMatchesApp() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("快捷指令要求 iOS 16") }
    let json = #"{"name":"奶油","aliases":[],"type":"portionBox","singleServingGrams":100,"allowMultiple":false}"#
    let category = try JSONDecoder().decode(IntentCategory.self, from: Data(json.utf8))
    for weight in [350.0, 367.5, 367.51, 500.0] {
      XCTAssertEqual(try category.calculate(weight: weight), "奶油：0.9 份")
    }
    XCTAssertThrowsError(try category.calculate(weight: 249.99))
    let multiple = try JSONDecoder().decode(IntentCategory.self,
      from: Data(json.replacingOccurrences(of: "false", with: "true").utf8))
    XCTAssertEqual(try multiple.calculate(weight: 500), "奶油：2.5 份")
  }

  private func pattern() -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 192, height: 900), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 192, height: 900))
      // 非周期纹理模拟不同品名，接缝方向及位移不应依赖重复行。
      var state: UInt64 = 17
      for y in stride(from: 0, to: 900, by: 6) {
        for x in stride(from: 0, to: 192, by: 6) {
          state = state &* 6364136223846793005 &+ 1
          UIColor(white: CGFloat((state >> 32) % 180) / 255, alpha: 1).setFill()
          context.fill(CGRect(x: x, y: y, width: 5, height: 4))
        }
      }
    }.cgImage!
  }

  func testScrollAlignmentInBothDirections() throws {
    let source = pattern()
    let first = source.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 600))!
    let second = source.cropping(to: CGRect(x: 0, y: 120, width: 192, height: 600))!
    let a = try StockGrayFrame(first)
    let b = try StockGrayFrame(second)
    XCTAssertEqual(try a.displacement(to: a), 0)
    XCTAssertEqual(try a.displacement(to: b), 120)
    XCTAssertEqual(try b.displacement(to: a), -120)
    XCTAssertLessThan(a.error(with: b, shift: 120), a.error(with: b, shift: 117))
    XCTAssertLessThan(a.error(with: b, shift: 120), a.error(with: b, shift: 123))
    for offset in [119, 121, 137] {
      let shifted = try StockGrayFrame(source.cropping(to:
        CGRect(x: 0, y: offset, width: 192, height: 600))!)
      XCTAssertEqual(try a.displacement(to: shifted), offset)
      XCTAssertEqual(try shifted.displacement(to: a), -offset)
    }
  }

  func testBacktrackingDoesNotDuplicateDocumentRows() throws {
    var coverage = StockScrollCoverage()
    XCTAssertEqual(try coverage.advance(by: 120), 120)
    XCTAssertEqual(try coverage.advance(by: -80), 0)
    XCTAssertEqual(try coverage.advance(by: 50), 0)
    XCTAssertEqual(try coverage.advance(by: 60), 30)
    XCTAssertEqual(try coverage.advance(by: 0), 0)
    XCTAssertEqual(coverage.furthest, 150)
    XCTAssertThrowsError(try coverage.advance(by: -160))
  }

  func testScreenshotTimestampOrderingAndOverlappingStitch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    let source = pattern()
    let firstURL = directory.appendingPathComponent("first.png")
    let lastURL = directory.appendingPathComponent("last.png")
    let first = UIImage(cgImage: source.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 450))!)
    let last = UIImage(cgImage: source.cropping(to: CGRect(x: 0, y: 380, width: 192, height: 450))!)
    try XCTUnwrap(first.pngData()).write(to: firstURL)
    try XCTUnwrap(last.pngData()).write(to: lastURL)
    let earlier = StockScreenshotInput(url: firstURL, capturedAt: Date(timeIntervalSince1970: 10))
    let later = StockScreenshotInput(url: lastURL, capturedAt: Date(timeIntervalSince1970: 20))
    XCTAssertEqual(try StockScreenshotInput.ordered([later, earlier]).map(\.url), [firstURL, lastURL])
    // 选择顺序相反，且滚动超过视频匹配的 55% 范围，仍应按时间正确拼接。
    let stitched = try StockHistoryProcessor.stitchScreenshots([later, earlier], crop: StockCrop(top: 0, bottom: 0))
    XCTAssertEqual(stitched.size, CGSize(width: 192, height: 830))
    let expected = try StockGrayFrame(source.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 830))!)
    XCTAssertLessThan(try StockGrayFrame(XCTUnwrap(stitched.cgImage)).error(with: expected, shift: 0), 3)
    XCTAssertThrowsError(try StockScreenshotInput.ordered([earlier]))
    XCTAssertThrowsError(try StockScreenshotInput.ordered([earlier, earlier]))
    XCTAssertThrowsError(try StockScreenshotInput.ordered([
      earlier, StockScreenshotInput(url: lastURL, capturedAt: earlier.capturedAt)]))
    XCTAssertThrowsError(try StockHistoryProcessor.stitchScreenshots([
      StockScreenshotInput(url: lastURL, capturedAt: earlier.capturedAt),
      StockScreenshotInput(url: firstURL, capturedAt: later.capturedAt)
    ], crop: StockCrop(top: 0, bottom: 0)))
  }

  func testOCRContrastSuppressesFaintWatermarkAndPreservesDarkInk() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let source = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 120), format: format).image { context in
      UIColor(white: 230.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 192, height: 120))
      UIColor(white: 60.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 40, y: 40, width: 80, height: 40))
    }.cgImage!
    let output = try StockHistoryProcessor.textImage(source)
    XCTAssertEqual(output.width, source.width)
    XCTAssertEqual(output.height, source.height)
    XCTAssertEqual(output.bitsPerPixel, 8)
    let data = output.dataProvider!.data!
    let pixels = CFDataGetBytePtr(data)!
    let values = (0..<CFDataGetLength(data)).map { pixels[$0] }
    XCTAssertTrue(values.contains(255))
    XCTAssertTrue(values.contains(where: { $0 < 100 }))
    XCTAssertFalse(values.contains(where: { (210...254).contains($0) }))
  }

  func testPreparedContrastPreservesLightGrayDigitsThatGoodsFilterErases() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { context in
      UIColor(white: 245.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
      UIColor(white: 215.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
    }.cgImage!
    let goods = try StockHistoryProcessor.textImage(image)
    let prepared = try StockHistoryProcessor.textImage(image, preserveFaintText: true)
    let goodsData = try XCTUnwrap(goods.dataProvider?.data)
    let preparedData = try XCTUnwrap(prepared.dataProvider?.data)
    let goodsPixels = try XCTUnwrap(CFDataGetBytePtr(goodsData))
    let preparedPixels = try XCTUnwrap(CFDataGetBytePtr(preparedData))
    XCTAssertEqual(goodsPixels[20 * goods.bytesPerRow + 20], 255)
    XCTAssertLessThan(preparedPixels[20 * prepared.bytesPerRow + 20], 220)
    XCTAssertEqual(preparedPixels[0], 255)
  }

  func testTablePairsMultilineNamesAndQuantitiesByProductCode() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [
      cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("两用不锈钢量勺（大）JZ", 80, 50), cell("GS00099-01", 80, 80), cell("3个", 500, 65),
      cell("奶油 0.5L", 80, 120), cell("GS00147-01", 80, 150),
      cell("总库存：7个", 500, 120), cell("冷藏：2个", 500, 145), cell("冷冻：5个", 500, 170),
      cell("奶油 0.5L", 80, 210), cell("GS00147-01", 80, 240), cell("0个", 500, 225),
      cell("预制物料信息", 20, 280), cell("不应进入货物表", 80, 320),
    ]
    let rows = try StockTableParser.rows(cells)
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows[0].cells, ["两用不锈钢量勺（大）JZ\nGS00099-01", "3个"])
    XCTAssertEqual(rows[1].cells[1], "总库存：7个\n冷藏：2个\n冷冻：5个")
    XCTAssertEqual(rows[2].cells[1], "0个")
    XCTAssertTrue(rows.allSatisfy { $0.cells.count == 2 })
    let missing = try StockTableParser.rows(cells.filter { $0.text != "3个" })
    XCTAssertEqual(missing[0].cells[1], "")
    XCTAssertEqual(missing[0].inventoryUncertain, true)
    XCTAssertThrowsError(try StockTableParser.rows(cells.filter { $0.text != "实盘总库存" }))
  }

  func testInventoryCanExtendAboveNameAndStartLeftOfHeader() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [
      cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("上一项", 80, 50), cell("GS00395-09", 80, 80), cell("3盒", 500, 65),
      cell("新塞尚黄油丝绒风味奶", 80, 145), cell("GS06628-06", 80, 175),
      cell("总库存：12.1盒", 420, 120), cell("冷藏：12.1盒", 420, 150), cell("冷冻：0盒", 420, 180),
      cell("下一项", 80, 240), cell("GS05532-05", 80, 270), cell("5.7盒", 500, 255),
      cell("预制物料信息", 20, 310),
    ]
    let rows = try StockTableParser.rows(cells)
    XCTAssertEqual(rows[0].cells[1], "3盒")
    XCTAssertEqual(rows[1].cells[1], "总库存：12.1盒\n冷藏：12.1盒\n冷冻：0盒")
    XCTAssertEqual(rows[2].cells[1], "5.7盒")
    let missing = try StockTableParser.rows(cells.filter { !$0.text.contains("12.1") && $0.text != "冷冻：0盒" })
    XCTAssertEqual(missing[1].inventoryUncertain, true)
  }

  func testRecognitionRevisionAutomaticallyUpgradesOnlyUnreviewedHistory() throws {
    let id = UUID().uuidString
    let legacy = StockHistoryDocument(schemaVersion: 2, id: id,
      title: "历史单据", createdAt: "2026-10-01T02:30:00Z", imageName: "\(id).png",
      lines: [StockTextLine(cells: ["奶油", "13包"], confidence: 0.5)], reviewed: false)
    XCTAssertTrue(legacy.needsRecognition)
    var current = legacy
    current.recognitionRevision = StockHistoryProcessor.recognitionRevision
    XCTAssertFalse(current.needsRecognition)
    var reviewed = legacy
    reviewed.reviewed = true
    XCTAssertFalse(reviewed.needsRecognition)
    let roundTrip = try JSONDecoder().decode(StockHistoryDocument.self, from: JSONEncoder().encode(current))
    XCTAssertFalse(roundTrip.needsRecognition)
  }

  func testRefinementRequiresAgreementAndUsesMeasuredConfidence() {
    let box = CGRect(x: 100, y: 100, width: 180, height: 24)
    let original = StockOCRCell(text: "GS007I2-01", confidence: 0.4, box: box)
    let raw = StockOCRCell(text: "GS00712-01", confidence: 0.94, box: box)
    let clean = StockOCRCell(text: "GS00712-01", confidence: 0.87, box: box)
    let corrected = StockOCRRefinement.resolve(original, raw: raw, clean: clean, inventory: false)
    XCTAssertEqual(corrected.text, "GS00712-01")
    XCTAssertEqual(corrected.confidence, 0.87)
    XCTAssertEqual(corrected.box, box)
    let disagreement = StockOCRCell(text: "GS00713-01", confidence: 0.99, box: box)
    XCTAssertEqual(StockOCRRefinement.resolve(original, raw: raw, clean: disagreement, inventory: false).text, original.text)
    XCTAssertEqual(StockOCRRefinement.resolve(original, raw: nil, clean: clean, inventory: false).confidence, 0.4)
    let smallGain = StockOCRCell(text: "GS00712-01", confidence: 0.42, box: box)
    XCTAssertEqual(StockOCRRefinement.resolve(original, raw: raw, clean: smallGain, inventory: false).text, original.text)
  }

  func testGenericRefinementKeepsVerifiedCodeCanonical() {
    let box = CGRect(x: 40, y: 100, width: 70, height: 14)
    let raw = StockOCRCell(text: "G508050-01", confidence: 0.9, box: box)
    let clean = StockOCRCell(text: "G508050-01", confidence: 0.8, box: box)
    for text in ["GS0805001", "G508050-01", "G$08050-01"] {
      // 通用复核首次发现完整编码，或复读一个未确认的编码时，都不能留下错误前缀。
      let original = StockOCRCell(text: text, confidence: 0.3, box: box)
      let corrected = StockOCRRefinement.resolve(original, raw: raw, clean: clean, inventory: false)
      XCTAssertEqual(corrected.text, "GS08050-01")
      XCTAssertEqual(corrected.confidence, 0.8)
      XCTAssertEqual(corrected.box, box)
      let disagreement = StockOCRCell(text: "G508050-02", confidence: 0.99, box: box)
      XCTAssertEqual(StockOCRRefinement.resolve(original, raw: raw, clean: disagreement,
        inventory: false).text, original.text)
      let ambiguous = StockOCRCell(text: "G508O50-01", confidence: 0.99, box: box)
      if StockOCRRefinement.isProductCodeCandidate(text) {
        XCTAssertEqual(StockOCRRefinement.resolve(original, raw: ambiguous, clean: ambiguous,
          inventory: false).text, original.text, "不能把数字里的 O 替换为 0")
      }
    }
    for text in ["名称1L*12盒/箱GS08050-01", "名称1L*12盒/箱G508050-01"] {
      let original = StockOCRCell(text: text, confidence: 0.3, box: box)
      XCTAssertEqual(StockOCRRefinement.resolve(original, raw: raw, clean: clean,
        inventory: false).text, text, "名称和编码粘连时必须保留完整规格")
    }
  }

  func testRefinementCannotBorrowAnotherRowOrReplaceInventoryWithNonNumericText() {
    let box = CGRect(x: 500, y: 100, width: 100, height: 24)
    let original = StockOCRCell(text: "13包", confidence: 0.4, box: box)
    let nextRow = StockOCRCell(text: "18包", confidence: 0.99,
      box: CGRect(x: 500, y: 240, width: 100, height: 24))
    let fragment = StockOCRCell(text: "3包", confidence: 0.99,
      box: CGRect(x: 570, y: 100, width: 30, height: 24))
    XCTAssertNil(StockOCRRefinement.match(original, in: [nextRow, fragment]))
    let clear = StockOCRCell(text: "13包", confidence: 0.9, box: box)
    XCTAssertEqual(StockOCRRefinement.match(original, in: [nextRow, clear])?.text, "13包")
    let invalid = StockOCRCell(text: "弘", confidence: 0.99, box: box)
    XCTAssertEqual(StockOCRRefinement.resolve(original, raw: invalid, clean: invalid, inventory: true).text, "13包")
  }

  func testMissingLastInventoryIsRetriedInsideGoodsSectionOnly() throws {
    func cell(_ text: String, _ x: Double, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: x, y: y, width: 100, height: 20))
    }
    let cells = [
      cell("货物规格名称", 20, 0), cell("实盘总库存", 440, 0),
      cell("竹浆擦手纸", 80, 50), cell("GS00657-07", 80, 80), cell("4包", 500, 65),
      cell("原色竹浆餐巾纸 QR100张*60包/箱", 80, 145), cell("GS00659-02", 80, 175),
      cell("－箱丨Ｂ包", 500, 150),
      cell("预制物料信息", 20, 220), cell("预制物料名称", 20, 260),
      cell("实盘总库存", 440, 260), cell("2200毫升", 500, 310),
    ]
    var calls = 0
    let rows = try StockTableParser.rows(cells) { start, end in
      calls += 1
      XCTAssertEqual(start, 122.5)
      XCTAssertEqual(end, 220)
      return [cell("－箱13包", 500, 150)]
    }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].cells[1], "4包")
    XCTAssertEqual(rows[1].cells[1], "－箱13包")
    XCTAssertEqual(try StockTableParser.rows(cells).last?.inventoryUncertain, true)
    XCTAssertEqual(try StockTableParser.rows(cells) { _, _ in [cell("2200毫升", 500, 310)] }.last?.inventoryUncertain, true)
  }

  func testMergedNameAndInventorySplitUsesGeometryRatherThanSpecificationDigits() {
    let text = "型含乳饮料）1L*12盒/箱 12.1盒"
    let quantityStart = text.range(of: "12.1盒")!.lowerBound
    var characters: [(Range<String.Index>, CGRect)] = []
    var left = 110.0
    var right = 508.0
    for index in text.indices where !text[index].isWhitespace {
      let x = index < quantityStart ? left : right
      characters.append((index..<text.index(after: index), CGRect(x: x, y: 0, width: 18, height: 26)))
      if index < quantityStart { left += 20 } else { right += 20 }
    }
    let parts = StockTableParser.splitColumnGap(text, characters: characters, stockColumnStart: 440)
      .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
    XCTAssertEqual(parts, ["型含乳饮料）1L*12盒/箱", "12.1盒"])
    let uninterrupted = characters.enumerated().map { index, item in
      (item.0, CGRect(x: 110 + index * 20, y: 0, width: 18, height: 26))
    }
    XCTAssertEqual(StockTableParser.splitColumnGap(text, characters: uninterrupted, stockColumnStart: 440).count, 1)
  }

  func testDeleteRemovesOnlySelectedDocumentAndItsOriginalImage() throws {
    let image = UIImage(cgImage: pattern())
    let lines = [StockTextLine(cells: ["奶油", "12.1盒"], confidence: 1)]
    let first = try StockHistoryStorage.create(image: image, lines: lines)
    let second = try StockHistoryStorage.create(image: image, lines: lines)
    addTeardownBlock {
      for record in [first, second] {
        let location = try StockHistoryStorage.directory(record.id)
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
      }
    }
    let backup = try StockHistoryStorage.directory(first.id).appendingPathComponent("legacy-recognized-lines.json")
    try Data("{}".utf8).write(to: backup)
    try StockHistoryStorage.delete(first.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try StockHistoryStorage.directory(first.id).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    XCTAssertFalse(try StockHistoryStorage.image(second.id).isEmpty)
    XCTAssertThrowsError(try StockHistoryStorage.delete(first.id))
    XCTAssertThrowsError(try StockHistoryStorage.delete("../" + second.id))
  }

  func testLongImagePreviewTilesPreserveAllPixelsAndAspectRatio() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 4000), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 192, height: 4000))
    }
    let record = try StockHistoryStorage.create(image: image,
      lines: [StockTextLine(cells: ["奶油", "12.1盒"], confidence: 1)])
    addTeardownBlock { try StockHistoryStorage.delete(record.id) }
    let tiles = try StockHistoryStorage.imageTiles(record.id)
    let images = try tiles.map { data -> CGImage in
      guard let image = UIImage(data: data)?.cgImage else {
        throw StockHistoryError.invalid("测试预览无法解码")
      }
      return image
    }
    XCTAssertEqual(images.map(\.height), [1800, 1800, 400])
    XCTAssertTrue(images.allSatisfy { $0.width == 192 })
  }

  func testBlankAndUnmatchedImagesAreNotAccepted() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let blank = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 600), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 192, height: 600))
    }.cgImage!
    let gray = try StockGrayFrame(blank)
    XCTAssertThrowsError(try gray.displacement(to: gray))
    let other = try StockGrayFrame(pattern().cropping(to: CGRect(x: 0, y: 0, width: 192, height: 600))!)
    XCTAssertThrowsError(try other.displacement(to: gray))
  }

  func testCropAndFlutterTimestampRoundTrip() throws {
    XCTAssertThrowsError(try StockCrop(top: .nan, bottom: 0.1).validate())
    XCTAssertThrowsError(try StockCrop(top: 0.5, bottom: 0.1).validate())
    let crop = try StockCrop(top: 0.2, bottom: 0.1).apply(pattern())
    XCTAssertEqual(crop.height, 630)
    let original = StockHistoryDocument.date("2026-10-01T02:30:00Z")
    XCTAssertNotNil(original)
    XCTAssertEqual(original, StockHistoryDocument.date("2026-10-01T02:30:00.000Z"))
    XCTAssertNil(StockHistoryDocument.date("not-a-date"))
  }

  private func documentIDs() throws -> [String] {
    let json = try StockHistoryStorage.list()
    return try JSONDecoder().decode([StockHistoryDocument].self, from: Data(json.utf8)).map(\.id)
  }

  func testReorderPersistsUserOrderAndKeepsNewDocumentsFirst() throws {
    let orderFile = try StockHistoryStorage.root()
      .appendingPathComponent(StockHistoryStorage.orderFileName)
    // 排序文件是全局状态，测试前后都清理，避免影响其他用例。
    if FileManager.default.fileExists(atPath: orderFile.path) {
      try FileManager.default.removeItem(at: orderFile)
    }
    addTeardownBlock {
      if FileManager.default.fileExists(atPath: orderFile.path) {
        try FileManager.default.removeItem(at: orderFile)
      }
    }
    let image = UIImage(cgImage: pattern())
    let lines = [StockTextLine(cells: ["奶油", "12.1盒"], confidence: 1)]
    let first = try StockHistoryStorage.create(image: image, lines: lines)
    let second = try StockHistoryStorage.create(image: image, lines: lines)
    let third = try StockHistoryStorage.create(image: image, lines: lines)
    addTeardownBlock {
      for record in [first, second, third] {
        let location = try StockHistoryStorage.directory(record.id)
        if FileManager.default.fileExists(atPath: location.path) {
          try FileManager.default.removeItem(at: location)
        }
      }
    }
    let others = try documentIDs().filter { ![first.id, second.id, third.id].contains($0) }
    try StockHistoryStorage.reorder([third.id, second.id, first.id] + others)
    XCTAssertEqual(Array(try documentIDs().prefix(3)), [third.id, second.id, first.id])
    // 排序后新增的记录（不在顺序文件里）置顶，不打断用户已排好的顺序。
    let fourth = try StockHistoryStorage.create(image: image, lines: lines)
    addTeardownBlock { try StockHistoryStorage.delete(fourth.id) }
    XCTAssertEqual(try documentIDs().first, fourth.id)
    XCTAssertEqual(Array(try documentIDs().dropFirst().prefix(3)), [third.id, second.id, first.id])
    // 非法排序必须被拒绝：缺项、重复、空、未知标识。
    XCTAssertThrowsError(try StockHistoryStorage.reorder([first.id, second.id]))
    XCTAssertThrowsError(try StockHistoryStorage.reorder([first.id, first.id, third.id] + others))
    XCTAssertThrowsError(try StockHistoryStorage.reorder([]))
    XCTAssertThrowsError(try StockHistoryStorage.reorder([UUID().uuidString]))
  }

}

/// 真实原始 PNG 的独立识别验收；不进入日常编译的确定性规则测试。
class VisionAcceptanceTests: XCTestCase {
  func testBlankImageCannotInventGoodsHeaders() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 800), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 800))
    }
    let original = try XCTUnwrap(image.cgImage)
    XCTAssertNil(try StockHistoryProcessor.recoverGoodsHeaders(original, clean: original))
    XCTAssertThrowsError(try StockHistoryProcessor.recognize(image))
    let different = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 800)))
    XCTAssertThrowsError(try StockHistoryProcessor.recoverGoodsHeaders(original, clean: different))
  }

  func testPreparedUnitRecoveryReadsCurrentRowAndDeepInkExcludesWatermark() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "inventory_weekly_20260925_prepared",
      withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    let clean = try StockHistoryProcessor.textImage(image)
    func unit(_ text: String, _ y: Double) -> StockOCRCell {
      StockOCRCell(text: text, confidence: 0.95, box: CGRect(x: 563, y: y, width: 30, height: 28))
    }
    let anchors = [unit("个", 971), unit("个", 1054), unit("毫升", 1237), unit("克", 1318)]
    let lemonUnit = try XCTUnwrap(StockHistoryProcessor.recoverPreparedUnit(image, clean: clean,
      cells: anchors, start: 1115, end: 1200, quantityLeft: 440))
    XCTAssertEqual(StockOCRRefinement.compact(lemonUnit.text), "个")
    XCTAssertGreaterThanOrEqual(lemonUnit.box.midY, 1115)
    XCTAssertLessThan(lemonUnit.box.midY, 1200)
    XCTAssertNil(try StockHistoryProcessor.recoverPreparedUnit(image, clean: clean,
      cells: [anchors[0]], start: 1115, end: 1200, quantityLeft: 440),
      "只有一个列锚点时不能借用邻行单位")
    let quantity = try XCTUnwrap(StockHistoryProcessor.compactPreparedQuantity(image,
      numberCrop: CGRect(x: 440, y: 957, width: 115, height: 50), unit: anchors[0], inkThreshold: 210))
    XCTAssertEqual(StockOCRRefinement.compact(quantity.text), "12")
    XCTAssertGreaterThan(quantity.box.minX, 480, "水印字符不能参与数字像素边界")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let faintWatermark = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 50), format: format).image {
      context in
      UIColor(white: 245.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 50))
      UIColor(white: 214.0 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 20, y: 10, width: 30, height: 25))
    }
    let blankUnit = StockOCRCell(text: "个", confidence: 0.95,
      box: CGRect(x: 120, y: 10, width: 25, height: 25))
    XCTAssertNil(try StockHistoryProcessor.compactPreparedQuantity(XCTUnwrap(faintWatermark.cgImage),
      numberCrop: CGRect(x: 0, y: 0, width: 110, height: 50), unit: blankUnit, inkThreshold: 210),
      "仅有浅色水印的空框不能生成数量")
  }

  func testDefaultNameRecognizesRealWeeklyMonthlyAndDailyScreenshots() throws {
    for (resource, expected) in [
      ("metadata_week", "2026-09-18 周盘"),
      ("metadata_month", "2026-09-30 月盘"),
      ("metadata_daily", "2026-10-02 日盘")
    ] {
      let url = try XCTUnwrap(Bundle(for: Self.self).url(
        forResource: resource, withExtension: "png", subdirectory: "Fixtures"))
      let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
      XCTAssertEqual(try StockHistoryProcessor.documentTitle(image), expected)
    }
  }

  func testRealScreenshotGroupIgnoresPinnedHeadersAndRetainsShortOverlaps() throws {
    let cases = [
      ("screenshot_first", "screenshot_second", 1233),
      ("screenshot_sparse_first", "screenshot_sparse_second", 1240),
      ("screenshot_short_first", "screenshot_short_second", 1315),
      ("screenshot_footer_first", "screenshot_footer_second", 1265)
    ]
    for (firstName, secondName, expectedShift) in cases {
      let firstURL = try XCTUnwrap(Bundle(for: Self.self).url(
        forResource: firstName, withExtension: "PNG", subdirectory: "Fixtures"))
      let secondURL = try XCTUnwrap(Bundle(for: Self.self).url(
        forResource: secondName, withExtension: "PNG", subdirectory: "Fixtures"))
      let first = try StockCrop.screenshots.apply(XCTUnwrap(UIImage(contentsOfFile: firstURL.path)?.cgImage))
      let second = try StockCrop.screenshots.apply(XCTUnwrap(UIImage(contentsOfFile: secondURL.path)?.cgImage))
      let firstTop = try StockHistoryProcessor.screenshotBodyTop(first)
      let secondTop = try StockHistoryProcessor.screenshotBodyTop(second)
      XCTAssertLessThan(secondTop, 220, "应定位货物表头，不能被下方预制物料的表头干扰")
      if firstName == "screenshot_first" {
        XCTAssertGreaterThan(firstTop, 500)
        XCTAssertLessThan(secondTop, 220)
        let oldFirst = try StockGrayFrame(StockCrop.automatic.apply(
          XCTUnwrap(UIImage(contentsOfFile: firstURL.path)?.cgImage)))
        let oldSecond = try StockGrayFrame(StockCrop.automatic.apply(
          XCTUnwrap(UIImage(contentsOfFile: secondURL.path)?.cgImage)))
        XCTAssertThrowsError(try oldFirst.displacement(to: oldSecond, maximumShiftRatio: 0.90))
      }
      let a = try StockGrayFrame(first, contentTop: firstTop)
      let b = try StockGrayFrame(second, contentTop: secondTop)
      XCTAssertEqual(try a.displacement(to: b, maximumShiftRatio: 0.90), expectedShift)
      let stitched = try StockHistoryProcessor.stitchScreenshots([
        StockScreenshotInput(url: secondURL, capturedAt: Date(timeIntervalSince1970: 20)),
        StockScreenshotInput(url: firstURL, capturedAt: Date(timeIntervalSince1970: 10))
      ])
      XCTAssertEqual(stitched.size, CGSize(width: first.width, height: first.height + expectedShift))
      if firstName == "screenshot_first" {
        let rows = try StockHistoryProcessor.recognize(stitched)
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(rows.filter { $0.cells[0].contains("GS00804-01") }.count, 1)
      }
    }
  }

  func testPartialInventoryDoesNotRequireEveryProductToHaveQuantity() throws {
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(
      forResource: "partial_inventory", withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
    let rows = try StockHistoryProcessor.recognize(image)
    XCTAssertEqual(rows.count, 3)
    XCTAssertTrue(rows[0].cells[1].contains("14"))
    XCTAssertNil(rows[1].cells[1].range(of: "[0-9]", options: .regularExpression))
    XCTAssertNil(rows[2].cells[1].range(of: "[0-9]", options: .regularExpression))
    let id = UUID().uuidString
    let record = StockHistoryDocument(schemaVersion: 2, id: id, title: "部分盘点",
      createdAt: "2026-10-02T08:49:00Z", imageName: "\(id).png", lines: rows, reviewed: false)
    XCTAssertNoThrow(try record.validate())
    XCTAssertTrue(StockTableParser.blankInventory("-袋-根"))
    XCTAssertFalse(StockTableParser.blankInventory("0袋"))
  }

  func testVisionRecognizesInventoryFromProvidedRecording() throws {
    // 从用户录屏的原比例长图截取表头、126～128项及176～177项，保留原水印。
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(
      forResource: "recording_inventory_rows", withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
    let rows = try StockHistoryProcessor.recognize(image)
    XCTAssertEqual(rows.count, 5)
    let milk = try XCTUnwrap(rows.first { $0.cells[0].contains("GS06628-06") })
    XCTAssertTrue(milk.cells[1].contains("12.1"))
    XCTAssertFalse(milk.cells[0].contains("12.1"))
    let straw = try XCTUnwrap(rows.first { $0.cells[0].contains("GS01429-09") })
    XCTAssertTrue(straw.cells[1].contains("400"))
    XCTAssertTrue(straw.cells[1].contains("2"))
  }

  func testVisionRecognizesLastGoodsBeforePreparedMaterials() throws {
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(
      forResource: "recording_inventory_footer", withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
    let rows = try StockHistoryProcessor.recognize(image)
    let goods = rows.filter { $0.category != "prepared" }
    let prepared = rows.filter { $0.category == "prepared" }
    XCTAssertEqual(goods.count, 2)
    XCTAssertEqual(prepared.count, 4)
    let coldBrew = try XCTUnwrap(prepared.first { $0.cells[0].contains("冷萃") },
      "预制名称识别结果：\(prepared.map { $0.cells[0] })")
    let citrus = try XCTUnwrap(prepared.first { $0.cells[0].contains("青金桔") },
      "预制名称识别结果：\(prepared.map { $0.cells[0] })")
    XCTAssertEqual(StockOCRRefinement.compact(coldBrew.cells[1]), "2200毫升",
      "冷萃实际识别：\(coldBrew.cells[1])，待确认：\(coldBrew.inventoryUncertain ?? false)")
    XCTAssertEqual(StockOCRRefinement.compact(citrus.cells[1]), "0个",
      "青金桔实际识别：\(citrus.cells[1])，待确认：\(citrus.inventoryUncertain ?? false)")
    let tissue = try XCTUnwrap(goods.last)
    XCTAssertTrue(tissue.cells[0].contains("GS00659-02"))
    XCTAssertTrue(tissue.cells[1].contains("13"))
    XCTAssertFalse(tissue.cells[1].contains("2200"))
    let cg = try XCTUnwrap(image.cgImage)
    let enlarged = try StockHistoryProcessor.inventoryRow(cg,
      crop: CGRect(x: 487, y: 205, width: cg.width - 487, height: 145), scale: 2)
    XCTAssertTrue(enlarged.contains { $0.text.contains("13") })
    XCTAssertTrue(enlarged.allSatisfy { $0.box.midY >= 205 && $0.box.midY < 350 })
  }
}
