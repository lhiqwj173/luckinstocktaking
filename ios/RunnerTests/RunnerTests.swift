import Flutter
import CoreFoundation
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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
    XCTAssertThrowsError(try StockTableParser.rows(cells.filter { $0.text != "3个" }))
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
    XCTAssertThrowsError(try StockTableParser.rows(cells.filter { !$0.text.contains("12.1") && $0.text != "冷冻：0盒" }))
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
    XCTAssertThrowsError(try StockTableParser.rows(cells))
    XCTAssertThrowsError(try StockTableParser.rows(cells) { _, _ in [cell("2200毫升", 500, 310)] })
  }

  func testVisionRecognizesLastGoodsBeforePreparedMaterials() throws {
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(
      forResource: "recording_inventory_footer", withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
    let rows = try StockHistoryProcessor.recognize(image)
    XCTAssertEqual(rows.count, 2)
    let tissue = try XCTUnwrap(rows.last)
    XCTAssertTrue(tissue.cells[0].contains("GS00659-02"))
    XCTAssertTrue(tissue.cells[1].contains("13"))
    XCTAssertFalse(tissue.cells[1].contains("2200"))
    let cg = try XCTUnwrap(image.cgImage)
    let enlarged = try StockHistoryProcessor.inventoryRow(cg,
      crop: CGRect(x: 487, y: 205, width: cg.width - 487, height: 145), scale: 2)
    XCTAssertTrue(enlarged.contains { $0.text.contains("13") })
    XCTAssertTrue(enlarged.allSatisfy { $0.box.midY >= 205 && $0.box.midY < 350 })
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

}
