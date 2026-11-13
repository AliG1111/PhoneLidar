import Foundation
import XCTest

/// A complete laser calibration with sensible defaults: laser on the left, scale A = 200 px, camera 500 mm above the
/// belt, line on the empty belt at `baselineRow` in every profile column.
func makeLaserCalibration(width: Int = 400, height: Int = 300, stride: Int = 2, cameraHeight: Double = 500,
                          scale: Double? = 200, baselineRow: Float = 150, side: LaserSide = .left,
                          fx: Double = 1000, fy: Double = 1000, cx: Double = 200, cy: Double = 150)
    -> LaserCalibration {
    let columns = LaserColumns.make(width: width, stride: stride)
    return LaserCalibration(date: Date(timeIntervalSince1970: 1_700_000_000), cameraHeight: cameraHeight,
                            cameraHeightSource: .entered, scale: scale,
                            scaleSource: scale == nil ? nil : .shim, shimThickness: scale == nil ? nil : 10,
                            shimShift: nil, laserAngle: nil, laserSide: side, videoWidth: width,
                            videoHeight: height, columns: columns,
                            baselineRows: [Float](repeating: baselineRow, count: columns.count),
                            coverage: 100, filledColumns: 0, lensPosition: 0.8, fx: fx, fy: fy, cx: cx, cy: cy)
}

/// Settings of a synthetic laser recording that match `makeLaserCalibration`.
func makeLaserInfo(calibration: LaserCalibration = makeLaserCalibration(), direction: TravelDirection = .rightToLeft,
                   mapMethod: MapMethod = .singleReading, frameCount: Int? = nil, duration: Double? = nil)
    -> LaserRecordingInfo {
    LaserRecordingInfo(videoWidth: calibration.videoWidth, videoHeight: calibration.videoHeight, frameRate: 240,
                       activeFrameRate: 240, direction: direction, columnFirst: calibration.columns.first,
                       columnStride: calibration.columns.stride, columnCount: calibration.columns.count,
                       fx: calibration.fx, fy: calibration.fy, cx: calibration.cx, cy: calibration.cy,
                       shutterLimit: 0.001, exposureBias: 0, maxHeight: 100, mapMethod: mapMethod,
                       calibration: calibration, frameCount: frameCount, duration: duration, droppedFrames: nil,
                       stopReason: nil)
}
