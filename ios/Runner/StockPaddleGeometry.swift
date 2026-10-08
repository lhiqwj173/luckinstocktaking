import Foundation
import CoreGraphics
import CoreImage

enum StockPaddleGeometry {
  private static let imageContext = CIContext(options: [.cacheIntermediates: false])
  static func bounds(_ points: [CGPoint]) -> CGRect {
    points.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0.000001, height: 0.000001)) }
  }
  private static func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
  }
  private static func hull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    guard sorted.count >= 3 else { return sorted }
    var lower: [CGPoint] = []; var upper: [CGPoint] = []
    for point in sorted {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, point) <= 0 { lower.removeLast() }
      lower.append(point)
    }
    for point in sorted.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, point) <= 0 { upper.removeLast() }
      upper.append(point)
    }
    return Array(lower.dropLast()) + Array(upper.dropLast())
  }
  /// 连通区域→凸包→最小旋转矩形→区域均分→DB unclip。保留旋转几何以过滤斜水印。
  static func detect(_ probabilities: [Float], width: Int, height: Int) throws -> [[CGPoint]] {
    guard width > 0, height > 0, probabilities.count == width * height,
      probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw StockHistoryError.invalid("文字检测概率图无效")
    }
    var visited = [UInt8](repeating: 0, count: probabilities.count)
    var boxes: [[CGPoint]] = []
    for seed in probabilities.indices where visited[seed] == 0 && probabilities[seed] > 0.2 {
      var queue = [seed]; visited[seed] = 1; var cursor = 0
      var boundary: [CGPoint] = []
      while cursor < queue.count {
        let index = queue[cursor]; cursor += 1
        let x = index % width; let y = index / width
        var edge = false
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
          let nx = x + dx; let ny = y + dy
          if nx < 0 || nx >= width || ny < 0 || ny >= height { edge = true; continue }
          let next = ny * width + nx
          if probabilities[next] <= 0.2 { edge = true; continue }
          if visited[next] == 0 { visited[next] = 1; queue.append(next) }
        } }
        if edge { boundary.append(CGPoint(x: x, y: y)) }
      }
      if queue.count < 9 { continue }
      let polygon = hull(boundary)
      if polygon.count < 3 { continue }
      var bestArea = CGFloat.greatestFiniteMagnitude
      var best: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)?
      for index in polygon.indices {
        let a = polygon[index]; let b = polygon[(index + 1) % polygon.count]
        var angle = atan2(b.y - a.y, b.x - a.x)
        while angle > .pi / 4 { angle -= .pi / 2 }
        while angle < -.pi / 4 { angle += .pi / 2 }
        let cosA = cos(angle); let sinA = sin(angle)
        var minU = CGFloat.greatestFiniteMagnitude; var maxU = -CGFloat.greatestFiniteMagnitude
        var minV = CGFloat.greatestFiniteMagnitude; var maxV = -CGFloat.greatestFiniteMagnitude
        for point in polygon {
          let u = point.x * cosA + point.y * sinA
          let v = -point.x * sinA + point.y * cosA
          minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        let area = (maxU - minU) * (maxV - minV)
        if area < bestArea { bestArea = area; best = (angle, minU, maxU, minV, maxV) }
      }
      guard let (angle, minU, maxU, minV, maxV) = best else { throw StockHistoryError.invalid("无法计算文字检测矩形") }
      let boxWidth = maxU - minU; let boxHeight = maxV - minV
      if min(boxWidth, boxHeight) < 3 { continue }
      let cosA = cos(angle); let sinA = sin(angle)
      func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: u * cosA - v * sinA, y: u * sinA + v * cosA) }
      let unexpanded = bounds([point(minU, minV), point(maxU, maxV), point(minU, maxV), point(maxU, minV)])
      var sum: Double = 0; var count = 0
      for y in max(0, Int(floor(unexpanded.minY)))...min(height - 1, Int(ceil(unexpanded.maxY))) {
        for x in max(0, Int(floor(unexpanded.minX)))...min(width - 1, Int(ceil(unexpanded.maxX))) {
          let u = CGFloat(x) * cosA + CGFloat(y) * sinA; let v = -CGFloat(x) * sinA + CGFloat(y) * cosA
          if u >= minU && u <= maxU && v >= minV && v <= maxV { sum += Double(probabilities[y * width + x]); count += 1 }
        }
      }
      if count == 0 || sum / Double(count) < 0.4 { continue }
      let distance = boxWidth * boxHeight * 1.4 / (2 * (boxWidth + boxHeight))
      let expanded = [point(minU - distance, minV - distance), point(maxU + distance, minV - distance),
        point(maxU + distance, maxV + distance), point(minU - distance, maxV + distance)]
      boxes.append(expanded.map { CGPoint(x: max(0, min(1, $0.x / CGFloat(width))),
        y: 1 - max(0, min(1, $0.y / CGFloat(height)))) })
      guard boxes.count <= 3000 else { throw StockHistoryError.invalid("文字检测区域超过上限，不能丢弃后续货物") }
    }
    return boxes.sorted {
      let a = bounds($0); let b = bounds($1)
      return a.midY == b.midY ? a.minX < b.minX : a.midY > b.midY
    }
  }
  static func crop(_ image: CGImage, polygon: [CGPoint]) throws -> CGImage {
    guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
      let filter = CIFilter(name: "CIPerspectiveCorrection") else { throw StockHistoryError.invalid("文字区域透视裁剪参数无效") }
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    for (name, point) in zip(["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"], polygon) {
      filter.setValue(CIVector(x: point.x, y: CGFloat(image.height) - point.y), forKey: name)
    }
    guard let output = filter.outputImage, !output.extent.isEmpty,
      let result = imageContext.createCGImage(output, from: output.extent), result.width > 0, result.height > 0 else {
      throw StockHistoryError.invalid("无法裁剪模型检测到的文字区域")
    }
    return result
  }
}
