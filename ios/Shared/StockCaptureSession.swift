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
  static let notification = "com.luckinstocktaking.capture.finished"
  private static let installedGroup: Result<String, Error> = Result { try signedGroup(in: Bundle.main) }

  // 重签工具可能重命名共享组。读取安装包实际授权的组，不拼接或猜测团队标识。
  static func profileGroups(_ data: Data) throws -> [String] {
    guard let start = data.range(of: Data("<plist".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
      throw StockCaptureError.invalid("签名描述文件缺少有效的权限配置")
    }
    let plist = try PropertyListSerialization.propertyList(
      from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil)
    guard let profile = plist as? [String: Any],
      let entitlements = profile["Entitlements"] as? [String: Any] else {
      throw StockCaptureError.invalid("签名描述文件的权限配置损坏")
    }
    guard let value = entitlements["com.apple.security.application-groups"] else {
      throw StockCaptureError.invalid("安装包的签名未授权 App Groups；请在重签时保留主 App 和录屏扩展的共享组权限")
    }
    guard let groups = value as? [String], !groups.isEmpty,
      groups.allSatisfy({ $0.hasPrefix("group.") && $0.count > 6 }),
      Set(groups).count == groups.count else {
      throw StockCaptureError.invalid("签名描述文件的共享组配置无效")
    }
    return groups
  }

  static func selectGroup(_ groups: [String]) throws -> String {
    if groups.contains(group) { return group }
    guard groups.count == 1, let renamed = groups.first else {
      throw StockCaptureError.invalid("重签后的共享组不明确，无法确定录屏数据目录")
    }
    return renamed
  }

  static func signedGroup(in bundle: Bundle) throws -> String {
    // App Store 安装包可能没有 embedded.mobileprovision，此时仍使用声明的组并验证容器。
    guard let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
      return group
    }
    return try selectGroup(profileGroups(Data(contentsOf: profile)))
  }

  static func broadcastExtensionID() throws -> String {
    guard let plugins = Bundle.main.builtInPlugInsURL else {
      throw StockCaptureError.invalid("安装包未包含录屏扩展；请勿在 Sideloadly 中移除 PlugIns")
    }
    let urls = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
    let matches = urls.filter { $0.lastPathComponent == "StockCapture.appex" }
    guard matches.count == 1, let url = matches.first, let bundle = Bundle(url: url),
      let identifier = bundle.bundleIdentifier,
      let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
      info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload" else {
      throw StockCaptureError.invalid("安装包的录屏扩展缺失或配置无效；请保留 StockCapture.appex")
    }
    guard try signedGroup(in: bundle) == signedGroup(in: Bundle.main) else {
      throw StockCaptureError.invalid("主 App 与录屏扩展授权的共享组不同，请使用相同共享组重新签名两者")
    }
    return identifier
  }

  static func root() throws -> URL {
    let installedGroup = try Self.installedGroup.get()
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: installedGroup) else {
      throw StockCaptureError.invalid("签名未授予共享目录权限（\(installedGroup)）。请在重签时为主 App 和录屏扩展保留相同的 App Groups 权限")
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
