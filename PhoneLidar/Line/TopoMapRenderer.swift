import UIKit

/// Shareable TopoMap.png: the colour map plus a title, legend and key statistics.
/// Not tied to the main actor: UIGraphicsImageRenderer and UIKit string/image drawing into its context are
/// thread-safe, so the map builders render it on their background task.
enum TopoMapRenderer {
    /// PNG data of the composite (staged by `TopoMapBuilder.build` together with the other map files).
    static func compositePNG(map: CGImage, stats: TopoStats, direction: TravelDirection) throws -> Data {
        let scale = max(1, min(8, 1600 / max(map.width, 1)))
        let mapWidth = CGFloat(map.width * scale)
        let mapHeight = CGFloat(map.height * scale)
        let width = max(mapWidth, 1100)
        let header: CGFloat = 70
        let footer: CGFloat = 150
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: header + mapHeight + footer),
                                               format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: header + mapHeight + footer))

            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.black
            ]
            let body: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .regular), .foregroundColor: UIColor.black
            ]
            let arrow: String = direction == .rightToLeft ? "←" : "→"
            let edge: String = direction == .rightToLeft ? "left" : "right"
            let what = stats.heightMode == true ? "height above the flat-surface baseline" : "distance from camera"
            let titleText = "Topographic map — \(what)   (material travel \(arrow), leading edge on the \(edge))"
            (titleText as NSString).draw(at: CGPoint(x: 20, y: 18), withAttributes: title)

            UIColor(white: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: header, width: mapWidth, height: mapHeight))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: map).draw(in: CGRect(x: 0, y: header, width: mapWidth, height: mapHeight))

            // Legend: far (dark blue) → near (dark red).
            let barY = header + mapHeight + 20
            let barWidth: CGFloat = 600
            for i in 0..<Int(barWidth) {
                let c = DepthColors.rgb(Float(i) / Float(barWidth - 1))
                UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1).setFill()
                context.fill(CGRect(x: 20 + CGFloat(i), y: barY, width: 1, height: 26))
            }
            let heights = stats.heightMode == true
            (String(format: heights ? "Low %.1f mm" : "Far %.0f mm", stats.colorFar) as NSString)
                .draw(at: CGPoint(x: 20, y: barY + 32), withAttributes: body)
            let nearText = String(format: heights ? "High %.1f mm" : "Near %.0f mm", stats.colorNear) as NSString
            let nearSize = nearText.size(withAttributes: body)
            nearText.draw(at: CGPoint(x: 20 + barWidth - nearSize.width, y: barY + 32), withAttributes: body)

            let line1 = String(format: heights
                               ? "Mean height %.2f mm   Std dev %.2f mm   Variance %.2f mm²   Range %.1f mm   Cells %@ mm"
                               : "Mean %.1f mm   Std dev %.2f mm   Variance %.2f mm²   Range %.1f mm   Cells %@ mm",
                               stats.mean, stats.stdDev, stats.variance, stats.range,
                               TopoMapBuilder.cellText(stats.cellSize))
            var line2 = String(format: "Across std dev %.2f mm   Along std dev %.2f mm   Length %.2f m",
                               stats.acrossStdDev, stats.alongStdDev, stats.lengthMM / 1000)
            if let speed = stats.speedMean {
                line2 += String(format: "   Speed %.0f mm/s (%.2f m/min)", speed, speed * 0.06)
            }
            (line1 as NSString).draw(at: CGPoint(x: 20, y: barY + 62), withAttributes: body)
            (line2 as NSString).draw(at: CGPoint(x: 20, y: barY + 90), withAttributes: body)
        }
        guard let data = image.pngData() else { throw LineError.badFile }
        return data
    }
}
