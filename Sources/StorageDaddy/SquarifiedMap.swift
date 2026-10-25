import SwiftUI

/// Squarified exact-area layout. Inputs are already ordered largest first;
/// output indices stay aligned with the source file/process records.
enum SquarifiedMap {
    static func layout(weights: [Double], in bounds: CGRect) -> [CGRect] {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, total.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }
        let areas = weights.map { max(0, $0) / total * bounds.width * bounds.height }
        var remaining = bounds, result: [CGRect] = [], row: [Double] = []
        func worst(_ values: [Double], side: Double) -> Double {
            guard let low = values.min(), let high = values.max(), low > 0, side > 0 else { return .infinity }
            let sum = values.reduce(0, +), square = side * side
            return max(square * high / (sum * sum), sum * sum / (square * low))
        }
        func flush() {
            let sum = row.reduce(0, +)
            guard sum > 0 else { return }
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            let thickness = sum / max(0.001, side)
            var offset: Double = 0
            for area in row {
                let length = area / max(0.001, thickness)
                let rect = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                result.append(rect); offset += length
            }
            if vertical { remaining.origin.x += thickness; remaining.size.width = max(0, remaining.width - thickness) }
            else { remaining.origin.y += thickness; remaining.size.height = max(0, remaining.height - thickness) }
            row = []
        }
        for area in areas {
            let side = min(remaining.width, remaining.height)
            if !row.isEmpty, worst(row + [area], side: side) > worst(row, side: side) { flush() }
            row.append(area)
        }
        flush()
        return result
    }
}

enum FileExtensionPalette {
    static func color(for filename: String) -> Color {
        let ext = (filename as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "(no extension)" : ext
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        if UserDefaults.standard.bool(forKey: "colorBlindMap") {
            let colors: [Color] = [.blue, .orange, .cyan, .purple, .yellow, .pink, .gray, .green]
            return colors[Int(hash % UInt64(colors.count))]
        }
        return Color(hue: Double(hash % 72) / 72, saturation: 0.52 + Double((hash >> 8) % 3) * 0.12, brightness: 0.68)
    }
}
