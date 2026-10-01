import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testResignedCaptureProfile() throws {
    let renamed = "group.com.luckinstocktaking.shared.resigned"
    let plist = try PropertyListSerialization.data(fromPropertyList: [
      "Entitlements": ["com.apple.security.application-groups": [renamed]],
    ], format: .xml, options: 0)
    var cms = Data([0x30, 0x82, 0x01, 0x00])
    cms.append(plist)
    cms.append(Data([0x00, 0xff]))
    let groups = try StockCaptureSession.profileGroups(cms)
    XCTAssertEqual(try StockCaptureSession.selectGroup(groups), renamed)
    XCTAssertEqual(try StockCaptureSession.selectGroup([renamed, StockCaptureSession.group]), StockCaptureSession.group)
    XCTAssertThrowsError(try StockCaptureSession.selectGroup([renamed, "group.other"]))
  }

  func testCaptureProfileRejectsMissingOrInvalidGrant() throws {
    let cases: [[String: Any]] = [[:],
      ["com.apple.security.application-groups": [] as [String]],
      ["com.apple.security.application-groups": ["invalid"]],
      ["com.apple.security.application-groups": [StockCaptureSession.group, StockCaptureSession.group]],
    ]
    for entitlements in cases {
      let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements],
        format: .xml, options: 0)
      XCTAssertThrowsError(try StockCaptureSession.profileGroups(plist))
    }
    XCTAssertThrowsError(try StockCaptureSession.profileGroups(Data("damaged".utf8)))
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

  func testScrollAlignmentAndReverseRejection() throws {
    let source = pattern()
    let first = source.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 600))!
    let second = source.cropping(to: CGRect(x: 0, y: 120, width: 192, height: 600))!
    let a = try StockGrayFrame(first)
    let b = try StockGrayFrame(second)
    XCTAssertEqual(try a.displacement(to: a), 0)
    XCTAssertEqual(try a.displacement(to: b), 120)
    XCTAssertThrowsError(try b.displacement(to: a))
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
