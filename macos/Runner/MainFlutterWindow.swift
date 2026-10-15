import Cocoa
import FlutterMacOS

/// 原生磨砂窗口、统一圆角、系统菜单和文件面板。正文不透明度独立控制。
class MainFlutterWindow: NSWindow {
  private var bridge: FlutterMethodChannel?
  private var choosing = false
  private let fileQueue = DispatchQueue(label: "com.xiongjian.reader.files", qos: .userInitiated)

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let originalFrame = frame
    // 扩展内容到标题栏下方，由原生磨砂背景连续覆盖窗口顶部和阅读区域。
    styleMask.insert(.fullSizeContentView)
    let container = NSViewController()
    let glass = NSVisualEffectView()
    glass.material = .underWindowBackground
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.wantsLayer = true
    glass.layer?.cornerRadius = 12
    glass.layer?.masksToBounds = true
    container.view = glass
    container.addChild(controller)
    glass.addSubview(controller.view)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: glass.topAnchor, constant: 32),
      controller.view.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
    ])
    contentViewController = container
    setFrame(originalFrame, display: true)
    minSize = NSSize(width: 300, height: 320)
    setContentSize(NSSize(width: 1000, height: 740))
    center()
    setFrameAutosaveName("ReaderMainWindow")
    isOpaque = false
    backgroundColor = .clear
    controller.backgroundColor = .clear
    title = "Reader"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    RegisterGeneratedPlugins(registry: controller)
    bridge = FlutterMethodChannel(name: "com.xiongjian.reader/platform",
      binaryMessenger: controller.engine.binaryMessenger)
    bridge?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "closed", message: "窗口已关闭", details: nil)); return }
      switch call.method {
      case "supportPath":
        do {
          let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
          let directory = base.appendingPathComponent("Reader", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          result(directory.path)
        } catch { result(FlutterError(code: "storage", message: "无法创建书架目录", details: nil)) }
      case "readingMode":
        self.hasShadow = true
        result(nil)
      case "appearance":
        switch call.arguments as? String {
        case "dark": self.appearance = NSAppearance(named: .darkAqua)
        case "light": self.appearance = NSAppearance(named: .aqua)
        default: self.appearance = nil
        }
        result(nil)
      case "pick":
        let args = call.arguments as? [String: Any]
        self.pick(folder: args?["folder"] as? Bool ?? false,
          font: args?["font"] as? Bool ?? false, result: result)
      case "discard":
        let paths = call.arguments as? [String] ?? []
        self.fileQueue.async {
          let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path + "/"
          for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            if file.path.hasPrefix(temporary) { try? FileManager.default.removeItem(at: file) }
          }
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    DispatchQueue.main.async { [weak self] in self?.installMenus() }
    super.awakeFromNib()
  }

  /// 系统标准“设置…”入口和 ⌘,；阅读界面无需常驻设置按钮。
  private func installMenus() {
    guard let menu = NSApp.mainMenu else { return }
    if let appMenu = menu.items.first?.submenu,
       let preferences = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
      preferences.title = "设置…"
      preferences.target = self
      preferences.action = #selector(openSettings(_:))
    }
    let fileMenu = NSMenu(title: "文件")
    for (title, action, key) in [
      ("导入电子书…", #selector(importBooks(_:)), "o"),
      ("导入文件夹…", #selector(importFolder(_:)), ""),
      ("返回书架", #selector(showShelf(_:)), "b")
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      fileMenu.addItem(item)
    }
    let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    file.submenu = fileMenu
    menu.insertItem(file, at: 1)
    let readingMenu = NSMenu(title: "阅读")
    for (title, action, key) in [
      ("搜索正文…", #selector(findText(_:)), "f"),
      ("添加 / 移除书签", #selector(bookmark(_:)), "d"),
      ("锁定阅读器", #selector(lockApp(_:)), "l")
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      readingMenu.addItem(item)
    }
    let reading = NSMenuItem(title: "阅读", action: nil, keyEquivalent: "")
    reading.submenu = readingMenu
    menu.insertItem(reading, at: 2)
  }
  @objc private func openSettings(_ sender: Any?) { bridge?.invokeMethod("openSettings", arguments: nil) }
  @objc private func importBooks(_ sender: Any?) { bridge?.invokeMethod("importBooks", arguments: nil) }
  @objc private func importFolder(_ sender: Any?) { bridge?.invokeMethod("importFolder", arguments: nil) }
  @objc private func showShelf(_ sender: Any?) { bridge?.invokeMethod("showShelf", arguments: nil) }
  @objc private func findText(_ sender: Any?) { bridge?.invokeMethod("findText", arguments: nil) }
  @objc private func bookmark(_ sender: Any?) { bridge?.invokeMethod("bookmark", arguments: nil) }
  @objc private func lockApp(_ sender: Any?) { bridge?.invokeMethod("lockApp", arguments: nil) }

  /// 选择后立即在授权有效期间复制文件，重启后不再依赖临时的沙盒授权。
  private func pick(folder: Bool, font: Bool, result: @escaping FlutterResult) {
    guard !choosing else { result(FlutterError(code: "busy", message: "文件面板已打开", details: nil)); return }
    choosing = true
    let panel = NSOpenPanel()
    panel.title = font ? "选择字体" : (folder ? "选择电子书文件夹" : "导入电子书")
    panel.canChooseDirectories = folder
    panel.canChooseFiles = !folder
    panel.allowsMultipleSelection = !folder
    let extensions = font ? ["ttf", "otf"] : ["txt", "epub", "mobi", "azw", "azw3", "html", "htm"]
    if !folder { panel.allowedFileTypes = extensions }
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self = self else { result(nil); return }
      guard response == .OK else { self.choosing = false; result([String]()); return }
      let urls = panel.urls
      self.fileQueue.async {
        var copies = [String]()
        do {
          for selected in urls {
            let scoped = selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            var files = [URL]()
            if folder {
              let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              if let enumerator = FileManager.default.enumerator(at: selected,
                includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let file as URL in enumerator {
                  if files.count >= 500 { break }
                  let values = try file.resourceValues(forKeys: Set(keys))
                  if values.isRegularFile == true && values.isSymbolicLink != true &&
                    extensions.contains(file.pathExtension.lowercased()) { files.append(file) }
                }
              }
            } else { files = [selected] }
            for source in files {
              let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
              guard size > 0 && (font || size <= 64 * 1024 * 1024) else {
                throw NSError(domain: "Reader", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: font ? "请选择非空的字体文件" : "请选择非空且不超过 64 MB 的电子书"])
              }
              let name = UUID().uuidString.lowercased() + "_" + source.lastPathComponent
              let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
              try FileManager.default.copyItem(at: source, to: target)
              copies.append(target.path)
            }
          }
          DispatchQueue.main.async { self.choosing = false; result(copies) }
        } catch {
          for path in copies { try? FileManager.default.removeItem(atPath: path) }
          DispatchQueue.main.async {
            self.choosing = false
            result(FlutterError(code: "read", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
