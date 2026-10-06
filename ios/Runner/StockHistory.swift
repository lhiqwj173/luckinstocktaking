import AVFoundation
import Flutter
import PhotosUI
import Photos
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
  var inventoryUncertain: Bool? = nil
  var category: String? = nil
}

struct StockOCRCell {
  let text: String
  let confidence: Double
  let box: CGRect
}

enum StockOCRRefinement {
  static func canonicalProductCode(_ text: String) -> String? {
    let value = compact(text).uppercased().replacingOccurrences(of: "－", with: "-")
      .replacingOccurrences(of: "—", with: "-")
    guard value.range(of: "^GS[0-9]{4,8}-[0-9]{2,3}$", options: .regularExpression) != nil else { return nil }
    return value
  }
  static func compact(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
  }
  static func coalesce(_ cells: [StockOCRCell]) -> [StockOCRCell] {
    let pattern = "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}"
    var output: [StockOCRCell] = []
    var groups: [String: [Int]] = [:]
    for cell in cells {
      precondition(cell.box.width > 0 && cell.box.height > 0, "识别文字区域必须非空")
      let text = compact(cell.text)
      let code = text.range(of: pattern, options: .regularExpression).map { String(text[$0]).uppercased() }
      let key = code.map { "code:\($0)" } ?? "text:\(text)"
      let duplicate = (groups[key] ?? []).first { index in
        let other = output[index]
        let otherText = compact(other.text)
        // 仅合并同一像素区域的重复结果；不同位置的相同货号仍是两个真实条目。
        guard text == otherText || (code != nil &&
          (text.uppercased() == code || otherText.uppercased() == code)) else { return false }
        let intersection = cell.box.intersection(other.box)
        guard !intersection.isNull else { return false }
        let area = min(cell.box.width * cell.box.height, other.box.width * other.box.height)
        return intersection.width * intersection.height / area >= 0.6
      }
      if let index = duplicate {
        let other = output[index]
        let otherText = compact(other.text)
        if text.count > otherText.count || (text.count == otherText.count && cell.confidence > other.confidence) {
          output[index] = cell
        }
      } else {
        groups[key, default: []].append(output.count)
        output.append(cell)
      }
    }
    return output
  }
  static func match(_ original: StockOCRCell, in candidates: [StockOCRCell]) -> StockOCRCell? {
    let area = original.box.width * original.box.height
    precondition(area > 0, "复识别原始文字区域必须非空")
    return candidates.filter { candidate in
      let intersection = original.box.intersection(candidate.box)
      guard !intersection.isNull else { return false }
      let overlap = intersection.width * intersection.height
      let candidateArea = candidate.box.width * candidate.box.height
      return overlap / area >= 0.6 && overlap / candidateArea >= 0.6
    }.max { $0.confidence < $1.confidence }
  }
  static func resolve(_ original: StockOCRCell, raw: StockOCRCell?, clean: StockOCRCell?,
    inventory: Bool) -> StockOCRCell {
    guard let raw = raw, let clean = clean,
      compact(raw.text) == compact(clean.text),
      min(raw.confidence, clean.confidence) > original.confidence + 0.05 else { return original }
    let text = compact(raw.text)
    if inventory {
      guard text.range(of: "[0-9]", options: .regularExpression) != nil else { return original }
    } else if compact(original.text).range(of: "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}",
      options: .regularExpression) != nil {
      guard compact(original.text).range(of: "^[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}$",
        options: .regularExpression) != nil else { return original }
      guard text.range(of: "^[Gg][Ss][0-9]{4,8}[-－—][0-9]{2,3}$",
        options: .regularExpression) != nil else { return original }
    }
    // 只采用两次真实识别中较低的评分，不人为加分；坐标仍用于原来的行配对。
    return StockOCRCell(text: raw.text, confidence: min(raw.confidence, clean.confidence), box: original.box)
  }
}

enum StockTableParser {
  static func preparedHeaders(_ cells: [StockOCRCell]) -> (name: StockOCRCell, stock: StockOCRCell)? {
    let names = cells.filter { StockOCRRefinement.compact($0.text).contains("预制物料名称") }
      .sorted { $0.box.minY < $1.box.minY }
    for name in names {
      if let stock = cells.first(where: {
        StockOCRRefinement.compact($0.text).contains("实盘总库存") &&
          $0.box.minX > name.box.maxX &&
          abs($0.box.midY - name.box.midY) <= max($0.box.height, name.box.height)
      }) {
        return (name, stock)
      }
    }
    return nil
  }

  /// 预制物料没有 GS 货号，以完整的制作/处理名称为行锚点，仍按像素位置配对库存。
  static func preparedRows(_ cells: [StockOCRCell],
    retryInventory: ((CGFloat, CGFloat, CGFloat) throws -> [StockOCRCell]?)? = nil) throws -> [StockTextLine] {
    let ordered = StockOCRRefinement.coalesce(cells).sorted {
      $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY
    }
    guard let headers = preparedHeaders(ordered) else {
      throw StockHistoryError.invalid("未能完整识别预制物料表头，请重试导入")
    }
    let nameHeader = headers.name
    let stockHeader = headers.stock
    let top = max(nameHeader.box.maxY, stockHeader.box.maxY)
    let bottom = ordered.first(where: { cell in
      cell.box.minY > top && ["其他信息", "其它信息", "历史记录"].contains { label in
        StockOCRRefinement.compact(cell.text).contains(label)
      }
    })?.box.minY ?? .greatestFiniteMagnitude
    let boundary = (nameHeader.box.maxX + stockHeader.box.minX) / 2
    // 预制输入框的数字可在货物库存列起点左侧；用预制表头自身定位，保留左侧空白。
    let quantityLeft = max(boundary, stockHeader.box.minX - stockHeader.box.height)
    let body = ordered.filter { $0.box.midY > top && $0.box.midY < bottom }
    var names: [[StockOCRCell]] = []
    var current: [StockOCRCell] = []
    for cell in body where cell.box.minX < boundary {
      // 分列失败时数量框数字、单位或水印残留可能留在名称列；它们不属于名称，
      // 不能参与行划分，也不能触发跨行缺字判断。
      if isStrayPreparedCell(cell) { continue }
      if let previous = current.last,
        cell.box.minY - previous.box.maxY > max(previous.box.height, cell.box.height) * 1.25 {
        throw StockHistoryError.invalid("预制物料名称缺少制作/处理尾字，不能与下一行合并，请核对原图")
      }
      current.append(cell)
      let name = StockOCRRefinement.compact(current.map(\.text).joined())
      if let length = preparedNameLength(name) {
        // 尾字后误并入的数量、单位或水印字符不计入名称。
        names.append(truncate(current, to: length))
        current = []
      }
    }
    guard !names.isEmpty, current.isEmpty else {
      throw StockHistoryError.invalid("预制物料名称不完整，无法可靠划分行，请核对原图")
    }
    return try names.enumerated().map { index, parts in
      let start = index == 0 ? top :
        (names[index - 1].map { $0.box.maxY }.max()! + parts.map { $0.box.minY }.min()!) / 2
      let end = index + 1 == names.count ? bottom :
        (parts.map { $0.box.maxY }.max()! + names[index + 1].map { $0.box.minY }.min()!) / 2
      var stocks = body.filter { $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end }
      #if DEBUG
      let rowName = StockOCRRefinement.compact(parts.map(\.text).joined())
      print("[StockOCR] 预制行 name=\(rowName) start=\(start) end=\(end) boundary=\(boundary) quantityLeft=\(quantityLeft) initial=\(stocks.map { "\($0.text)@\($0.box)" })")
      #endif
      if let retry = retryInventory, let recovered = try retry(start, end, quantityLeft) {
        stocks = recovered.filter {
          $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end
        }
        #if DEBUG
        print("[StockOCR] 预制复核配对 name=\(rowName) recovered=\(recovered.map { "\($0.text)@\($0.box)" }) retained=\(stocks.map { "\($0.text)@\($0.box)" })")
        #endif
      }
      // 数量和单位来自同一物料行的输入框，按水平方向读取，不能按基线的细微高低排序。
      stocks.sort { $0.box.minX == $1.box.minX ? $0.box.midY < $1.box.midY : $0.box.minX < $1.box.minX }
      let text = stocks.map(\.text).joined()
      return StockTextLine(cells: [parts.map(\.text).joined(separator: "\n"), text],
        confidence: (parts + stocks).map(\.confidence).min()!,
        inventoryUncertain: stocks.isEmpty || (!blankInventory(text) &&
          text.range(of: "[0-9]", options: .regularExpression) == nil), category: "prepared")
    }
  }

  /// 分列失败时，数量框数字、单位或斜向水印残留会落在名称列；它们不可能是预制名称。
  static func isStrayPreparedCell(_ cell: StockOCRCell) -> Bool {
    let text = StockOCRRefinement.compact(cell.text)
    return text.range(of: "^[A-Za-z0-9.]+$", options: .regularExpression) != nil ||
      ["个", "毫升", "克"].contains(text)
  }

  /// 预制名称必须以「预制作」或「预处理」收尾；尾字后若只剩数量、单位或水印字符，
  /// 说明是输入框或水印误并入，按尾字截断即可。返回名称在紧缩文本中的长度。
  static func preparedNameLength(_ name: String) -> Int? {
    for suffix in ["预制作", "预处理"] {
      guard let range = name.range(of: suffix, options: .backwards) else { continue }
      let tail = String(name[range.upperBound...])
      if tail.isEmpty || tail.range(of: "^[0-9A-Za-z.]*(?:个|毫升|克)?$",
        options: .regularExpression) != nil {
        return name.distance(from: name.startIndex, to: range.upperBound)
      }
    }
    return nil
  }

  /// 按紧缩文本长度裁剪累积的名称单元格，剥离尾字后误并入的字符；坐标保持原样。
  static func truncate(_ cells: [StockOCRCell], to length: Int) -> [StockOCRCell] {
    var remaining = length
    var output: [StockOCRCell] = []
    for cell in cells {
      if remaining <= 0 { break }
      let compact = StockOCRRefinement.compact(cell.text)
      if compact.count <= remaining {
        output.append(cell)
        remaining -= compact.count
        continue
      }
      var kept = ""
      var count = 0
      for character in cell.text {
        if !character.isWhitespace { count += 1 }
        if count > remaining { break }
        kept.append(character)
      }
      let text = kept.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        output.append(StockOCRCell(text: text, confidence: cell.confidence, box: cell.box))
      }
      remaining = 0
    }
    return output
  }

  static func blankInventory(_ text: String) -> Bool {
    let value = text.replacingOccurrences(of: "\\s+|总库存[:：·;；]?|冷藏[:：·;；]?|冷冻[:：·;；]?", with: "", options: .regularExpression)
    return value.isEmpty || value.range(of: "^(?:[-－—一]+[\\p{Han}A-Za-z]{0,3})+$", options: .regularExpression) != nil
  }
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
    retryName: ((CGFloat, CGFloat, CGFloat) throws -> [StockOCRCell]?)? = nil,
    retryInventory: ((CGFloat, CGFloat) throws -> [StockOCRCell])? = nil) throws -> [StockTextLine] {
    let ordered = StockOCRRefinement.coalesce(cells).sorted {
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
    let codeExpression = try NSRegularExpression(pattern: code)
    var names: [[StockOCRCell]] = []
    var current: [StockOCRCell] = []
    for cell in left {
      let anchors = codeExpression.matches(in: compact(cell.text),
        range: NSRange(location: 0, length: (compact(cell.text) as NSString).length))
      guard anchors.count <= 1 else {
        throw StockHistoryError.invalid("同一文字块包含多个货号，不能合并货物行，请核对原图")
      }
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
      var nameParts = parts
      let name = parts.map(\.text).joined(separator: "\n")
      let missingSpecification = name.range(of: "饮料|饮品|咖啡豆|调味酱|蛋糕|面包", options: .regularExpression) != nil &&
        name.range(of: "[0-9](?:\\.[0-9]+)?\\s*(?:kg|KG|g|ml|mL|L|升|克)", options: .regularExpression) == nil
      if missingSpecification || parts.contains(where: { $0.confidence < 0.8 ||
        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/") ||
        StockOCRRefinement.compact($0.text).range(of: "^[\\p{Han}]$", options: .regularExpression) != nil
      }), let retry = retryName, let recovered = try retry(start, end, parts.map { $0.box.minX }.min()!) {
        let expression = try NSRegularExpression(pattern: code)
        func codes(_ text: String) -> [String] {
          expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
          }
        }
        let oldCodes = codes(name)
        let newName = recovered.map(\.text).joined(separator: "\n")
        let newCodes = codes(newName)
        let complete = parts.filter {
          $0.confidence >= 0.8 && StockOCRRefinement.compact($0.text).count > 1
        }.allSatisfy { StockOCRRefinement.compact(newName).contains(StockOCRRefinement.compact($0.text)) }
        if complete && oldCodes == newCodes && oldCodes.count == 1 { nameParts = recovered }
      }
      var stocks = body.filter { $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end }
      var inventory = stocks.map(\.text).joined(separator: "\n")
      if inventory.range(of: "[0-9]", options: .regularExpression) == nil,
        (stocks.isEmpty || !blankInventory(inventory)), let retry = retryInventory {
        stocks = try retry(start, end).filter {
          $0.box.minX >= boundary && $0.box.midY >= start && $0.box.midY < end
        }.sorted { $0.box.midY < $1.box.midY }
        inventory = stocks.map(\.text).joined(separator: "\n")
      }
      return StockTextLine(cells: [nameParts.map {
        StockOCRRefinement.canonicalProductCode($0.text) ?? $0.text
      }.joined(separator: "\n"), inventory],
        confidence: (nameParts + stocks).map(\.confidence).min()!,
        inventoryUncertain: stocks.isEmpty || (!blankInventory(inventory) && inventory.range(of: "[0-9]", options: .regularExpression) == nil))
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
  var recognitionRevision: Int? = nil

  var needsRecognition: Bool {
    schemaVersion != 2 || (!reviewed && (recognitionRevision ?? 0) < StockHistoryProcessor.recognitionRevision)
  }
  var needsAutomaticTitle: Bool {
    !reviewed && title.hasPrefix("旧盘点单 ")
  }

  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if text.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    return formatter.date(from: text)
  }

  func validate() throws {
    guard (schemaVersion == 1 || schemaVersion == 2), UUID(uuidString: id) != nil,
          (recognitionRevision == nil || recognitionRevision! >= 0),
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          Self.date(createdAt) != nil,
          imageName == "\(id).png", !lines.isEmpty,
          (schemaVersion != 2 || lines.allSatisfy { $0.cells.count == 2 }),
          lines.allSatisfy({ !$0.cells.isEmpty && $0.cells.enumerated().allSatisfy { index, text in
            (schemaVersion == 2 && index == 1) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          } && ($0.category == nil || $0.category == "goods" || $0.category == "prepared") &&
            $0.confidence.isFinite && (0...1).contains($0.confidence) }) else {
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
  static let orderFileName = "order.json"
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
  static func order() throws -> [String] {
    let url = try root().appendingPathComponent(orderFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    guard ids.allSatisfy({ UUID(uuidString: $0) != nil }),
          Set(ids).count == ids.count else {
      throw StockHistoryError.invalid("盘点单排序文件损坏")
    }
    return ids
  }

  private static func records() throws -> [StockHistoryDocument] {
    // 顺序文件与盘点单目录同在根目录，这里只读取目录，跳过文件本身。
    let files = try FileManager.default.contentsOfDirectory(at: root(),
      includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    return try files.filter {
      try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }.map { directory -> StockHistoryDocument in
      let record = try JSONDecoder().decode(StockHistoryDocument.self,
        from: Data(contentsOf: directory.appendingPathComponent("record.json")))
      try record.validate()
      guard directory.lastPathComponent == record.id,
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.imageName).path) else {
        throw StockHistoryError.invalid("历史盘点单原图或标识损坏")
      }
      return record
    }
  }

  static func list() throws -> String {
    let records = try records()
    // 用户调整过顺序的记录按顺序文件排；调整后新增的记录（不在顺序文件里）置顶。
    let existing = Set(records.map(\.id))
    var rank: [String: Int] = [:]
    for (index, id) in try order().enumerated() where existing.contains(id) {
      rank[id] = index
    }
    let sorted = records.sorted { a, b in
      switch (rank[a.id], rank[b.id]) {
      case let (left?, right?): return left < right
      case (nil, _?): return true
      case (_?, nil): return false
      case (nil, nil): return a.createdAt > b.createdAt
      }
    }
    guard let json = String(data: try JSONEncoder().encode(sorted), encoding: .utf8) else {
      throw StockHistoryError.invalid("历史列表无法编码为 UTF-8")
    }
    return json
  }

  /// 顺序文件必须覆盖当前全部盘点单，避免搜索过滤后的部分列表覆盖真实顺序。
  static func reorder(_ ids: [String]) throws {
    guard !ids.isEmpty,
          ids.allSatisfy({ UUID(uuidString: $0) != nil }),
          Set(ids).count == ids.count else {
      throw StockHistoryError.invalid("盘点单排序参数无效")
    }
    guard Set(try records().map(\.id)) == Set(ids) else {
      throw StockHistoryError.invalid("盘点单排序必须覆盖全部历史记录")
    }
    let url = try root().appendingPathComponent(orderFileName)
    try JSONEncoder().encode(ids).write(to: url, options: .atomic)
  }
  static func create(image: UIImage, lines: [StockTextLine], id: String = UUID().uuidString,
    title: String = "待命名盘点单") throws -> StockHistoryDocument {
    let record = StockHistoryDocument(schemaVersion: 2, id: id,
      title: title,
      createdAt: ISO8601DateFormatter().string(from: Date()), imageName: "\(id).png",
      lines: lines, reviewed: false, recognitionRevision: StockHistoryProcessor.recognitionRevision)
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

/// 把盘点单导出内容与原始长图交给系统分享面板，再由用户选微信等目标应用。
enum StockExporter {
  /// 导出文件暂存目录；每个分享单独一个子目录，面板关闭即连目录一起删除。
  private static let exportsDirectory = "StockExports"

  static func shareBytes(name: String, data: Data, onFinish: @escaping () -> Void) throws {
    guard !data.isEmpty else { throw StockHistoryError.invalid("导出内容为空") }
    // 文件名来自 Dart 侧的单据名称，必须确认它没有路径分隔符或父目录引用。
    guard name == URL(fileURLWithPath: name).lastPathComponent,
          !name.hasPrefix("."), name.hasSuffix(".xlsx") else {
      throw StockHistoryError.invalid("导出文件名无效：\(name)")
    }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent(exportsDirectory, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let url = staging.appendingPathComponent(name)
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      // 回滚失败同样向调用方抛出；不得留下一个看似成功的残缺目录。
      try FileManager.default.removeItem(at: staging)
      throw error
    }
    try share(url: url, cleanup: staging, onFinish: onFinish)
  }

  static func shareImage(id: String, onFinish: @escaping () -> Void) throws {
    // 长图直接分享 Documents 下的原件：它是用户的原始数据，复制一份只会白占磁盘。
    try share(url: try StockHistoryStorage.directory(id).appendingPathComponent("\(id).png"),
      cleanup: nil, onFinish: onFinish)
  }

  /// `onFinish` 在分享面板关闭后调用，让调用方在整个面板存活期间保持忙碌状态；
  /// 面板还开着时再次 present 会让 UIKit 报 already presenting 警告。
  private static func share(url: URL, cleanup: URL?, onFinish: @escaping () -> Void) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw StockHistoryError.invalid("待分享的文件不存在")
    }
    guard let presenter = topViewController() else {
      throw StockHistoryError.invalid("无法打开分享面板，请保持应用在前台")
    }
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    // iPad 上分享面板必须挂 popover 锚点，否则呈现时直接崩溃。
    controller.popoverPresentationController?.sourceView = presenter.view
    controller.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
    controller.popoverPresentationController?.permittedArrowDirections = []
    controller.completionWithItemsHandler = { _, _, _, _ in
      // 取消分享是正常路径，同样要清理已写入的临时文件。
      if let cleanup = cleanup {
        do {
          try FileManager.default.removeItem(at: cleanup)
        } catch {
          // 该回调无法向调用方抛出错误；残留目录由 iOS 在磁盘紧张时回收。
          NSLog("清理导出临时文件失败：\(error.localizedDescription)")
        }
      }
      onFinish()
    }
    presenter.present(controller, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes
      .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
      var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
      return nil
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    return presenter
  }
}

struct StockCrop {
  static let automatic = StockCrop(top: 0.18, bottom: 0.10)
  // 截图的重叠通常只有一行；只排除导航栏和底部安全区域，不能沿用录屏的大幅裁剪。
  static let screenshots = StockCrop(top: 0.10, bottom: 0.04)
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
  let contentTop: Int
  init(_ image: CGImage, contentTop: Int = 0) throws {
    let width = 192
    // 保留原始行高，避免竖向缩小后文字采样相位改变，造成虚假的接缝误差。
    let height = image.height
    guard height >= 100, contentTop >= 0, contentTop < height - 6 else {
      throw StockHistoryError.invalid("拼接正文区域无效")
    }
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
    self.width = width; self.height = height; self.contentTop = contentTop
    pixels = bytes; smooth = blurred
  }

  func error(with other: StockGrayFrame, shift: Int, smoothed: Bool = false) -> Double {
    precondition(width == other.width && height == other.height)
    let aPixels = smoothed ? smooth : pixels
    let bPixels = smoothed ? other.smooth : other.pixels
    // 固定表头不随正文滚动。比较双方真正的正文交集，而不是整段重叠画面。
    let start = max(max(0, -shift), max(other.contentTop, contentTop - shift))
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
    // 粗匹配每六行只取一行，样本下限同步换算；精匹配仍须至少 100 个墨迹采样点。
    return count >= max(1, 100 / rowStride) ? sum / Double(count) : .infinity
  }

  func displacement(to next: StockGrayFrame, maximumShiftRatio: Double = 0.55) throws -> Int {
    guard maximumShiftRatio > 0, maximumShiftRatio <= 0.90 else {
      throw StockHistoryError.invalid("拼接重叠范围无效")
    }
    guard width == next.width, height == next.height else {
      throw StockHistoryError.invalid("录屏分辨率改变，请保持竖屏重新录制")
    }
    if error(with: next, shift: 0) < 3 { return 0 }
    let limit = Int(Double(height) * maximumShiftRatio)
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

struct StockScreenshotInput {
  let url: URL
  let capturedAt: Date

  static func ordered(_ inputs: [StockScreenshotInput]) throws -> [StockScreenshotInput] {
    guard (2...60).contains(inputs.count),
      inputs.allSatisfy({ $0.capturedAt.timeIntervalSince1970.isFinite }),
      Set(inputs.map(\.url)).count == inputs.count else {
      throw StockHistoryError.invalid("请选择 2～60 张不同的截图")
    }
    let sorted = inputs.sorted { $0.capturedAt < $1.capturedAt }
    for index in 1..<sorted.count {
      guard sorted[index - 1].capturedAt < sorted[index].capturedAt else {
        throw StockHistoryError.invalid("截图拍摄时间相同，无法确定先后，请排除重复截图")
      }
    }
    return sorted
  }
}

enum StockDocumentNaming {
  static func title(from texts: [String]) throws -> String {
    let codePattern = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9])PD(20\d{2})(\d{2})(\d{2})\d{4,8}(?![A-Za-z0-9])"#,
      options: .caseInsensitive)
    let kindPattern = try NSRegularExpression(pattern: #"^(?:盘点类型[:：]?)?(?:门店[-－—:：]?)?(日盘|周盘|月盘|常规盘点)$"#)
    var dates = Set<String>()
    var kinds = Set<String>()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for raw in texts {
      let text = StockOCRRefinement.compact(raw)
      for match in codePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let value = text as NSString
        let year = Int(value.substring(with: match.range(at: 1)))!
        let month = Int(value.substring(with: match.range(at: 2)))!
        let day = Int(value.substring(with: match.range(at: 3)))!
        let components = DateComponents(year: year, month: month, day: day)
        if let date = calendar.date(from: components) {
          let actual = calendar.dateComponents([.year, .month, .day], from: date)
          if actual.year == year, actual.month == month, actual.day == day {
            dates.insert(String(format: "%04d-%02d-%02d", year, month, day))
          }
        }
      }
      if let match = kindPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let kind = (text as NSString).substring(with: match.range(at: 1))
        kinds.insert(kind == "常规盘点" ? "日盘" : kind)
      }
    }
    guard dates.count <= 1, kinds.count <= 1 else {
      throw StockHistoryError.invalid("截图包含相互冲突的盘点日期或类型，请选择同一张盘点单")
    }
    // 未识别的字段明确标为待确认，不使用截图时间或导入日期冒充盘点日期。
    return "\(dates.first ?? "日期待确认") \(kinds.first ?? "类型待确认")"
  }
}

enum StockHistoryProcessor {
  static let recognitionRevision = 11
  static func processScreenshots(_ inputs: [StockScreenshotInput],
    progress: @escaping (String) -> Void = { _ in }) throws -> StockHistoryDocument {
    let first = try StockScreenshotInput.ordered(inputs)[0]
    guard let source = UIImage(contentsOfFile: first.url.path) else {
      throw StockHistoryError.invalid("无法读取首张截图中的盘点信息")
    }
    let title = try documentTitle(source)
    let image = try stitchScreenshots(inputs, progress: progress)
    let lines = try recognize(image, progress: progress)
    progress("正在保存长截图与识别结果")
    return try StockHistoryStorage.create(image: image, lines: lines, title: title)
  }

  // 明确传入裁剪时处理没有固定表头的原始图像；默认自动定位盘点截图中的固定表头。
  static func stitchScreenshots(_ inputs: [StockScreenshotInput], crop: StockCrop? = nil,
    progress: (String) -> Void = { _ in }) throws -> UIImage {
    let activeCrop = crop ?? .screenshots
    try activeCrop.validate()
    let sorted = try StockScreenshotInput.ordered(inputs)
    var pieces: [CGImage] = []
    var previous: StockGrayFrame?
    var width = 0
    var totalHeight = 0
    for (index, input) in sorted.enumerated() {
      try autoreleasepool {
        guard let image = UIImage(contentsOfFile: input.url.path),
          image.imageOrientation == .up, let raw = image.cgImage,
          raw.width * raw.height <= 40_000_000 else {
          throw StockHistoryError.invalid("第 \(index + 1) 张截图无法读取、方向不正确或尺寸过大")
        }
        let frame = try activeCrop.apply(raw)
        let bodyTop: Int
        if crop == nil { bodyTop = try screenshotBodyTop(frame) }
        else { bodyTop = 0 }
        let gray = try StockGrayFrame(frame, contentTop: bodyTop)
        if let old = previous {
          guard width == frame.width, old.height == frame.height else {
            throw StockHistoryError.invalid("截图尺寸不一致，请选择同一手机、同一方向的原始截图")
          }
          let shift: Int
          do { shift = try old.displacement(to: gray, maximumShiftRatio: 0.90) }
          catch {
            throw StockHistoryError.invalid("第 \(index) 与 \(index + 1) 张截图无法确认接缝，请保留两三行重叠：\(error.localizedDescription)")
          }
          guard shift >= 0 else {
            throw StockHistoryError.invalid("第 \(index + 1) 张截图向上回滚，请选择从上往下截取的截图")
          }
          if shift > 0 {
            guard let strip = frame.cropping(to: CGRect(x: 0,
              y: frame.height - shift, width: frame.width, height: shift)) else {
              throw StockHistoryError.invalid("无法提取截图新增内容")
            }
            pieces.append(try ownedImage(strip))
            totalHeight += strip.height
          }
        } else {
          pieces.append(try ownedImage(frame))
          width = frame.width
          totalHeight = frame.height
        }
        guard totalHeight <= 48_000, width * totalHeight <= 40_000_000 else {
          throw StockHistoryError.invalid("截图组拼接后过长，请分组导入")
        }
        previous = gray
        progress("正在拼接截图 · \(index + 1)/\(sorted.count)")
      }
    }
    return renderPieces(pieces, width: width, height: totalHeight)
  }

  static func screenshotBodyTop(_ image: CGImage) throws -> Int {
    // 首张截图表头随基本信息向下移动，后续截图表头固定在顶部，须逐张定位。
    let height = min(image.height, 900)
    guard let tile = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height)) else {
      throw StockHistoryError.invalid("无法读取截图表头区域")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: textImage(tile), options: [:]).perform([request])
    guard let results = request.results else { throw StockHistoryError.invalid("截图表头识别未返回结果") }
    var nameHeaders: [CGRect] = []
    var stockHeaders: [CGRect] = []
    for observation in results {
      guard let candidate = observation.topCandidates(1).first else {
        throw StockHistoryError.invalid("截图表头识别候选为空")
      }
      let text = StockOCRRefinement.compact(candidate.string)
      let isName = text.contains("货物规格名称")
      let isStock = text.contains("实盘总库存")
      if isName || isStock {
        let box = observation.boundingBox
        let rect = CGRect(x: box.minX * Double(image.width),
          y: (1 - box.maxY) * Double(height),
          width: box.width * Double(image.width), height: box.height * Double(height))
        if isName { nameHeaders.append(rect) }
        if isStock { stockHeaders.append(rect) }
      }
    }
    // 末张截图还可能出现「预制物料」的库存表头，只配对同一行的货物名称与库存标题。
    let headerPairs = nameHeaders.flatMap { name in
      stockHeaders.filter { abs($0.midY - name.midY) < max($0.height, name.height) * 1.25 }
        .map { (name, $0) }
    }
    guard let pair = headerPairs.min(by: { max($0.0.maxY, $0.1.maxY) < max($1.0.maxY, $1.1.maxY) }) else {
      throw StockHistoryError.invalid("无法定位截图的货物表头，请选择保留两列表头的原始截图")
    }
    let bodyTop = Int(ceil(max(pair.0.maxY + pair.0.height, pair.1.maxY + pair.1.height)))
    guard bodyTop > 0, bodyTop < image.height - 100 else {
      throw StockHistoryError.invalid("截图货物正文区域过小，无法拼接")
    }
    return bodyTop
  }
  static func process(url: URL, video: Bool, crop: StockCrop, documentID: String = UUID().uuidString,
    progress: @escaping (String) -> Void = { _ in }) throws -> StockHistoryDocument {
    let image: UIImage
    let title: String
    if video {
      let (generator, _) = try makeGenerator(url: url)
      let first = try generator.copyCGImage(at: .zero, actualTime: nil)
      title = try documentTitle(UIImage(cgImage: first))
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
      title = try documentTitle(image)
    }
    let lines = try recognize(image, progress: progress)
    progress("正在保存长截图与识别结果")
    return try StockHistoryStorage.create(image: image, lines: lines, id: documentID, title: title)
  }

  static func documentTitle(_ image: UIImage) throws -> String {
    guard let source = image.cgImage else { throw StockHistoryError.invalid("无法读取盘点单基本信息") }
    let height = min(source.height, Int((Double(source.width) * 1.1).rounded(.up)))
    guard let tile = source.cropping(to: CGRect(x: 0, y: 0, width: source.width, height: height)) else {
      throw StockHistoryError.invalid("无法提取盘点单基本信息")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: textImage(tile), options: [:]).perform([request])
    guard let results = request.results else { throw StockHistoryError.invalid("盘点基本信息识别未返回结果") }
    let texts = try results.map { observation -> String in
      guard let candidate = observation.topCandidates(1).first else {
        throw StockHistoryError.invalid("盘点基本信息识别候选为空")
      }
      return candidate.string
    }
    return try StockDocumentNaming.title(from: texts)
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
    return renderPieces(pieces, width: width, height: totalHeight)
  }

  private static func renderPieces(_ pieces: [CGImage], width: Int, height totalHeight: Int) -> UIImage {
    precondition(!pieces.isEmpty && width > 0 && totalHeight > 0)
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

  static func textImage(_ image: CGImage, preserveFaintText: Bool = false,
    isolatedNumber: Bool = false) throws -> CGImage {
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
      for index in 0..<size {
        let value = Int(pixels[index])
        if isolatedNumber {
          // 仅用于已定位的数量框：浅灰数字约 190～215，输入框背景约 243。
          // 不能用于整张盘点单，否则同样浅色的水印也会变成黑字。
          pixels[index] = UInt8(max(0, min(255, (value - 215) * 255 / 25)))
        } else {
          pixels[index] = preserveFaintText ? UInt8(max(0, min(255, (value - 160) * 255 / 80))) :
            UInt8(min(255, value * 255 / 210))
        }
      }
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
          do {
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StockHistoryError.invalid("识别到空文字，请检查截图") }
            if rect.midY >= Double(start), rect.midY < Double(min(cg.height, start + block)),
              text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).contains("实盘总库存") {
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
              let partBox = CGRect(x: box.minX * Double(cg.width),
                  y: Double(top) + (1 - box.maxY) * Double(bottom - top),
                  width: box.width * Double(cg.width), height: box.height * Double(bottom - top))
              // 分列后按实际文字区域归属分块，不能沿用品名与库存合并框的中心点。
              if partBox.midY >= Double(start), partBox.midY < Double(min(cg.height, start + block)) {
                cells.append(StockOCRCell(text: part, confidence: Double(candidate.confidence), box: partBox))
              }
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
    cells = try recoverProductCodes(cells, original: cg, clean: recognitionImage,
      columnX: columnX, progress: progress)
    cells = try refine(cells, original: cg, clean: recognitionImage, columnX: columnX, progress: progress)
    let goods = try StockTableParser.rows(cells, retryName: { start, end, left in
      progress("正在复核名称和规格")
      let top = max(0, start.rounded(.down))
      let bottom = min(CGFloat(cg.height), end.rounded(.up))
      let x = max(0, (left - 8).rounded(.down))
      let crop = CGRect(x: x, y: top, width: CGFloat(columnX) - x, height: bottom - top)
      let raw = try inventoryRow(cg, crop: crop, scale: 2).sorted { $0.box.midY < $1.box.midY }
      let clean = try inventoryRow(recognitionImage, crop: crop, scale: 2).sorted { $0.box.midY < $1.box.midY }
      // 只有原图与去水印图的完整行文本一致时才替换；不同读法保留原结果供校对。
      guard !raw.isEmpty, !clean.isEmpty,
        StockOCRRefinement.compact(raw.map(\.text).joined()) ==
          StockOCRRefinement.compact(clean.map(\.text).joined()),
        min(raw.map(\.confidence).min()!, clean.map(\.confidence).min()!) >= 0.8 else { return nil }
      let confidence = min(raw.map(\.confidence).min()!, clean.map(\.confidence).min()!)
      return raw.map { StockOCRCell(text: $0.text, confidence: min($0.confidence, confidence), box: $0.box) }
    }) { start, end in
      progress("正在放大复核未识别的库存行")
      let crop = CGRect(x: CGFloat(columnX), y: max(0, start.rounded(.down)),
        width: CGFloat(cg.width - columnX),
        height: min(CGFloat(cg.height), end.rounded(.up)) - max(0, start.rounded(.down)))
      // 短行单独放大，避开分块边缘和下面的预制物料表。只有该行真实 OCR
      // 返回数字才用于数量；技术错误继续抛出，未识别的值保留状态，不填成 0。
      var readings: [[StockOCRCell]] = []
      for (source, scale) in [(recognitionImage, 2), (cg, 2), (recognitionImage, 4)] {
        let recovered = try inventoryRow(source, crop: crop, scale: scale)
        readings.append(recovered)
        if recovered.contains(where: { $0.text.range(of: "[0-9]", options: .regularExpression) != nil }) {
          return recovered
        }
      }
      // 识别任务成功但数量不确定：保留实际 OCR 文本并标记待确认，允许部分盘点单保存。
      return readings.max { $0.count < $1.count }!
    }
    if let marker = cells.filter({
      StockOCRRefinement.compact($0.text).contains("预制物料信息") ||
        StockOCRRefinement.compact($0.text).contains("预制物料名称")
    }).min(by: { $0.box.minY < $1.box.minY }) {
      progress("正在识别预制物料")
      let top = max(0, (marker.box.minY - 12).rounded(.down))
      // 预制数量是浅灰色输入框文字，必须读原图，不能用去水印图抹掉真实数量。
      var prepared = try inventoryRow(cg,
        crop: CGRect(x: 0, y: top, width: CGFloat(cg.width), height: CGFloat(cg.height) - top),
        scale: 2, stockColumnStart: CGFloat(columnX))
      if StockTableParser.preparedHeaders(prepared) == nil {
        progress("正在复核预制物料表头")
        // 原图负责保留浅色数量；去水印图只复核表头，避免水印与标题合并。
        // 从库存标题的左缘分开读取，不能从货物数字列的起点截掉「实盘」二字。
        let split = max(1, min(CGFloat(cg.width - 1),
          (header.box.minX - header.box.height * 0.5).rounded(.down)))
        let bottom = min(CGFloat(cg.height),
          (marker.box.maxY + max(marker.box.height, header.box.height) * 10).rounded(.up))
        let leftCrop = CGRect(x: 0, y: top, width: split, height: bottom - top)
        let rightCrop = CGRect(x: split, y: top, width: CGFloat(cg.width) - split, height: bottom - top)
        for scale in [2, 4] {
          let left = try inventoryRow(recognitionImage, crop: leftCrop, scale: scale,
            diagnosticContext: "预制名称表头")
          let right = try inventoryRow(recognitionImage, crop: rightCrop, scale: scale,
            diagnosticContext: "预制库存表头")
          if let recovered = StockTableParser.preparedHeaders(left + right) {
            prepared.removeAll {
              let text = StockOCRRefinement.compact($0.text)
              return text.contains("预制物料名称") || text.contains("实盘总库存")
            }
            prepared.append(contentsOf: [recovered.name, recovered.stock])
            break
          }
        }
      }
      let faintText = try textImage(cg, preserveFaintText: true)
      let preparedRows = try StockTableParser.preparedRows(prepared) { start, end, quantityLeft in
        progress("正在复核预制物料数量")
        let y = max(0, start.rounded(.down))
        let x = max(0, quantityLeft.rounded(.down))
        let crop = CGRect(x: x, y: y, width: CGFloat(cg.width) - x,
          height: min(CGFloat(cg.height), end.rounded(.up)) - y)
        // 原图与保留浅色文字的增强图独立复读，整行数字和单位一致才采纳。
        for scale in [2, 4] {
          let raw = try inventoryRow(cg, crop: crop, scale: scale, horizontalOrder: true,
            diagnosticContext: "预制整行原图")
            .sorted { $0.box.minX < $1.box.minX }
          let enhanced = try inventoryRow(faintText, crop: crop, scale: scale, horizontalOrder: true,
            diagnosticContext: "预制整行浅灰增强")
            .sorted { $0.box.minX < $1.box.minX }
          let value = StockOCRRefinement.compact(raw.map(\.text).joined())
          if !raw.isEmpty, !enhanced.isEmpty,
            value.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:个|毫升|克)$", options: .regularExpression) != nil,
            value == StockOCRRefinement.compact(enhanced.map(\.text).joined()) {
            let confidence = min(raw.map(\.confidence).min()!, enhanced.map(\.confidence).min()!)
            return raw.map { StockOCRCell(text: $0.text, confidence: min($0.confidence, confidence), box: $0.box) }
          }
        }
        // 单字符数量常被整行中文识别忽略。依据已识别单位的位置单独裁出数字输入框。
        let units = prepared.filter { cell in
          cell.box.minX >= x && cell.box.midY >= start && cell.box.midY < end &&
            StockOCRRefinement.compact(cell.text).range(of: "^(?:个|毫升|克)$", options: .regularExpression) != nil
        }
        #if DEBUG
        print("[StockOCR] 预制单位定位 crop=\(crop) units=\(units.map { "\($0.text)@\($0.box)" })")
        #endif
        if units.count == 1 {
          let unit = units[0]
          let numberTop = max(y, (unit.box.midY - unit.box.height * 1.5).rounded(.down))
          let numberBottom = min(crop.maxY, (unit.box.midY + unit.box.height * 1.5).rounded(.up))
          let numberRight = (unit.box.minX - unit.box.height * 0.25).rounded(.down)
          guard numberRight > x, numberBottom > numberTop else {
            throw StockHistoryError.invalid("预制物料数量输入框位置无效")
          }
          let numberCrop = CGRect(x: x, y: numberTop, width: numberRight - x, height: numberBottom - numberTop)
          for scale in [2, 4] {
            let raw = try inventoryRow(cg, crop: numberCrop, scale: scale,
              requiredPattern: "^[0-9]+(?:\\.[0-9]+)?$", diagnosticContext: "预制数量原图")
            let enhanced = try inventoryRow(faintText, crop: numberCrop, scale: scale,
              requiredPattern: "^[0-9]+(?:\\.[0-9]+)?$", diagnosticContext: "预制数量浅灰增强")
            if raw.count == 1, enhanced.count == 1,
              StockOCRRefinement.compact(raw[0].text) == StockOCRRefinement.compact(enhanced[0].text) {
              let confidence = min(raw[0].confidence, enhanced[0].confidence)
              return [StockOCRCell(text: raw[0].text, confidence: confidence, box: raw[0].box), unit]
            }
          }
          // accurate 按整行推断，孤立单字可能没有观察结果。fast 使用字符检测，
          // 数量框只读英文数字，并仅接受第一候选，不能从低排名候选中挑出想要的数。
          for scale in [2, 4] {
            let raw = try inventoryRow(cg, crop: numberCrop, scale: scale,
              requiredPattern: "^[0-9]+(?:\\.[0-9]+)?$", recognitionLevel: .fast,
              diagnosticContext: "预制数量字符原图")
            let enhanced = try inventoryRow(cg, crop: numberCrop, scale: scale,
              requiredPattern: "^[0-9]+(?:\\.[0-9]+)?$", recognitionLevel: .fast,
              isolatedNumber: true, diagnosticContext: "预制数量字符局部增强")
            if raw.count == 1, enhanced.count == 1,
              StockOCRRefinement.compact(raw[0].text) == StockOCRRefinement.compact(enhanced[0].text),
              raw[0].box.intersects(enhanced[0].box) {
              let confidence = min(raw[0].confidence, enhanced[0].confidence)
              return [StockOCRCell(text: raw[0].text, confidence: confidence, box: raw[0].box), unit]
            }
          }
          if let number = try compactPreparedQuantity(cg, numberCrop: numberCrop, unit: unit) {
            return [number, unit]
          }
        }
        #if DEBUG
        print("[StockOCR] 预制数量未恢复 crop=\(crop) unitCount=\(units.count)")
        #endif
        return nil
      }
      return goods + preparedRows
    }
    return goods
  }

  static func refine(_ cells: [StockOCRCell], original: CGImage, clean: CGImage,
    columnX: Int, progress: (String) -> Void) throws -> [StockOCRCell] {
    guard original.width == clean.width, original.height == clean.height,
      columnX > 0, columnX < original.width else { throw StockHistoryError.invalid("复识别图像尺寸或列位置无效") }
    guard let header = cells.filter({ StockOCRRefinement.compact($0.text).contains("实盘总库存") })
      .min(by: { $0.box.minY < $1.box.minY }) else { throw StockHistoryError.invalid("复识别缺少库存表头") }
    let footer = cells.filter { cell in
      cell.box.minY > header.box.maxY && ["预制物料信息", "其他信息", "历史记录"]
        .contains { StockOCRRefinement.compact(cell.text).contains($0) }
    }.map { $0.box.minY }.min() ?? CGFloat(original.height)
    var output = cells
    for start in stride(from: 0, to: original.height, by: 1800) {
      for inventory in [false, true] {
        let indices = cells.indices.filter { index in
          let cell = cells[index]
          return cell.confidence < 0.8 && cell.box.height >= 8 &&
            cell.box.midY > header.box.maxY && cell.box.midY < footer &&
            cell.box.midY >= CGFloat(start) && cell.box.midY < CGFloat(start + 1800) &&
            (cell.box.minX >= CGFloat(columnX)) == inventory
        }
        if indices.isEmpty { continue }
        try autoreleasepool {
          progress("正在优化\(inventory ? "库存" : "品名及货号")识别 · \(start / 1800 + 1)")
          let top = max(header.box.maxY, indices.map { cells[$0].box.minY }.min()! - 12).rounded(.down)
          let bottom = min(footer, indices.map { cells[$0].box.maxY }.max()! + 12).rounded(.up)
          let left = inventory ? CGFloat(columnX) : max(0, indices.map { cells[$0].box.minX }.min()! - 12).rounded(.down)
          let right = inventory ? CGFloat(original.width) : min(CGFloat(columnX),
            indices.map { cells[$0].box.maxX }.max()! + 12).rounded(.up)
          let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
          let raw = try inventoryRow(original, crop: crop, scale: 2)
          let enhanced = try inventoryRow(clean, crop: crop, scale: 2)
          for index in indices {
            if !crop.contains(cells[index].box) { continue }
            output[index] = StockOCRRefinement.resolve(cells[index],
              raw: StockOCRRefinement.match(cells[index], in: raw),
              clean: StockOCRRefinement.match(cells[index], in: enhanced), inventory: inventory)
          }
        }
      }
    }
    return output
  }

  /// 单独复读货号所在窄列，补回首次 OCR 完全遗漏的行锚点；不依赖已解析出的货物行。
  static func recoverProductCodes(_ cells: [StockOCRCell], original: CGImage, clean: CGImage,
    columnX: Int, progress: (String) -> Void) throws -> [StockOCRCell] {
    let pattern = "^[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}$"
    let anchors = cells.filter {
      $0.box.minX < CGFloat(columnX) &&
        StockOCRRefinement.compact($0.text).range(of: pattern, options: .regularExpression) != nil
    }
    guard !anchors.isEmpty else { throw StockHistoryError.invalid("缺少可定位的货号列，请核对原图") }
    guard let top = cells.filter({ StockOCRRefinement.compact($0.text).contains("货物规格名称") })
      .map({ $0.box.maxY }).min() else {
      throw StockHistoryError.invalid("复核货号缺少货物表头")
    }
    let bottom = cells.filter { cell in
      cell.box.minY > top && ["预制物料信息", "其他信息", "历史记录"].contains {
        StockOCRRefinement.compact(cell.text).contains($0)
      }
    }.map { $0.box.minY }.min() ?? CGFloat(original.height)
    let left = max(0, (anchors.map { $0.box.minX }.min()! - 16).rounded(.down))
    let right = min(CGFloat(columnX), (anchors.map { $0.box.maxX }.max()! + 16).rounded(.up))
    var output = StockOCRRefinement.coalesce(cells)
    for start in stride(from: Int(top.rounded(.down)), to: Int(bottom.rounded(.up)), by: 1200) {
      try autoreleasepool {
        progress("正在复核货号完整性")
        let y = max(top.rounded(.down), CGFloat(start - 80))
        let end = min(bottom.rounded(.up), CGFloat(start + 1280))
        let crop = CGRect(x: left, y: y, width: right - left, height: end - y)
        let raw = try inventoryRow(original, crop: crop, scale: 2,
          requiredPattern: "^[Gg][Ss][0-9]{4,8}[-－—][0-9]{2,3}$")
        let enhanced = try inventoryRow(clean, crop: crop, scale: 2,
          requiredPattern: "^[Gg][Ss][0-9]{4,8}[-－—][0-9]{2,3}$")
        for candidate in raw {
          guard candidate.box.midY >= CGFloat(start), candidate.box.midY < CGFloat(start + 1200),
            let code = StockOCRRefinement.canonicalProductCode(candidate.text),
            let agreement = StockOCRRefinement.match(candidate, in: enhanced),
            code == StockOCRRefinement.canonicalProductCode(agreement.text) else { continue }
          // 已有货号的物理位置不新增锚点；仅补回原先没有货号的区域。
          let existing = output.indices.filter { index in
            let cell = output[index]
            return StockOCRRefinement.compact(cell.text).range(of:
              "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}", options: .regularExpression) != nil &&
              !cell.box.intersection(candidate.box).isNull &&
              cell.box.intersection(candidate.box).height >= min(cell.box.height, candidate.box.height) * 0.5
          }
          if existing.isEmpty {
            output.append(StockOCRCell(text: code,
              confidence: min(candidate.confidence, agreement.confidence), box: candidate.box))
          } else if existing.count == 1 {
            let index = existing[0]
            let old = output[index]
            let expression = try NSRegularExpression(pattern: "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}")
            let matches = expression.matches(in: old.text, range: NSRange(old.text.startIndex..., in: old.text))
            if matches.count == 1 {
              let oldCode = (old.text as NSString).substring(with: matches[0].range)
              if oldCode == code { continue }
              // 原图和增强图实际读到相同数字货号时，允许修复已有的含糊锚点。
              // 货号与名称处于同一文字块时只改货号，保留原名称与规格。
              let repaired = (old.text as NSString).replacingCharacters(in: matches[0].range, with: code)
              output[index] = StockOCRCell(text: repaired,
                confidence: min(old.confidence, min(candidate.confidence, agreement.confidence)), box: old.box)
            }
          }
        }
      }
    }
    let expression = try NSRegularExpression(pattern: "[Gg][Ss][0-9OoIl]{4,8}[-－—][0-9OoIl]{2,3}")
    for index in output.indices {
      let old = output[index]
      let matches = expression.matches(in: old.text, range: NSRange(old.text.startIndex..., in: old.text))
      guard old.box.minX < CGFloat(columnX), matches.count == 1 else { continue }
      let oldCode = (old.text as NSString).substring(with: matches[0].range)
      guard StockOCRRefinement.canonicalProductCode(oldCode) == nil else { continue }
      try autoreleasepool {
        progress("正在放大复核含糊货号")
        let x = max(0, (old.box.minX - 8).rounded(.down))
        let y = max(top.rounded(.down), (old.box.minY - 8).rounded(.down))
        let crop = CGRect(x: x, y: y,
          width: min(CGFloat(columnX), (old.box.maxX + 8).rounded(.up)) - x,
          height: min(bottom.rounded(.up), (old.box.maxY + 8).rounded(.up)) - y)
        let raw = try inventoryRow(original, crop: crop, scale: 4,
          requiredPattern: "^[Gg][Ss][0-9]{4,8}[-－—][0-9]{2,3}$")
        let enhanced = try inventoryRow(clean, crop: crop, scale: 4,
          requiredPattern: "^[Gg][Ss][0-9]{4,8}[-－—][0-9]{2,3}$")
        if raw.count == 1, enhanced.count == 1,
          let code = StockOCRRefinement.canonicalProductCode(raw[0].text),
          code == StockOCRRefinement.canonicalProductCode(enhanced[0].text),
          StockOCRRefinement.match(raw[0], in: enhanced) != nil {
          let repaired = (old.text as NSString).replacingCharacters(in: matches[0].range, with: code)
          output[index] = StockOCRCell(text: repaired,
            confidence: min(old.confidence, min(raw[0].confidence, enhanced[0].confidence)), box: old.box)
        }
      }
    }
    return output
  }

  /// 将同一行的真实数字像素和真实单位像素靠拢，给单字检测提供连续文本。
  /// 不添加数字、不重复数字；返回坐标仍属于原图，而非重排后的识别画布。
  static func compactPreparedQuantity(_ source: CGImage, numberCrop: CGRect,
    unit: StockOCRCell) throws -> StockOCRCell? {
    let unitText = StockOCRRefinement.compact(unit.text)
    let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    guard ["个", "毫升", "克"].contains(unitText), unit.box.height > 0,
      imageBounds.contains(numberCrop), numberCrop.width > 0, numberCrop.height > 0 else {
      throw StockHistoryError.invalid("预制数量紧凑识别区域无效")
    }
    // 按单位基线收窄垂直范围，避免把上下分隔线当作数字笔画。
    let band = CGRect(x: numberCrop.minX,
      y: floor(unit.box.midY - unit.box.height * 0.85), width: numberCrop.width,
      height: ceil(unit.box.midY + unit.box.height * 0.85) - floor(unit.box.midY - unit.box.height * 0.85))
      .intersection(numberCrop).integral
    guard !band.isNull, !band.isEmpty, let tile = source.cropping(to: band) else {
      throw StockHistoryError.invalid("无法读取预制数字像素")
    }
    var pixels = [UInt8](repeating: 0, count: tile.width * tile.height)
    try pixels.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(data: buffer.baseAddress, width: tile.width, height: tile.height,
        bitsPerComponent: 8, bytesPerRow: tile.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
        throw StockHistoryError.invalid("无法创建预制数字像素图")
      }
      context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
    }
    var left = tile.width, right = -1, top = tile.height, bottom = -1, ink = 0
    for y in 0..<tile.height {
      for x in 0..<tile.width where pixels[y * tile.width + x] < 225 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
        ink += 1
      }
    }
    // 空白或噪点属于没有可识别数量，不能因此补零。
    guard ink >= 6, right >= left, bottom >= top,
      CGFloat(bottom - top + 1) >= unit.box.height * 0.25 else { return nil }
    let numberBox = CGRect(x: band.minX + CGFloat(left) - 2, y: band.minY + CGFloat(top) - 2,
      width: CGFloat(right - left + 5), height: CGFloat(bottom - top + 5)).intersection(numberCrop).integral
    let unitBox = unit.box.insetBy(dx: -1, dy: -1).integral.intersection(imageBounds)
    guard numberBox.maxX < unitBox.minX,
      let numberImage = source.cropping(to: numberBox), let unitImage = source.cropping(to: unitBox) else {
      throw StockHistoryError.invalid("无法裁出同一行的预制数字和单位")
    }
    let padding = max(4, Int(ceil(unit.box.height * 0.5)))
    let gap = max(1, Int(ceil(unit.box.height * 0.08)))
    let contentBottom = max(numberBox.maxY, unitBox.maxY)
    let contentTop = min(numberBox.minY, unitBox.minY)
    let width = padding * 2 + numberImage.width + gap + unitImage.width
    let height = padding * 2 + Int(ceil(contentBottom - contentTop))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
      throw StockHistoryError.invalid("无法创建预制数量紧凑画布")
    }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(numberImage, in: CGRect(x: CGFloat(padding),
      y: CGFloat(padding) + contentBottom - numberBox.maxY,
      width: CGFloat(numberImage.width), height: CGFloat(numberImage.height)))
    context.draw(unitImage, in: CGRect(x: CGFloat(padding + numberImage.width + gap),
      y: CGFloat(padding) + contentBottom - unitBox.maxY,
      width: CGFloat(unitImage.width), height: CGFloat(unitImage.height)))
    guard let compact = context.makeImage() else {
      throw StockHistoryError.invalid("无法生成预制数量紧凑图")
    }
    let faint = try textImage(compact, preserveFaintText: true)
    let contrast = try textImage(compact, isolatedNumber: true)
    let compactBounds = CGRect(x: 0, y: 0, width: width, height: height)
    #if DEBUG
    print("[StockOCR] 预制紧凑画布 number=\(numberBox) unit=\(unitBox) ink=\(ink) size=\(width)x\(height)")
    #endif
    for scale in [2, 4] {
      var readings: [(String, Double)] = []
      for (label, image) in [("原图", compact), ("浅灰增强", faint), ("局部增强", contrast)] {
        let cells = try inventoryRow(image, crop: compactBounds, scale: scale,
          diagnosticContext: "预制紧凑\(label)").sorted { $0.box.minX < $1.box.minX }
        let value = StockOCRRefinement.compact(cells.map(\.text).joined())
        if value.range(of: "^[0-9]+(?:\\.[0-9]+)?\(unitText)$", options: .regularExpression) != nil {
          readings.append((value, cells.map(\.confidence).min()!))
        }
      }
      // 至少两种真实像素读数一致；有有效读数冲突时继续保留待确认。
      if readings.count >= 2, Set(readings.map { $0.0 }).count == 1 {
        return StockOCRCell(text: String(readings[0].0.dropLast(unitText.count)),
          confidence: readings.map { $0.1 }.min()!, box: numberBox)
      }
    }
    return nil
  }

  static func inventoryRow(_ source: CGImage, crop: CGRect, scale: Int,
    stockColumnStart: CGFloat? = nil, horizontalOrder: Bool = false,
    requiredPattern: String? = nil, recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
    isolatedNumber: Bool = false, diagnosticContext: String? = nil) throws -> [StockOCRCell] {
    guard (1...4).contains(scale), crop.width > 0, crop.height > 0,
      crop.minX >= 0, crop.minY >= 0,
      crop.maxX <= CGFloat(source.width), crop.maxY <= CGFloat(source.height),
      let tile = source.cropping(to: crop),
      let context = CGContext(data: nil, width: tile.width * scale, height: tile.height * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
      throw StockHistoryError.invalid("无法放大库存行")
    }
    guard !isolatedNumber || (requiredPattern != nil && recognitionLevel == .fast) else {
      throw StockHistoryError.invalid("数量框增强必须用于独立数字字符识别")
    }
    let input = isolatedNumber ? try textImage(tile, isolatedNumber: true) : tile
    context.interpolationQuality = .high
    context.draw(input, in: CGRect(x: 0, y: 0, width: tile.width * scale, height: tile.height * scale))
    guard let enlarged = context.makeImage() else { throw StockHistoryError.invalid("无法生成库存行识别图") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = recognitionLevel
    request.recognitionLanguages = requiredPattern == nil ? ["zh-Hans", "en-US"] : ["en-US"]
    request.usesLanguageCorrection = false
    if requiredPattern != nil { request.minimumTextHeight = 0.01 }
    try VNImageRequestHandler(cgImage: enlarged, options: [:]).perform([request])
    guard let results = request.results else { throw StockHistoryError.invalid("库存行识别未返回结果") }
    #if DEBUG
    if let label = diagnosticContext {
      let readings = results.map { observation in
        let candidates = observation.topCandidates(5).map { "\($0.string):\($0.confidence)" }.joined(separator: "|")
        let dx = abs(observation.topRight.x - observation.topLeft.x) * Double(enlarged.width)
        let dy = abs(observation.topRight.y - observation.topLeft.y) * Double(enlarged.height)
        return "box=\(observation.boundingBox) rejectedSlope=\(dy > dx * 0.25) candidates=[\(candidates)]"
      }.joined(separator: "; ")
      print("[StockOCR] \(label) crop=\(crop) scale=\(scale) mode=\(recognitionLevel.rawValue) observations=\(results.count) \(readings)")
    }
    #endif
    return try results.flatMap { observation -> [StockOCRCell] in
      let dx = observation.topRight.x - observation.topLeft.x
      let dy = observation.topRight.y - observation.topLeft.y
      if abs(dy) * Double(enlarged.height) > abs(dx) * Double(enlarged.width) * 0.25 { return [] }
      let candidates = observation.topCandidates(requiredPattern == nil || recognitionLevel == .fast ? 1 : 5)
      guard !candidates.isEmpty else {
        throw StockHistoryError.invalid("库存行识别候选为空")
      }
      let candidate: VNRecognizedText
      if let pattern = requiredPattern {
        guard let selected = candidates.first(where: {
          StockOCRRefinement.compact($0.string).range(of: pattern, options: .regularExpression) != nil
        }) else { return [] }
        candidate = selected
      } else {
        candidate = candidates[0]
      }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw StockHistoryError.invalid("库存行识别文字为空") }
      let original = candidate.string
      var ranges = [original.startIndex..<original.endIndex]
      if horizontalOrder {
        // Vision 也可能把单位和数字合成一个逆序字符串，单字符坐标可还原真实横向顺序。
        ranges = original.indices.filter { !original[$0].isWhitespace }.map {
          $0..<original.index(after: $0)
        }
      }
      if let nameRange = original.range(of: "预\\s*制\\s*物\\s*料\\s*名\\s*称", options: .regularExpression),
        let stockRange = original.range(of: "实\\s*盘\\s*总\\s*库\\s*存", options: .regularExpression) {
        // 两个表头可能被 Vision 合成一条观察结果，按真实文字范围分别取得坐标。
        // 库存表头的左缘在货物数量列左侧，不能用数量列阈值判断是否拆分。
        ranges = [nameRange, stockRange]
      } else if let column = stockColumnStart {
        var characters: [(Range<String.Index>, CGRect)] = []
        for index in original.indices where !original[index].isWhitespace {
          let range = index..<original.index(after: index)
          guard let character = try candidate.boundingBox(for: range) else {
            throw StockHistoryError.invalid("无法定位预制物料列边界")
          }
          let box = character.boundingBox
          characters.append((range, CGRect(x: crop.minX + box.minX * CGFloat(tile.width), y: 0,
            width: box.width * CGFloat(tile.width), height: box.height * CGFloat(tile.height))))
        }
        ranges = StockTableParser.splitColumnGap(original, characters: characters, stockColumnStart: column)
      }
      return try ranges.map { range in
        guard let region = try candidate.boundingBox(for: range) else {
          throw StockHistoryError.invalid("无法定位行识别文字")
        }
        let box = region.boundingBox
        let part = String(original[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !part.isEmpty else { throw StockHistoryError.invalid("行识别文字分列后为空") }
        return StockOCRCell(text: part, confidence: Double(candidate.confidence),
          box: CGRect(x: crop.minX + box.minX * CGFloat(tile.width),
            y: crop.minY + (1 - box.maxY) * CGFloat(tile.height),
            width: box.width * CGFloat(tile.width), height: box.height * CGFloat(tile.height)))
      }
    }
  }
}

final class StockHistoryBridge: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var sharing = false
  private var activePicker: PHPickerViewController?
  private var video = true
  private var screenshots = false
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
    // 分享必须在主线程呈现，不能落到下面的处理队列里。
    if call.method == "shareBytes" || call.method == "shareImage" {
      precondition(Thread.isMainThread)
      guard !sharing else {
        result(FlutterError(code: "INVALID_SHARE", message: "已有分享面板正在显示", details: nil)); return
      }
      sharing = true
      do {
        // 面板关闭才解除占用，期间再次分享会被上面的守卫挡下。
        try Self.presentShare(call) { [weak self] in self?.sharing = false }
      } catch {
        sharing = false
        Self.fail(error, result: result)
        return
      }
      // 面板呈现成功即视为受理；用户选谁、是否取消都不再回传。
      result(nil)
      return
    }
    if call.method == "import" || call.method == "importScreenshots" {
      guard pending == nil else {
        result(FlutterError(code: "INVALID_IMPORT", message: "导入参数无效或已有导入任务", details: nil)); return
      }
      let screenshots = call.method == "importScreenshots"
      let video: Bool
      if screenshots { video = false }
      else {
        guard let arguments = call.arguments as? [String: Any], let selectedVideo = arguments["video"] as? Bool else {
          result(FlutterError(code: "INVALID_IMPORT", message: "导入参数无效", details: nil)); return
        }
        video = selectedVideo
      }
      let crop = StockCrop.automatic
      do { try crop.validate() } catch { Self.fail(error, result: result); return }
      guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
        result(FlutterError(code: "NO_WINDOW", message: "无法打开照片选择器", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      self.video = video; self.screenshots = screenshots; self.crop = crop; pending = result
      let presentPicker = {
        var configuration = screenshots
          ? PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared()) : PHPickerConfiguration()
        configuration.selectionLimit = screenshots ? 60 : 1
        configuration.filter = video ? .videos : .images
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        self.activePicker = picker
        presenter.present(picker, animated: true)
        picker.presentationController?.delegate = self
      }
      if screenshots {
        // 相册创建时间不能从临时文件的创建时间推断；读取所选 PHAsset 需要相册授权。
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          DispatchQueue.main.async {
            guard status == .authorized || status == .limited else {
              self.finish(nil, error: StockHistoryError.invalid("请允许访问所选截图，以读取拍摄时间并正确排序")); return
            }
            presentPicker()
          }
        }
      } else { presentPicker() }
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
          if !original.needsRecognition && !original.needsAutomaticTitle { value = try original.json() }
          else {
            guard let image = UIImage(data: try StockHistoryStorage.image(id)) else {
              throw StockHistoryError.invalid("历史长图无法读取")
            }
            let rows: [StockTextLine]
            if original.needsRecognition { rows = try StockHistoryProcessor.recognize(image) }
            else { rows = original.lines }
            let title: String
            if original.needsAutomaticTitle { title = try StockHistoryProcessor.documentTitle(image) }
            else { title = original.title }
            let table = StockHistoryDocument(schemaVersion: 2, id: original.id, title: title,
              createdAt: original.createdAt, imageName: original.imageName, lines: rows, reviewed: false,
              recognitionRevision: StockHistoryProcessor.recognitionRevision)
            let backup = url.deletingLastPathComponent().appendingPathComponent(
              original.schemaVersion == 1 ? "legacy-recognized-lines.json" : "before-refinement.json")
            if original.schemaVersion == 2 || !FileManager.default.fileExists(atPath: backup.path) {
              try JSONEncoder().encode(original).write(to: backup, options: .atomic)
            }
            try StockHistoryStorage.save(table.json())
            value = try table.json()
          }
        case "list": value = try StockHistoryStorage.list()
        case "reorder":
          guard let ids = call.arguments as? [String] else { throw StockHistoryError.invalid("排序参数无效") }
          try StockHistoryStorage.reorder(ids); value = nil
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
  private static func presentShare(_ call: FlutterMethodCall, onFinish: @escaping () -> Void) throws {
    precondition(Thread.isMainThread)
    switch call.method {
    case "shareBytes":
      guard let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String,
            let bytes = arguments["bytes"] as? FlutterStandardTypedData else {
        throw StockHistoryError.invalid("导出参数无效")
      }
      try StockExporter.shareBytes(name: name, data: bytes.data, onFinish: onFinish)
    case "shareImage":
      guard let id = call.arguments as? String else { throw StockHistoryError.invalid("盘点单标识缺失") }
      try StockExporter.shareImage(id: id, onFinish: onFinish)
    default:
      throw StockHistoryError.invalid("未知的分享操作")
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
    precondition(Thread.isMainThread)
    // 滑动关闭与系统取消回调可能先后到达，同一次选择只完成一次。
    guard activePicker === picker else { return }
    activePicker = nil
    if results.isEmpty {
      // 系统可能已开始关闭选择器，此时 dismiss 的 completion 不保证调用。
      // 取消结果必须立即返回，让 Flutter 清除加载状态，不能等待动画。
      finish(nil)
      picker.dismiss(animated: true)
      return
    }
    picker.dismiss(animated: true) {
      let selection = results[0]
      if self.screenshots {
        self.loadScreenshots(results)
        return
      }
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
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard let picker = activePicker, presentationController.presentedViewController === picker else { return }
    activePicker = nil
    finish(nil)
  }
  private func loadScreenshots(_ results: [PHPickerResult]) {
    do {
      guard (2...60).contains(results.count) else {
        throw StockHistoryError.invalid("请选择 2～60 张截图")
      }
      let selections = try results.map { selection -> (PHPickerResult, Date) in
        guard let identifier = selection.assetIdentifier,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
          asset.mediaType == .image, let date = asset.creationDate else {
          throw StockHistoryError.invalid("无法读取截图拍摄时间，请在系统相册权限中允许访问所选截图")
        }
        return (selection, date)
      }.sorted { $0.1 < $1.1 }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      loadScreenshotFiles(selections, index: 0, inputs: [], directory: directory)
    } catch { finish(nil, error: error) }
  }

  private func loadScreenshotFiles(_ selections: [(PHPickerResult, Date)], index: Int,
    inputs: [StockScreenshotInput], directory: URL) {
    precondition(Thread.isMainThread)
    if index == selections.count {
      process(directory, screenshots: inputs)
      return
    }
    selections[index].0.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
      do {
        if let error = error { throw error }
        guard let source = url else { throw StockHistoryError.invalid("无法读取第 \(index + 1) 张截图") }
        let local = directory.appendingPathComponent("\(index)").appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: local)
        let input = StockScreenshotInput(url: local, capturedAt: selections[index].1)
        DispatchQueue.main.async {
          self.loadScreenshotFiles(selections, index: index + 1, inputs: inputs + [input], directory: directory)
        }
      } catch { DispatchQueue.main.async { self.cleanup(directory, value: nil, error: error) } }
    }
  }

  private func process(_ url: URL, screenshots: [StockScreenshotInput]? = nil) {
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
          let progress: (String) -> Void = { text in
            DispatchQueue.main.async { self.processingView?.update(text) }
          }
          let document: StockHistoryDocument
          if let screenshots = screenshots {
            document = try StockHistoryProcessor.processScreenshots(screenshots, progress: progress)
          } else {
            document = try StockHistoryProcessor.process(url: url, video: video, crop: crop, progress: progress)
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
    update("正在读取盘点单素材")
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
