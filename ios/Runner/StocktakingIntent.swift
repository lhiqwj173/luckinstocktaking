import AppIntents
import Foundation

@available(iOS 16.0, *)
private struct IntentCategory: Decodable {
  let name: String
  let aliases: [String]
  let tareGrams: Double
  let referenceGrams: Double
  let referenceQuantity: Double
  let decimals: Int

  func calculate(weight: Double) throws -> String {
    guard weight.isFinite, weight >= 0, tareGrams.isFinite, tareGrams >= 0,
          referenceGrams.isFinite, referenceGrams > 0,
          referenceQuantity.isFinite, referenceQuantity > 0,
          (0...3).contains(decimals), weight >= tareGrams else {
      throw StocktakingIntentError.invalidRule
    }
    let value = (weight - tareGrams) / referenceGrams * referenceQuantity
    guard value.isFinite else { throw StocktakingIntentError.invalidRule }
    return String(format: "%.*f", decimals, value)
  }
}

@available(iOS 16.0, *)
private enum StocktakingIntentError: LocalizedError {
  case emptyCatalog
  case noMatch
  case invalidRule

  var errorDescription: String? {
    switch self {
    case .emptyCatalog: return "请先在称重盘点助手中录入品类"
    case .noMatch: return "没有匹配的品类，请检查名称或别名"
    case .invalidRule: return "称重或品类计算规则无效"
    }
  }
}

@available(iOS 16.0, *)
struct CalculateStockIntent: AppIntent {
  static var title: LocalizedStringResource { "称重盘点计算" }
  static var description = IntentDescription("输入品类名称或别名和称重，从称重盘点助手的品类库计算结果。")
  static var openAppWhenRun: Bool { false }

  @Parameter(title: "品类名称或别名")
  var categoryName: String

  @Parameter(title: "称重（克）")
  var weightGrams: Double

  static var parameterSummary: some ParameterSummary {
    Summary("计算 \(\.$categoryName) 的 \(\.$weightGrams) 克称重")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let data = Data(try CatalogStorage.load().utf8)
    let categories = try JSONDecoder().decode([IntentCategory].self, from: data)
    guard !categories.isEmpty else { throw StocktakingIntentError.emptyCatalog }

    let query = Self.normalize(categoryName)
    guard !query.isEmpty else { throw StocktakingIntentError.noMatch }
    let matches = categories.compactMap { category -> (score: Int, category: IntentCategory)? in
      let names = [category.name] + category.aliases
      if names.contains(where: { Self.normalize($0) == query }) {
        return (2, category)
      }
      if names.contains(where: { Self.normalize($0).contains(query) }) {
        return (1, category)
      }
      return nil
    }.sorted { left, right in
      left.score == right.score
        ? left.category.name < right.category.name
        : left.score > right.score
    }
    guard !matches.isEmpty else { throw StocktakingIntentError.noMatch }

    let bestScore = matches[0].score
    let best = matches.filter { $0.score == bestScore }.map(\.category)
    let chosen: IntentCategory
    if best.count == 1 {
      chosen = best[0]
    } else {
      let name = try await $categoryName.requestDisambiguation(
        among: best.map(\.name),
        dialog: "请选择要计算的品类"
      )
      guard let selected = best.first(where: { $0.name == name }) else {
        throw StocktakingIntentError.noMatch
      }
      chosen = selected
    }
    return .result(value: try chosen.calculate(weight: weightGrams))
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace }
  }
}

@available(iOS 16.0, *)
struct StocktakingShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CalculateStockIntent(),
      phrases: ["用\(\.applicationName)称重盘点"],
      shortTitle: "称重盘点",
      systemImageName: "scalemass"
    )
  }
}
