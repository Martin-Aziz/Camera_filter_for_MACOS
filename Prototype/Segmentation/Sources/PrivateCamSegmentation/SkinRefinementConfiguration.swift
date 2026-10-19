import Foundation

public enum SkinRefinementPreset: String, CaseIterable, Identifiable {
    case off, subtle, refined, custom
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var intensity: Double { switch self { case .off: 0; case .subtle: 0.16; case .refined: 0.30; case .custom: 0.20 } }
}

public struct SkinRefinementConfiguration: Equatable {
    public static let presetKey = "aurevixSkinPreset"
    public static let intensityKey = "aurevixSkinIntensity"
    public var preset: SkinRefinementPreset
    public var intensity: Double
    public var effectiveIntensity: Double { preset == .off ? 0 : (preset == .custom ? intensity : preset.intensity) }
    public init(preset: SkinRefinementPreset = .off, intensity: Double = 0.2) {
        self.preset = preset; self.intensity = min(max(intensity, 0), 0.4)
    }
    public static func read(from defaults: UserDefaults? = UserDefaults(suiteName: "MPLX762T5G.com.martinaziz.privatecam")) -> Self {
        guard let defaults else { return Self() }
        return Self(preset: SkinRefinementPreset(rawValue: defaults.string(forKey: presetKey) ?? "off") ?? .off,
                    intensity: defaults.object(forKey: intensityKey) as? Double ?? 0.2)
    }
    public func write(to defaults: UserDefaults? = UserDefaults(suiteName: "MPLX762T5G.com.martinaziz.privatecam")) {
        defaults?.set(preset.rawValue, forKey: Self.presetKey)
        defaults?.set(min(max(intensity, 0), 0.4), forKey: Self.intensityKey)
    }
}
