import Flutter
import UIKit
import UniformTypeIdentifiers

/// 只读取文件，解析、预览和持久化由 Flutter 统一处理。
final class CatalogFileImporter: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?

  func open(result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "CATALOG_IMPORT_BUSY", message: "请先完成当前文件选择", details: nil))
      return
    }
    guard let scene = UIApplication.shared.connectedScenes
      .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
      var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
      result(FlutterError(code: "CATALOG_IMPORT_UNAVAILABLE", message: "无法打开文件选择器，请保持应用在前台", details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    pending = result
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard urls.count == 1 else {
      finish(FlutterError(code: "INVALID_CATALOG_FILE", message: "请选择一个品类规则文件", details: nil))
      return
    }
    do {
      let json = try String(contentsOf: urls[0], encoding: .utf8)
      finish(json)
    } catch {
      finish(FlutterError(code: "CATALOG_FILE_READ_FAILED", message: "读取规则文件失败：\(error.localizedDescription)", details: nil))
    }
  }

  private func finish(_ value: Any?) {
    guard let result = pending else { preconditionFailure("品类文件选择缺少待处理请求") }
    pending = nil
    result(value)
  }
}

enum CatalogStorage {
  static let key = "catalog.v2"

  static func load() throws -> String {
    if let stored = UserDefaults.standard.object(forKey: key) {
      guard let json = stored as? String else {
        throw CatalogStorageError.invalidStoredCatalog
      }
      return json
    }
    return "[]"
  }

  static func save(_ json: String) throws {
    guard let data = json.data(using: .utf8),
          let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw CatalogStorageError.invalidCatalog
    }
    guard decoded.allSatisfy({ $0["name"] is String }) else {
      throw CatalogStorageError.invalidCatalog
    }
    UserDefaults.standard.set(json, forKey: key)
  }
}

enum CatalogStorageError: Error {
  case invalidStoredCatalog
  case invalidCatalog
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var historyBridge: StockHistoryBridge?
  private var recentWeighingBridge: RecentWeighingBridge?
  private let catalogFileImporter = CatalogFileImporter()
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    historyBridge = StockHistoryBridge(messenger: engineBridge.applicationRegistrar.messenger())
    recentWeighingBridge = RecentWeighingBridge(messenger: engineBridge.applicationRegistrar.messenger())
    let channel = FlutterMethodChannel(
      name: "com.luckinstocktaking/catalog",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [self] call, result in
      switch call.method {
      case "importFile":
        catalogFileImporter.open(result: result)
      case "diagnostics":
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let appID = Bundle.main.bundleIdentifier else {
          result(FlutterError(code: "INVALID_APP_BUNDLE", message: "主应用版本或标识缺失", details: nil))
          return
        }
        result(["version": version, "appBundleId": appID])
      case "load":
        do {
          result(try CatalogStorage.load())
        } catch {
          result(FlutterError(code: "INVALID_STORED_CATALOG", message: "本地品类数据格式错误", details: nil))
        }
      case "save":
        guard let json = call.arguments as? String else {
          result(FlutterError(code: "INVALID_CATALOG", message: "品类数据必须为 JSON 文本", details: nil))
          return
        }
        do {
          try CatalogStorage.save(json)
          result(nil)
        } catch {
          result(FlutterError(code: "INVALID_CATALOG", message: "品类数据格式错误", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
