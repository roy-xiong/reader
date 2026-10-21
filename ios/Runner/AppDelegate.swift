import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

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
    if #available(iOS 15.0, *) { configuration.selection = .ordered }
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    picker.modalPresentationStyle = .fullScreen
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else { finishPhotos([]); return }
    // 逐张加载，避免多张高分辨率照片同时解码造成内存峰值。
    func load(_ index: Int, _ copies: [String]) {
      guard index < results.count else { finishPhotos(copies); return }
      let provider = results[index].itemProvider
      guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
        load(index + 1, copies); return
      }
      // 文件回调中的 URL 仅在回调期间有效；在受控串行队列同步读取，不把临时 URL 留给异步任务。
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
        guard let self = self else { return }
        let path: String? = self.imageQueue.sync {
          autoreleasepool { url.flatMap { self.writePhoto(at: $0, index: index) } }
        }
        var next = copies
        if let path = path { next.append(path) }
        DispatchQueue.main.async { load(index + 1, next) }
      }
    }
    load(0, [])
  }

  /** 直接从 HEIC/JPEG 等源文件降采样，避免先完整解码高像素照片造成内存峰值。 */
  private func writePhoto(at sourceURL: URL, index: Int) -> String? {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048,
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else { return nil }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString.lowercased() + "_照片\(index + 1).jpg")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
      UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image,
      [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: url); return nil
    }
    return url.path
  }

  private func finishPhotos(_ paths: [String]) {
    let result = photoResult
    photoResult = nil
    result?(paths)
  }
}
