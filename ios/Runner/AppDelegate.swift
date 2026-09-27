import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let group = "group.com.luckinstocktaking.shared"
  private let key = "catalog.v1"

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.luckinstocktaking/catalog",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "APP_DELEGATE", message: "应用代理已释放", details: nil))
        return
      }
      let keyboardBundle = Bundle.main.bundleURL
        .appendingPathComponent("PlugIns/StockKeyboard.appex", isDirectory: true)
      if call.method == "diagnostics" {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let appID = Bundle.main.bundleIdentifier else {
          result(FlutterError(code: "INVALID_APP_BUNDLE", message: "主应用版本或标识缺失", details: nil))
          return
        }
        let embedded = FileManager.default.fileExists(atPath: keyboardBundle.path)
        let keyboardID: String
        if embedded {
          guard let identifier = Bundle(url: keyboardBundle)?.bundleIdentifier else {
            result(FlutterError(code: "INVALID_KEYBOARD_BUNDLE", message: "键盘扩展的 Info.plist 无法读取", details: nil))
            return
          }
          keyboardID = identifier
        } else {
          keyboardID = "扩展缺失"
        }
        result([
          "version": version,
          "appBundleId": appID,
          "keyboardEmbedded": embedded,
          "keyboardBundleId": keyboardID,
          "appGroupAvailable": FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: self.group
          ) != nil,
        ])
        return
      }
      guard FileManager.default.fileExists(atPath: keyboardBundle.path) else {
        result(FlutterError(
          code: "KEYBOARD_NOT_EMBEDDED",
          message: "安装包未包含称重盘点键盘扩展；重新签名时须保留并签名 PlugIns/StockKeyboard.appex",
          details: nil
        ))
        return
      }
      guard let defaults = UserDefaults(suiteName: self.group) else {
        result(FlutterError(code: "APP_GROUP", message: "无法打开共享数据容器，请检查 App Groups 签名配置", details: nil))
        return
      }
      switch call.method {
      case "load":
        result(defaults.string(forKey: self.key) ?? "[]")
      case "save":
        guard let json = call.arguments as? String,
              let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              decoded is [[String: Any]] else {
          result(FlutterError(code: "INVALID_CATALOG", message: "品类数据格式错误", details: nil))
          return
        }
        defaults.set(json, forKey: self.key)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
