import Foundation

public enum SkinRefinementPreset: String, CaseIterable, Identifiable {
    case off, subtle, refined, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Off"; case .subtle: "Natural"; case .refined: "Polished"; case .custom: "Custom" }
    }
    public var intensity: Double { switch self { case .off: 0; case .subtle: 0.16; case .refined: 0.36; case .custom: 0.20 } }
    /// Presets offered in the UI; `.custom` remains only for stored legacy values.
    public static var visiblePresets: [SkinRefinementPreset] { [.off, .subtle, .refined] }
}

public struct SkinRefinementConfiguration: Equatable {
    public static let presetKey = "aurevixSkinPreset"
    public static let intensityKey = "aurevixSkinIntensity"
    public static let lightToneEnabledKey = "aurevixLightToneEnabled"
    public static let lightToneIntensityKey = "aurevixLightToneIntensity"
    public static let strengthKey = "aurevixSkinStrength"
    public var preset: SkinRefinementPreset
    public var intensity: Double
    public var lightToneEnabled: Bool
    public var lightToneIntensity: Double
    /// Strength slider, 0...1. 0.5 is the preset's tuned default; the range
    /// spans 0 to twice that value, bounded by the 0.40 retouch maximum.
    public var strength: Double
    public var effectiveIntensity: Double {
        guard preset != .off else { return 0 }
        guard preset == .custom else { return min(preset.intensity * 2 * strength, 0.4) }
        return min(max(intensity, 0), 0.4)
    }
    public init(preset: SkinRefinementPreset = .off, intensity: Double = 0.2,
                lightToneEnabled: Bool = false, lightToneIntensity: Double = 0.35, strength: Double = 0.5) {
        self.strength = min(max(strength, 0), 1)
        self.preset = preset
        self.intensity = min(max(intensity, 0), 0.4)
        self.lightToneEnabled = lightToneEnabled
        self.lightToneIntensity = min(max(lightToneIntensity, 0), 1)
    }
    public static func read(from defaults: UserDefaults? = UserDefaults(suiteName: "MPLX762T5G.com.martinaziz.privatecam")) -> Self {
        guard let defaults else { return Self() }
        // First launch (no stored preset) starts at the gentlest visible preset.
        return Self(preset: SkinRefinementPreset(rawValue: defaults.string(forKey: presetKey) ?? "subtle") ?? .subtle,
                    intensity: defaults.object(forKey: intensityKey) as? Double ?? 0.2,
                    lightToneEnabled: defaults.bool(forKey: lightToneEnabledKey),
                    lightToneIntensity: defaults.object(forKey: lightToneIntensityKey) as? Double ?? 0.35,
                    strength: defaults.object(forKey: strengthKey) as? Double ?? 0.5)
    }
    public func write(to defaults: UserDefaults? = UserDefaults(suiteName: "MPLX762T5G.com.martinaziz.privatecam")) {
        defaults?.set(preset.rawValue, forKey: Self.presetKey)
        let storedIntensity = min(max(intensity, 0), 0.4)
        defaults?.set(storedIntensity, forKey: Self.intensityKey)
        defaults?.set(lightToneEnabled, forKey: Self.lightToneEnabledKey)
        let storedLightToneIntensity = min(max(lightToneIntensity, 0), 1)
        defaults?.set(storedLightToneIntensity, forKey: Self.lightToneIntensityKey)
        defaults?.set(min(max(strength, 0), 1), forKey: Self.strengthKey)
    }
}
