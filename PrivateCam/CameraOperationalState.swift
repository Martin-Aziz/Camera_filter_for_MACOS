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
