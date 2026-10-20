import Foundation

enum CameraOperationalState: Equatable {
    case discovering
    case cameraUnavailable
    case cameraReady
    case previewStarting
    case previewRunning
    case processingUnavailable
    case error(String)

    static func resolve(
        discoveryComplete: Bool,
        matchingCameraAvailable: Bool,
        previewStarting: Bool,
        previewRunning: Bool,
        processingConfirmed: Bool,
        errorMessage: String? = nil
    ) -> Self {
        if let errorMessage { return .error(errorMessage) }
        guard discoveryComplete else { return .discovering }
        guard matchingCameraAvailable else { return .cameraUnavailable }
        if previewStarting { return .previewStarting }
        guard previewRunning else { return .cameraReady }
        return processingConfirmed ? .previewRunning : .processingUnavailable
    }

    var title: String {
        switch self {
        case .discovering: "Discovering camera"
        case .cameraUnavailable: "Camera unavailable"
        case .cameraReady: "Camera ready"
        case .previewStarting: "Preview starting"
        case .previewRunning: "Preview running"
        case .processingUnavailable: "Processing unavailable"
        case .error: "Camera error"
        }
    }
}

/// Camera setup status shown in the Studio pill, popup and Settings.
enum CameraSetupState: Equatable {
    case checking
    case ready
    case settingUp
    case needsApproval
    case needsRestart
    case failed(String)
    case missing
}
