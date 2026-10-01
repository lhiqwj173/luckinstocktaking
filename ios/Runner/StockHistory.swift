import AVFoundation
import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Vision
import ReplayKit
import CoreFoundation

enum StockHistoryError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self { case .invalid(let message): return message }
  }
}

struct StockTextLine: Codable {
  var cells: [String]
  var confidence: Double
}

struct StockHistoryDocument: Codable {
  let schemaVersion: Int
  let id: String
  var title: String
  let createdAt: String
  let imageName: String
  var lines: [StockTextLine]
  var reviewed: Bool

  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if text.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    return formatter.date(from: text)
  }

  func validate() throws {
    guard schemaVersion == 1, UUID(uuidString: id) != nil,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          Self.date(createdAt) != nil,
          imageName == "\(id).png", !lines.isEmpty,
          lines.allSatisfy({ !$0.cells.isEmpty && $0.cells.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          } && $0.confidence.isFinite && (0...1).contains($0.confidence) }) else {
      throw StockHistoryError.invalid("历史盘点单格式无效，请检查本地数据")
    }
  }
  func json() throws -> String {
    try validate()
    guard let json = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
      throw StockHistoryError.invalid("盘点单无法编码为 UTF-8")
    }
    return json
  }
}

enum StockHistoryStorage {
  // 所有磁盘操作和处理任务共用串行队列，避免快捷指令与前台更新相互覆盖。
  static let queue = DispatchQueue(label: "com.luckinstocktaking.history", qos: .userInitiated)
  static let readyNotification = Notification.Name("StockHistoryReady")
  static let pendingKey = "stockHistory.pendingDocumentID"
  static let captureStartKey = "stockCapture.openStart"

  static func consumeCapture(onProcessing: () -> Void = {}) throws -> StockHistoryDocument? {
    let root = try StockCaptureSession.root()
    let folders = try FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for folder in folders {
      let imported = folder.appendingPathComponent("imported.json")
      if FileManager.default.fileExists(atPath: imported.path) { continue }
      let failure = folder.appendingPathComponent("failure.json")
      if FileManager.default.fileExists(atPath: failure.path) {
        let message = try JSONDecoder().decode(String.self, from: Data(contentsOf: failure))
        throw StockCaptureError.invalid("自动录屏失败：\(message)。可在旧盘点单页面清除失败会话后重试。")
      }
      let complete = folder.appendingPathComponent("completed.json")
      let request = try JSONDecoder().decode(StockCaptureRequest.self,
        from: Data(contentsOf: folder.appendingPathComponent("request.json")))
      try request.validate()
      guard request.id == folder.lastPathComponent else { throw StockCaptureError.invalid("录屏配置的会话标识不一致") }
      if !FileManager.default.fileExists(atPath: complete.path) {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording").path),
          Date().timeIntervalSince(request.createdAt) > 480 {
          let error = StockCaptureError.invalid("录屏扩展异常退出，未收到完整结束数据，请清除失败会话后重录")
          try StockCaptureSession.fail(error, id: request.id)
          throw error
        }
        continue
      }
      let state = try JSONDecoder().decode(StockCaptureCompletion.self, from: Data(contentsOf: complete))
      guard request.id == folder.lastPathComponent, state.id == request.id,
        state.frames >= 2, state.duration.isFinite, state.duration > 0, state.duration <= 120 else {
        throw StockCaptureError.invalid("自动录屏完成状态无效")
      }
      let record: StockHistoryDocument
      onProcessing()
      do {
        let existing = try directory(request.id).appendingPathComponent("record.json")
        if FileManager.default.fileExists(atPath: existing.path) {
          record = try JSONDecoder().decode(StockHistoryDocument.self, from: Data(contentsOf: existing))
          try record.validate()
          guard record.id == request.id else { throw StockCaptureError.invalid("已导入的录屏记录标识不一致") }
          _ = try image(record.id)
        } else {
          record = try StockHistoryProcessor.process(url: folder.appendingPathComponent("capture.mp4"),
            video: true, crop: StockCrop(top: request.top, bottom: request.bottom), documentID: request.id)
        }
      } catch {
        try StockCaptureSession.fail(error, id: request.id)
        throw error
      }
      try JSONEncoder().encode(record.id).write(to: imported, options: .atomic)
      UserDefaults.standard.set(record.id, forKey: pendingKey)
      return record
    }
    return nil
  }

  static func pendingDocument(onProcessing: () -> Void = {}) throws -> String? {
    // 只在安装的主 App 能访问共享目录时读取扩展结果；无待处理会话是合法状态。
    _ = try consumeCapture(onProcessing: onProcessing)
    guard let value = UserDefaults.standard.object(forKey: pendingKey) else { return nil }
    guard let id = value as? String else { throw StockHistoryError.invalid("待打开的盘点单标识损坏") }
    let record = try JSONDecoder().decode(StockHistoryDocument.self,
      from: Data(contentsOf: directory(id).appendingPathComponent("record.json")))
    guard record.id == id else { throw StockHistoryError.invalid("待打开的盘点单标识不一致") }
    let json = try record.json()
    UserDefaults.standard.removeObject(forKey: pendingKey)
    return json
  }

  static func root() throws -> URL {
    let documents = try FileManager.default.url(for: .documentDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = documents.appendingPathComponent("StockHistory", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
  static func directory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw StockHistoryError.invalid("盘点单标识无效") }
    return try root().appendingPathComponent(id, isDirectory: true)
  }
  static func list() throws -> String {
    let files = try FileManager.default.contentsOfDirectory(at: root(),
      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    let records = try files.map { directory -> StockHistoryDocument in
      let record = try JSONDecoder().decode(StockHistoryDocument.self,
        from: Data(contentsOf: directory.appendingPathComponent("record.json")))
      try record.validate()
      guard directory.lastPathComponent == record.id,
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.imageName).path) else {
        throw StockHistoryError.invalid("历史盘点单原图或标识损坏")
      }
      return record
    }.sorted { $0.createdAt > $1.createdAt }
    guard let json = String(data: try JSONEncoder().encode(records), encoding: .utf8) else {
      throw StockHistoryError.invalid("历史列表无法编码为 UTF-8")
    }
    return json
  }
  static func create(image: UIImage, lines: [StockTextLine], id: String = UUID().uuidString) throws -> StockHistoryDocument {
    let record = StockHistoryDocument(schemaVersion: 1, id: id,
      title: "旧盘点单 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
      createdAt: ISO8601DateFormatter().string(from: Date()), imageName: "\(id).png",
      lines: lines, reviewed: false)
    try record.validate()
    guard let png = image.pngData() else { throw StockHistoryError.invalid("无法生成盘点单长截图") }
    let staging = try root().appendingPathComponent(".\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    do {
      try png.write(to: staging.appendingPathComponent(record.imageName), options: .atomic)
      try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
      try FileManager.default.moveItem(at: staging, to: directory(id))
    } catch {
      // 回滚失败同样向调用方抛出；不得留下一个看似成功的残缺记录。
      try FileManager.default.removeItem(at: staging)
      throw error
    }
    return record
  }
  static func save(_ json: String) throws {
    let record = try JSONDecoder().decode(StockHistoryDocument.self, from: Data(json.utf8))
    try record.validate()
    let location = try directory(record.id)
    let original = try JSONDecoder().decode(StockHistoryDocument.self,
      from: Data(contentsOf: location.appendingPathComponent("record.json")))
    try original.validate()
    guard original.id == record.id,
          StockHistoryDocument.date(original.createdAt) == StockHistoryDocument.date(record.createdAt),
          original.imageName == record.imageName,
          FileManager.default.fileExists(atPath: location.appendingPathComponent(record.imageName).path) else {
      throw StockHistoryError.invalid("盘点单标识、导入时间或原图发生异常变更")
    }
    try JSONEncoder().encode(record).write(to: location.appendingPathComponent("record.json"), options: .atomic)
  }
  static func image(_ id: String) throws -> Data {
    try Data(contentsOf: directory(id).appendingPathComponent("\(id).png"))
  }
}

struct StockCrop {
  let top: Double
  let bottom: Double
  func validate() throws {
    guard top.isFinite, bottom.isFinite, (0...0.4).contains(top),
          (0...0.3).contains(bottom), top + bottom < 0.7 else {
      throw StockHistoryError.invalid("裁剪比例无效，顶部范围 0～0.4，底部范围 0～0.3")
    }
  }
  func apply(_ image: CGImage) throws -> CGImage {
    try validate()
    let start = Int((Double(image.height) * top).rounded())
    let end = Int((Double(image.height) * (1 - bottom)).rounded())
    guard end - start >= 100, let cropped = image.cropping(to:
      CGRect(x: 0, y: start, width: image.width, height: end - start)) else {
      throw StockHistoryError.invalid("裁剪后画面太小，无法拼接")
    }
    return cropped
  }
}

struct StockGrayFrame {
  let pixels: [UInt8]
  let width: Int
  let height: Int
  init(_ image: CGImage, fullHeight: Bool = false) throws {
    let width = 96
    let height = fullHeight ? image.height : min(640, image.height)
    var bytes = [UInt8](repeating: 0, count: width * height)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw StockHistoryError.invalid("无法创建拼接特征") }
    self.width = width
    self.height = height
    pixels = bytes
  }

  func error(with other: StockGrayFrame, shift: Int) -> Double {
    precondition(width == other.width && height == other.height)
    let start = max(0, -shift)
    let end = min(height, height - shift)
    var sum = 0.0
    var count = 0
    // 只比较有内容的像素，白色背景不能成为高置信度接缝。
    for y in stride(from: start + 2, to: end - 2, by: 3) {
      for x in stride(from: 4, to: width - 4, by: 2) {
        let a = Int(pixels[(y + shift) * width + x])
        let b = Int(other.pixels[y * width + x])
        if min(a, b) < 220 { sum += Double(abs(a - b)); count += 1 }
      }
    }
    return count >= 100 ? sum / Double(count) : .infinity
  }

  func displacement(to next: StockGrayFrame) throws -> Int {
    guard width == next.width, height == next.height else {
      throw StockHistoryError.invalid("录屏分辨率改变，请保持竖屏重新录制")
    }
    if error(with: next, shift: 0) < 2 { return 0 }
    let limit = Int(Double(height) * 0.55)
    let scores = (-limit...limit).map { ($0, error(with: next, shift: $0)) }
    guard let best = scores.min(by: { $0.1 < $1.1 }), best.1 < 20 else {
      throw StockHistoryError.invalid("无法匹配相邻画面，请排除固定栏并放慢滚动速度重新录屏")
    }
    guard best.0 >= 0 else {
      throw StockHistoryError.invalid("检测到向上回滚，请从单据顶部开始，始终向下滚动")
    }
    let competing = scores.filter { abs($0.0 - best.0) > 12 }.map { $0.1 }.min()
    guard let alternative = competing, alternative > best.1 * 1.2 + 1 else {
      throw StockHistoryError.invalid("画面重复或接缝不明确，无法可靠拼接，请调整裁剪范围重新录屏")
    }
    return best.0
  }
}

enum StockHistoryProcessor {
  static func process(url: URL, video: Bool, crop: StockCrop, documentID: String = UUID().uuidString) throws -> StockHistoryDocument {
    let image: UIImage
    if video {
      image = try stitch(url: url, crop: crop)
    } else {
      guard let source = UIImage(contentsOfFile: url.path) else {
        throw StockHistoryError.invalid("无法读取截图，请选择清晰的图片")
      }
      guard source.size.width * source.size.height * source.scale * source.scale <= 40_000_000 else {
        throw StockHistoryError.invalid("截图超过 4000 万像素，请拆分后导入")
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      image = UIGraphicsImageRenderer(size: CGSize(width: source.size.width * source.scale,
        height: source.size.height * source.scale), format: format).image { _ in
        source.draw(in: CGRect(origin: .zero, size: CGSize(width: source.size.width * source.scale,
          height: source.size.height * source.scale)))
      }
    }
    let lines = try recognize(image)
    return try StockHistoryStorage.create(image: image, lines: lines, id: documentID)
  }

  static func makeGenerator(url: URL) throws -> (AVAssetImageGenerator, Double) {
    let asset = AVURLAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0, duration <= 120,
          !asset.tracks(withMediaType: .video).isEmpty else {
      throw StockHistoryError.invalid("请选择有效的录屏视频，时长须在 120 秒以内")
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1080, height: 2400)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return (generator, duration)
  }

  static func stitch(url: URL, crop: StockCrop) throws -> UIImage {
    try crop.validate()
    let (generator, duration) = try makeGenerator(url: url)
    var pieces: [CGImage] = []
    var previous: CGImage?
    var previousGray: StockGrayFrame?
    var totalHeight = 0
    var width = 0
    // 每秒 5 帧，逐帧释放解码临时对象，仅保留新增画面。
    let samples = max(1, Int(ceil(duration * 5)))
    for index in 0..<samples {
      try autoreleasepool {
        let raw = try generator.copyCGImage(at: CMTime(seconds: Double(index) / 5,
          preferredTimescale: 600), actualTime: nil)
        let frame = try crop.apply(raw)
        let gray = try StockGrayFrame(frame)
        if let old = previous, let oldGray = previousGray {
          guard old.width == frame.width, old.height == frame.height else {
            throw StockHistoryError.invalid("录屏尺寸发生变化，请勿旋转屏幕")
          }
          let displacement = try oldGray.displacement(to: gray)
          if displacement == 0 { return }
          // 用原始高度细化接缝，避免缩小特征造成数像素累计偏移。
          let predicted = Int((Double(displacement) * Double(frame.height) / Double(gray.height)).rounded())
          let radius = max(2, Int(ceil(Double(frame.height) / Double(gray.height))))
          let oldFull = try StockGrayFrame(old, fullHeight: true)
          let nextFull = try StockGrayFrame(frame, fullHeight: true)
          let shifts = max(1, predicted - radius)...min(frame.height - 1, predicted + radius)
          guard let best = shifts.map({ ($0, oldFull.error(with: nextFull, shift: $0)) })
            .min(by: { $0.1 < $1.1 }), best.1 < 20,
            let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - best.0,
              width: frame.width, height: best.0)) else {
            throw StockHistoryError.invalid("接缝校验失败，请缓慢滚动重新录屏")
          }
          pieces.append(strip)
          totalHeight += strip.height
        } else {
          pieces.append(frame)
          width = frame.width
          totalHeight = frame.height
        }
        guard totalHeight <= 32_000, width * totalHeight <= 40_000_000 else {
          throw StockHistoryError.invalid("盘点单过长，请分成多段录屏导入")
        }
        previous = frame
        previousGray = gray
      }
    }
    guard !pieces.isEmpty else { throw StockHistoryError.invalid("录屏中没有可读取的画面") }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight), format: format).image { _ in
      var y = 0
      for piece in pieces {
        UIImage(cgImage: piece).draw(in: CGRect(x: 0, y: y, width: width, height: piece.height))
        y += piece.height
      }
    }
  }

  static func recognize(_ image: UIImage) throws -> [StockTextLine] {
    guard let cg = image.cgImage else { throw StockHistoryError.invalid("无法读取截图像素") }
    struct Cell { let text: String; let confidence: Double; let box: CGRect }
    var cells: [Cell] = []
    // 对长图分块识别，用中心点归属消除块边缘重复；不按文本去重，保留真实重复行。
    let block = 1800
    let margin = 120
    for start in stride(from: 0, to: cg.height, by: block) {
      try autoreleasepool {
        let top = max(0, start - margin)
        let bottom = min(cg.height, start + block + margin)
        guard let tile = cg.cropping(to: CGRect(x: 0, y: top, width: cg.width, height: bottom - top)) else {
          throw StockHistoryError.invalid("无法分块读取长截图")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
        guard let results = request.results else { throw StockHistoryError.invalid("文字识别未返回结果") }
        for observation in results {
          guard let candidate = observation.topCandidates(1).first else {
            throw StockHistoryError.invalid("文字识别候选为空")
          }
          let bounds = observation.boundingBox
          let rect = CGRect(x: bounds.minX * Double(cg.width),
            y: Double(top) + (1 - bounds.maxY) * Double(bottom - top),
            width: bounds.width * Double(cg.width), height: bounds.height * Double(bottom - top))
          if rect.midY >= Double(start) && rect.midY < Double(min(cg.height, start + block)) {
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StockHistoryError.invalid("识别到空文字，请检查截图") }
            cells.append(Cell(text: text, confidence: Double(candidate.confidence), box: rect))
          }
        }
      }
    }
    cells.sort { $0.box.midY < $1.box.midY }
    var groups: [[Cell]] = []
    for cell in cells {
      if let last = groups.last, let anchor = last.first,
         abs(anchor.box.midY - cell.box.midY) < min(anchor.box.height, cell.box.height) * 0.45 {
        groups[groups.count - 1].append(cell)
      } else { groups.append([cell]) }
    }
    guard !groups.isEmpty else { throw StockHistoryError.invalid("没有识别到文字，请选择清晰的盘点单截图") }
    return groups.map { group in
      StockTextLine(cells: group.sorted { $0.box.minX < $1.box.minX }.map(\.text),
        confidence: group.map(\.confidence).min()!)
    }
  }
}

final class StockHistoryBridge: NSObject, PHPickerViewControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var video = true
  private var crop = StockCrop(top: 0.18, bottom: 0.10)
  private var captureConfigured = false
  private weak var captureStartView: StockCaptureStartView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.luckinstocktaking/history", binaryMessenger: messenger)
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(historyReady),
      name: StockHistoryStorage.readyNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(hostInactive),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(hostActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
        guard let observer = observer else { preconditionFailure("录屏通知观察者缺失") }
        let bridge = Unmanaged<StockHistoryBridge>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { bridge.historyReady() }
      }, StockCaptureSession.notification as CFString, nil, .deliverImmediately)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "HISTORY_UNAVAILABLE", message: "历史服务不可用", details: nil)); return
      }
      self.handle(call, result: result)
    }
  }
  deinit {
    NotificationCenter.default.removeObserver(self)
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque())
  }
  @objc private func historyReady() {
    guard UIApplication.shared.applicationState == .active else { return }
    channel.invokeMethod("historyReady", arguments: nil)
  }
  private func hostState(_ active: Bool) {
    guard captureConfigured else { return }
    do { try StockCaptureSession.setHostForeground(active) }
    catch { channel.invokeMethod("captureError", arguments: error.localizedDescription) }
  }
  @objc private func hostInactive() { hostState(false) }
  @objc private func hostActive() { hostState(true) }

  private func presentCapture(top: Double, bottom: Double) throws {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
      var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
      throw StockCaptureError.invalid("无法显示系统录屏入口")
    }
    while let next = presenter.presentedViewController { presenter = next }
    let extensionID = try StockCaptureSession.broadcastExtensionID()
    _ = try StockCaptureSession.prepare(top: top, bottom: bottom)
    captureConfigured = true
    let controller = StockCaptureStartView(extensionID: extensionID)
    captureStartView = controller
    presenter.present(controller, animated: true)
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "startCapture" {
      do {
        guard let args = call.arguments as? [String: Any], let top = args["top"] as? Double,
          let bottom = args["bottom"] as? Double else { throw StockCaptureError.invalid("录屏配置缺失") }
        try presentCapture(top: top, bottom: bottom)
        result(nil)
      } catch { Self.fail(error, result: result) }
      return
    }
    if call.method == "pendingStart" {
      do {
        if let json = UserDefaults.standard.object(forKey: StockHistoryStorage.captureStartKey) {
          guard let json = json as? String else { throw StockCaptureError.invalid("录屏启动配置损坏") }
          let request = try JSONDecoder().decode(StockCaptureRequest.self, from: Data(json.utf8))
          try presentCapture(top: request.top, bottom: request.bottom)
          UserDefaults.standard.removeObject(forKey: StockHistoryStorage.captureStartKey)
        }
        result(nil)
      } catch { Self.fail(error, result: result) }
      return
    }
    if call.method == "import" {
      guard pending == nil, let arguments = call.arguments as? [String: Any],
        let video = arguments["video"] as? Bool,
        let top = arguments["top"] as? Double, let bottom = arguments["bottom"] as? Double else {
        result(FlutterError(code: "INVALID_IMPORT", message: "导入参数无效或已有导入任务", details: nil)); return
      }
      let crop = StockCrop(top: top, bottom: bottom)
      do { try crop.validate() } catch { Self.fail(error, result: result); return }
      guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
        result(FlutterError(code: "NO_WINDOW", message: "无法打开照片选择器", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      self.video = video; self.crop = crop; pending = result
      var configuration = PHPickerConfiguration()
      configuration.selectionLimit = 1
      configuration.filter = video ? .videos : .images
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      presenter.present(picker, animated: true)
      return
    }
    StockHistoryStorage.queue.async {
      do {
        let value: Any?
        switch call.method {
        case "clearCaptureFailures":
          let root = try StockCaptureSession.root()
          let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
          for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("failure.json").path) {
              try FileManager.default.removeItem(at: folder)
            }
          }
          value = nil
        case "pending": value = try StockHistoryStorage.pendingDocument {
          DispatchQueue.main.async { self.captureStartView?.showProcessing() }
        }
        case "list": value = try StockHistoryStorage.list()
        case "save":
          guard let json = call.arguments as? String else { throw StockHistoryError.invalid("盘点单必须为 JSON 文本") }
          try StockHistoryStorage.save(json); value = nil
        case "image":
          guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
          value = FlutterStandardTypedData(bytes: try StockHistoryStorage.image(id))
        default: value = FlutterMethodNotImplemented
        }
        DispatchQueue.main.async {
          if call.method == "pending", value != nil {
            self.captureStartView?.dismiss(animated: false)
            self.captureStartView = nil
          }
          result(value)
          if call.method == "clearCaptureFailures" { self.historyReady() }
        }
      } catch { DispatchQueue.main.async { Self.fail(error, result: result) } }
    }
  }
  private static func fail(_ error: Error, result: FlutterResult) {
    result(FlutterError(code: "HISTORY_ERROR", message: error.localizedDescription,
      details: String(reflecting: error)))
  }
  private func finish(_ value: String?, error: Error? = nil) {
    precondition(Thread.isMainThread)
    guard let result = pending else { preconditionFailure("导入回调状态丢失") }
    pending = nil
    if let error = error { Self.fail(error, result: result) } else { result(value) }
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true) {
      guard let selection = results.first else { self.finish(nil); return }
      let type = self.video ? UTType.movie.identifier : UTType.image.identifier
      selection.itemProvider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        do {
          if let error = error { throw error }
          guard let url = url else { throw StockHistoryError.invalid("无法读取选中的文件") }
          let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
          try FileManager.default.copyItem(at: url, to: local)
          DispatchQueue.main.async {
            if self.video { self.preview(local) } else { self.process(local) }
          }
        } catch { DispatchQueue.main.async { self.finish(nil, error: error) } }
      }
    }
  }
  private func preview(_ url: URL) {
    StockHistoryStorage.queue.async {
      do {
        let (generator, _) = try StockHistoryProcessor.makeGenerator(url: url)
        let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
        DispatchQueue.main.async {
          guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            self.cleanup(url, value: nil, error: StockHistoryError.invalid("无法显示录屏预览")); return
          }
          let preview = StockCropPreview(image: UIImage(cgImage: cg), crop: self.crop) { selected in
            if let selected = selected { self.crop = selected; self.process(url) }
            else { self.cleanup(url, value: nil) }
          }
          presenter.present(preview, animated: true)
        }
      } catch { DispatchQueue.main.async { self.cleanup(url, value: nil, error: error) } }
    }
  }
  private func process(_ url: URL) {
    let video = self.video, crop = self.crop
    StockHistoryStorage.queue.async {
      do {
        let document = try StockHistoryProcessor.process(url: url, video: video, crop: crop)
        let json = try document.json()
        DispatchQueue.main.async { self.cleanup(url, value: json) }
      } catch { DispatchQueue.main.async { self.cleanup(url, value: nil, error: error) } }
    }
  }
  private func cleanup(_ url: URL, value: String?, error: Error? = nil) {
    do { try FileManager.default.removeItem(at: url); finish(value, error: error) }
    catch { finish(nil, error: error) }
  }
}

final class StockCaptureStartView: UIViewController {
  private let label = UILabel()
  private let extensionID: String
  init(extensionID: String) {
    self.extensionID = extensionID
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("不支持 storyboard 初始化") }
  func showProcessing() {
    label.text = "录屏已接收\n\n正在拼接长截图、识别文字并保存历史。\n请保持助手打开，完成后自动显示结果。"
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.text = "读取旧盘点单\n\n点击下方系统录屏按钮，并确认「开始直播」。\n随后切回瑞幸盘，从单据顶部缓慢滚动到底。\n\n结束系统录屏后返回助手，自动拼接、识别并保存历史。\n录屏仅保存在本机，不上传、不保存音轨。"
    label.numberOfLines = 0; label.textAlignment = .center
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
    picker.preferredExtension = extensionID
    picker.showsMicrophoneButton = false
    let close = UIButton(type: .system)
    close.setTitle("返回助手", for: .normal)
    close.addTarget(self, action: #selector(closeView), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, picker, close])
    stack.axis = .vertical; stack.alignment = .center; stack.spacing = 28
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      label.widthAnchor.constraint(equalTo: stack.widthAnchor),
      picker.widthAnchor.constraint(equalToConstant: 80), picker.heightAnchor.constraint(equalToConstant: 80),
    ])
  }
  @objc private func closeView() { dismiss(animated: true) }
}

final class StockCropPreview: UIViewController {
  private let image: UIImage
  private let top = UISlider()
  private let bottom = UISlider()
  private let picture = UIImageView()
  private let label = UILabel()
  private let completion: (StockCrop?) -> Void
  init(image: UIImage, crop: StockCrop, completion: @escaping (StockCrop?) -> Void) {
    self.image = image; self.completion = completion
    super.init(nibName: nil, bundle: nil)
    top.maximumValue = 0.4; bottom.maximumValue = 0.3
    top.value = Float(crop.top); bottom.value = Float(crop.bottom)
    isModalInPresentation = true
  }
  required init?(coder: NSCoder) { fatalError("不支持 storyboard 初始化") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0; label.textAlignment = .center
    picture.contentMode = .scaleAspectFit
    top.addTarget(self, action: #selector(update), for: .valueChanged)
    bottom.addTarget(self, action: #selector(update), for: .valueChanged)
    let accept = UIButton(type: .system)
    accept.setTitle("范围正确，开始拼接", for: .normal)
    accept.addTarget(self, action: #selector(confirm), for: .touchUpInside)
    let cancel = UIButton(type: .system)
    cancel.setTitle("取消", for: .normal)
    cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, picture, top, bottom, accept, cancel])
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      picture.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    update()
  }
  @objc private func update() {
    let crop = StockCrop(top: Double(top.value), bottom: Double(bottom.value))
    label.text = "仅保留滚动内容，排除固定导航和底栏\n顶部 \(Int(top.value * 100))% · 底部 \(Int(bottom.value * 100))%"
    do {
      guard let cg = image.cgImage else { throw StockHistoryError.invalid("预览图片无效") }
      picture.image = UIImage(cgImage: try crop.apply(cg))
    } catch { preconditionFailure(error.localizedDescription) }
  }
  @objc private func confirm() {
    let crop = StockCrop(top: Double(top.value), bottom: Double(bottom.value))
    dismiss(animated: true) { self.completion(crop) }
  }
  @objc private func close() { dismiss(animated: true) { self.completion(nil) } }
}
