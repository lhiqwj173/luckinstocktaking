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
    case .invalidWeight(let range): return "称重超出合理范围（\(range) 克），请检查输入重量"
    }
  }
}

@available(iOS 16.0, *)
private struct IntentCategory: Decodable {
  enum WeighingType: String, Decodable {
    case portionBox
    case openedClip
    var label: String {
      switch self {
      case .portionBox: return "份盒称重"
      case .openedClip: return "开封夹称重"
      }
    }
    var tareGrams: Double {
      switch self {
      case .portionBox: return 250
      case .openedClip: return 20
      }
    }
  }

  let name: String
  let aliases: [String]
  let type: WeighingType
  let singleServingGrams: Double

  func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          aliases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          singleServingGrams.isFinite, singleServingGrams > 0 else {
      throw StocktakingError.invalidCatalog
    }
  }

  func calculate(weight: Double) throws -> String {
    try validate()
    guard weight.isFinite, weight >= 0 else {
      throw StocktakingError.invalidNumber
    }
    let tare = type.tareGrams
    let net = weight - tare
    guard net >= 0, net <= singleServingGrams else {
      throw StocktakingError.invalidWeight("\(tare)～\(tare + singleServingGrams)")
    }
    let tenths = Int((net / singleServingGrams * 10 + 0.5).rounded(.down))
    return "\(name)（\(type.label)）：\(tenths / 10).\(tenths % 10) 份"
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
struct FindStockCategoryIntent: AppIntent {
  static var title: LocalizedStringResource { "匹配称重品类" }
  static var description = IntentDescription("按名称或别名模糊查找品类，有多个候选时选择一个。")
  static var openAppWhenRun: Bool { false }

  @Parameter(title: "品类名称或别名")
  var query: String

  static var parameterSummary: some ParameterSummary {
    Summary("匹配 \(\.$query)")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let categories = try IntentCatalog.load()
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
    if best.count == 1 { return .result(value: best[0].name) }
    let selected = try await $query.requestDisambiguation(
      among: best.map(\.name),
      dialog: "找到多个品类，请选择准确的一项"
    )
    guard best.contains(where: { $0.name == selected }) else {
      throw StocktakingError.noMatch
    }
    return .result(value: selected)
  }
}

@available(iOS 16.0, *)
struct CalculateStockIntent: AppIntent {
  static var title: LocalizedStringResource { "称重盘点计算" }
  static var description = IntentDescription("根据已匹配的品类和称重计算 0～1 份。")
  static var openAppWhenRun: Bool { false }

  @Parameter(title: "已匹配的品类")
  var categoryName: String

  @Parameter(title: "称重（克）")
  var weightGrams: Double

  static var parameterSummary: some ParameterSummary {
    Summary("计算 \(\.$categoryName) 的 \(\.$weightGrams) 克称重")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let categories = try IntentCatalog.load()
    let key = IntentCatalog.normalize(categoryName)
    guard let chosen = categories.first(where: { IntentCatalog.normalize($0.name) == key }) else {
      throw StocktakingError.noMatch
    }
    return .result(value: try chosen.calculate(weight: weightGrams))
  }
}
