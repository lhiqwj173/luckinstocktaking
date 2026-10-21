import Flutter
import Foundation

struct RecentWeighingRecord: Codable {
  let id: String
  let createdAt: Double
  let categoryName: String
  let weightGrams: Double
  let tareGrams: Double
  let singleServingGrams: Double
  let typeLabel: String
  let result: String
  let source: String
  let allowMultiple: Bool

  func validate() throws {
    guard UUID(uuidString: id) != nil,
          createdAt.isFinite, createdAt >= 0, createdAt <= 8640000000000000,
          createdAt.rounded(.down) == createdAt,
          !categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          weightGrams.isFinite, tareGrams.isFinite, tareGrams >= 0,
          weightGrams >= tareGrams,
          singleServingGrams.isFinite, singleServingGrams > 0,
          !typeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          result.range(of: #"^\d+\.\d（(?:\d+\.\d{3}|\d+(?:\.\d+)?e[+-]?\d+)）$"#, options: .regularExpression) != nil,
          ["app", "shortcut"].contains(source) else {
      throw RecentWeighingError.invalidRecord
    }
  }
}

enum RecentWeighingError: LocalizedError {
  case invalidRecord
  case missingRecord

  var errorDescription: String? {
    switch self {
    case .invalidRecord: return "最近称重数据格式无效，请检查记录"
    case .missingRecord: return "该称重记录已不存在，请刷新后重试"
    }
  }
}

/// App 与快捷指令共用同一串行存储；原子写入成功后才返回计算结果。
final class RecentWeighingStorage {
  static let shared = RecentWeighingStorage()
  private let queue = DispatchQueue(label: "com.luckinstocktaking.recent-weighing.storage")
  private let fileURL: URL?

  init(fileURL: URL? = nil) { self.fileURL = fileURL }

  private func location() throws -> URL {
    if let fileURL { return fileURL }
    let folder = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    return folder.appendingPathComponent("recent-weighing-v1.json")
  }

  private func read() throws -> [RecentWeighingRecord] {
    let url = try location()
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let records = try JSONDecoder().decode([RecentWeighingRecord].self, from: Data(contentsOf: url))
    guard records.count <= 100, Set(records.map(\.id)).count == records.count else {
      throw RecentWeighingError.invalidRecord
    }
    for record in records { try record.validate() }
    return records
  }

  private func write(_ records: [RecentWeighingRecord]) throws {
    try JSONEncoder().encode(records).write(to: location(), options: .atomic)
  }

  func load() throws -> [RecentWeighingRecord] { try queue.sync { try read() } }

  @discardableResult
  func append(categoryName: String, weightGrams: Double, tareGrams: Double,
              singleServingGrams: Double, typeLabel: String, result: String,
              source: String, allowMultiple: Bool) throws -> [RecentWeighingRecord] {
    try queue.sync {
      let record = RecentWeighingRecord(id: UUID().uuidString,
        createdAt: (Date().timeIntervalSince1970 * 1000).rounded(.down),
        categoryName: categoryName, weightGrams: weightGrams, tareGrams: tareGrams,
        singleServingGrams: singleServingGrams, typeLabel: typeLabel, result: result,
        source: source, allowMultiple: allowMultiple)
      try record.validate()
      var records = try read()
      records.insert(record, at: 0)
      records = Array(records.prefix(100))
      try write(records)
      return records
    }
  }

  func delete(id: String) throws -> [RecentWeighingRecord] {
    try queue.sync {
      var records = try read()
      guard let index = records.firstIndex(where: { $0.id == id }) else {
        throw RecentWeighingError.missingRecord
      }
      records.remove(at: index)
      try write(records)
      return records
    }
  }

  func clear() throws -> [RecentWeighingRecord] {
    try queue.sync {
      _ = try read()
      try write([])
      return []
    }
  }
}

final class RecentWeighingBridge {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.luckinstocktaking.recent-weighing.bridge")

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.luckinstocktaking/recent-weighing", binaryMessenger: messenger)
    channel.setMethodCallHandler { [self] call, callback in
      queue.async {
        do {
          let records: [RecentWeighingRecord]
          let store = RecentWeighingStorage.shared
          switch call.method {
          case "load": records = try store.load()
          case "clear": records = try store.clear()
          case "delete":
            guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
              throw RecentWeighingError.invalidRecord
            }
            records = try store.delete(id: id)
          case "append":
            guard let args = call.arguments as? [String: Any],
                  let name = args["categoryName"] as? String,
                  let weight = args["weightGrams"] as? Double,
                  let tare = args["tareGrams"] as? Double,
                  let serving = args["singleServingGrams"] as? Double,
                  let type = args["typeLabel"] as? String,
                  let result = args["result"] as? String,
                  let allowMultiple = args["allowMultiple"] as? Bool,
                  let source = args["source"] as? String, source == "app" else {
              throw RecentWeighingError.invalidRecord
            }
            records = try store.append(categoryName: name, weightGrams: weight,
              tareGrams: tare, singleServingGrams: serving, typeLabel: type, result: result,
              source: source, allowMultiple: allowMultiple)
          default:
            DispatchQueue.main.async { callback(FlutterMethodNotImplemented) }
            return
          }
          let data = try JSONEncoder().encode(records)
          guard let json = String(data: data, encoding: .utf8) else {
            throw RecentWeighingError.invalidRecord
          }
          DispatchQueue.main.async { callback(json) }
        } catch {
          DispatchQueue.main.async {
            callback(FlutterError(code: "RECENT_WEIGHING_FAILED",
              message: error.localizedDescription, details: String(reflecting: error)))
          }
        }
      }
    }
  }
}

