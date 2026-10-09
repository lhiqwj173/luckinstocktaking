import AppIntents
import Foundation

@available(iOS 16.0, *)
private enum StocktakingError: LocalizedError {
  case emptyCatalog
  case noMatch
  case invalidCatalog
  case invalidNumber
  case invalidWeight(String)

  var errorDescription: String? {
    switch self {
    case .emptyCatalog: return "请先在称重盘点助手中录入品类"
    case .noMatch: return "没有匹配的品类，请检查名称或别名"
    case .invalidCatalog: return "品类数据无效，请在称重盘点助手中检查"
    case .invalidNumber: return "请输入有效的称重（克）"
    case .invalidWeight(let range): return "称重超出合理范围（\(range)），请检查输入重量"
    }
  }
}

@available(iOS 16.0, *)
struct IntentCategory: Decodable {
  enum WeighingType: String, Decodable {
    case portionBox
    case openedClip
    case other
    var label: String {
      switch self {
      case .portionBox: return "份盒称重"
      case .openedClip: return "开封夹称重"
      case .other: return "其他"
      }
    }
    var fixedTareGrams: Double? {
      switch self {
      case .portionBox: return 300
      case .openedClip: return 21
      case .other: return nil
      }
    }
  }

  let name: String
  let aliases: [String]
  let type: WeighingType
  let singleServingGrams: Double
  let customTareGrams: Double?
  let allowMultiple: Bool

  private enum CodingKeys: String, CodingKey {
    case name, aliases, type, singleServingGrams, customTareGrams, allowMultiple
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    name = try values.decode(String.self, forKey: .name)
    aliases = try values.decode([String].self, forKey: .aliases)
    type = try values.decode(WeighingType.self, forKey: .type)
    singleServingGrams = try values.decode(Double.self, forKey: .singleServingGrams)
    customTareGrams = try values.decodeIfPresent(Double.self, forKey: .customTareGrams)
    if values.contains(.allowMultiple) {
      allowMultiple = try values.decode(Bool.self, forKey: .allowMultiple)
    } else {
      allowMultiple = false
    }
  }

  func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          aliases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          singleServingGrams.isFinite, singleServingGrams > 0 else {
      throw StocktakingError.invalidCatalog
    }
    if type == .other {
      guard let tare = customTareGrams, tare.isFinite, tare >= 0 else {
        throw StocktakingError.invalidCatalog
      }
    } else if customTareGrams != nil {
      throw StocktakingError.invalidCatalog
    }
    guard let tare = type.fixedTareGrams ?? customTareGrams,
          (tare + singleServingGrams).isFinite else {
      throw StocktakingError.invalidCatalog
    }
  }

  func calculate(weight: Double) throws -> String {
    try validate()
    guard weight.isFinite, weight >= 0 else {
      throw StocktakingError.invalidNumber
    }
    guard let tare = type.fixedTareGrams ?? customTareGrams else {
      throw StocktakingError.invalidCatalog
    }
    let net = weight - tare
    guard net >= 0 else {
      throw StocktakingError.invalidWeight(
        "\(tare) 克以上"
      )
    }
    let ratio = net / singleServingGrams
    guard ratio.isFinite else { throw StocktakingError.invalidNumber }
    let scaled = ratio * 10
    let tenths: Int
    if !allowMultiple && ratio >= 0.9 {
      tenths = 9
    } else {
      guard scaled.isFinite, scaled < Double(Int.max) else {
        throw StocktakingError.invalidNumber
      }
      let roundedTenths = Int(scaled.rounded(.down))
      tenths = allowMultiple ? max(1, roundedTenths) : min(9, max(1, roundedTenths))
    }
    let exactRatio = String(
      format: "%.3f",
      locale: Locale(identifier: "en_US_POSIX"),
      ratio
    )
    return "\(name)：\(tenths / 10).\(tenths % 10)（\(exactRatio)）份"
  }
}

@available(iOS 16.0, *)
private enum IntentCatalog {
  static func normalize(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace }
  }

  static func load() throws -> [IntentCategory] {
    let data = Data(try CatalogStorage.load().utf8)
    let categories = try JSONDecoder().decode([IntentCategory].self, from: data)
    guard !categories.isEmpty else { throw StocktakingError.emptyCatalog }
    for category in categories { try category.validate() }
    let names = categories.flatMap { [$0.name] + $0.aliases }.map(normalize)
    guard Set(names).count == names.count else { throw StocktakingError.invalidCatalog }
    return categories
  }
}

@available(iOS 16.0, *)
struct CalculateStockIntent: AppIntent {
  static var title: LocalizedStringResource { "称重盘点计算" }
  static var description = IntentDescription("先按名称或别名确认品类，再输入称重；返回正式名称和计算结果。")
  static var openAppWhenRun: Bool { false }

  @Parameter(title: "品类名称或别名")
  var categoryName: String?

  @Parameter(title: "称重（克）")
  var weightGrams: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("计算 \(\.$categoryName) 的称重 \(\.$weightGrams) 克")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let categories = try IntentCatalog.load()
    let query: String
    if let provided = categoryName {
      query = provided
    } else {
      query = try await $categoryName.requestValue("请输入品类名称或别名")
    }
    let key = IntentCatalog.normalize(query)
    guard !key.isEmpty else { throw StocktakingError.noMatch }
    let matches = categories.compactMap { category -> (score: Int, category: IntentCategory)? in
      let names = [category.name] + category.aliases
      if names.contains(where: { IntentCatalog.normalize($0) == key }) {
        return (2, category)
      }
      if names.contains(where: { IntentCatalog.normalize($0).contains(key) }) {
        return (1, category)
      }
      return nil
    }.sorted { left, right in
      left.score == right.score
        ? left.category.name < right.category.name
        : left.score > right.score
    }
    guard let first = matches.first else { throw StocktakingError.noMatch }
    let best = matches.filter { $0.score == first.score }.map(\.category)
    let chosen: IntentCategory
    if best.count == 1 {
      chosen = best[0]
    } else {
      let selected = try await $categoryName.requestDisambiguation(
        among: best.map(\.name),
        dialog: "找到多个品类，请选择准确的一项"
      )
      guard let category = best.first(where: { $0.name == selected }) else {
        throw StocktakingError.noMatch
      }
      chosen = category
    }
    let weight: Double
    if let provided = weightGrams {
      weight = provided
    } else {
      weight = try await $weightGrams.requestValue("请输入称重（克）")
    }
    return .result(value: try chosen.calculate(weight: weight))
  }
}

@available(iOS 16.0, *)
struct ReadOldStockIntent: AppIntent {
  static var title: LocalizedStringResource { "拼接盘点单录屏" }
  static var description = IntentDescription("将系统录屏拼成长截图并识别文字，保存为待校对历史；也支持直接传入截图。")
  static var openAppWhenRun: Bool { true }

  // supportedContentTypes 的文件参数初始化方法要求 iOS 18；此快捷指令兼容 iOS 16。
  @Parameter(title: "盘点单文件", supportedTypeIdentifiers: ["public.movie", "public.image"])
  var file: IntentFile
  @Parameter(title: "录屏视频", default: true)
  var video: Bool

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let crop = StockCrop.automatic
    try crop.validate()
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(video ? "mov" : "png")
    if let source = file.fileURL {
      let scoped = source.startAccessingSecurityScopedResource()
      defer { if scoped { source.stopAccessingSecurityScopedResource() } }
      try FileManager.default.copyItem(at: source, to: local)
    } else {
      try file.data.write(to: local, options: .atomic)
    }
    let document: StockHistoryDocument = try await withCheckedThrowingContinuation { continuation in
      StockHistoryStorage.queue.async {
        do {
          let record = try StockHistoryProcessor.process(url: local, video: video, crop: crop)
          try FileManager.default.removeItem(at: local)
          UserDefaults.standard.set(record.id, forKey: StockHistoryStorage.pendingKey)
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: StockHistoryStorage.readyNotification, object: nil)
          }
          continuation.resume(returning: record)
        } catch {
          do { try FileManager.default.removeItem(at: local) }
          catch { continuation.resume(throwing: error); return }
          continuation.resume(throwing: error)
        }
      }
    }
    return .result(value: "已保存 \(document.lines.count) 项货物，请在「旧盘点单」中校对：\(document.title)")
  }
}
