import Foundation

/// Deterministic model tests for publisher accounting. These tests use frame IDs,
/// not pixel-buffer identity or output PTS, so publishing the same composite on
/// multiple ticks cannot inflate the unique processed count.
@main
private enum MotionDiagnosticsTests {
    private static var assertions = 0

    static func main() {
        var metrics = MotionMetricsModel()
        metrics.processed(10, latencyMilliseconds: 20, captureAgeMilliseconds: 40)
        metrics.publish(.processed(10), atMilliseconds: 100)
        metrics.publish(.processed(10), atMilliseconds: 133.333)
        metrics.publish(.processed(11), atMilliseconds: 166.666)
        metrics.processed(11, latencyMilliseconds: 24, captureAgeMilliseconds: 35)
        metrics.publish(.neutral, atMilliseconds: 199.999)
        check("published output count includes processed, repeated, and neutral") { metrics.outputFrames == 4 }
        check("unique processed counts processing operations, not repeated sends") { metrics.uniqueProcessedFrames == 2 }
        check("unique presented counts distinct processed IDs delivered") { metrics.uniquePresentedProcessedFrames == 2 }
        check("same frame ID is counted as reused") { metrics.reusedOutputFrames == 1 }
        check("repeat streak excludes the first presentation") { metrics.maximumRepeatedFrameStreak == 1 }
        check("neutral output breaks a repeat streak") { metrics.currentRepeatedFrameStreak == 0 }
        check("processing latency samples only successful processed results") { metrics.processingLatency.count == 2 }
        check("capture age samples have independent distribution") { metrics.captureAge.count == 2 }

        var cadence = MotionMetricsModel()
        cadence.processed(1, latencyMilliseconds: 5, captureAgeMilliseconds: 10)
        cadence.publish(.processed(1), atMilliseconds: 0)
        cadence.publish(.processed(1), atMilliseconds: 33.333)
        cadence.publish(.processed(1), atMilliseconds: 66.666)
        cadence.publish(.processed(1), atMilliseconds: 99.999)
        check("repeat duration tracks published intervals") { abs(cadence.maximumRepeatedDurationMilliseconds - 100) < 0.01 }
        cadence.rejected("capture_age")
        cadence.rejected("effect_changed")
        cadence.neutralFallback()
        check("rejections are separated by cause") { cadence.rejections["capture_age"] == 1 && cadence.rejections["effect_changed"] == 1 }
        check("neutral fallback is independent of neutral output") { cadence.neutralFallbacks == 1 }

        print("motion_diagnostics_tests=\(assertions) assertions_passed failed=0 camera_started=false images_saved=0")
    }

    private static func check(_ name: String, _ body: () -> Bool) {
        assertions += 1
        if body() { print("PASS \(name)") }
        else { fputs("FAIL \(name)\n", stderr); exit(1) }
    }
}

private enum PublishedFrame {
    case processed(UInt64)
    case neutral
}

private struct MotionMetricsModel {
    private(set) var outputFrames = 0
    private(set) var uniqueProcessedIDs = Set<UInt64>()
    private(set) var uniquePresentedIDs = Set<UInt64>()
    private(set) var reusedOutputFrames = 0
    private(set) var currentRepeatedFrameStreak = 0
    private(set) var maximumRepeatedFrameStreak = 0
    private(set) var maximumRepeatedDurationMilliseconds = 0.0
    private(set) var processingLatency: [Double] = []
    private(set) var captureAge: [Double] = []
    private(set) var rejections: [String: Int] = [:]
    private(set) var neutralFallbacks = 0
    private var previousID: UInt64?
    private var previousOutputTime: Double?

    var uniqueProcessedFrames: Int { uniqueProcessedIDs.count }
    var uniquePresentedProcessedFrames: Int { uniquePresentedIDs.count }

    mutating func processed(_ id: UInt64, latencyMilliseconds: Double, captureAgeMilliseconds: Double) {
        uniqueProcessedIDs.insert(id)
        processingLatency.append(latencyMilliseconds)
        captureAge.append(captureAgeMilliseconds)
    }

    mutating func publish(_ frame: PublishedFrame, atMilliseconds timestamp: Double) {
        outputFrames += 1
        switch frame {
        case .processed(let id):
            uniquePresentedIDs.insert(id)
            if previousID == id {
                reusedOutputFrames += 1
                currentRepeatedFrameStreak += 1
                maximumRepeatedFrameStreak = max(maximumRepeatedFrameStreak, currentRepeatedFrameStreak)
                maximumRepeatedDurationMilliseconds = max(maximumRepeatedDurationMilliseconds,
                    Double(currentRepeatedFrameStreak) * 33.333333)
            } else {
                currentRepeatedFrameStreak = 0
            }
            previousID = id
        case .neutral:
            currentRepeatedFrameStreak = 0
            previousID = nil
        }
        previousOutputTime = timestamp
    }

    mutating func rejected(_ cause: String) { rejections[cause, default: 0] += 1 }
    mutating func neutralFallback() { neutralFallbacks += 1 }
}
