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
      let keyboardBundle = Bundle.main.bundleURL
        .appendingPathComponent("PlugIns/StockKeyboard.appex", isDirectory: true)
      guard FileManager.default.fileExists(atPath: keyboardBundle.path) else {
        result(FlutterError(
          code: "KEYBOARD_NOT_EMBEDDED",
          message: "安装包未包含称重盘点键盘扩展；重新签名时须保留并签名 PlugIns/StockKeyboard.appex",
          details: nil
        ))
        return
      }
      guard let self, let defaults = UserDefaults(suiteName: self.group) else {
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
