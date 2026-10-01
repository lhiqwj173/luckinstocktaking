import Foundation
import CoreFoundation

enum StockCaptureError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self { case .invalid(let text): return text }
  }
}

struct StockCaptureRequest: Codable {
  let id: String
  let createdAt: Date
  let top: Double
  let bottom: Double

  func validate() throws {
    guard UUID(uuidString: id) != nil, top.isFinite, bottom.isFinite,
      (0...0.4).contains(top), (0...0.3).contains(bottom), top + bottom < 0.7 else {
      throw StockCaptureError.invalid("自动录屏配置无效")
    }
  }
}

struct StockCaptureCompletion: Codable {
  let id: String
  let frames: Int
  let duration: Double
}

enum StockCaptureSession {
  static let group = "group.com.luckinstocktaking.shared"
  static let extensionID = "com.luckinstocktaking.luckinstocktaking.StockCapture"
  static let notification = "com.luckinstocktaking.capture.finished"

  static func root() throws -> URL {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw StockCaptureError.invalid("无法访问录屏共享目录，请确认主 App 和录屏扩展均已签名并启用 App Groups")
    }
    let root = container.appendingPathComponent("StockCaptures", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  static func directory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw StockCaptureError.invalid("录屏会话标识无效") }
    return try root().appendingPathComponent(id, isDirectory: true)
  }
  static func prepare(top: Double, bottom: Double) throws -> StockCaptureRequest {
    let root = try root()
    let active = root.appendingPathComponent("active.json")
    if FileManager.default.fileExists(atPath: active.path) {
      let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: active))
      let folder = try directory(id)
      if FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording").path),
         !FileManager.default.fileExists(atPath: folder.appendingPathComponent("completed.json").path),
         !FileManager.default.fileExists(atPath: folder.appendingPathComponent("failure.json").path) {
        throw StockCaptureError.invalid("已有录屏正在进行，请先结束系统录屏")
      }
    }
    let request = StockCaptureRequest(id: UUID().uuidString, createdAt: Date(), top: top, bottom: bottom)
    try request.validate()
    let folder = try directory(request.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
    try JSONEncoder().encode(request.id).write(to: active, options: .atomic)
    try setHostForeground(true)
    return request
  }
  static func active() throws -> StockCaptureRequest {
    let active = try root().appendingPathComponent("active.json")
    guard FileManager.default.fileExists(atPath: active.path) else {
      throw StockCaptureError.invalid("请先运行「开始读取旧盘点单」快捷指令或助手内的录屏入口")
    }
    let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: active))
    let request = try JSONDecoder().decode(StockCaptureRequest.self,
      from: Data(contentsOf: directory(id).appendingPathComponent("request.json")))
    try request.validate()
    guard request.id == id else { throw StockCaptureError.invalid("录屏会话与配置不一致") }
    return request
  }
  static func setHostForeground(_ foreground: Bool) throws {
    try JSONEncoder().encode(foreground).write(to: root().appendingPathComponent("host.json"), options: .atomic)
  }
  static func hostForeground() throws -> Bool {
    try JSONDecoder().decode(Bool.self, from: Data(contentsOf: root().appendingPathComponent("host.json")))
  }
  static func announce() {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(notification as CFString), nil, nil, true)
  }
  static func fail(_ error: Error, id: String) throws {
    try JSONEncoder().encode(error.localizedDescription).write(
      to: directory(id).appendingPathComponent("failure.json"), options: .atomic)
    announce()
  }
}
