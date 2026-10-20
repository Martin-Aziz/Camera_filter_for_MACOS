import Foundation
import CoreMedia
import CoreVideo

enum CameraBackgroundMode: String, CaseIterable, Hashable {
    /// Real room, still rendered through the processor (never the raw buffer).
    case original = "none"
    case solid
    case blur
    case image
}

enum CameraBlurPreset: String, CaseIterable, Hashable, Identifiable {
    case natural
    case soft
    case strong
    case softBlue

    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: "Natural"
        case .soft: "Soft"
        case .strong: "Strong"
        case .softBlue: "Soft Blue"
        }
    }

    /// Radius values are tuned for 720p output and bounded to avoid a flat,
    /// indistinct background. Intensity scales within each preset's range.
    func radius(intensity: Double) -> Double {
        let t = min(max(intensity, 0), 1)
        if self == .softBlue { return 0 }
        let range: ClosedRange<Double>
        switch self {
        case .natural: range = 3...8
        case .soft: range = 8...14
        case .strong: range = 20...34
        case .softBlue: range = 0...0
        }
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}

/// App Group preferences carry effect configuration only; they are not treated
/// as camera authorization. Defaults are conservative and usable by any client.
struct CameraProcessingConfiguration: Equatable {
    static let suiteName = "MPLX762T5G.com.martinaziz.privatecam"
    static let modeKey = "privateCamBackgroundMode"
    static let redKey = "privateCamBackgroundRed"
    static let greenKey = "privateCamBackgroundGreen"
    static let blueKey = "privateCamBackgroundBlue"
    static let blurRadiusKey = "privateCamBackgroundBlurRadius"
    static let blurPresetKey = "privateCamBackgroundBlurPreset"
    static let launchAtLoginKey = "privateCamLaunchAtLogin"
    static let backgroundPresetIDKey = "privateCamBackgroundPresetID"
    static let backgroundFilePathKey = "privateCamBackgroundFilePath"
    static let effectsEnabledKey = "aurevixEffectsEnabled"
    static let lastImportedBackgroundFilePathKey = "privateCamLastImportedBackgroundFilePath"
    static let engineStatusKey = "privateCamProcessingEngineStatus"
    static let engineStatusTimestampKey = "privateCamProcessingEngineStatusUpdatedAt"
    static let liveMotionMetricsKey = "privateCamLiveMotionMetrics"
    static let liveMotionMetricsTimestampKey = "privateCamLiveMotionMetricsUpdatedAt"

    var mode: CameraBackgroundMode = .blur
    var red: Double = 0.24
    var green: Double = 0.27
    var blue: Double = 0.30
    var blurRadius: Double = 0.5
    var blurPreset: CameraBlurPreset = .softBlue
    var backgroundPresetID: String = "soft-blue"
    var backgroundFilePath: String = ""
    /// Master switch from the menu bar popup. Off renders the real room with
    /// no retouch or lighting; the processed-output path is unchanged.
    var effectsEnabled: Bool = true

    /// Applies a supported background as one complete preference snapshot.
    mutating func selectBackground(presetID: String, importedFilePath: String = "") {
        backgroundPresetID = presetID
        backgroundFilePath = importedFilePath
        switch presetID {
        case "soft-blue":
            mode = .blur
            blurPreset = .softBlue
        case "neutral":
            mode = .solid
            red = 0.24
            green = 0.27
            blue = 0.30
        case "solid":
            mode = .solid
        case "none":
            mode = .original
        case "imported":
            mode = .image
        default:
            mode = .image
        }
    }

    static func read(from defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> Self {
        guard let defaults else { return Self() }
        let hasStoredMode = defaults.object(forKey: modeKey) != nil
        var mode = CameraBackgroundMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? (hasStoredMode ? .solid : .blur)
        let red = defaults.object(forKey: redKey) == nil ? 0.24 : defaults.double(forKey: redKey)
        let green = defaults.object(forKey: greenKey) == nil ? 0.27 : defaults.double(forKey: greenKey)
        let blue = defaults.object(forKey: blueKey) == nil ? 0.30 : defaults.double(forKey: blueKey)
        let storedIntensity = defaults.object(forKey: blurRadiusKey) == nil ? 0.5 : defaults.double(forKey: blurRadiusKey)
        // v1 stored a pixel radius (0...48). Convert that legacy value once
        // into the normalized control range while preserving a similar feel.
        let intensity = storedIntensity > 1 ? min(max(storedIntensity, 0), 48) / 48 : storedIntensity
        let storedPreset = defaults.string(forKey: blurPresetKey)
        let presetDefault = hasStoredMode ? CameraBlurPreset.natural.rawValue : CameraBlurPreset.softBlue.rawValue
        var preset = CameraBlurPreset(rawValue: storedPreset ?? presetDefault) ?? .natural
        var backgroundPresetID = defaults.string(forKey: backgroundPresetIDKey) ?? "soft-blue"
        var backgroundFilePath = defaults.string(forKey: backgroundFilePathKey) ?? ""
        // Migrate selections from the removed bundled photo gallery. Preserve
        // imported user photos; old stock IDs fall back to the safe neutral plate.
        let supportedImage = backgroundPresetID == "imported"
        if mode == .image && !supportedImage {
            mode = .blur
            preset = .softBlue
            backgroundPresetID = "soft-blue"
            backgroundFilePath = ""
        }
        if mode == .solid {
            if backgroundPresetID != "neutral" && backgroundPresetID != "solid" {
                let isNeutral = abs(red - 0.24) < 0.000001
                    && abs(green - 0.27) < 0.000001 && abs(blue - 0.30) < 0.000001
                backgroundPresetID = isNeutral ? "neutral" : "solid"
            }
            backgroundFilePath = ""
        }
        if mode == .original {
            backgroundPresetID = "none"
            backgroundFilePath = ""
        }
        let effectsEnabled = defaults.object(forKey: effectsEnabledKey) as? Bool ?? true
        return Self(mode: mode, red: min(max(red, 0), 1), green: min(max(green, 0), 1),
                    blue: min(max(blue, 0), 1), blurRadius: min(max(intensity, 0), 1), blurPreset: preset,
                    backgroundPresetID: backgroundPresetID, backgroundFilePath: backgroundFilePath,
                    effectsEnabled: effectsEnabled)
    }

    func write(to defaults: UserDefaults? = UserDefaults(suiteName: Self.suiteName)) {
        guard let defaults else { return }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(min(max(red, 0), 1), forKey: Self.redKey)
        defaults.set(min(max(green, 0), 1), forKey: Self.greenKey)
        defaults.set(min(max(blue, 0), 1), forKey: Self.blueKey)
        defaults.set(min(max(blurRadius, 0), 1), forKey: Self.blurRadiusKey)
        defaults.set(blurPreset.rawValue, forKey: Self.blurPresetKey)
        defaults.set(backgroundPresetID, forKey: Self.backgroundPresetIDKey)
        defaults.set(backgroundFilePath, forKey: Self.backgroundFilePathKey)
        defaults.set(effectsEnabled, forKey: Self.effectsEnabledKey)
    }

    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func writeEngineStatus(_ status: String, defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        defaults?.set(status, forKey: engineStatusKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: engineStatusTimestampKey)
    }

    static func readFreshEngineStatus(from defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
                                      now: Date = Date(), maximumAge: TimeInterval = 5) -> String? {
        guard let defaults,
              let status = defaults.string(forKey: engineStatusKey),
              let timestamp = defaults.object(forKey: engineStatusTimestampKey) as? Double else { return nil }
        let age = now.timeIntervalSince1970 - timestamp
        guard age >= 0, age <= maximumAge else { return nil }
        return status
    }

    static func writeLiveMotionMetrics(_ metrics: String, defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
                                       now: Date = Date()) {
        defaults?.set(metrics, forKey: liveMotionMetricsKey)
        defaults?.set(now.timeIntervalSince1970, forKey: liveMotionMetricsTimestampKey)
    }

    static func readFreshLiveMotionMetrics(from defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
                                           now: Date = Date(), maximumAge: TimeInterval = 3) -> String? {
        guard let defaults,
              let metrics = defaults.string(forKey: liveMotionMetricsKey),
              let timestamp = defaults.object(forKey: liveMotionMetricsTimestampKey) as? Double else { return nil }
        let age = now.timeIntervalSince1970 - timestamp
        guard age >= 0, age <= maximumAge else { return nil }
        return metrics
    }
}

struct ProcessedFramePublicationConditions {
    let generationIsCurrent: Bool
    let effectConfigurationIsCurrent: Bool
    let outputIsDistinctFromCapture: Bool
    let dimensionsMatch: Bool
    let pixelFormatMatches: Bool
    let frameAgeMilliseconds: Double

    var mayPublish: Bool {
        generationIsCurrent && effectConfigurationIsCurrent && outputIsDistinctFromCapture
            && dimensionsMatch && pixelFormatMatches
            && frameAgeMilliseconds.isFinite && frameAgeMilliseconds >= 0 && frameAgeMilliseconds <= 100
    }
}

/// One frame admitted to the serialized output publisher. The capture PTS is
/// retained only for freshness/diagnostics; the publisher assigns the output
/// PTS from its own CMIO host-clock tick.
struct ApprovedProcessedFrame {
    /// Monotonic identity for the processing operation. Unlike output PTS or
    /// buffer identity, this remains stable when the same composite is reused.
    let processingFrameID: UInt64
    let frameIdentity: ObjectIdentifier
    let generation: UInt64
    let configuration: CameraProcessingConfiguration
    let captureArrivalUptime: UInt64
    let sourcePresentationTime: CMTime
    let pixelBuffer: CVPixelBuffer
}

/// Bounded latest-frame slot. Call only from the serialized publisher queue.
struct ProcessedFrameSlot {
    private(set) var latest: ApprovedProcessedFrame?

    mutating func offer(_ frame: ApprovedProcessedFrame) {
        latest = frame
    }

    mutating func invalidate() {
        latest = nil
    }

    mutating func takeIfCurrent(generation: UInt64, configuration: CameraProcessingConfiguration,
                                nowUptime: UInt64, maximumAgeNanoseconds: UInt64) -> ApprovedProcessedFrame? {
        guard let frame = latest else { return nil }
        guard frame.generation == generation, frame.configuration == configuration,
              nowUptime >= frame.captureArrivalUptime,
              nowUptime - frame.captureArrivalUptime <= maximumAgeNanoseconds else {
            latest = nil
            return nil
        }
        return frame
    }
}

/// Pure scheduling policy used by deterministic continuity tests. The runtime
/// publisher always emits a neutral frame when there is no current composite.
enum SafePublisherSelection: Equatable {
    case neutral
    case processed(ObjectIdentifier)
}

struct SafePublisherState {
    var slot = ProcessedFrameSlot()

    mutating func select(generation: UInt64, configuration: CameraProcessingConfiguration,
                         nowUptime: UInt64, maximumAgeNanoseconds: UInt64,
                         processingWorkerBlocked: Bool = false) -> SafePublisherSelection {
        guard !processingWorkerBlocked,
              let frame = slot.takeIfCurrent(generation: generation, configuration: configuration,
                                             nowUptime: nowUptime, maximumAgeNanoseconds: maximumAgeNanoseconds)
        else { return .neutral }
        return .processed(frame.frameIdentity)
    }
}

enum ProcessingFailureReason: String {
    case physicalCameraUnavailable
    case captureFailed
}
