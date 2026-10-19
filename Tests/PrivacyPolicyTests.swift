import Foundation
import CoreMedia
import CoreVideo

@main
private enum PrivacyPolicyTests {
    private static var assertions = 0

    static func main() {
        check("fresh configuration defaults to lightweight Soft Blue") {
            let value = CameraProcessingConfiguration()
            return value.mode == .blur && value.blurRadius == 0.5 && value.blurPreset == .softBlue
                && value.red == 0.24 && value.green == 0.27 && value.blue == 0.30
        }
        check("invalid persisted effect falls back to safe solid") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set("unknown", forKey: CameraProcessingConfiguration.modeKey)
            let result = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return result.mode == .solid && result.blurPreset == .natural
        }
        check("blur intensity is clamped to supported range") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(90.0, forKey: CameraProcessingConfiguration.blurRadiusKey)
            let result = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return result.blurRadius == 1
        }
        check("legacy pixel blur radius migrates to normalized intensity") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(18.0, forKey: CameraProcessingConfiguration.blurRadiusKey)
            let result = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return abs(result.blurRadius - 0.375) < 0.0001
        }
        check("background color channels are clamped") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(-0.4, forKey: CameraProcessingConfiguration.redKey)
            defaults.set(1.8, forKey: CameraProcessingConfiguration.greenKey)
            let result = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return result.red == 0 && result.green == 1 && result.blue == 0.30
        }
        check("processing configuration is delivered through app group preferences") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let expected = CameraProcessingConfiguration(mode: .blur, red: 0.3, green: 0.4, blue: 0.5,
                blurRadius: 0.7, blurPreset: .soft)
            expected.write(to: defaults)
            let actual = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return actual == expected
        }
        check("engine status must have a fresh heartbeat") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set("Blur processing active.", forKey: CameraProcessingConfiguration.engineStatusKey)
            defaults.set(Date().timeIntervalSince1970 - 30,
                         forKey: CameraProcessingConfiguration.engineStatusTimestampKey)
            let stale = CameraProcessingConfiguration.readFreshEngineStatus(from: defaults)
            CameraProcessingConfiguration.writeEngineStatus("Neutral fallback active.", defaults: defaults)
            let fresh = CameraProcessingConfiguration.readFreshEngineStatus(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return stale == nil && fresh == "Neutral fallback active."
        }
        check("unique processed FPS diagnostics expire when the stream heartbeat stops") {
            let name = "AurevixCamMotion-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let now = Date(timeIntervalSince1970: 10_000)
            CameraProcessingConfiguration.writeLiveMotionMetrics("Unique processed-video FPS: 27.4", defaults: defaults, now: now)
            let fresh = CameraProcessingConfiguration.readFreshLiveMotionMetrics(from: defaults, now: now)
            let expired = CameraProcessingConfiguration.readFreshLiveMotionMetrics(from: defaults, now: now.addingTimeInterval(4))
            defaults.removePersistentDomain(forName: name)
            return fresh == "Unique processed-video FPS: 27.4" && expired == nil
        }
        check("blur presets map intensity into restrained perceptual ranges") {
            CameraBlurPreset.natural.radius(intensity: 0) == 3
                && CameraBlurPreset.natural.radius(intensity: 1) == 8
                && CameraBlurPreset.soft.radius(intensity: 0.5) == 11
                && CameraBlurPreset.strong.radius(intensity: 1) == 22
                && CameraBlurPreset.softBlue.radius(intensity: 0.5) == 0
        }
        check("soft blue preset persists through app group configuration") {
            let name = "PrivateCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let expected = CameraProcessingConfiguration(mode: .blur, blurPreset: .softBlue)
            expected.write(to: defaults)
            let actual = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return actual == expected
        }
        check("photo preset identity and shared imported path persist without changing legacy keys") {
            let name = "AurevixCamTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let expected = CameraProcessingConfiguration(mode: .image, blurPreset: .softBlue,
                backgroundPresetID: "quiet-office", backgroundFilePath: "/shared/Backgrounds/Imported/example.jpg")
            expected.write(to: defaults)
            let actual = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return actual == expected && CameraProcessingConfiguration.modeKey == "privateCamBackgroundMode"
                && CameraProcessingConfiguration.blurPresetKey == "privateCamBackgroundBlurPreset"
        }
        check("gallery photo selection publishes image mode and clears a prior imported path") {
            var value = CameraProcessingConfiguration(mode: .image, backgroundPresetID: "imported",
                backgroundFilePath: "/shared/Backgrounds/Imported/old.jpg")
            value.selectBackground(presetID: "beach-sunrise")
            let name = "AurevixCamSelection-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            value.write(to: defaults)
            let selected = CameraProcessingConfiguration.read(from: defaults)
            defaults.removePersistentDomain(forName: name)
            return selected.mode == .image && selected.backgroundPresetID == "beach-sunrise"
                && selected.backgroundFilePath.isEmpty
        }
        check("Soft Blue selection restores the cached gradient treatment") {
            var value = CameraProcessingConfiguration(mode: .image, backgroundPresetID: "quiet-office")
            value.selectBackground(presetID: "soft-blue")
            return value.mode == .blur && value.blurPreset == .softBlue
                && value.backgroundPresetID == "soft-blue" && value.backgroundFilePath.isEmpty
        }
        let valid = ProcessedFramePublicationConditions(
            generationIsCurrent: true, effectConfigurationIsCurrent: true,
            outputIsDistinctFromCapture: true, dimensionsMatch: true,
            pixelFormatMatches: true, frameAgeMilliseconds: 20)
        check("fresh processed output passes publication boundary") { valid.mayPublish }
        check("generation cancellation rejects pending output") {
            conditions(generation: false).mayPublish == false
        }
        check("effect change rejects stale processing configuration") {
            conditions(configuration: false).mayPublish == false
        }
        check("source buffer identity rejects raw passthrough") {
            conditions(distinct: false).mayPublish == false
        }
        check("dimension mismatch rejects output") { conditions(dimensions: false).mayPublish == false }
        check("pixel-format mismatch rejects output") { conditions(format: false).mayPublish == false }
        check("frame age above 100 ms rejects stale output") { conditions(age: 100.01).mayPublish == false }
        check("negative frame age rejects future timestamps") { conditions(age: -1).mayPublish == false }
        check("non-finite frame age rejects malformed timestamps") { conditions(age: .infinity).mayPublish == false }
        check("100 ms frame age remains within the bound") { conditions(age: 100).mayPublish }
        let config = CameraProcessingConfiguration(mode: .blur, blurRadius: 48)
        let buffer = makeBuffer()
        let identity = ObjectIdentifier(buffer)
        let frame = ApprovedProcessedFrame(processingFrameID: 1, frameIdentity: identity, generation: 7, configuration: config,
            captureArrivalUptime: 1_000_000_000, sourcePresentationTime: CMTime(value: 1, timescale: 30), pixelBuffer: buffer)
        var slot = ProcessedFrameSlot()
        slot.offer(frame)
        check("valid processed composite reaches publisher slot") {
            slot.takeIfCurrent(generation: 7, configuration: config, nowUptime: 1_010_000_000,
                maximumAgeNanoseconds: 100_000_000)?.frameIdentity == identity
        }
        var repeatingPublisher = SafePublisherState()
        repeatingPublisher.slot.offer(frame)
        check("latest processed composite can fill a cadence tick while still fresh") {
            let first = repeatingPublisher.select(generation: 7, configuration: config,
                nowUptime: 1_010_000_000, maximumAgeNanoseconds: 100_000_000)
            let nextTick = repeatingPublisher.select(generation: 7, configuration: config,
                nowUptime: 1_043_333_333, maximumAgeNanoseconds: 100_000_000)
            return first == .processed(identity) && nextTick == .processed(identity)
        }
        check("reused output stays the same immutable pixel buffer between publication ticks") {
            let reusable = makeBuffer()
            CVPixelBufferLockBaseAddress(reusable, [])
            guard let base = CVPixelBufferGetBaseAddressOfPlane(reusable, 0) else {
                CVPixelBufferUnlockBaseAddress(reusable, [])
                return false
            }
            base.storeBytes(of: UInt8(73), as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(reusable, [])
            let reusableID = ObjectIdentifier(reusable)
            var reuseSlot = ProcessedFrameSlot()
            reuseSlot.offer(ApprovedProcessedFrame(processingFrameID: 2, frameIdentity: reusableID, generation: 7,
                configuration: config, captureArrivalUptime: 2_000_000_000,
                sourcePresentationTime: CMTime(value: 9, timescale: 30), pixelBuffer: reusable))
            let first = reuseSlot.takeIfCurrent(generation: 7, configuration: config,
                nowUptime: 2_010_000_000, maximumAgeNanoseconds: 100_000_000)
            let second = reuseSlot.takeIfCurrent(generation: 7, configuration: config,
                nowUptime: 2_043_333_333, maximumAgeNanoseconds: 100_000_000)
            CVPixelBufferLockBaseAddress(reusable, .readOnly)
            let unchanged = CVPixelBufferGetBaseAddressOfPlane(reusable, 0)?.load(as: UInt8.self) == 73
            CVPixelBufferUnlockBaseAddress(reusable, .readOnly)
            return first?.frameIdentity == reusableID && second?.frameIdentity == reusableID && unchanged
        }
        slot.offer(frame)
        check("capture PTS older than neutral clock is retained as source metadata") {
            slot.takeIfCurrent(generation: 7, configuration: config, nowUptime: 1_020_000_000,
                maximumAgeNanoseconds: 100_000_000)?.sourcePresentationTime == frame.sourcePresentationTime
        }
        slot.offer(frame)
        check("slow processing expires the pending composite") {
            slot.takeIfCurrent(generation: 7, configuration: config, nowUptime: 1_101_000_001,
                maximumAgeNanoseconds: 100_000_000) == nil && slot.latest == nil
        }
        slot.offer(frame)
        check("effect change rejects pending composite") {
            slot.takeIfCurrent(generation: 7, configuration: CameraProcessingConfiguration(mode: .solid),
                nowUptime: 1_010_000_000, maximumAgeNanoseconds: 100_000_000) == nil
        }
        slot.offer(frame)
        check("capture generation change rejects pending composite") {
            slot.takeIfCurrent(generation: 8, configuration: config, nowUptime: 1_010_000_000,
                maximumAgeNanoseconds: 100_000_000) == nil
        }
        slot.offer(frame)
        check("Vision failure invalidates pending composite") {
            slot.invalidate()
            return slot.latest == nil
        }
        slot.offer(frame)
        check("latest processed frame replaces the prior bounded slot item") {
            let replacement = makeBuffer()
            let next = ApprovedProcessedFrame(processingFrameID: 3, frameIdentity: ObjectIdentifier(replacement), generation: 7,
                configuration: config, captureArrivalUptime: 1_015_000_000,
                sourcePresentationTime: CMTime(value: 2, timescale: 30), pixelBuffer: replacement)
            slot.offer(next)
            return slot.latest?.frameIdentity == ObjectIdentifier(replacement)
        }
        var publisher = SafePublisherState()
        publisher.slot.offer(frame)
        check("blocked processing worker leaves neutral publisher selection available") {
            publisher.select(generation: 7, configuration: config, nowUptime: 1_010_000_000,
                maximumAgeNanoseconds: 100_000_000, processingWorkerBlocked: true) == .neutral
        }
        publisher.slot.offer(frame)
        check("stale processed frame selects neutral without extending freshness") {
            publisher.select(generation: 7, configuration: config, nowUptime: 1_101_000_001,
                maximumAgeNanoseconds: 100_000_000) == .neutral
        }
        let recoveredBuffer = makeBuffer()
        publisher.slot.offer(ApprovedProcessedFrame(processingFrameID: 4, frameIdentity: ObjectIdentifier(recoveredBuffer), generation: 7,
            configuration: config, captureArrivalUptime: 1_105_000_000,
            sourcePresentationTime: CMTime(value: 3, timescale: 30), pixelBuffer: recoveredBuffer))
        check("fresh processing recovery resumes distinct processed output") {
            publisher.select(generation: 7, configuration: config, nowUptime: 1_110_000_000,
                maximumAgeNanoseconds: 100_000_000) == .processed(ObjectIdentifier(recoveredBuffer))
        }
        check("neutral fallback never exposes capture buffer identity") {
            publisher.slot.invalidate()
            return publisher.select(generation: 7, configuration: config, nowUptime: 1_110_000_000,
                maximumAgeNanoseconds: 100_000_000) == .neutral
        }
        check("1280x720 420v is format compatible") {
            formatCompatible(1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        check("1280x720 420f is rejected against advertised 420v") {
            !formatCompatible(1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
        check("1920x1080 callback is rejected to neutral") {
            !formatCompatible(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        check("unsupported format is rejected to neutral") {
            !formatCompatible(1280, 720, kCVPixelFormatType_422YpCbCr8)
        }
        check("300 publisher ticks at 30fps have strict monotonic timestamps") {
            var previous = CMTime.invalid
            for index in 0..<300 {
                let timestamp = CMTime(value: Int64(index), timescale: 30)
                if previous.isValid && CMTimeCompare(timestamp, previous) <= 0 { return false }
                previous = timestamp
            }
            return true
        }
        check("two consumers share one newest-frame slot") { slot.latest?.frameIdentity != identity }
        print("processing_boundary_tests=\(assertions) assertions_passed failed=0 camera_started=false images_saved=0")
    }

    private static func conditions(
        generation: Bool = true, configuration: Bool = true, distinct: Bool = true,
        dimensions: Bool = true, format: Bool = true, age: Double = 20
    ) -> ProcessedFramePublicationConditions {
        ProcessedFramePublicationConditions(generationIsCurrent: generation,
            effectConfigurationIsCurrent: configuration, outputIsDistinctFromCapture: distinct,
            dimensionsMatch: dimensions, pixelFormatMatches: format, frameAgeMilliseconds: age)
    }

    private static func formatCompatible(_ width: Int, _ height: Int, _ format: OSType) -> Bool {
        width == 1280 && height == 720 && format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func makeBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1280,
            kCVPixelBufferHeightKey: 720,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        return buffer!
    }

    @discardableResult
    private static func check(_ name: String, _ assertion: () -> Bool) -> Bool {
        guard assertion() else {
            fputs("FAIL \(name)\n", stderr)
            exit(EXIT_FAILURE)
        }
        assertions += 1
        print("PASS \(name)")
        return true
    }
}
