import Foundation
import CoreGraphics

let size = CGSize(width: 1000, height: 740)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 8, y: 300), size: size) == .left)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 992, y: 300), size: size) == .right)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 500, y: 8), size: size) == .bottom)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 500, y: 732), size: size) == .top)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 8, y: 732), size: size) == [.left, .top])
assert(ReaderWindowGeometry.edges(at: CGPoint(x: 500, y: 300), size: size).isEmpty)
assert(ReaderWindowGeometry.edges(at: CGPoint(x: -1, y: 300), size: size).isEmpty)
let frame = CGRect(x: 100, y: 200, width: 1000, height: 740)
let minimum = CGSize(width: 300, height: 320)
let compressed = ReaderWindowGeometry.resizedFrame(frame, delta: CGPoint(x: 2000, y: 2000),
                                                   edges: [.left, .bottom], minimum: minimum)
assert(compressed.width == 300 && compressed.height == 320)
assert(compressed.maxX == frame.maxX && compressed.maxY == frame.maxY)
let expanded = ReaderWindowGeometry.resizedFrame(frame, delta: CGPoint(x: 200, y: 120),
                                                 edges: [.right, .top], minimum: minimum)
assert(expanded == CGRect(x: 100, y: 200, width: 1200, height: 860))
print("窗口四边、四角命中、最小尺寸和固定对侧几何测试通过")
