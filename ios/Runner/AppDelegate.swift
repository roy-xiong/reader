import Flutter
import UIKit
import PhotosUI

/**
 * iOS 系统入口。书籍、字体使用 Wi-Fi 上传；背景照片由系统照片选择器提供。
 * 照片逐张缩小后存入临时目录，通道返回和控制器展示始终在主线程执行。
 */
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PHPickerViewControllerDelegate {
  private var bridge: FlutterMethodChannel?
  private var photoResult: FlutterResult?
  private let imageQueue = DispatchQueue(label: "com.xiongjian.reader.photos", qos: .userInitiated)

  override func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    bridge = FlutterMethodChannel(name: "com.xiongjian.reader/platform",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    bridge?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "closed", message: "阅读器已关闭", details: nil)); return
      }
      switch call.method {
      case "supportPath":
        do {
          let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
          let root = base.appendingPathComponent("Reader", isDirectory: true)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          result(root.path)
        } catch { result(FlutterError(code: "storage", message: "无法创建本地书架", details: nil)) }
      case "pickImages": self.pickPhotos(result)
      case "pick":
        result(FlutterError(code: "wifi", message: "请从 Wi-Fi 上传页面导入书籍和字体", details: nil))
      case "discard":
        let paths = call.arguments as? [String] ?? []
        self.imageQueue.async {
          let prefix = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path + "/"
          for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            if file.path.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
          }
        }
        result(nil)
      case "readingMode", "appearance": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickPhotos(_ result: @escaping FlutterResult) {
    guard photoResult == nil else {
      result(FlutterError(code: "busy", message: "照片选择器已打开", details: nil)); return
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "window", message: "当前页面不可用", details: nil)); return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    photoResult = result
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 0
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else { finishPhotos([]); return }
    // 逐张加载，避免多张高分辨率照片同时解码造成内存峰值。
    func load(_ index: Int, _ copies: [String]) {
      guard index < results.count else { finishPhotos(copies); return }
      let provider = results[index].itemProvider
      guard provider.canLoadObject(ofClass: UIImage.self) else { load(index + 1, copies); return }
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let self = self else { return }
        self.imageQueue.async {
          var next = copies
          if let image = object as? UIImage, let path = self.writePhoto(image, index: index) { next.append(path) }
          DispatchQueue.main.async { load(index + 1, next) }
        }
      }
    }
    load(0, [])
  }

  private func writePhoto(_ image: UIImage, index: Int) -> String? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    let ratio = min(1, 2048 / max(image.size.width, image.size.height))
    let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let data = resized.jpegData(compressionQuality: 0.9) else { return nil }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString.lowercased() + "_照片\(index + 1).jpg")
    do { try data.write(to: url, options: .atomic); return url.path } catch { return nil }
  }

  private func finishPhotos(_ paths: [String]) {
    let result = photoResult
    photoResult = nil
    result?(paths)
  }
}
