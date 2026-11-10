import SceneKit
import UIKit
import simd

/// SceneKit content of the topographic replay: the 3D surface strip with its coloured side walls, the
/// tolerance planes, the newest-line marker and the axis labels.
///
/// Scene units are metres. x runs along the strip (0 = oldest end of the window, newest data at the right),
/// y is up (base of the walls at 0), z runs across the material (back = top of the recording screen,
/// front = bottom). The strip is drawn in a parallel projection with the depth axis sheared up and to the right,
/// so the front edge stays horizontal and both end walls are visible.
@MainActor
final class TopoReplayScene {
    struct Layout: Equatable {
        /// Window length and strip width, m.
        var length: Float
        var width: Float
        /// Height of the top of the value range above the base, m.
        var height: Float
        /// Values (mm) at the base and at `height`.
        var base: Float
        var top: Float
        /// Colour scale ends (mm): blue at colorLow, red at colorHigh.
        var colorLow: Float
        var colorHigh: Float
        /// Tolerance band (mm).
        var lowerTolerance: Float
        var upperTolerance: Float
        var flat: Bool
        var planes: Bool
        /// Across position (mm from the image centre line) of the back edge of the strip.
        var acrossStart: Float
    }

    struct CameraSettings: Equatable {
        var elevation: Double
        var shear: Double
        var zoom: Double
        var aspect: Double
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let world = SCNNode()
    private let strip = SCNNode()
    private let lowerPlane = SCNNode()
    private let upperPlane = SCNNode()
    private let newestLine = SCNNode()
    private let heightAxis = SCNNode()
    private let labels = SCNNode()
    private let surfaceMaterial = SCNMaterial()
    private var labelBases: [(node: SCNNode, position: SIMD3<Float>)] = []
    private var layout: Layout?
    private var currentShear: Float = 0

    init() {
        scene.background.contents = UIColor.white

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1
        camera.zNear = 0.5
        camera.zFar = 400
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 560
        ambientLight.color = UIColor.white
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 560
        sunLight.color = UIColor.white
        sun.light = sunLight
        sun.simdLook(at: SIMD3<Float>(0.35, -1, -0.6))
        scene.rootNode.addChildNode(sun)

        surfaceMaterial.lightingModel = .lambert
        surfaceMaterial.diffuse.contents = UIColor.white
        surfaceMaterial.isDoubleSided = true

        scene.rootNode.addChildNode(world)
        scene.rootNode.addChildNode(labels)
        world.addChildNode(strip)
        world.addChildNode(lowerPlane)
        world.addChildNode(upperPlane)
        world.addChildNode(newestLine)
        world.addChildNode(heightAxis)

        // Tolerance planes are drawn first and do not take part in depth testing, so the surface always covers
        // them: they show only where there is no data yet (as in the X-ray replay).
        lowerPlane.renderingOrder = -20
        upperPlane.renderingOrder = -19
        lowerPlane.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        upperPlane.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        newestLine.renderingOrder = 50
    }

    // MARK: Layout

    /// Rebuilds the planes, the newest-line marker and the axes for new dimensions or value ranges.
    func apply(_ newLayout: Layout) {
        guard newLayout != layout else { return }
        layout = newLayout
        let l = newLayout

        lowerPlane.geometry = Self.plane(length: l.length, width: l.width,
                                         color: UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1))
        upperPlane.geometry = Self.plane(length: l.length, width: l.width,
                                         color: UIColor(red: 1.0, green: 0.88, blue: 0.96, alpha: 1))
        lowerPlane.simdPosition = SIMD3<Float>(l.length / 2, y(for: l.lowerTolerance, l), 0)
        upperPlane.simdPosition = SIMD3<Float>(l.length / 2, y(for: l.upperTolerance, l), 0)
        lowerPlane.isHidden = l.flat || !l.planes
        upperPlane.isHidden = l.flat || !l.planes

        let thickness = max(l.width * 0.012, 0.004)
        let bar = SCNBox(width: CGFloat(thickness), height: CGFloat(thickness), length: CGFloat(l.width),
                         chamferRadius: 0)
        bar.firstMaterial = Self.flatMaterial(.black, onTop: true)
        newestLine.geometry = bar
        newestLine.simdPosition = SIMD3<Float>(l.length, l.flat ? 0.002 : thickness / 2, 0)

        heightAxis.childNodes.forEach { $0.removeFromParentNode() }
        labels.childNodes.forEach { $0.removeFromParentNode() }
        labelBases.removeAll()
        let textSize = l.width * 0.055
        let grey = UIColor(white: 0.35, alpha: 1)

        if !l.flat {
            // Height axis at the back-left corner.
            let axisX = -l.width * 0.04
            let line = SCNBox(width: CGFloat(thickness * 0.3), height: CGFloat(l.height * 1.1),
                              length: CGFloat(thickness * 0.3), chamferRadius: 0)
            line.firstMaterial = Self.flatMaterial(UIColor(white: 0.6, alpha: 1), onTop: false)
            let lineNode = SCNNode(geometry: line)
            lineNode.simdPosition = SIMD3<Float>(axisX, l.height * 0.55, -l.width / 2)
            heightAxis.addChildNode(lineNode)
            let ticks = ReplayNumbers.ticks(Double(l.base), Double(l.base + (l.top - l.base) * 1.1), count: 5)
            let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
            let digits = ReplayNumbers.decimals(for: step)
            for value in ticks {
                let yPos = y(for: Float(value), l)
                addLabel(ReplayNumbers.text(value, decimals: digits), size: textSize, color: grey,
                         at: SIMD3<Float>(axisX - textSize * 1.6, yPos, -l.width / 2))
                let tick = SCNBox(width: CGFloat(textSize * 0.5), height: CGFloat(thickness * 0.3),
                                  length: CGFloat(thickness * 0.3), chamferRadius: 0)
                tick.firstMaterial = Self.flatMaterial(UIColor(white: 0.6, alpha: 1), onTop: false)
                let tickNode = SCNNode(geometry: tick)
                tickNode.simdPosition = SIMD3<Float>(axisX - textSize * 0.25, yPos, -l.width / 2)
                heightAxis.addChildNode(tickNode)
            }
            addLabel("mm", size: textSize, color: grey,
                     at: SIMD3<Float>(axisX - textSize * 1.6, l.height * 1.22, -l.width / 2))
        }

        // Across positions along the newest end (mm from the image centre line).
        let acrossEnd = l.acrossStart + l.width * 1000
        let acrossTicks = ReplayNumbers.ticks(Double(l.acrossStart), Double(acrossEnd), count: 4)
        for value in acrossTicks {
            let z = -l.width / 2 + (Float(value) - l.acrossStart) / 1000
            addLabel(String(format: "%.0f", value), size: textSize * 0.9, color: grey,
                     at: SIMD3<Float>(l.length + textSize * (l.flat ? 1.8 : 1.4), 0, z))
        }
        addLabel("across mm", size: textSize * 0.9, color: grey,
                 at: SIMD3<Float>(l.length + textSize * 1.6, 0, -l.width / 2 - textSize * 1.3))
        positionLabels()
    }

    private func y(for value: Float, _ l: Layout) -> Float {
        if l.flat { return 0 }
        let f = (value - l.base) / max(l.top - l.base, 1e-6)
        return l.height * min(max(f, 0), 1.25)
    }

    private func addLabel(_ text: String, size: Float, color: UIColor, at position: SIMD3<Float>) {
        let node = Self.label(text, size: size, color: color)
        labels.addChildNode(node)
        labelBases.append((node, position))
    }

    /// Labels sit outside the sheared node (so the text is not slanted); their positions follow the shear.
    private func positionLabels() {
        for item in labelBases {
            let p = item.position
            item.node.simdPosition = SIMD3<Float>(p.x - currentShear * p.z, p.y, p.z)
        }
    }

    // MARK: Strip

    /// Reused between strip rebuilds (the strip is rebuilt at every new display column while playing).
    private var heights: [Float] = []
    private var valid: [Bool] = []
    private var surfaceColors: [SIMD4<Float>] = []
    private var colors: [SIMD4<Float>] = []
    private var positions: [SCNVector3] = []
    private var normals: [SCNVector3] = []
    private var indices: [UInt32] = []

    /// Replaces the surface. `values` is rows × columns (row-major; row 0 = back edge, column 0 = oldest),
    /// `rowCenters` the centre of each row in mm from the back edge, `blockLength` the column spacing in m and
    /// `offset` the x position (m) of the centre of column 0 in the window. Empty `values` removes the surface.
    func setStrip(values: [Float], rows: Int, columns: Int, rowCenters: [Double], blockLength: Float,
                  offset: Float) {
        guard let l = layout else { return }
        strip.simdPosition = SIMD3<Float>(offset, 0, 0)
        let geometry = values.withUnsafeBufferPointer { buffer in
            makeStrip(values: buffer, rows: rows, columns: columns, rowCenters: rowCenters,
                      blockLength: blockLength, layout: l)
        }
        if let geometry {
            surfaceMaterial.lightingModel = l.flat ? .constant : .lambert
            geometry.materials = [surfaceMaterial]
        }
        strip.geometry = geometry
    }

    func moveStrip(offset: Float) {
        strip.simdPosition = SIMD3<Float>(offset, 0, 0)
    }

    private func makeStrip(values: UnsafeBufferPointer<Float>, rows: Int, columns: Int, rowCenters: [Double],
                           blockLength: Float, layout l: Layout) -> SCNGeometry? {
        let nc = columns
        let nr = rows
        guard nc >= 2, nr >= 2, values.count >= rows * columns, rowCenters.count >= nr, blockLength > 0 else {
            return nil
        }
        let dx = blockLength
        let span = max(l.top - l.base, 1e-6)
        let colorSpan = max(l.colorHigh - l.colorLow, 1e-6)
        let lut = ReplayPalette.lut
        let count = nr * nc
        let wallVertices = l.flat ? 0 : 2 * (2 * nc + 2 * nr)

        heights.removeAll(keepingCapacity: true)
        heights.append(contentsOf: repeatElement(0, count: count))
        valid.removeAll(keepingCapacity: true)
        valid.append(contentsOf: repeatElement(false, count: count))
        surfaceColors.removeAll(keepingCapacity: true)
        surfaceColors.append(contentsOf: repeatElement(ReplayPalette.noData, count: count))
        for jj in 0..<nc {
            for i in 0..<nr {
                let v = values[i * columns + jj]
                let k = jj * nr + i
                if v.isFinite {
                    valid[k] = true
                    heights[k] = l.flat ? 0 : l.height * min(max((v - l.base) / span, 0), 1.25)
                    let t = min(max((v - l.colorLow) / colorSpan, 0), 1)
                    surfaceColors[k] = lut[Int(t * 255)]
                }
            }
        }

        positions.removeAll(keepingCapacity: true)
        normals.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        positions.reserveCapacity(count + wallVertices)
        normals.reserveCapacity(count + wallVertices)
        colors.reserveCapacity(count + wallVertices)
        indices.reserveCapacity((nc - 1) * (nr - 1) * 6 + (l.flat ? 0 : 3 * wallVertices))

        let z = rowCenters.prefix(nr).map { Float($0 / 1000) - l.width / 2 }

        for jj in 0..<nc {
            let x = Float(jj) * dx
            let jl = max(jj - 1, 0)
            let jr = min(jj + 1, nc - 1)
            for i in 0..<nr {
                let k = jj * nr + i
                positions.append(SCNVector3(x, heights[k], z[i]))
                if l.flat {
                    normals.append(SCNVector3(0, 1, 0))
                } else {
                    let ib = max(i - 1, 0)
                    let iff = min(i + 1, nr - 1)
                    // Neighbours without data count as level with this block (no slope towards a hole).
                    func h(_ index: Int) -> Float { valid[index] ? heights[index] : heights[k] }
                    let ddx = (h(jr * nr + i) - h(jl * nr + i)) / (Float(jr - jl) * dx)
                    let ddz = (h(jj * nr + iff) - h(jj * nr + ib)) / max(z[iff] - z[ib], 1e-6)
                    let n = simd_normalize(SIMD3<Float>(-ddx, 1, -ddz))
                    normals.append(SCNVector3(n.x, n.y, n.z))
                }
            }
        }
        colors.append(contentsOf: surfaceColors)
        // In 3D, triangles touching a block without data are left out, so the tolerance planes show through
        // there (no data yet); the flat map draws them grey.
        let skipEmpty = !l.flat
        for jj in 0..<(nc - 1) {
            for i in 0..<(nr - 1) {
                let a = jj * nr + i
                let b = a + 1
                let c = (jj + 1) * nr + i
                let d = c + 1
                if !skipEmpty || (valid[a] && valid[b] && valid[c]) {
                    indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
                }
                if !skipEmpty || (valid[c] && valid[b] && valid[d]) {
                    indices.append(contentsOf: [UInt32(c), UInt32(b), UInt32(d)])
                }
            }
        }

        if !l.flat {
            // Walls from the surface edge down to the base, coloured like the edge (vertical stripes); no wall
            // under blocks without data.
            func wall(_ count: Int, normal: SIMD3<Float>, vertex: (Int) -> Int) {
                let start = UInt32(positions.count)
                let n = SCNVector3(normal.x, normal.y, normal.z)
                for m in 0..<count {
                    let top = positions[vertex(m)]
                    let shade = surfaceColors[vertex(m)] * SIMD4<Float>(0.93, 0.93, 0.93, 1)
                    positions.append(top)
                    positions.append(SCNVector3(top.x, 0, top.z))
                    normals.append(n)
                    normals.append(n)
                    colors.append(shade)
                    colors.append(shade)
                }
                for m in 0..<(count - 1) where valid[vertex(m)] && valid[vertex(m + 1)] {
                    let a = start + UInt32(2 * m)
                    indices.append(contentsOf: [a, a + 1, a + 2, a + 2, a + 1, a + 3])
                }
            }
            wall(nc, normal: SIMD3<Float>(0, 0, 1)) { $0 * nr + (nr - 1) }        // front
            wall(nr, normal: SIMD3<Float>(1, 0, 0)) { (nc - 1) * nr + $0 }        // newest end
            wall(nr, normal: SIMD3<Float>(-1, 0, 0)) { $0 }                        // oldest end
            wall(nc, normal: SIMD3<Float>(0, 0, -1)) { $0 * nr }                   // back
        }
        guard !indices.isEmpty else { return nil }

        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let sources = [
            SCNGeometrySource(vertices: positions),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                              usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        ]
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    // MARK: Camera

    /// Parallel projection: camera elevation (degrees above horizontal) and depth shear, fitted to the window.
    func applyCamera(_ v: CameraSettings) {
        guard let l = layout else { return }
        let shear = l.flat ? 0 : Float(v.shear)
        currentShear = shear
        var transform = matrix_identity_float4x4
        transform.columns.2 = SIMD4<Float>(-shear, 0, 1, 0)
        world.simdTransform = transform
        positionLabels()

        let elevation = Float((l.flat ? 90 : min(max(v.elevation, 5), 90)) * .pi / 180)
        let back = SIMD3<Float>(0, sin(elevation), cos(elevation))
        let right = SIMD3<Float>(1, 0, 0)
        let up = simd_normalize(simd_cross(right, -back))
        cameraNode.simdOrientation = simd_quatf(simd_float3x3(right, up, back))

        // Fit the window (with room for the labels) to the view.
        let margin = l.width * 0.22
        let topY = l.flat ? 0 : l.height * 1.3
        var uMin = Float.infinity, uMax = -Float.infinity, vMin = Float.infinity, vMax = -Float.infinity
        for x in [-margin, l.length + margin] {
            for yy in [0, topY] {
                for zz in [-l.width / 2 - margin * 0.5, l.width / 2] {
                    let p = SIMD3<Float>(x - shear * zz, yy, zz)
                    let u = simd_dot(p, right)
                    let w = simd_dot(p, up)
                    uMin = min(uMin, u)
                    uMax = max(uMax, u)
                    vMin = min(vMin, w)
                    vMax = max(vMax, w)
                }
            }
        }
        let aspect = Float(max(v.aspect, 0.1))
        let halfHeight = max((vMax - vMin) / 2, (uMax - uMin) / 2 / aspect) * 1.03
        cameraNode.camera?.orthographicScale = Double(halfHeight / Float(max(v.zoom, 0.2)))
        let center = right * (uMin + uMax) / 2 + up * (vMin + vMax) / 2
        cameraNode.simdPosition = center + back * 100
    }

    // MARK: Builders

    private static func plane(length: Float, width: Float, color: UIColor) -> SCNGeometry {
        let plane = SCNPlane(width: CGFloat(length), height: CGFloat(width))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material
        return plane
    }

    private static func flatMaterial(_ color: UIColor, onTop: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        if onTop {
            material.readsFromDepthBuffer = false
        }
        return material
    }

    private static func label(_ text: String, size: Float, color: UIColor) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        geometry.flatness = 0.25
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        let (minBound, maxBound) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, 0)
        let scale = size / 10
        node.simdScale = SIMD3<Float>(scale, scale, scale)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        node.renderingOrder = 40
        return node
    }
}
