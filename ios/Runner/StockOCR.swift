import Foundation
import CoreGraphics
import Vision
import OnnxRuntimeBindings
import Darwin

enum StockOCREngine: String, CaseIterable, Codable {
  case vision, paddleTiny = "paddle_tiny", paddleSmall = "paddle_small"
  var folder: String { self == .paddleTiny ? "tiny" : "small" }
  static func selected() throws -> StockOCREngine {
    guard let raw = UserDefaults.standard.string(forKey: "stock.ocr.engine") else { return .vision }
    guard let value = Self(rawValue: raw) else { throw StockHistoryError.invalid("已保存的识别模型无效") }
    return value
  }
}

struct StockOCRMetrics: Codable {
  let elapsedMs: Double
  let modelLoadMs: Double
  let ocrCalls: Int
  let processedPixels: Int64
  let modelBytes: Int64
  let residentBytes: UInt64
  let imageSHA256: String
  let policyRevision: Int
}

struct StockOCREvaluationRun: Codable {
  let engine: StockOCREngine
  let document: StockHistoryDocument
  let metrics: StockOCRMetrics
  let evaluatedAt: String
}

final class StockOCRContext: NSObject {
  let engine: StockOCREngine
  var calls = 0
  var pixels: Int64 = 0
  var loadSeconds: Double = 0
  init(_ engine: StockOCREngine) { self.engine = engine }
}

struct StockOCRRegion {
  let boundingBox: CGRect
  let topLeft: CGPoint
  let topRight: CGPoint
}

/// 模型输出统一成规范化坐标。Paddle 字符位置来自 CTC 时间步，不按字数均分。
final class StockOCRText {
  let string: String
  let confidence: Float
  private let vision: VNRecognizedText?
  private let polygon: [CGPoint]
  private let spans: [(Range<Int>, CGFloat, CGFloat)]
  init(vision: VNRecognizedText) {
    self.vision = vision; string = vision.string; confidence = vision.confidence
    polygon = []; spans = []
  }
  init(string: String, confidence: Float, polygon: [CGPoint], spans: [(Range<Int>, CGFloat, CGFloat)]) {
    self.string = string; self.confidence = confidence; self.polygon = polygon; self.spans = spans
    vision = nil
  }
  func boundingBox(for range: Range<String.Index>) throws -> StockOCRRegion? {
    if let vision = vision {
      guard let box = try vision.boundingBox(for: range) else { return nil }
      return StockOCRRegion(boundingBox: box.boundingBox, topLeft: box.topLeft, topRight: box.topRight)
    }
    guard polygon.count == 4, !range.isEmpty else { throw StockHistoryError.invalid("模型字符坐标无效") }
    let first = string.distance(from: string.startIndex, to: range.lowerBound)
    let last = string.distance(from: string.startIndex, to: range.upperBound)
    let parts = spans.filter { $0.0.overlaps(first..<last) }
    guard !parts.isEmpty else { throw StockHistoryError.invalid("模型未返回对应字符的 CTC 位置") }
    let full = range == (string.startIndex..<string.endIndex)
    let left = full ? 0 : parts.map { $0.1 }.min()!
    let right = full ? 1 : parts.map { $0.2 }.max()!
    func along(_ a: CGPoint, _ b: CGPoint, _ position: CGFloat) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * position, y: a.y + (b.y - a.y) * position)
    }
    let points = [along(polygon[0], polygon[1], left), along(polygon[0], polygon[1], right),
      along(polygon[3], polygon[2], right), along(polygon[3], polygon[2], left)]
    return StockOCRRegion(boundingBox: StockPaddleGeometry.bounds(points), topLeft: points[0], topRight: points[1])
  }
}

struct StockOCRObservation {
  let boundingBox: CGRect
  let topLeft: CGPoint
  let topRight: CGPoint
  let candidates: [StockOCRText]
  func topCandidates(_ count: Int) -> [StockOCRText] { Array(candidates.prefix(count)) }
}

enum StockOCR {
  private static let contextKey = "stock.ocr.context"
  private static var paddle: StockPaddleRuntime?
  private static let runtimeLock = NSRecursiveLock()
  static var context: StockOCRContext? { Thread.current.threadDictionary[contextKey] as? StockOCRContext }
  static func withEngine<T>(_ engine: StockOCREngine, operation: () throws -> T) rethrows -> (T, StockOCRContext, Double) {
    runtimeLock.lock()
    defer { runtimeLock.unlock() }
    paddle = nil // 对比任务统一重新加载 Paddle 会话，避免评估顺序影响加载耗时。
    let previous = Thread.current.threadDictionary[contextKey]
    let context = StockOCRContext(engine)
    Thread.current.threadDictionary[contextKey] = context
    defer {
      if let previous = previous { Thread.current.threadDictionary[contextKey] = previous }
      else { Thread.current.threadDictionary.removeObject(forKey: contextKey) }
    }
    let start = ProcessInfo.processInfo.systemUptime
    let value = try operation()
    return (value, context, (ProcessInfo.processInfo.systemUptime - start) * 1000)
  }
  static func modelBytes(_ engine: StockOCREngine) throws -> Int64 {
    if engine == .vision { return 0 }
    var size: Int64 = 0
    for role in ["det", "rec"] {
      let url = try modelURL(engine, role: role, file: "inference.onnx")
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let bytes = attributes[.size] as? NSNumber else { throw StockHistoryError.invalid("模型文件大小缺失") }
      size += bytes.int64Value
    }
    return size
  }
  static func prepare(_ engine: StockOCREngine) throws {
    runtimeLock.lock()
    defer { runtimeLock.unlock() }
    if engine == .vision { paddle = nil; return }
    if paddle?.engine != engine {
      paddle = nil
      paddle = try StockPaddleRuntime(engine: engine)
    }
  }
  static func modelURL(_ engine: StockOCREngine, role: String, file: String) throws -> URL {
    guard engine != .vision, let root = Bundle.main.resourceURL else { throw StockHistoryError.invalid("模型资源目录无效") }
    let url = root.appendingPathComponent("OCRModels/\(engine.folder)/\(role)/\(file)")
    guard FileManager.default.fileExists(atPath: url.path) else { throw StockHistoryError.invalid("缺少 \(engine.rawValue) 模型资源：\(file)，请重新安装完整版本") }
    return url
  }
  static func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard code == KERN_SUCCESS else { throw StockHistoryError.invalid("无法获取识别进程内存：\(code)") }
    return UInt64(info.resident_size)
  }
  static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel = .accurate,
    minimumTextHeight: Float = 0) throws -> [StockOCRObservation] {
    runtimeLock.lock()
    defer { runtimeLock.unlock() }
    let engine = try context?.engine ?? StockOCREngine.selected()
    context?.calls += 1; context?.pixels += Int64(image.width) * Int64(image.height)
    if engine == .vision {
      paddle = nil
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = level
      request.recognitionLanguages = level == .fast ? ["en-US"] : ["zh-Hans", "en-US"]
      request.usesLanguageCorrection = false
      request.minimumTextHeight = minimumTextHeight
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      guard let results = request.results else { throw StockHistoryError.invalid("Vision 未返回识别结果") }
      return results.map { item in StockOCRObservation(boundingBox: item.boundingBox,
        topLeft: item.topLeft, topRight: item.topRight, candidates: item.topCandidates(5).map { StockOCRText(vision: $0) }) }
    }
    if paddle?.engine != engine {
      paddle = nil // 切换模型释放旧会话，不同时驻留两套权重。
      let start = ProcessInfo.processInfo.systemUptime
      paddle = try StockPaddleRuntime(engine: engine)
      context?.loadSeconds += ProcessInfo.processInfo.systemUptime - start
    }
    guard let runtime = paddle else { throw StockHistoryError.invalid("Paddle 模型会话未初始化") }
    return try runtime.recognize(image, minimumTextHeight: minimumTextHeight)
  }
}

final class StockPaddleRuntime {
  let engine: StockOCREngine
  private static var environment: ORTEnv?
  private let detection: ORTSession
  private let recognition: ORTSession
  private let dictionary: [String]
  init(engine: StockOCREngine) throws {
    self.engine = engine
    if Self.environment == nil { Self.environment = try ORTEnv(loggingLevel: .warning) }
    guard let env = Self.environment else { throw StockHistoryError.invalid("ONNX 运行环境未初始化") }
    let options = try ORTSessionOptions()
    try options.setGraphOptimizationLevel(.all)
    try options.setIntraOpNumThreads(2)
    detection = try ORTSession(env: env, modelPath: StockOCR.modelURL(engine, role: "det", file: "inference.onnx").path, sessionOptions: options)
    recognition = try ORTSession(env: env, modelPath: StockOCR.modelURL(engine, role: "rec", file: "inference.onnx").path, sessionOptions: options)
    let data = try Data(contentsOf: StockOCR.modelURL(engine, role: "rec", file: "config.json"))
    guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let post = config["PostProcess"] as? [String: Any], let chars = post["character_dict"] as? [String], !chars.isEmpty else {
      throw StockHistoryError.invalid("Paddle 字符字典缺失")
    }
    dictionary = [""] + chars + [" "]
  }
  private func infer(_ session: ORTSession, values: [Float], shape: [Int]) throws -> ([Float], [Int]) {
    let inputs = try session.inputNames(); let outputs = try session.outputNames()
    guard inputs.count == 1, outputs.count == 1, shape.reduce(1, *) == values.count else {
      throw StockHistoryError.invalid("ONNX 模型输入输出契约无效")
    }
    let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let tensor = try ORTValue(tensorData: bytes, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    let result = try session.run(withInputs: [inputs[0]: tensor], outputNames: Set(outputs), runOptions: nil)
    guard let output = result[outputs[0]] else { throw StockHistoryError.invalid("ONNX 模型没有返回输出张量") }
    let metadata = try output.tensorTypeAndShapeInfo()
    let dimensions = metadata.shape.map { $0.intValue }
    let data = try output.tensorData() as Data
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard dimensions.allSatisfy({ $0 > 0 }), dimensions.reduce(1, *) == floats.count,
      floats.allSatisfy(\.isFinite) else { throw StockHistoryError.invalid("ONNX 输出形状或数值无效") }
    return (floats, dimensions)
  }
  /// 使用相同 DB 阈值、归一化和 CTC 解码，tiny/small 仅权重与字典不同。
  func recognize(_ image: CGImage, minimumTextHeight: Float) throws -> [StockOCRObservation] {
    let scale = min(1, 1536 / Double(max(image.width, image.height)))
    let width = max(32, Int((Double(image.width) * scale / 32).rounded()) * 32)
    let height = max(32, Int((Double(image.height) * scale / 32).rounded()) * 32)
    let input = try pixels(image, width: width, height: height, detector: true)
    let (probabilities, shape) = try infer(detection, values: input, shape: [1, 3, height, width])
    guard shape.count == 4, shape[0] == 1, shape[1] == 1 else { throw StockHistoryError.invalid("Paddle 检测输出应为 [1,1,H,W]") }
    let boxes = try StockPaddleGeometry.detect(probabilities, width: shape[3], height: shape[2])
    return try boxes.compactMap { normalized -> StockOCRObservation? in
      let region = StockPaddleGeometry.bounds(normalized)
      if region.height < CGFloat(minimumTextHeight) { return nil }
      return try autoreleasepool {
        let topPoints = normalized.map { CGPoint(x: $0.x * CGFloat(image.width), y: (1 - $0.y) * CGFloat(image.height)) }
        let line = try StockPaddleGeometry.crop(image, polygon: topPoints)
        let resized = max(1, Int(ceil(48 * Double(line.width) / Double(line.height))))
        guard resized <= 3200 else { throw StockHistoryError.invalid("单行文字过长，请检查检测区域") }
        let canvas = max(320, (resized + 7) / 8 * 8)
        let tensor = try pixels(line, width: resized, height: 48, detector: false, canvasWidth: canvas)
        let (scores, dimensions) = try infer(recognition, values: tensor, shape: [1, 3, 48, canvas])
        guard dimensions.count == 3, dimensions[0] == 1, dimensions[2] == dictionary.count else {
          throw StockHistoryError.invalid("Paddle 识别输出与字符字典不一致")
        }
        let decoded = try Self.decode(scores, steps: dimensions[1], dictionary: dictionary,
          widthRatio: CGFloat(canvas) / CGFloat(resized))
        if decoded.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let candidate = StockOCRText(string: decoded.0, confidence: decoded.1, polygon: normalized, spans: decoded.2)
        return StockOCRObservation(boundingBox: region, topLeft: normalized[0], topRight: normalized[1], candidates: [candidate])
      }
    }
  }
  static func decode(_ values: [Float], steps: Int, dictionary: [String], widthRatio: CGFloat)
    throws -> (String, Float, [(Range<Int>, CGFloat, CGFloat)]) {
    guard steps > 0, dictionary.count > 1, dictionary[0].isEmpty,
      values.count == steps * dictionary.count, widthRatio.isFinite, widthRatio >= 1,
      values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw StockHistoryError.invalid("CTC 输出无效")
    }
    var previous = 0; var text = ""; var confidence: Float = 0
    var spans: [(Range<Int>, CGFloat, CGFloat)] = []
    var offset = 0
    var activeSpan: Int?
    for step in 0..<steps {
      let base = step * dictionary.count
      var best = 0
      for index in 1..<dictionary.count where values[base + index] > values[base + best] { best = index }
      let score = values[base + best]
      guard score.isFinite, (0...1).contains(score) else { throw StockHistoryError.invalid("CTC 置信度不是有效概率") }
      if best != 0 && best != previous {
        activeSpan = nil
        let token = dictionary[best]
        let start = min(1, CGFloat(step) / CGFloat(steps) * widthRatio)
        let end = min(1, CGFloat(step + 1) / CGFloat(steps) * widthRatio)
        if start < end {
          spans.append((offset..<(offset + token.count), start, end))
          text += token; offset += token.count; confidence += score
          activeSpan = spans.count - 1
        }
      } else if best != 0, let last = activeSpan {
        spans[last].2 = min(1, CGFloat(step + 1) / CGFloat(steps) * widthRatio)
      }
      previous = best
      if best == 0 { activeSpan = nil }
    }
    return (text, spans.isEmpty ? 0 : confidence / Float(spans.count), spans)
  }
  private func pixels(_ image: CGImage, width: Int, height: Int, detector: Bool, canvasWidth: Int? = nil) throws -> [Float] {
    let canvas = canvasWidth ?? width
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    try rgba.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw StockHistoryError.invalid("无法生成模型图像输入")
      }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var result = [Float](repeating: 0, count: 3 * canvas * height)
    let mean: [Float] = [0.485, 0.456, 0.406]; let std: [Float] = [0.229, 0.224, 0.225]
    for channel in 0..<3 {
      for y in 0..<height { for x in 0..<width {
        let value = Float(rgba[(y * width + x) * 4 + 2 - channel]) / 255 // 官方模型输入 BGR
        result[channel * canvas * height + y * canvas + x] = detector ? (value - mean[channel]) / std[channel] : (value - 0.5) / 0.5
      } }
    }
    return result
  }
}
