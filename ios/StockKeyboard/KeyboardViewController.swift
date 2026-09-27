import UIKit

private struct StockCategory: Decodable {
  let name: String
  let aliases: [String]
  let tareGrams: Double
  let referenceGrams: Double
  let referenceQuantity: Double
  let decimals: Int

  func calculate(_ weight: Double) throws -> String {
    guard weight.isFinite, weight >= tareGrams, tareGrams >= 0,
          referenceGrams.isFinite, referenceGrams > 0,
          referenceQuantity.isFinite, referenceQuantity > 0,
          (0...3).contains(decimals) else {
      throw StockError.invalidRule
    }
    let value = (weight - tareGrams) / referenceGrams * referenceQuantity
    guard value.isFinite else { throw StockError.invalidRule }
    return String(format: "%.*f", decimals, value)
  }
}

private enum StockError: Error {
  case invalidRule
}

final class KeyboardViewController: UIInputViewController {
  private let group = "group.com.luckinstocktaking.shared"
  private let key = "catalog.v1"
  private var categories: [StockCategory] = []
  private var selected: StockCategory?
  private var weight = ""
  private var resultText: String?
  private let titleLabel = UILabel()
  private let weightLabel = UILabel()
  private let resultLabel = UILabel()
  private let categoryStack = UIStackView()
  private let root = UIStackView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .secondarySystemBackground
    view.heightAnchor.constraint(equalToConstant: 350).isActive = true
    root.axis = .vertical
    root.spacing = 5
    root.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      root.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
      root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
    ])

    let header = UIStackView()
    header.axis = .horizontal
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    header.addArrangedSubview(titleLabel)
    let next = button("🌐", action: #selector(nextKeyboard))
    next.widthAnchor.constraint(equalToConstant: 52).isActive = true
    header.addArrangedSubview(next)
    root.addArrangedSubview(header)

    let scroll = UIScrollView()
    scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
    categoryStack.axis = .horizontal
    categoryStack.spacing = 6
    categoryStack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(categoryStack)
    NSLayoutConstraint.activate([
      categoryStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      categoryStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      categoryStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      categoryStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      categoryStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    root.addArrangedSubview(scroll)

    let status = UIStackView()
    status.axis = .horizontal
    status.distribution = .fillEqually
    weightLabel.textAlignment = .center
    resultLabel.textAlignment = .center
    status.addArrangedSubview(weightLabel)
    status.addArrangedSubview(resultLabel)
    root.addArrangedSubview(status)

    for row in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]] {
      let stack = UIStackView()
      stack.axis = .horizontal
      stack.distribution = .fillEqually
      stack.spacing = 5
      for digit in row { stack.addArrangedSubview(button(digit, action: #selector(pressDigit(_:)))) }
      root.addArrangedSubview(stack)
    }
    let actions = UIStackView()
    actions.axis = .horizontal
    actions.distribution = .fillEqually
    actions.spacing = 5
    actions.addArrangedSubview(button("清空", action: #selector(clearWeight)))
    actions.addArrangedSubview(button("计算", action: #selector(calculate)))
    actions.addArrangedSubview(button("填入结果", action: #selector(insertResult)))
    root.addArrangedSubview(actions)
    refreshLabels()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    loadCategories()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    showCategories()
  }

  private func button(_ text: String, action: Selector) -> UIButton {
    let control = UIButton(type: .system)
    control.setTitle(text, for: .normal)
    control.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
    control.backgroundColor = .tertiarySystemBackground
    control.layer.cornerRadius = 6
    control.addTarget(self, action: action, for: .touchUpInside)
    return control
  }

  private func loadCategories() {
    guard let defaults = UserDefaults(suiteName: group) else {
      titleLabel.text = "共享数据不可用：检查签名"
      return
    }
    guard let raw = defaults.string(forKey: key) else {
      categories = []
      titleLabel.text = "请先在主 App 录入品类"
      showCategories()
      return
    }
    do {
      categories = try JSONDecoder().decode([StockCategory].self, from: Data(raw.utf8))
    } catch {
      fatalError("品类数据损坏：\(error)")
    }
    titleLabel.text = "选择品类并输入克数"
    showCategories()
  }

  private func showCategories() {
    categoryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let input = (textDocumentProxy.documentContextBeforeInput ?? "")
      .split(whereSeparator: { $0.isWhitespace || ",，。:：;；\n".contains($0) })
      .last.map(String.init)?.lowercased() ?? ""
    let ordered = categories.sorted { left, right in
      let l = matchScore(left, input)
      let r = matchScore(right, input)
      return l == r ? left.name < right.name : l > r
    }
    for category in ordered {
      let control = button(category.name, action: #selector(selectCategory(_:)))
      control.accessibilityIdentifier = category.name
      control.backgroundColor = selected?.name == category.name ? .systemTeal : .tertiarySystemBackground
      control.setTitleColor(selected?.name == category.name ? .white : .label, for: .normal)
      control.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
      categoryStack.addArrangedSubview(control)
    }
  }

  private func matchScore(_ category: StockCategory, _ input: String) -> Int {
    guard !input.isEmpty else { return 0 }
    let names = [category.name] + category.aliases
    if names.contains(where: { $0.lowercased() == input }) { return 2 }
    if names.contains(where: { $0.lowercased().contains(input) || input.contains($0.lowercased()) }) { return 1 }
    return 0
  }

  private func refreshLabels() {
    weightLabel.text = "称重：\(weight.isEmpty ? "—" : weight) 克"
    resultLabel.text = "结果：\(resultText ?? "—")"
  }

  @objc private func nextKeyboard() { advanceToNextInputMode() }

  @objc private func selectCategory(_ sender: UIButton) {
    selected = categories.first { $0.name == sender.accessibilityIdentifier }
    resultText = nil
    showCategories()
    refreshLabels()
  }

  @objc private func pressDigit(_ sender: UIButton) {
    guard let digit = sender.title(for: .normal) else { return }
    if digit == "⌫" { if !weight.isEmpty { weight.removeLast() } }
    else if digit == "." { if !weight.contains(".") { weight += weight.isEmpty ? "0." : "." } }
    else if weight.count < 15 { weight += digit }
    resultText = nil
    refreshLabels()
  }

  @objc private func clearWeight() { weight = ""; resultText = nil; refreshLabels() }

  @objc private func calculate() {
    guard let category = selected else { resultLabel.text = "请选品类"; return }
    guard let value = Double(weight), value.isFinite else { resultLabel.text = "称重无效"; return }
    do {
      resultText = try category.calculate(value)
      refreshLabels()
    } catch {
      resultText = nil
      resultLabel.text = "称重或规则无效"
    }
  }

  @objc private func insertResult() {
    guard let value = resultText else { resultLabel.text = "请先计算"; return }
    textDocumentProxy.insertText(value)
  }
}
