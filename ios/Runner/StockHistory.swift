import AVFoundation
import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Vision

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

struct StockOCRCell {
  let text: String
  let confidence: Double
  let box: CGRect
}

enum StockTableParser {
  static func splitColumnGap(_ text: String, characters: [(Range<String.Index>, CGRect)],
    stockColumnStart: CGFloat) -> [Range<String.Index>] {
    guard characters.count >= 2 else { return [text.startIndex..<text.endIndex] }
    for index in 1..<characters.count {
      let previous = characters[index - 1]
      let next = characters[index]
      let gap = next.1.minX - previous.1.maxX
      if previous.1.minX < stockColumnStart, next.1.minX >= stockColumnStart,
        gap > max(previous.1.height, next.1.height) * 0.8 {
        return [text.startIndex..<next.0.lowerBound, next.0.lowerBound..<text.endIndex]
      }
    }
    return [text.startIndex..<text.endIndex]
  }
  static func rows(_ cells: [StockOCRCell],
    retryInventory: ((CGFloat, CGFloat) throws -> [StockOCRCell])? = nil) throws -> [StockTextLine] {
    let ordered = cells.sorted {
      $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY
    }
    func compact(_ text: String) -> String {
      text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
    guard let nameHeader = ordered.first(where: { compact($0.text).contains("货物规格名称") }),
      let stockHeader = ordered.first(where: {
        compact($0.text).contains("实盘总库存") && abs($0.box.midY - nameHeader.box.midY) < 50
      }), stockHeader.box.minX > nameHeader.box.maxX else {
      throw StockHistoryError.invalid("未识别到「货物规格名称 / 实盘总库存」表头，请确认长图包含表头")
    }
    let boundary = (nameHeader.box.maxX + stockHeader.box.minX) / 2
    let top = max(nameHeader.box.maxY, stockHeader.box.maxY)
    let footer = ordered.first(where: { cell in
      cell.box.minY > top && ["预制物料信息", "其他信息", "历史记录"].contains(where: { compact(cell.text).contains($0) })
    })?.box.minY ?? .greatestFiniteMagnitude
    let body = ordered.filter { $0.box.midY > top && $0.box.midY < footer }
    let left = body.filter { $0.box.minX < boundary && !compact($0.text).contains("货物规格名称") }
    // O/I 与数字混淆只用于寻找行锚点，显示和保存时保留识别原文供校对。
    let code = "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}"
    var names: [[StockOCRCell]] = []
    var current: [StockOCRCell] = []
    for cell in left {
      current.append(cell)
      if compact(cell.text).range(of: code, options: .regularExpression) != nil {
        names.append(current)
        current = []
      }
    }
    guard !names.isEmpty, current.isEmpty else {
      throw StockHistoryError.invalid("货物编码识别不完整，无法可靠划分货物行，请核对原始长图")
    }
    return try names.enumerated().map { index, parts in
      // 左右两列独立垂直居中，库存可能比品名更高；用相邻名称块间的空白中点划分行。
      let start = index == 0 ? top :
        (names[index - 1].map { $0.box.maxY }.max()! + parts.map { $0.box.minY }.min()!) / 2
      let end = index + 1 < names.count ?
        (parts.map { $0.box.maxY }.max()! + names[index + 1].map { $0.box.minY }.min()!) / 2 : footer
      var stocks = body.filter { $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end }
      var inventory = stocks.map(\.text).joined(separator: "\n")
      if inventory.range(of: "[0-9]", options: .regularExpression) == nil, let retry = retryInventory {
        stocks = try retry(start, end).filter {
          $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end
        }.sorted { $0.box.midY < $1.box.midY }
        inventory = stocks.map(\.text).joined(separator: "\n")
      }
      guard !stocks.isEmpty, inventory.range(of: "[0-9]", options: .regularExpression) != nil else {
        throw StockHistoryError.invalid("第 \(index + 1) 项货物（\(parts.map(\.text).joined(separator: " "))）缺少可识别的库存数量，请核对原始长图")
      }
      return StockTextLine(cells: [parts.map(\.text).joined(separator: "\n"), inventory],
        confidence: (parts + stocks).map(\.confidence).min()!)
    }
  }
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
    guard (schemaVersion == 1 || schemaVersion == 2), UUID(uuidString: id) != nil,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          Self.date(createdAt) != nil,
          imageName == "\(id).png", !lines.isEmpty,
          (schemaVersion != 2 || lines.allSatisfy { $0.cells.count == 2 }),
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
  static func pendingDocument() throws -> String? {
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
    let record = StockHistoryDocument(schemaVersion: 2, id: id,
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
  static func delete(_ id: String) throws {
    let location = try directory(id)
    let record = try JSONDecoder().decode(StockHistoryDocument.self,
      from: Data(contentsOf: location.appendingPathComponent("record.json")))
    try record.validate()
    guard record.id == id else { throw StockHistoryError.invalid("待删除的盘点单标识不一致") }
    try FileManager.default.removeItem(at: location)
    if UserDefaults.standard.string(forKey: pendingKey) == id {
      UserDefaults.standard.removeObject(forKey: pendingKey)
    }
  }
  static func imageTiles(_ id: String) throws -> [Data] {
    guard let cg = UIImage(data: try image(id))?.cgImage else {
      throw StockHistoryError.invalid("历史长图无法读取")
    }
    // 超长纹理可能超过 GPU 上限，分别解码短图，保持每一段的原始宽高比。
    return try stride(from: 0, to: cg.height, by: 1800).map { start in
      try autoreleasepool {
        guard let tile = cg.cropping(to: CGRect(x: 0, y: start,
          width: cg.width, height: min(1800, cg.height - start))),
          let png = UIImage(cgImage: tile).pngData() else {
          throw StockHistoryError.invalid("无法生成长图预览分段")
        }
        return png
      }
    }
  }
}

struct StockCrop {
  static let automatic = StockCrop(top: 0.18, bottom: 0.10)
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
  let smooth: [UInt8]
  let width: Int
  let height: Int
  init(_ image: CGImage) throws {
    let width = 192
    // 保留原始行高，避免竖向缩小后文字采样相位改变，造成虚假的接缝误差。
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw StockHistoryError.invalid("无法创建拼接特征") }
    // 淡灰水印不应参与定位；原始截图仍完整保留，用于校对。
    for index in bytes.indices { bytes[index] = UInt8(min(255, Int(bytes[index]) * 255 / 210)) }
    var blurred = bytes
    for y in 3..<(height - 3) {
      for x in 0..<width {
        var sum = 0
        for row in (y - 3)...(y + 3) { sum += Int(bytes[row * width + x]) }
        blurred[y * width + x] = UInt8(sum / 7)
      }
    }
    self.width = width; self.height = height; pixels = bytes; smooth = blurred
  }

  func error(with other: StockGrayFrame, shift: Int, smoothed: Bool = false) -> Double {
    precondition(width == other.width && height == other.height)
    let aPixels = smoothed ? smooth : pixels
    let bPixels = smoothed ? other.smooth : other.pixels
    let start = max(0, -shift)
    let end = min(height, height - shift)
    var sum = 0.0; var count = 0
    // 粗匹配稀疏采样；精匹配逐行比较，避免采样周期让不同位移得到相同误差。
    let rowStride = smoothed ? 6 : 1
    for y in stride(from: start + 3, to: end - 3, by: rowStride) {
      for x in stride(from: 8, to: width - 8, by: 4) {
        let a = Int(aPixels[(y + shift) * width + x])
        let b = Int(bPixels[y * width + x])
        if min(a, b) < 220 { sum += Double(abs(a - b)); count += 1 }
      }
    }
    return count >= 100 ? sum / Double(count) : .infinity
  }

  func displacement(to next: StockGrayFrame) throws -> Int {
    guard width == next.width, height == next.height else {
      throw StockHistoryError.invalid("录屏分辨率改变，请保持竖屏重新录制")
    }
    if error(with: next, shift: 0) < 3 { return 0 }
    let limit = Int(Double(height) * 0.55)
    let scores = stride(from: -limit, through: limit, by: 4).map {
      ($0, error(with: next, shift: $0, smoothed: true))
    }
    guard let coarse = scores.min(by: { $0.1 < $1.1 }), coarse.1.isFinite else {
      throw StockHistoryError.invalid("相邻画面没有可靠重叠，请排除固定栏并放慢滚动速度")
    }
    let fine = max(-limit, coarse.0 - 5)...min(limit, coarse.0 + 5)
    guard let best = fine.map({ ($0, error(with: next, shift: $0)) }).min(by: { $0.1 < $1.1 }),
      best.1 < 45, error(with: next, shift: best.0, smoothed: true) < 18 else {
      throw StockHistoryError.invalid("接缝内容变化过大，请排除固定栏或弹窗后重新导入")
    }
    let competing = scores.filter { abs($0.0 - best.0) > 24 }.map { $0.1 }.min()
    guard let alternative = competing,
      alternative > error(with: next, shift: best.0, smoothed: true) * 1.2 + 2 else {
      throw StockHistoryError.invalid("画面重复或接缝不明确，无法可靠拼接，请调整裁剪范围")
    }
    return best.0
  }
}

struct StockScrollCoverage {
  private(set) var offset = 0
  private(set) var furthest = 0
  mutating func advance(by displacement: Int) throws -> Int {
    offset += displacement
    guard offset >= -3 else {
      throw StockHistoryError.invalid("录屏回滚超过起始位置，请从单据顶部重新录制")
    }
    let added = max(0, offset - furthest)
    furthest = max(furthest, offset)
    return added
  }
}

enum StockHistoryProcessor {
  static func process(url: URL, video: Bool, crop: StockCrop, documentID: String = UUID().uuidString,
    progress: @escaping (String) -> Void = { _ in }) throws -> StockHistoryDocument {
    let image: UIImage
    if video {
      image = try stitch(url: url, crop: crop, progress: progress)
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
    let lines = try recognize(image, progress: progress)
    progress("正在保存长截图与识别结果")
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

  static func stitch(url: URL, crop: StockCrop, progress: (String) -> Void = { _ in }) throws -> UIImage {
    try crop.validate()
    let (generator, duration) = try makeGenerator(url: url)
    var pieces: [CGImage] = []
    var coverage = StockScrollCoverage()
    var previousGray: StockGrayFrame?
    var totalHeight = 0
    var width = 0
    // 每秒 10 帧，降低快速滑动时重叠区域丢失的风险。
    let samples = max(1, Int(ceil(duration * 10)))
    for index in 0..<samples {
      try autoreleasepool {
        let raw = try generator.copyCGImage(at: CMTime(seconds: Double(index) / 10,
          preferredTimescale: 600), actualTime: nil)
        let frame = try crop.apply(raw)
        let gray = try StockGrayFrame(frame)
        if let oldGray = previousGray {
          guard width == frame.width, oldGray.height == frame.height else {
            throw StockHistoryError.invalid("录屏尺寸发生变化，请勿旋转屏幕")
          }
          let displacement: Int
          do { displacement = try oldGray.displacement(to: gray) }
          catch { throw StockHistoryError.invalid("录屏第 \(String(format: "%.1f", Double(index) / 10)) 秒：\(error.localizedDescription)") }
          let added = try coverage.advance(by: displacement)
          if added > 0 {
            guard added < frame.height, let strip = frame.cropping(to:
              CGRect(x: 0, y: frame.height - added, width: frame.width, height: added)) else {
              throw StockHistoryError.invalid("新增画面超出重叠范围，无法可靠拼接")
            }
            // CGImage.cropping 可能仍持有整帧解码缓冲；复制新增区域，避免数百帧占用数 GB。
            pieces.append(try ownedImage(strip))
            totalHeight += strip.height
          }
        } else {
          pieces.append(try ownedImage(frame))
          width = frame.width
          totalHeight = frame.height
        }
        guard totalHeight <= 48_000, width * totalHeight <= 40_000_000 else {
          throw StockHistoryError.invalid("盘点单过长，请分成多段录屏导入")
        }
        previousGray = gray
        if index % 10 == 0 || index == samples - 1 {
          progress("正在拼接录屏 · \(Int(Double(index + 1) / Double(samples) * 100))%")
        }
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

  static func ownedImage(_ image: CGImage) throws -> CGImage {
    guard let context = CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw StockHistoryError.invalid("无法分配拼接图像内存")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else { throw StockHistoryError.invalid("无法复制拼接图像") }
    return result
  }

  static func textImage(_ image: CGImage) throws -> CGImage {
    let size = image.width * image.height
    var bytes = [UInt8](repeating: 0, count: size)
    return try bytes.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        throw StockHistoryError.invalid("无法创建文字识别图像")
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let pixels = buffer.bindMemory(to: UInt8.self)
      for index in 0..<size { pixels[index] = UInt8(min(255, Int(pixels[index]) * 255 / 210)) }
      guard let result = context.makeImage() else { throw StockHistoryError.invalid("无法生成文字识别图像") }
      return result
    }
  }

  static func recognize(_ image: UIImage, progress: @escaping (String) -> Void = { _ in }) throws -> [StockTextLine] {
    guard let cg = image.cgImage else { throw StockHistoryError.invalid("无法读取截图像素") }
    let recognitionImage = try textImage(cg)
    var cells: [StockOCRCell] = []
    var stockColumnStart: CGFloat?
    // 对长图分块识别，用中心点归属消除块边缘重复；不按文本去重，保留真实重复行。
    let block = 1800
    let margin = 120
    for start in stride(from: 0, to: cg.height, by: block) {
      try autoreleasepool {
        let top = max(0, start - margin)
        let bottom = min(cg.height, start + block + margin)
        progress("正在识别文字 · \(start / block + 1)/\((cg.height + block - 1) / block)")
        guard let tile = recognitionImage.cropping(to: CGRect(x: 0, y: top, width: cg.width, height: bottom - top)) else {
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
          // 斜向水印不属于表格文字；保留横向的品名、编码与数量。
          let dx = observation.topRight.x - observation.topLeft.x
          let dy = observation.topRight.y - observation.topLeft.y
          if abs(dy) * Double(tile.height) > abs(dx) * Double(tile.width) * 0.25 { continue }
          let bounds = observation.boundingBox
          let rect = CGRect(x: bounds.minX * Double(cg.width),
            y: Double(top) + (1 - bounds.maxY) * Double(bottom - top),
            width: bounds.width * Double(cg.width), height: bounds.height * Double(bottom - top))
          if rect.midY >= Double(start) && rect.midY < Double(min(cg.height, start + block)) {
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StockHistoryError.invalid("识别到空文字，请检查截图") }
            if text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).contains("实盘总库存") {
              stockColumnStart = rect.midX - rect.height * 0.75
            }
            // Vision 可能把同一高度的品名续行和库存合并。根据字符间真实空白拆列，
            // 不能按字符串中的数字拆分，规格本身也包含数字。
            let original = candidate.string
            var ranges = [original.startIndex..<original.endIndex]
            if let column = stockColumnStart, rect.minX < column, rect.maxX > column {
              var characters: [(Range<String.Index>, CGRect)] = []
              for index in original.indices where !original[index].isWhitespace {
                let range = index..<original.index(after: index)
                guard let character = try candidate.boundingBox(for: range) else {
                  throw StockHistoryError.invalid("无法定位识别文字的列边界")
                }
                let box = character.boundingBox
                characters.append((range, CGRect(x: box.minX * Double(cg.width), y: 0,
                  width: box.width * Double(cg.width), height: box.height * Double(bottom - top))))
              }
              ranges = StockTableParser.splitColumnGap(original, characters: characters, stockColumnStart: column)
            }
            for range in ranges {
              guard let observation = try candidate.boundingBox(for: range) else {
                throw StockHistoryError.invalid("无法定位识别文字")
              }
              let box = observation.boundingBox
              let part = String(original[range]).trimmingCharacters(in: .whitespacesAndNewlines)
              guard !part.isEmpty else { throw StockHistoryError.invalid("识别文字分列后为空") }
              cells.append(StockOCRCell(text: part, confidence: Double(candidate.confidence),
                box: CGRect(x: box.minX * Double(cg.width),
                  y: Double(top) + (1 - box.maxY) * Double(bottom - top),
                  width: box.width * Double(cg.width), height: box.height * Double(bottom - top))))
            }
          }
        }
      }
    }
    guard let header = cells.first(where: {
      $0.text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).contains("实盘总库存")
    }) else { throw StockHistoryError.invalid("未识别到实盘总库存表头") }
    // 单独识别库存列，避免横跨两列的长文字吞掉短数量。保留完整品名识别，
    // 右列裁剪从表头中心略向左开始；该页面的数量统一左对齐。
    let columnX = Int((header.box.midX - header.box.height * 0.75).rounded(.down))
    guard columnX > 0, columnX < cg.width else { throw StockHistoryError.invalid("库存列位置无效") }
    cells.removeAll { $0.box.minX >= header.box.minX && $0.box.midY > header.box.maxY }
    for start in stride(from: 0, to: cg.height, by: block) {
      try autoreleasepool {
        let top = max(0, start - margin)
        let bottom = min(cg.height, start + block + margin)
        progress("正在识别库存列 · \(start / block + 1)/\((cg.height + block - 1) / block)")
        guard let tile = recognitionImage.cropping(to: CGRect(x: columnX, y: top,
          width: cg.width - columnX, height: bottom - top)) else {
          throw StockHistoryError.invalid("无法读取库存列")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
        guard let results = request.results else { throw StockHistoryError.invalid("库存识别未返回结果") }
        for observation in results {
          guard let candidate = observation.topCandidates(1).first else {
            throw StockHistoryError.invalid("库存识别候选为空")
          }
          let dx = observation.topRight.x - observation.topLeft.x
          let dy = observation.topRight.y - observation.topLeft.y
          if abs(dy) * Double(tile.height) > abs(dx) * Double(tile.width) * 0.25 { continue }
          let box = observation.boundingBox
          let rect = CGRect(x: Double(columnX) + box.minX * Double(tile.width),
            y: Double(top) + (1 - box.maxY) * Double(tile.height),
            width: box.width * Double(tile.width), height: box.height * Double(tile.height))
          if rect.midY >= Double(start), rect.midY < Double(min(cg.height, start + block)),
            rect.midY > header.box.maxY {
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StockHistoryError.invalid("库存识别文字为空") }
            cells.append(StockOCRCell(text: text, confidence: Double(candidate.confidence), box: rect))
          }
        }
      }
    }
    return try StockTableParser.rows(cells) { start, end in
      progress("正在放大复核未识别的库存行")
      let crop = CGRect(x: CGFloat(columnX), y: max(0, start.rounded(.down)),
        width: CGFloat(cg.width - columnX),
        height: min(CGFloat(cg.height), end.rounded(.up)) - max(0, start.rounded(.down)))
      // 短行单独放大，避开分块边缘和下面的预制物料表。只有该行真实 OCR
      // 返回数字才接受；识别仍失败则继续抛错，不把缺失库存当作 0。
      for (source, scale) in [(recognitionImage, 2), (cg, 2), (recognitionImage, 4)] {
        let recovered = try inventoryRow(source, crop: crop, scale: scale)
        if recovered.contains(where: { $0.text.range(of: "[0-9]", options: .regularExpression) != nil }) {
          return recovered
        }
      }
      throw StockHistoryError.invalid("库存行放大识别仍未读到数量（长图纵向位置 \(Int(start))～\(Int(min(end, CGFloat(cg.height))))），请核对原始长图")
    }

  }

  static func inventoryRow(_ source: CGImage, crop: CGRect, scale: Int) throws -> [StockOCRCell] {
    guard (1...4).contains(scale), crop.width > 0, crop.height > 0,
      crop.minX >= 0, crop.minY >= 0,
      crop.maxX <= CGFloat(source.width), crop.maxY <= CGFloat(source.height),
      let tile = source.cropping(to: crop),
      let context = CGContext(data: nil, width: tile.width * scale, height: tile.height * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
      throw StockHistoryError.invalid("无法放大库存行")
    }
    context.interpolationQuality = .high
    context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width * scale, height: tile.height * scale))
    guard let enlarged = context.makeImage() else { throw StockHistoryError.invalid("无法生成库存行识别图") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: enlarged, options: [:]).perform([request])
    guard let results = request.results else { throw StockHistoryError.invalid("库存行识别未返回结果") }
    return try results.compactMap { observation in
      let dx = observation.topRight.x - observation.topLeft.x
      let dy = observation.topRight.y - observation.topLeft.y
      if abs(dy) * Double(enlarged.height) > abs(dx) * Double(enlarged.width) * 0.25 { return nil }
      guard let candidate = observation.topCandidates(1).first else {
        throw StockHistoryError.invalid("库存行识别候选为空")
      }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw StockHistoryError.invalid("库存行识别文字为空") }
      let box = observation.boundingBox
      return StockOCRCell(text: text, confidence: Double(candidate.confidence),
        box: CGRect(x: crop.minX + box.minX * CGFloat(tile.width),
          y: crop.minY + (1 - box.maxY) * CGFloat(tile.height),
          width: box.width * CGFloat(tile.width), height: box.height * CGFloat(tile.height)))
    }
  }
}

final class StockHistoryBridge: NSObject, PHPickerViewControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var video = true
  private var crop = StockCrop.automatic
  private var processingView: StockImportProgressView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.luckinstocktaking/history", binaryMessenger: messenger)
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(historyReady),
      name: StockHistoryStorage.readyNotification, object: nil)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "HISTORY_UNAVAILABLE", message: "历史服务不可用", details: nil)); return
      }
      self.handle(call, result: result)
    }
  }
  deinit {
    NotificationCenter.default.removeObserver(self)

  }
  @objc private func historyReady() {
    guard UIApplication.shared.applicationState == .active else { return }
    channel.invokeMethod("historyReady", arguments: nil)
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "import" {
      guard pending == nil, let arguments = call.arguments as? [String: Any],
        let video = arguments["video"] as? Bool else {
        result(FlutterError(code: "INVALID_IMPORT", message: "导入参数无效或已有导入任务", details: nil)); return
      }
      let crop = StockCrop.automatic
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
        case "pending": value = try StockHistoryStorage.pendingDocument()
        case "table":
          guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
          let url = try StockHistoryStorage.directory(id).appendingPathComponent("record.json")
          let original = try JSONDecoder().decode(StockHistoryDocument.self, from: Data(contentsOf: url))
          try original.validate()
          guard original.id == id else { throw StockHistoryError.invalid("盘点单标识不一致") }
          if original.schemaVersion == 2 { value = try original.json() }
          else {
            guard let image = UIImage(data: try StockHistoryStorage.image(id)) else {
              throw StockHistoryError.invalid("历史长图无法读取")
            }
            let rows = try StockHistoryProcessor.recognize(image)
            let table = StockHistoryDocument(schemaVersion: 2, id: original.id, title: original.title,
              createdAt: original.createdAt, imageName: original.imageName, lines: rows, reviewed: false)
            let backup = url.deletingLastPathComponent().appendingPathComponent("legacy-recognized-lines.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
              try JSONEncoder().encode(original).write(to: backup, options: .atomic)
            }
            try StockHistoryStorage.save(table.json())
            value = try table.json()
          }
        case "list": value = try StockHistoryStorage.list()
        case "save":
          guard let json = call.arguments as? String else { throw StockHistoryError.invalid("盘点单必须为 JSON 文本") }
          try StockHistoryStorage.save(json); value = nil
        case "image":
          guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
          value = FlutterStandardTypedData(bytes: try StockHistoryStorage.image(id))
        case "imageTiles":
          guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
          value = try StockHistoryStorage.imageTiles(id).map { FlutterStandardTypedData(bytes: $0) }
        case "delete":
          guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
          try StockHistoryStorage.delete(id); value = nil
        default: value = FlutterMethodNotImplemented
        }
        DispatchQueue.main.async {
          result(value)
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
            self.process(local)
          }
        } catch { DispatchQueue.main.async { self.finish(nil, error: error) } }
      }
    }
  }
  private func process(_ url: URL) {
    let video = self.video, crop = self.crop
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
      let presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
      cleanup(url, value: nil, error: StockHistoryError.invalid("无法显示导入进度")); return
    }
    let controller = StockImportProgressView()
    processingView = controller
    presenter.present(controller, animated: true) {
      StockHistoryStorage.queue.async {
        do {
          let document = try StockHistoryProcessor.process(url: url, video: video, crop: crop) { text in
            DispatchQueue.main.async { self.processingView?.update(text) }
          }
          let json = try document.json()
          DispatchQueue.main.async { self.cleanup(url, value: json) }
        } catch { DispatchQueue.main.async { self.cleanup(url, value: nil, error: error) } }
      }
    }
  }
  private func cleanup(_ url: URL, value: String?, error: Error? = nil) {
    let finalError: Error?
    do { try FileManager.default.removeItem(at: url); finalError = error }
    catch { finalError = error }
    if let controller = processingView {
      processingView = nil
      controller.dismiss(animated: true) { self.finish(value, error: finalError) }
    } else { finish(value, error: finalError) }
  }
}

final class StockImportProgressView: UIViewController {
  private let label = UILabel()
  init() {
    super.init(nibName: nil, bundle: nil)
    isModalInPresentation = true
  }
  required init?(coder: NSCoder) { fatalError("不支持 storyboard 初始化") }
  func update(_ text: String) { label.text = "\(text)\n\n请保持助手打开，完成后自动显示盘点单。" }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.startAnimating()
    label.numberOfLines = 0; label.textAlignment = .center
    update("正在读取录屏")
    let stack = UIStackView(arrangedSubviews: [spinner, label])
    stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
    ])
  }
}
