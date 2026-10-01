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
