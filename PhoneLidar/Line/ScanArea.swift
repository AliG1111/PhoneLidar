import Foundation
import CoreGraphics

/// Area of interest of a Line scan (design §17): the part of the picture whose readings go into the map.
///
/// Fractions of the camera buffer (design §6.1): `across` = buffer x / depth u (top → bottom of the portrait
/// picture), `along` = buffer y / depth v (right → left of the portrait picture; 0 = right edge). Recordings always
/// keep full frames; the area limits the map, its statistics and files, the replay and the Fastest zone.
struct ScanArea: Codable, Equatable, Sendable {
    var acrossStart: Double
    var acrossEnd: Double
    var alongStart: Double
    var alongEnd: Double

    /// The whole picture (the behaviour before P22).
    static let whole = ScanArea(acrossStart: 0, acrossEnd: 1, alongStart: 0, alongEnd: 1)
    /// Smallest side of the area, as a fraction of the picture (each way).
    static let minimumSpan = 0.1
    /// Edges this close to the picture edge count as the picture edge.
    static let wholeTolerance = 0.001

    init(acrossStart: Double, acrossEnd: Double, alongStart: Double, alongEnd: Double) {
        self.acrossStart = acrossStart
        self.acrossEnd = acrossEnd
        self.alongStart = alongStart
        self.alongEnd = alongEnd
    }

    /// From a rectangle of the portrait picture (0…1, x left → right, y top → bottom).
    init(picture rect: CGRect) {
        self.init(acrossStart: Double(rect.minY), acrossEnd: Double(rect.maxY),
                  alongStart: 1 - Double(rect.maxX), alongEnd: 1 - Double(rect.minX))
    }

    private enum CodingKeys: String, CodingKey {
        case acrossStart, acrossEnd, alongStart, alongEnd
    }

    /// Absent keys mean the picture edge; a key with a wrong type still fails, so a damaged file is reported.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acrossStart = try c.decodeIfPresent(Double.self, forKey: .acrossStart) ?? 0
        acrossEnd = try c.decodeIfPresent(Double.self, forKey: .acrossEnd) ?? 1
        alongStart = try c.decodeIfPresent(Double.self, forKey: .alongStart) ?? 0
        alongEnd = try c.decodeIfPresent(Double.self, forKey: .alongEnd) ?? 1
    }

    /// Each side sorted, inside [0, 1] and at least `minimumSpan` long; non-finite values give the whole side.
    var normalized: ScanArea {
        let across = Self.side(acrossStart, acrossEnd)
        let along = Self.side(alongStart, alongEnd)
        return ScanArea(acrossStart: across.lowerBound, acrossEnd: across.upperBound,
                        alongStart: along.lowerBound, alongEnd: along.upperBound)
    }

    /// One side: sorted, clamped to [0, 1]; shorter than `minimumSpan` → widened about its centre, kept inside.
    static func side(_ a: Double, _ b: Double) -> ClosedRange<Double> {
        guard a.isFinite, b.isFinite else { return 0...1 }
        var lo = min(max(min(a, b), 0), 1)
        var hi = min(max(max(a, b), 0), 1)
        if hi - lo < minimumSpan {
            let centre = (lo + hi) / 2
            lo = min(max(centre - minimumSpan / 2, 0), 1 - minimumSpan)
            hi = min(lo + minimumSpan, 1)
        }
        return lo...hi
    }

    /// True when every edge lies on the picture edge (within `wholeTolerance`).
    var isWhole: Bool {
        let a = normalized
        let t = Self.wholeTolerance
        return a.acrossStart <= t && a.acrossEnd >= 1 - t && a.alongStart <= t && a.alongEnd >= 1 - t
    }

    /// The area in the portrait picture (0…1, x left → right, y top → bottom).
    var pictureRect: CGRect {
        let a = normalized
        return CGRect(x: 1 - a.alongEnd, y: a.acrossStart,
                      width: a.alongEnd - a.alongStart, height: a.acrossEnd - a.acrossStart)
    }

    /// Edges of the picture rectangle in % of the portrait picture: left and right from its left edge, top and
    /// bottom from its top edge.
    var pictureEdgesPercent: (left: Double, right: Double, top: Double, bottom: Double) {
        let r = pictureRect
        return (Double(r.minX) * 100, Double(r.maxX) * 100, Double(r.minY) * 100, Double(r.maxY) * 100)
    }

    /// "Whole picture", or "5–95 % from the left, 10–90 % from the top".
    var text: String {
        guard !isWhole else { return "Whole picture" }
        let e = pictureEdgesPercent
        return String(format: "%.0f–%.0f %% from the left, %.0f–%.0f %% from the top",
                      e.left, e.right, e.top, e.bottom)
    }

    /// Summary line of a map built with this area (a map line, replaced on rebuild); nil for the whole picture.
    var summaryLine: String? {
        guard !isWhole else { return nil }
        return "Area of interest: \(text) of the picture; the rest of the picture is not in the map"
    }

    /// True when the buffer position (fractions) lies inside the area, edges included.
    func contains(across: Double, along: Double) -> Bool {
        let a = normalized
        return across >= a.acrossStart && across <= a.acrossEnd && along >= a.alongStart && along <= a.alongEnd
    }

    /// Speed zones in the area (index n = r·columns + c, design §6.1): a zone counts when its centre lies inside the
    /// area; when no centre does, the zone that holds the area's centre.
    func zoneMask(columns: Int, rows: Int) -> [Bool] {
        guard columns > 0, rows > 0 else { return [] }
        var mask = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let across = (Double(c) + 0.5) / Double(columns)
                let along = (Double(r) + 0.5) / Double(rows)
                mask[r * columns + c] = contains(across: across, along: along)
            }
        }
        if !mask.contains(true) {
            let a = normalized
            let c = min(columns - 1, max(0, Int((a.acrossStart + a.acrossEnd) / 2 * Double(columns))))
            let r = min(rows - 1, max(0, Int((a.alongStart + a.alongEnd) / 2 * Double(rows))))
            mask[r * columns + c] = true
        }
        return mask
    }
}

/// Edges of the area that a drag moves (edges of the portrait picture).
struct ScanAreaGrab: OptionSet, Sendable {
    let rawValue: Int
    static let left = ScanAreaGrab(rawValue: 1)
    static let right = ScanAreaGrab(rawValue: 2)
    static let top = ScanAreaGrab(rawValue: 4)
    static let bottom = ScanAreaGrab(rawValue: 8)
    /// The whole area moves.
    static let all: ScanAreaGrab = [.left, .right, .top, .bottom]
}

extension ScanArea {
    /// What a touch at `point` (portrait-picture fractions) grabs: the nearer of left/right and of top/bottom when
    /// within `reachX` / `reachY` (fractions; at most a third of the area's side), so a corner grabs two edges;
    /// otherwise, inside the area, the whole area (`.all`); nothing outside.
    func grab(at point: CGPoint, reachX: Double, reachY: Double) -> ScanAreaGrab {
        let r = pictureRect
        let x = Double(point.x)
        let y = Double(point.y)
        guard x.isFinite, y.isFinite else { return [] }
        let rx = max(0, min(reachX, Double(r.width) / 3))
        let ry = max(0, min(reachY, Double(r.height) / 3))
        guard x >= Double(r.minX) - rx, x <= Double(r.maxX) + rx,
              y >= Double(r.minY) - ry, y <= Double(r.maxY) + ry else { return [] }
        var grab: ScanAreaGrab = []
        let dLeft = abs(x - Double(r.minX))
        let dRight = abs(x - Double(r.maxX))
        if min(dLeft, dRight) <= rx { grab.insert(dLeft <= dRight ? .left : .right) }
        let dTop = abs(y - Double(r.minY))
        let dBottom = abs(y - Double(r.maxY))
        if min(dTop, dBottom) <= ry { grab.insert(dTop <= dBottom ? .top : .bottom) }
        if grab.isEmpty {
            let inside = x > Double(r.minX) && x < Double(r.maxX) && y > Double(r.minY) && y < Double(r.maxY)
            return inside ? .all : []
        }
        return grab
    }

    /// This area with the grabbed edges moved by (dx, dy) portrait-picture fractions. An edge stops at the picture
    /// edge and `minimumSpan` from the opposite edge; a moved area keeps its size and stops at the picture edges.
    func dragged(_ grab: ScanAreaGrab, dx: Double, dy: Double) -> ScanArea {
        let r = pictureRect
        var minX = Double(r.minX), maxX = Double(r.maxX)
        var minY = Double(r.minY), maxY = Double(r.maxY)
        let dx = dx.isFinite ? dx : 0
        let dy = dy.isFinite ? dy : 0
        let m = Self.minimumSpan
        if grab == .all {
            let mx = min(max(dx, -minX), 1 - maxX)
            let my = min(max(dy, -minY), 1 - maxY)
            minX += mx
            maxX += mx
            minY += my
            maxY += my
        } else {
            if grab.contains(.left) { minX = min(max(minX + dx, 0), maxX - m) }
            if grab.contains(.right) { maxX = max(min(maxX + dx, 1), minX + m) }
            if grab.contains(.top) { minY = min(max(minY + dy, 0), maxY - m) }
            if grab.contains(.bottom) { maxY = max(min(maxY + dy, 1), minY + m) }
        }
        return ScanArea(picture: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)).normalized
    }
}

/// Depth pixels a Line scan map uses (design §17.4): inside the border, between the side walls (when calibrated)
/// and inside the area of interest. With the whole picture and no walls these are the border ranges of design §6.8.
struct MapPixels: Equatable, Sendable {
    /// Depth columns u (across) whose readings go into the map.
    var columns: Range<Int>
    /// Depth rows v (along the travel) whose readings go into the map.
    var rows: Range<Int>
    /// Columns that size the grid (extent, cell size): inside the border and the area, not limited by the side
    /// walls, so a whole-picture map keeps exactly the grid it had before P22.
    var gridColumns: Range<Int>
    /// The area is the whole picture.
    var wholePicture: Bool

    /// At least two columns and two rows: enough for a map.
    var isUsable: Bool { columns.count >= 2 && rows.count >= 2 }

    static func make(width: Int, height: Int, border: Int, keptAcross: ClosedRange<Double>?,
                     area: ScanArea) -> MapPixels {
        let a = area.normalized
        let gridLo = max(border, Int((a.acrossStart * Double(width)).rounded(.up)))
        let gridHi = min(width - border, Int((a.acrossEnd * Double(width)).rounded(.down)))
        var lo = gridLo
        var hi = gridHi
        if let kept = keptAcross {
            lo = max(lo, Int((kept.lowerBound * Double(width)).rounded(.up)))
            hi = min(hi, Int((kept.upperBound * Double(width)).rounded(.down)))
        }
        let vLo = max(border, Int((a.alongStart * Double(height)).rounded(.up)))
        let vHi = min(height - border, Int((a.alongEnd * Double(height)).rounded(.down)))
        return MapPixels(columns: Self.range(lo, hi), rows: Self.range(vLo, vHi),
                         gridColumns: Self.range(gridLo, gridHi), wholePicture: a.isWhole)
    }

    private static func range(_ lo: Int, _ hi: Int) -> Range<Int> {
        lo < hi ? lo..<hi : lo..<lo
    }

    /// Why a map cannot use these pixels: the area misses the part between the side walls, or is too small.
    static func unusableMessage(sideWalls: Bool) -> String {
        sideWalls
            ? "No map: the area of interest does not overlap the part of the picture between the side walls. "
                + "Move the area (Topographic map › Area of interest › Set area…) or recalibrate the side walls."
            : "No map: the area of interest is too small for the depth map. Widen it (Topographic map › "
                + "Area of interest › Set area…)."
    }
}
