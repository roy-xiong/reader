import Flutter
import UIKit
import PhotosUI
import Photos
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
      case "photoAccess": result(self.photoAccessName())
      case "managePhotoAccess": self.managePhotoAccess(result)
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
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.preferredAssetRepresentationMode = .current
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
    // 逐张加载，避免多张高分辨率照片同时解码造成内存峰值；失败数量也返回 Flutter。
    func load(_ index: Int, _ copies: [String], _ failed: Int) {
      guard index < results.count else { finishPhotos(copies, failed: failed); return }
      let provider = results[index].itemProvider
      self.loadPhoto(provider, index: index) { path in
        var next = copies
        if let path = path { next.append(path) }
        load(index + 1, next, failed + (path == nil ? 1 : 0))
      }
    }
    load(0, [], 0)
  }

  /** 系统文件表示不可用时，尝试 UIImage 表示；包含 iCloud、编辑后的照片与兼容性回退。 */
  private func loadPhoto(_ provider: NSItemProvider, index: Int, completion: @escaping (String?) -> Void) {
    func fallback() {
      guard provider.canLoadObject(ofClass: UIImage.self) else {
        DispatchQueue.main.async { completion(nil) }; return
      }
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let self = self else { DispatchQueue.main.async { completion(nil) }; return }
        self.imageQueue.async {
          let path: String? = autoreleasepool {
            guard let image = object as? UIImage else { return nil }
            let longest = max(image.size.width, image.size.height)
            guard longest > 0 else { return nil }
            let ratio = min(1, 2048 / longest)
            let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
              image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let bytes = rendered.jpegData(compressionQuality: 0.9) else { return nil }
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent(UUID().uuidString.lowercased() + "_照片\(index + 1).jpg")
            do { try bytes.write(to: file, options: .atomic); return file.path } catch { return nil }
          }
          DispatchQueue.main.async { completion(path) }
        }
      }
    }
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { fallback(); return }
    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
      guard let self = self else { DispatchQueue.main.async { completion(nil) }; return }
      // 临时文件只在回调期间有效，必须在回调返回前完成降采样读取。
      let path: String? = self.imageQueue.sync {
        autoreleasepool { url.flatMap { self.writePhoto(at: $0, index: index) } }
      }
      if let path = path { DispatchQueue.main.async { completion(path) } }
      else { fallback() }
    }
  }

  private func photoAccessName() -> String {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized: return "authorized"
    case .limited: return "limited"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "system"
    }
  }

  /** 显式权限入口：首次由系统询问，受限时允许管理选择或前往设置申请完全访问。 */
  private func managePhotoAccess(_ result: @escaping FlutterResult) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
        DispatchQueue.main.async { result(nil) }
      }
      return
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "window", message: "当前页面不可用", details: nil)); return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let message: String
    switch status {
    case .authorized: message = "已允许访问全部照片，可以返回选择阅读背景。"
    case .limited: message = "当前仅授权部分照片。可管理已选照片，或在系统设置的照片权限中选择完全访问。系统相册选择器仍可浏览相册。"
    case .restricted: message = "相册访问受系统限制，请检查屏幕使用时间等系统设置。"
    default: message = "可在系统设置中允许完整照片访问；也可以继续使用系统相册选择器。"
    }
    let alert = UIAlertController(title: "相册访问权限", message: message, preferredStyle: .alert)
    if status == .limited {
      alert.addAction(UIAlertAction(title: "管理已选照片", style: .default) { [weak alert, weak presenter] _ in
        guard let presenter = presenter else { result(nil); return }
        alert?.dismiss(animated: true) {
          PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
          result(nil)
        }
      })
    }
    if status != .authorized {
      alert.addAction(UIAlertAction(title: "前往系统设置", style: .default) { _ in
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url, options: [:]) { _ in result(nil) }
        } else { result(nil) }
      })
    }
    alert.addAction(UIAlertAction(title: "完成", style: .cancel) { _ in result(nil) })
    presenter.present(alert, animated: true)
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

  private func finishPhotos(_ paths: [String], failed: Int = 0) {
    let result = photoResult
    photoResult = nil
    result?(["paths": paths, "failed": failed])
  }
}
