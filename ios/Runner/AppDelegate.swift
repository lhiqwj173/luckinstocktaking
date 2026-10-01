import Flutter
import UIKit

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
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    historyBridge = StockHistoryBridge(messenger: engineBridge.applicationRegistrar.messenger())
    let channel = FlutterMethodChannel(
      name: "com.luckinstocktaking/catalog",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
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
