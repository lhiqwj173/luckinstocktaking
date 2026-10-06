import Flutter
import CoreFoundation
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testProductCodeCanonicalizationDoesNotInventDigits() {
    XCTAssertEqual(StockOCRRefinement.canonicalProductCode("gs09637－02"), "GS09637-02")
    XCTAssertEqual(StockOCRRefinement.canonicalProductCode(" GS09889-03 "), "GS09889-03")
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("GS09637-O2"))
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("GS09889-O3"))
    XCTAssertNil(StockOCRRefinement.canonicalProductCode("活动周边 O202609YL1"))
  }

  func testRealDailyInventoryIncludesAllGoodsAndFivePreparedMaterials() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(
      forResource: "inventory_daily_20261005", withExtension: "jpg", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
    let rows = try StockHistoryProcessor.recognize(image)
    let goods = rows.filter { $0.category != "prepared" }
    let prepared = rows.filter { $0.category == "prepared" }
    XCTAssertEqual(goods.count, 116)
    let codesURL = try XCTUnwrap(Bundle(for: Self.self).url(
      forResource: "inventory_daily_20261005_codes", withExtension: "json", subdirectory: "Fixtures"))
    let expectedCodes = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: codesURL)))
    let expression = try NSRegularExpression(pattern: "GS[0-9]{5}-[0-9]{2}")
    let actualCodes = Set(goods.flatMap { row in
      let text = StockOCRRefinement.compact(row.cells[0])
      return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        (text as NSString).substring(with: $0.range)
      }
    })
    XCTAssertEqual(actualCodes, expectedCodes,
      "缺失货号：\(expectedCodes.subtracting(actualCodes).sorted())；额外货号：\(actualCodes.subtracting(expectedCodes).sorted())；含糊货号原文：\(goods.filter { row in expression.firstMatch(in: row.cells[0], range: NSRange(row.cells[0].startIndex..., in: row.cells[0])) == nil }.map { $0.cells[0] })")
    XCTAssertEqual(prepared.count, 5)
    let expected = [("青金桔", "13个"), ("冷萃咖啡液", "1200毫升"),
      ("鲜橙", "3个"), ("香水柠檬", "6个"), ("巧克力", "0克")]
    for (name, quantity) in expected {
      let row = try XCTUnwrap(prepared.first { $0.cells[0].contains(name) })
      XCTAssertEqual(StockOCRRefinement.compact(row.cells[1]), quantity)
      XCTAssertFalse(row.inventoryUncertain ?? true)
    }
    let concentrate = try XCTUnwrap(goods.first { $0.cells[0].contains("GS10623-01") })
    XCTAssertTrue(StockOCRRefinement.compact(concentrate.cells[0]).contains("1L*12瓶/箱"))
    XCTAssertEqual(StockOCRRefinement.compact(concentrate.cells[1]), "5.3瓶")
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
    XCTAssertEqual(try StockTableParser.rows(cells).last?.inventoryUncertain, true)
    XCTAssertEqual(try StockTableParser.rows(cells) { _, _ in [cell("2200毫升", 500, 310)] }.last?.inventoryUncertain, true)
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
