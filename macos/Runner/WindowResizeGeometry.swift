import Foundation

/// 窗口坐标系的外沿命中方向；同一份几何计算供原生拖动和平台回归测试使用。
struct ReaderResizeEdges: OptionSet {
  let rawValue: Int
  static let left = ReaderResizeEdges(rawValue: 1)
  static let right = ReaderResizeEdges(rawValue: 2)
  static let bottom = ReaderResizeEdges(rawValue: 4)
  static let top = ReaderResizeEdges(rawValue: 8)
}

enum ReaderWindowGeometry {
  static let resizeMargin: CGFloat = 10
  static let titlebarHeight: CGFloat = 32

  /// 只接管四边和四角，内部阅读区域仍由 Flutter 接收鼠标事件。
  static func edges(at point: CGPoint, size: CGSize) -> ReaderResizeEdges {
    guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return [] }
    var edges: ReaderResizeEdges = []
    if point.x <= resizeMargin { edges.insert(.left) }
    if point.x >= size.width - resizeMargin { edges.insert(.right) }
    if point.y <= resizeMargin { edges.insert(.bottom) }
    if point.y >= size.height - resizeMargin { edges.insert(.top) }
    return edges
  }

  /// 最小尺寸约束始终固定拖动边的对侧，防止触及最小尺寸时窗口发生位移跳变。
  static func resizedFrame(_ original: CGRect, delta: CGPoint,
                           edges: ReaderResizeEdges, minimum: CGSize) -> CGRect {
    guard delta.x.isFinite, delta.y.isFinite else { return original }
    var result = original
    if edges.contains(.left) {
      result.size.width = max(max(1, minimum.width), original.width - delta.x)
      result.origin.x = original.maxX - result.width
    } else if edges.contains(.right) {
      result.size.width = max(max(1, minimum.width), original.width + delta.x)
    }
    if edges.contains(.bottom) {
      result.size.height = max(max(1, minimum.height), original.height - delta.y)
      result.origin.y = original.maxY - result.height
    } else if edges.contains(.top) {
      result.size.height = max(max(1, minimum.height), original.height + delta.y)
    }
    return result
  }
}
