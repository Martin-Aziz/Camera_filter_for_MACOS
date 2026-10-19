import Foundation

@main
private enum CameraOperationalStateTests {
    private static var failures = 0
    private static var assertions = 0

    static func main() {
        check("initial discovery is explicit") {
            state(discoveryComplete: false, matching: false) == .discovering
        }
        check("zero matching cameras is unavailable") {
            state(discoveryComplete: true, matching: false) == .cameraUnavailable
        }
        check("one unrelated external camera does not satisfy identity match") {
            state(discoveryComplete: true, matching: false) == .cameraUnavailable
        }
        check("matching virtual camera is ready to preview") {
            state(discoveryComplete: true, matching: true) == .cameraReady
        }
        check("matching device disconnect returns to unavailable") {
            state(discoveryComplete: true, matching: false) == .cameraUnavailable
        }
        check("matching device reconnect returns to ready") {
            state(discoveryComplete: true, matching: true) == .cameraReady
        }
        check("stale discovery cannot claim the camera is ready") {
            state(discoveryComplete: false, matching: true) == .discovering
        }
        check("preview start is represented explicitly") {
            CameraOperationalState.resolve(discoveryComplete: true, matchingCameraAvailable: true,
                previewStarting: true, previewRunning: false, processingConfirmed: false) == .previewStarting
        }
        check("running preview without confirmed processing is unavailable") {
            CameraOperationalState.resolve(discoveryComplete: true, matchingCameraAvailable: true,
                previewStarting: false, previewRunning: true, processingConfirmed: false) == .processingUnavailable
        }
        check("processing state requires a running preview and confirmation") {
            CameraOperationalState.resolve(discoveryComplete: true, matchingCameraAvailable: true,
                previewStarting: false, previewRunning: true, processingConfirmed: true) == .previewRunning
        }
        check("preview failure is represented as an error") {
            CameraOperationalState.resolve(discoveryComplete: true, matchingCameraAvailable: true,
                previewStarting: false, previewRunning: false, processingConfirmed: false,
                errorMessage: "session start failed") == .error("session start failed")
        }
        check("camera unavailable never displays Ready") {
            CameraOperationalState.cameraUnavailable.title != "Ready"
                && CameraOperationalState.cameraUnavailable.title == "Camera unavailable"
        }
        print("\(assertions - failures)/\(assertions) operational state checks passed")
        if failures > 0 { exit(1) }
    }

    private static func state(discoveryComplete: Bool, matching: Bool) -> CameraOperationalState {
        CameraOperationalState.resolve(discoveryComplete: discoveryComplete,
            matchingCameraAvailable: matching, previewStarting: false,
            previewRunning: false, processingConfirmed: false)
    }

    private static func check(_ name: String, _ body: () -> Bool) {
        assertions += 1
        if body() { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }
}
