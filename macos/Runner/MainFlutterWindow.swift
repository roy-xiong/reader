import Cocoa
import FlutterMacOS

/// 仅标题栏磨砂；阅读视图和窗口内容底层保持透明。窗口几何由 AppKit 保存。
class MainFlutterWindow: NSWindow {
  private var bridge: FlutterMethodChannel?
  private var choosing = false
  private var frameObservers: [NSObjectProtocol] = []
  private let frameName = "ReaderMainWindow"
  private let fileQueue = DispatchQueue(label: "com.xiongjian.reader.files", qos: .userInitiated)

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let originalFrame = frame
    styleMask.insert(.fullSizeContentView)
    let container = NSViewController()
    let content = NSView(frame: NSRect(origin: .zero, size: originalFrame.size))
    content.wantsLayer = true
    content.layer?.cornerRadius = 12
    content.layer?.masksToBounds = true
    container.view = content
    let titlebar = NSVisualEffectView()
    titlebar.material = .titlebar
    titlebar.blendingMode = .behindWindow
    titlebar.state = .active
    titlebar.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(titlebar)
    container.addChild(controller)
    content.addSubview(controller.view)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    let handles = ReaderResizeHandleView()
    handles.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(handles)
    // 缩放热区覆盖窗口边缘，不参与页面布局；正文从标题栏下方铺满剩余区域。
    NSLayoutConstraint.activate([
      titlebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      titlebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      titlebar.topAnchor.constraint(equalTo: content.topAnchor),
      titlebar.heightAnchor.constraint(equalToConstant: ReaderWindowGeometry.titlebarHeight),
      controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
      controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      handles.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      handles.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      handles.topAnchor.constraint(equalTo: content.topAnchor),
      handles.bottomAnchor.constraint(equalTo: content.bottomAnchor)
    ])
    contentViewController = container
    setFrame(originalFrame, display: true)
    minSize = NSSize(width: 300, height: 320)
    isOpaque = false
    backgroundColor = .clear
    controller.backgroundColor = .clear
    title = "阅读"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    hasShadow = true
    // 先尝试恢复已保存的窗口，再决定是否使用首次启动的默认尺寸。
    setFrameAutosaveName(frameName)
    if !setFrameUsingName(frameName) {
      setContentSize(NSSize(width: 1000, height: 740))
      center()
    } else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
      center()
    }
    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
      frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: self,
        queue: .main) { [weak self] _ in
          guard let self = self, !self.styleMask.contains(.fullScreen), !self.isMiniaturized else { return }
          self.saveFrame(usingName: self.frameName)
        })
    }
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
        self.hasShadow = (call.arguments as? Bool) != true
        result(nil)
      case "minimize":
        self.miniaturize(nil)
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

  deinit {
    frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
      ("增大字体", #selector(increaseFont(_:)), "+"),
      ("减小字体", #selector(decreaseFont(_:)), "-"),
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
  @objc private func increaseFont(_ sender: Any?) { bridge?.invokeMethod("increaseFont", arguments: nil) }
  @objc private func decreaseFont(_ sender: Any?) { bridge?.invokeMethod("decreaseFont", arguments: nil) }
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

/// 加宽外沿缩放区域，鼠标拖动使用普通事件分发，不阻塞主线程事件循环。
private class ReaderResizeHandleView: NSView {
  private var dragEdges: ReaderResizeEdges = []
  private var initialFrame: NSRect = .zero
  private var initialMouse: NSPoint = .zero

  override var isOpaque: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let window = window, !window.styleMask.contains(.fullScreen) else { return nil }
    let local = convert(point, from: superview)
    return ReaderWindowGeometry.edges(at: local, size: bounds.size).isEmpty ? nil : self
  }
  override func draw(_ dirtyRect: NSRect) {
    // 仅覆盖边缘热区，提供透明窗口的命中边；不挤占页面尺寸，内部区域完全不绘制。
    NSColor(calibratedWhite: 0, alpha: 0.01).setFill()
    let border = NSBezierPath(rect: bounds)
    border.append(NSBezierPath(rect: bounds.insetBy(dx: ReaderWindowGeometry.resizeMargin,
                                                  dy: ReaderWindowGeometry.resizeMargin)))
    border.windingRule = .evenOdd
    border.fill()
  }
  override func mouseDown(with event: NSEvent) {
    guard let window = window else { return }
    dragEdges = ReaderWindowGeometry.edges(at: convert(event.locationInWindow, from: nil), size: bounds.size)
    initialFrame = window.frame
    initialMouse = NSEvent.mouseLocation
  }
  override func mouseDragged(with event: NSEvent) {
    guard let window = window, !dragEdges.isEmpty else { return }
    let mouse = NSEvent.mouseLocation
    let delta = CGPoint(x: mouse.x - initialMouse.x, y: mouse.y - initialMouse.y)
    window.setFrame(ReaderWindowGeometry.resizedFrame(initialFrame, delta: delta,
      edges: dragEdges, minimum: window.minSize), display: true, animate: false)
  }
  override func mouseUp(with event: NSEvent) {
    dragEdges = []
    window?.invalidateCursorRects(for: self)
  }
  override func resetCursorRects() {
    let m = ReaderWindowGeometry.resizeMargin, w = bounds.width, h = bounds.height
    guard w > m * 2, h > m * 2 else { return }
    addCursorRect(NSRect(x: 0, y: m, width: m, height: h - 2 * m), cursor: .resizeLeftRight)
    addCursorRect(NSRect(x: w - m, y: m, width: m, height: h - 2 * m), cursor: .resizeLeftRight)
    addCursorRect(NSRect(x: m, y: 0, width: w - 2 * m, height: m), cursor: .resizeUpDown)
    addCursorRect(NSRect(x: m, y: h - m, width: w - 2 * m, height: m), cursor: .resizeUpDown)
    addCursorRect(NSRect(x: 0, y: 0, width: m, height: m), cursor: Self.ascendingCursor)
    addCursorRect(NSRect(x: w - m, y: h - m, width: m, height: m), cursor: Self.ascendingCursor)
    addCursorRect(NSRect(x: 0, y: h - m, width: m, height: m), cursor: Self.descendingCursor)
    addCursorRect(NSRect(x: w - m, y: 0, width: m, height: m), cursor: Self.descendingCursor)
  }
  private static let ascendingCursor = diagonalCursor(ascending: true)
  private static let descendingCursor = diagonalCursor(ascending: false)
  private static func diagonalCursor(ascending: Bool) -> NSCursor {
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
      let path = NSBezierPath()
      func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: ascending ? y : 24 - y) }
      path.move(to: point(6, 6)); path.line(to: point(18, 18))
      path.move(to: point(6, 11)); path.line(to: point(6, 6)); path.line(to: point(11, 6))
      path.move(to: point(13, 18)); path.line(to: point(18, 18)); path.line(to: point(18, 13))
      path.lineCapStyle = .round; path.lineJoinStyle = .round
      NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
      NSColor.black.setStroke(); path.lineWidth = 1.5; path.stroke()
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
  }
}
