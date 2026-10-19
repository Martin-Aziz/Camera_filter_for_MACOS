import Foundation
import AppKit
import AVFoundation
import SystemExtensions
import Combine
import os
import ServiceManagement
import ImageIO
import UniformTypeIdentifiers

final class CameraController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "Ready. Activate extension, then refresh the camera list."
    @Published var deviceList = "No enumeration performed yet."
    @Published var statistics = "Delivered output FPS (receiver): 0.0 | frames: 0 | elapsed: 0.0 s | dropped: 0"
    @Published var session: AVCaptureSession?
    @Published var isCapturing = false
    @Published var isStarting = false
    @Published var isDeviceAvailable = false
    @Published private(set) var discoveryComplete = false
    @Published private(set) var operationalError: String?
    @Published var isInterrupted = false
    @Published private(set) var captureRequested = false
    @Published var backgroundMode = CameraBackgroundMode.solid { didSet { persistProcessingConfiguration() } }
    @Published var backgroundRed = 0.24 { didSet { persistProcessingConfiguration() } }
    @Published var backgroundGreen = 0.27 { didSet { persistProcessingConfiguration() } }
    @Published var backgroundBlue = 0.30 { didSet { persistProcessingConfiguration() } }
    @Published var blurIntensity = 0.5 { didSet { persistProcessingConfiguration() } }
    @Published var blurPreset: CameraBlurPreset = .natural { didSet { persistProcessingConfiguration() } }
    @Published var backgroundPresetID = "soft-blue" { didSet { persistProcessingConfiguration() } }
    @Published var backgroundFilePath = "" { didSet { persistProcessingConfiguration() } }
    @Published private(set) var importedBackgroundPath = ""
    @Published private(set) var importedBackgroundPreview: NSImage?
    @Published private(set) var personalBackgrounds: [URL] = []
    @Published var skinPreset: SkinRefinementPreset = .off { didSet { persistSkinConfiguration() } }
    @Published var skinIntensity: Double = 0.2 { didSet { persistSkinConfiguration() } }
    @Published var lightToneEnabled = false { didSet { persistSkinConfiguration() } }
    @Published var lightToneIntensity = 0.35 { didSet { persistSkinConfiguration() } }
    @Published var processingStatus = "Processing status unavailable. Start a virtual-camera client to confirm."
    @Published var motionStatistics = "Unique processed-video FPS: unavailable (no active stream)"
    @Published var streamHealth = "Stream health: waiting for receiver data."
    @Published var launchAtLoginEnabled = false
    @Published var loginItemStatus = ""

    private let extensionID = "com.martinaziz.privatecam.CameraExtension"
    private let targetDeviceID = "76A10B58-2C45-4B8C-BE2A-0D6F1C286101"
    private let sessionQueue = DispatchQueue(label: "com.martinaziz.privatecam.session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.martinaziz.privatecam.capture-metadata", qos: .userInitiated)
    private var activeSession: AVCaptureSession?
    private var activeOutput: AVCaptureVideoDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var availabilityObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    // captureRequested is main-thread owned and retained only across bounded recovery.
    private var captureRequestGeneration: UInt64 = 0
    private var retryAttempts = 0
    private var retryScheduleGeneration: UInt64 = 0
    private var engineStatusTimer: DispatchSourceTimer?
    private var receiverSessionPreset = "unknown" // captureQueue owned
    private let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0]
    // The receiver delegate queue exclusively owns all metrics below. stopCapture
    // drains that queue after stopping the session before it emits a final summary.
    private var startUptimeNanoseconds: UInt64?
    private var sampleCount = 0
    private var callbackIntervalsMs: [Double] = []
    private var callbackReceiveUptimes: [UInt64] = []
    private var presentationIntervalsMs: [Double] = []
    private var previousReceiveTime: UInt64?
    private var previousPresentationTime: CMTime?
    private var receiverFrameSequence: UInt64 = 0
    private var droppedFrames = 0
    private var callbackGapsOver50ms = 0
    private var presentationGapsOver50ms = 0
    private var didLogCaptureDimensions = false
    private var isRestoringConfiguration = true

    var operationalState: CameraOperationalState {
        let confirmedProcessing = processingStatus.localizedCaseInsensitiveContains("processing active")
        return CameraOperationalState.resolve(
            discoveryComplete: discoveryComplete,
            matchingCameraAvailable: isDeviceAvailable,
            previewStarting: isStarting,
            previewRunning: isCapturing,
            processingConfirmed: confirmedProcessing,
            errorMessage: operationalError
        )
    }
    private var perSecondFrames: [Int] = []
    private var currentSecond = 0
    private var currentSecondFrames = 0
    private let logger = Logger(subsystem: "com.martinaziz.privatecam", category: "HostCapture")

    override init() {
        super.init()
        let config = CameraProcessingConfiguration.read()
        backgroundMode = config.mode
        backgroundRed = config.red
        backgroundGreen = config.green
        backgroundBlue = config.blue
        blurIntensity = config.blurRadius
        blurPreset = config.blurPreset
        backgroundPresetID = config.backgroundPresetID
        backgroundFilePath = config.backgroundFilePath
        // Persist canonicalized preferences so removed stock-scene IDs migrate
        // once to a supported neutral background while imported photos survive.
        config.write(to: CameraProcessingConfiguration.sharedDefaults())
        let defaults = CameraProcessingConfiguration.sharedDefaults()
        importedBackgroundPath = config.backgroundPresetID == "imported" && !config.backgroundFilePath.isEmpty
            ? config.backgroundFilePath
            : (defaults?.string(forKey: CameraProcessingConfiguration.lastImportedBackgroundFilePathKey) ?? "")
        if !importedBackgroundPath.isEmpty, FileManager.default.fileExists(atPath: importedBackgroundPath) {
            importedBackgroundPreview = NSImage(contentsOfFile: importedBackgroundPath)
        }
        let skin = SkinRefinementConfiguration.read()
        skinPreset = skin.preset
        skinIntensity = skin.intensity
        lightToneEnabled = skin.lightToneEnabled
        lightToneIntensity = skin.lightToneIntensity
        refreshPersonalBackgrounds()
        launchAtLoginEnabled = UserDefaults.standard.bool(forKey: CameraProcessingConfiguration.launchAtLoginKey)
        isRestoringConfiguration = false
        installObservers()
    }

    deinit {
        engineStatusTimer?.cancel()
        for observer in availabilityObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func activateExtension() {
        status = "Submitting system extension activation request…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        logger.notice("activation requested for \(self.extensionID, privacy: .public)")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "macOS requires approval in System Settings → Privacy & Security. Approve Aurevix Cam, then return and refresh."
        logger.notice("system reports user approval required")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = "Activation request completed: \(result.rawValue). Refresh the camera list."
        logger.notice("activation completed result=\(result.rawValue, privacy: .public)")
        refreshDevices()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        status = "Activation failed: \(error.localizedDescription)"
        logger.error("activation failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) description=\(error.localizedDescription, privacy: .public)")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension new: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        logger.notice("replacing extension version \(existing.bundleVersion, privacy: .public) with \(new.bundleVersion, privacy: .public)")
        return .replace
    }

    private var startAttemptInFlight = false // Main-thread owned.

    private func discoveredDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.external]
        } else {
            types = [.externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                position: .unspecified).devices
    }

    func refreshDevices() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshDevices() }
            return
        }
        let devices = discoveredDevices()
        discoveryComplete = true
        deviceList = devices.map { "\($0.localizedName) — \($0.uniqueID)" }.joined(separator: "\n")
        let camera = devices.first(where: { $0.uniqueID == targetDeviceID })
        let wasAvailable = isDeviceAvailable
        isDeviceAvailable = camera != nil
        if let camera {
            logger.notice("enumerated Aurevix Cam by stable ID unique_id=\(camera.uniqueID, privacy: .public)")
            if !isCapturing && !isStarting {
                status = "Aurevix Cam virtual camera is available."
            }
        } else {
            logger.notice("Aurevix Cam unavailable in current AVFoundation discovery snapshot; stale selection cleared")
            if !isCapturing && !isStarting {
                status = devices.isEmpty
                    ? "No external camera is available. Aurevix Cam will be checked again when devices change."
                    : "Aurevix Cam is not currently available (\(devices.count) other external camera(s) found)."
            }
        }
        logger.notice("enumeration external_count=\(devices.count, privacy: .public) aurevix_camera_available=\(camera != nil, privacy: .public)")
        if wasAvailable && camera == nil && captureRequested {
            handlePrivateCamUnavailable(reason: "discovery refresh no longer contains stable device ID")
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        availabilityObservers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
            object: nil, queue: .main) { [weak self] notification in
                self?.deviceAvailabilityChanged(notification, connected: true)
            })
        availabilityObservers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: .main) { [weak self] notification in
                self?.deviceAvailabilityChanged(notification, connected: false)
            })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.logger.notice("system wake observed; refreshing Aurevix Cam availability")
                self.refreshDevices()
                if self.captureRequested, !self.isCapturing, !self.startAttemptInFlight {
                    self.retryAttempts = 0
                    self.beginStartAttempt()
                }
            })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in self?.refreshDevices() })
    }

    private func deviceAvailabilityChanged(_ notification: Notification, connected: Bool) {
        let device = notification.object as? AVCaptureDevice
        guard device?.uniqueID == targetDeviceID else { return }
        logger.notice("Aurevix Cam availability notification connected=\(connected, privacy: .public) unique_id=\(self.targetDeviceID, privacy: .public)")
        if connected {
            refreshDevices()
            if captureRequested, !isCapturing, !startAttemptInFlight {
                retryScheduleGeneration &+= 1
                retryAttempts = 0
                beginStartAttempt()
            }
        } else {
            let otherDevices = discoveredDevices().filter { $0.uniqueID != targetDeviceID }
            deviceList = otherDevices.map { "\($0.localizedName) — \($0.uniqueID)" }.joined(separator: "\n")
            isDeviceAvailable = false
            if captureRequested {
                handlePrivateCamUnavailable(reason: "AVCaptureDevice disconnected notification")
            } else {
                status = "Aurevix Cam is unavailable. Waiting for the device to reconnect."
            }
        }
    }

    private func handlePrivateCamUnavailable(reason: String) {
        guard captureRequested else { return }
        captureRequestGeneration &+= 1
        let requestID = captureRequestGeneration
        isCapturing = false
        isStarting = true
        startAttemptInFlight = false
        status = "Aurevix Cam became unavailable; stopping the stale preview and checking for reconnection."
        logger.error("capture availability lost reason=\(reason, privacy: .public)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.cleanupActiveSession(reason: "Aurevix Cam unavailable")
            DispatchQueue.main.async {
                guard self.captureRequested, self.captureRequestGeneration == requestID else { return }
                self.session = nil
                self.scheduleRetry(for: requestID, detail: "Aurevix Cam is not currently discoverable")
            }
        }
    }

    func startMonitoringEngineStatus() {
        guard engineStatusTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.refreshEngineStatus() }
        engineStatusTimer = timer
        timer.resume()
        refreshEngineStatus()
    }

    func stopMonitoringEngineStatus() {
        engineStatusTimer?.cancel()
        engineStatusTimer = nil
    }

    private func refreshEngineStatus() {
        let engineStatus = CameraProcessingConfiguration.readFreshEngineStatus(from: CameraProcessingConfiguration.sharedDefaults())
            ?? "Processing status unavailable. Start a virtual-camera client to confirm."
        if engineStatus != processingStatus { processingStatus = engineStatus }
        let motion = CameraProcessingConfiguration.readFreshLiveMotionMetrics(
            from: CameraProcessingConfiguration.sharedDefaults()
        ) ?? "Unique processed-video FPS: unavailable (no fresh stream statistics)"
        if motion != motionStatistics { motionStatistics = motion }
    }

    func toggleCapture() { (captureRequested || isCapturing || isStarting) ? stopCapture() : startCapture() }

    private func persistProcessingConfiguration() {
        guard !isRestoringConfiguration else { return }
        CameraProcessingConfiguration(mode: backgroundMode, red: backgroundRed, green: backgroundGreen,
                                      blue: backgroundBlue, blurRadius: blurIntensity, blurPreset: blurPreset,
                                      backgroundPresetID: backgroundPresetID, backgroundFilePath: backgroundFilePath)
            .write(to: CameraProcessingConfiguration.sharedDefaults())
    }

    func selectBackground(_ presetID: String) {
        var config = currentProcessingConfiguration()
        config.selectBackground(presetID: presetID)
        applyProcessingConfiguration(config)
    }

    func selectSolidBackground() {
        var config = currentProcessingConfiguration()
        config.selectBackground(presetID: "solid")
        applyProcessingConfiguration(config)
    }

    func selectImportedBackground() {
        guard !importedBackgroundPath.isEmpty, FileManager.default.fileExists(atPath: importedBackgroundPath) else { return }
        var config = currentProcessingConfiguration()
        config.selectBackground(presetID: "imported", importedFilePath: importedBackgroundPath)
        applyProcessingConfiguration(config)
    }

    func selectPersonalBackground(_ url: URL) {
        guard isManagedPersonalBackground(url), FileManager.default.fileExists(atPath: url.path) else { return }
        var config = currentProcessingConfiguration()
        config.selectBackground(presetID: "imported", importedFilePath: url.path)
        applyProcessingConfiguration(config)
        importedBackgroundPath = url.path
        importedBackgroundPreview = NSImage(contentsOf: url)
        CameraProcessingConfiguration.sharedDefaults()?.set(url.path, forKey: CameraProcessingConfiguration.lastImportedBackgroundFilePathKey)
    }

    func removePersonalBackground(_ url: URL) throws {
        guard isManagedPersonalBackground(url) else { return }
        if currentProcessingConfiguration().backgroundFilePath == url.path {
            selectBackground("soft-blue")
        }
        try FileManager.default.removeItem(at: url)
        if importedBackgroundPath == url.path { importedBackgroundPath = ""; importedBackgroundPreview = nil }
        refreshPersonalBackgrounds()
    }

    private func personalBackgroundDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CameraProcessingConfiguration.suiteName)?
            .appendingPathComponent("Backgrounds/Imported", isDirectory: true)
    }

    private func isManagedPersonalBackground(_ url: URL) -> Bool {
        guard let root = personalBackgroundDirectory()?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(root + "/")
    }

    func refreshPersonalBackgrounds() {
        guard let directory = personalBackgroundDirectory() else { personalBackgrounds = []; return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        personalBackgrounds = urls.filter { isManagedPersonalBackground($0) && NSImage(contentsOf: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let selected = CameraProcessingConfiguration.read().backgroundFilePath
        if CameraProcessingConfiguration.read().backgroundPresetID == "imported", !FileManager.default.fileExists(atPath: selected) {
            selectBackground("soft-blue")
        }
    }

    private func persistSkinConfiguration() {
        guard !isRestoringConfiguration else { return }
        SkinRefinementConfiguration(preset: skinPreset, intensity: min(max(skinIntensity, 0), 0.4),
                                    lightToneEnabled: lightToneEnabled,
                                    lightToneIntensity: lightToneIntensity).write()
    }

    func importBackground(from sourceURL: URL) throws {
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer { if granted { sourceURL.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000 else {
            throw NSError(domain: "AurevixCam.Import", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a valid image file."])
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw NSError(domain: "AurevixCam.Import", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Aurevix Cam couldn’t decode this image."])
        }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CameraProcessingConfiguration.suiteName) else {
            throw NSError(domain: "AurevixCam.Import", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The shared background folder is unavailable."])
        }
        let directory = group.appendingPathComponent("Backgrounds/Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let imageType = hasAlpha ? UTType.png : UTType.jpeg
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(hasAlpha ? "png" : "jpg")")
        guard let imageData = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let imageDestination = CGImageDestinationCreateWithData(imageData, imageType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "AurevixCam.Import", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Aurevix Cam couldn’t prepare this image."])
        }
        let outputProperties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(imageDestination, thumbnail, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw NSError(domain: "AurevixCam.Import", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Aurevix Cam couldn’t save the imported image."])
        }
        try (imageData as Data).write(to: destination, options: .atomic)
        var config = currentProcessingConfiguration()
        config.selectBackground(presetID: "imported", importedFilePath: destination.path)
        applyProcessingConfiguration(config)
        importedBackgroundPath = destination.path
        CameraProcessingConfiguration.sharedDefaults()?.set(
            destination.path, forKey: CameraProcessingConfiguration.lastImportedBackgroundFilePathKey
        )
        importedBackgroundPreview = NSImage(contentsOf: destination)
        refreshPersonalBackgrounds()
    }

    func setBackgroundColor(red: Double, green: Double, blue: Double) {
        var config = currentProcessingConfiguration()
        config.red = red
        config.green = green
        config.blue = blue
        if config.mode == .solid { config.backgroundPresetID = "solid" }
        applyProcessingConfiguration(config)
    }

    private func currentProcessingConfiguration() -> CameraProcessingConfiguration {
        CameraProcessingConfiguration(mode: backgroundMode, red: backgroundRed, green: backgroundGreen,
            blue: backgroundBlue, blurRadius: blurIntensity, blurPreset: blurPreset,
            backgroundPresetID: backgroundPresetID, backgroundFilePath: backgroundFilePath)
    }

    private func applyProcessingConfiguration(_ config: CameraProcessingConfiguration) {
        // Suppress per-property preference writes while updating the published UI
        // state, then publish the completed effect selection to the CMIO extension.
        isRestoringConfiguration = true
        backgroundMode = config.mode
        backgroundRed = config.red
        backgroundGreen = config.green
        backgroundBlue = config.blue
        blurIntensity = config.blurRadius
        blurPreset = config.blurPreset
        backgroundPresetID = config.backgroundPresetID
        backgroundFilePath = config.backgroundFilePath
        isRestoringConfiguration = false
        config.write(to: CameraProcessingConfiguration.sharedDefaults())
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: CameraProcessingConfiguration.launchAtLoginKey)
            loginItemStatus = enabled ? "Launch at Login enabled." : "Launch at Login disabled."
        } catch {
            launchAtLoginEnabled = false
            UserDefaults.standard.set(false, forKey: CameraProcessingConfiguration.launchAtLoginKey)
            loginItemStatus = "macOS could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func startCapture() {
        guard !isCapturing, !isStarting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginCaptureIntent()
        case .notDetermined:
            captureRequestGeneration &+= 1
            let authorizationRequestID = captureRequestGeneration
            isStarting = true
            status = "Requesting camera access…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.captureRequestGeneration == authorizationRequestID, self.isStarting else { return }
                    self.logger.notice("camera access decision granted=\(granted, privacy: .public)")
                    if granted { self.beginCaptureIntent() }
                    else {
                        self.isStarting = false
                        self.status = "Camera access was denied. Aurevix Cam preview was not started."
                    }
                }
            }
        case .denied, .restricted:
            status = "Camera access is denied or restricted. Check System Settings → Privacy & Security → Camera."
        @unknown default:
            status = "Unknown camera authorization state: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)."
        }
    }

    private func beginCaptureIntent() {
        operationalError = nil
        captureRequested = true
        captureRequestGeneration &+= 1
        retryScheduleGeneration &+= 1
        retryAttempts = 0
        isStarting = true
        status = "Starting Aurevix Cam preview on the session queue…"
        persistProcessingConfiguration()
        refreshDevices()
        beginStartAttempt()
    }

    private func beginStartAttempt() {
        guard captureRequested, !isCapturing, !startAttemptInFlight else { return }
        startAttemptInFlight = true
        isStarting = true
        let requestID = captureRequestGeneration
        logger.notice("capture setup queued request_generation=\(requestID, privacy: .public)")
        sessionQueue.async { [weak self] in self?.configureAndStartSession(requestID: requestID) }
    }

    private func configureAndStartSession(requestID: UInt64) {
        if activeSession != nil { cleanupActiveSession(reason: "replace stale session before start") }
        var stage = "discover-device-by-stable-id"
        var candidate: AVCaptureSession?
        var configurationOpen = false
        do {
            guard let device = discoveredDevices().first(where: { $0.uniqueID == targetDeviceID }) else {
                throw NSError(domain: "PrivateCam.DeviceDiscovery", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Aurevix Cam stable camera ID is not present in the fresh discovery result"])
            }
            logger.notice("capture setup stage=device-found unique_id=\(device.uniqueID, privacy: .public)")
            let newSession = AVCaptureSession()
            candidate = newSession
            stage = "begin-session-configuration"
            newSession.beginConfiguration()
            configurationOpen = true

            stage = "create-camera-input"
            let input = try AVCaptureDeviceInput(device: device)
            stage = "add-camera-input"
            guard newSession.canAddInput(input) else {
                throw NSError(domain: "PrivateCam.CaptureSetup", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession rejected the Aurevix Cam input"])
            }
            newSession.addInput(input)

            stage = "select-1280x720-preset"
            guard newSession.canSetSessionPreset(.hd1280x720) else {
                throw NSError(domain: "PrivateCam.CaptureSetup", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Aurevix Cam does not expose a 1280x720 session preset"])
            }
            newSession.sessionPreset = .hd1280x720

            stage = "configure-metadata-output"
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            guard newSession.canAddOutput(videoOutput) else {
                throw NSError(domain: "PrivateCam.CaptureSetup", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession rejected the metadata output"])
            }
            newSession.addOutput(videoOutput)
            stage = "commit-session-configuration"
            newSession.commitConfiguration()
            configurationOpen = false
            captureQueue.sync {
                receiverSessionPreset = newSession.sessionPreset.rawValue
                resetReceiverMetrics()
            }
            installSessionObservers(for: newSession, requestID: requestID)

            stage = "start-running-off-main-thread"
            newSession.startRunning()
            guard newSession.isRunning else {
                throw NSError(domain: "PrivateCam.CaptureSetup", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession did not enter the running state"])
            }
            activeSession = newSession
            activeOutput = videoOutput
            logger.notice("capture setup stage=started device=Aurevix Cam unique_id=\(device.uniqueID, privacy: .public) session_preset=\(newSession.sessionPreset.rawValue, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startAttemptInFlight = false
                guard self.captureRequested, self.captureRequestGeneration == requestID else {
                    self.sessionQueue.async { self.cleanupActiveSession(reason: "start completed after user stop") }
                    return
                }
                self.session = newSession
                self.isStarting = false
                self.isCapturing = true
                self.isDeviceAvailable = true
                self.operationalError = nil
                self.retryAttempts = 0
                self.status = "Aurevix Cam preview is running. Processing status is read from the extension."
                self.refreshEngineStatus()
            }
        } catch {
            if let candidate {
                if configurationOpen { candidate.commitConfiguration() }
                candidate.stopRunning()
                candidate.beginConfiguration()
                for output in candidate.outputs { candidate.removeOutput(output) }
                for input in candidate.inputs { candidate.removeInput(input) }
                candidate.commitConfiguration()
            }
            removeSessionObservers()
            recordCaptureError(error, stage: stage)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startAttemptInFlight = false
                guard self.captureRequested, self.captureRequestGeneration == requestID else { return }
                self.session = nil
                self.isCapturing = false
                self.isDeviceAvailable = self.discoveredDevices().contains(where: { $0.uniqueID == self.targetDeviceID })
                self.scheduleRetry(for: requestID, detail: self.errorSummary(error, stage: stage))
            }
        }
    }

    private func installSessionObservers(for session: AVCaptureSession, requestID: UInt64) {
        removeSessionObservers()
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    ?? NSError(domain: "AVFoundationErrorDomain", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Session runtime error notification had no NSError"])
                self?.handleRuntimeError(error, requestID: requestID)
            })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main) { [weak self] notification in
                self?.isInterrupted = true
                let keys = (notification.userInfo?.keys.map { String(describing: $0) }.sorted() ?? []).joined(separator: ",")
                self?.status = "Preview interrupted; waiting for AVFoundation to resume."
                self?.logger.error("capture interrupted session_running=\(session.isRunning, privacy: .public) user_info_keys=\(keys, privacy: .public)")
            })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main) { [weak self] _ in
                self?.handleInterruptionEnded(session: session, requestID: requestID)
            })
    }

    private func removeSessionObservers() {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
    }

    private func handleRuntimeError(_ error: Error, requestID: UInt64) {
        recordCaptureError(error, stage: "AVCaptureSession.runtimeErrorNotification")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureRequested, self.captureRequestGeneration == requestID else { return }
            self.isCapturing = false
            self.isStarting = true
            self.startAttemptInFlight = false
            self.session = nil
            self.sessionQueue.async {
                self.cleanupActiveSession(reason: "AVFoundation runtime error")
                DispatchQueue.main.async {
                    guard self.captureRequested, self.captureRequestGeneration == requestID else { return }
                    self.scheduleRetry(for: requestID, detail: self.errorSummary(error, stage: "runtime error"))
                }
            }
        }
    }

    private func handleInterruptionEnded(session: AVCaptureSession, requestID: UInt64) {
        guard captureRequested, captureRequestGeneration == requestID else { return }
        isInterrupted = false
        sessionQueue.async { [weak self] in
            guard let self, self.activeSession === session else { return }
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            DispatchQueue.main.async {
                guard self.captureRequested, self.captureRequestGeneration == requestID else { return }
                self.isCapturing = running
                self.status = running ? "Aurevix Cam preview resumed after interruption." : "Preview did not resume after interruption."
                if !running { self.handleRuntimeError(NSError(domain: "AVFoundationErrorDomain", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Session remained stopped after interruption"]), requestID: requestID) }
            }
        }
    }

    private func scheduleRetry(for requestID: UInt64, detail: String) {
        guard captureRequested, captureRequestGeneration == requestID else { return }
        guard retryAttempts < retryDelays.count else {
            isStarting = false
            operationalError = detail
            status = "Preview start stopped after 3 bounded retries: \(detail). Press Start to try again."
            logger.error("capture retry limit reached detail=\(detail, privacy: .public)")
            return
        }
        let delay = retryDelays[retryAttempts]
        retryAttempts += 1
        retryScheduleGeneration &+= 1
        let retryID = retryScheduleGeneration
        isStarting = true
        status = "Preview start retry \(retryAttempts)/\(retryDelays.count) in \(delay)s: \(detail)"
        logger.notice("capture retry scheduled attempt=\(self.retryAttempts, privacy: .public) delay_s=\(delay, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.captureRequested, self.captureRequestGeneration == requestID,
                  self.retryScheduleGeneration == retryID,
                  !self.startAttemptInFlight, !self.isCapturing else { return }
            self.beginStartAttempt()
        }
    }

    private func recordCaptureError(_ error: Error, stage: String) {
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        let failure = value.localizedFailureReason ?? "none"
        let recovery = value.localizedRecoverySuggestion ?? "none"
        logger.error("capture error stage=\(stage, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code, privacy: .public) underlying_domain=\(underlying?.domain ?? "none", privacy: .public) underlying_code=\(underlying?.code ?? 0, privacy: .public) failure_reason=\(failure, privacy: .public) recovery_suggestion=\(recovery, privacy: .public)")
    }

    private func errorSummary(_ error: Error, stage: String) -> String {
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingText = underlying.map { " underlying \($0.domain) / \($0.code)" } ?? ""
        return "\(stage): \(value.domain) / \(value.code)\(underlyingText)"
    }

    func stopCapture() {
        guard captureRequested || isCapturing || isStarting else { return }
        captureRequested = false
        captureRequestGeneration &+= 1
        retryScheduleGeneration &+= 1
        isStarting = false
        startAttemptInFlight = false
        isInterrupted = false
        status = "Stopping preview…"
        processingStatus = "Stopped."
        let requestID = captureRequestGeneration
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.cleanupActiveSession(reason: "user stopped preview")
            DispatchQueue.main.async {
                guard self.captureRequestGeneration == requestID else { return }
                self.session = nil
                self.isCapturing = false
                self.status = "Preview stopped."
                self.statistics = "Delivered output FPS (receiver): unavailable (preview stopped)"
                self.motionStatistics = "Unique processed-video FPS: unavailable (preview stopped)"
            }
        }
    }

    private func cleanupActiveSession(reason: String) {
        guard let oldSession = activeSession else {
            removeSessionObservers()
            activeOutput = nil
            return
        }
        if oldSession.isRunning { oldSession.stopRunning() }
        removeSessionObservers()
        oldSession.beginConfiguration()
        for output in oldSession.outputs { oldSession.removeOutput(output) }
        for input in oldSession.inputs { oldSession.removeInput(input) }
        oldSession.commitConfiguration()
        activeSession = nil
        activeOutput = nil
        captureQueue.sync { logReceiverSummary() }
        logger.notice("capture session cleaned up reason=\(reason, privacy: .public)")
    }

    private func resetReceiverMetrics() {
        startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        sampleCount = 0
        callbackIntervalsMs.removeAll(keepingCapacity: true)
        callbackReceiveUptimes.removeAll(keepingCapacity: true)
        presentationIntervalsMs.removeAll(keepingCapacity: true)
        previousReceiveTime = nil
        previousPresentationTime = nil
        receiverFrameSequence = 0
        droppedFrames = 0
        callbackGapsOver50ms = 0
        presentationGapsOver50ms = 0
        didLogCaptureDimensions = false
        perSecondFrames.removeAll(keepingCapacity: true)
        currentSecond = 0
        currentSecondFrames = 0
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private func appendBoundedMetric(_ value: Double, to values: inout [Double]) {
        if values.count == 18_000 { values.removeFirst() }
        values.append(value)
    }

    private func logReceiverSummary() {
        let endUptime = DispatchTime.now().uptimeNanoseconds
        let elapsed = startUptimeNanoseconds.map { Double(endUptime - $0) / 1_000_000_000 } ?? 0
        let fps = elapsed > 0 ? Double(sampleCount) / elapsed : 0
        let allSecondBuckets = perSecondFrames + [currentSecondFrames]
        logger.notice("capture stopped; received_frames=\(self.sampleCount, privacy: .public) elapsed_s=\(elapsed, privacy: .public) avg_fps=\(fps, privacy: .public) callback_interval_ms_p50=\(self.percentile(self.callbackIntervalsMs, 0.50), privacy: .public) callback_interval_ms_p95=\(self.percentile(self.callbackIntervalsMs, 0.95), privacy: .public) callback_interval_ms_p99=\(self.percentile(self.callbackIntervalsMs, 0.99), privacy: .public) callback_interval_ms_max=\(self.callbackIntervalsMs.max() ?? 0, privacy: .public) pts_interval_ms_p50=\(self.percentile(self.presentationIntervalsMs, 0.50), privacy: .public) pts_interval_ms_p95=\(self.percentile(self.presentationIntervalsMs, 0.95), privacy: .public) pts_interval_ms_p99=\(self.percentile(self.presentationIntervalsMs, 0.99), privacy: .public) pts_interval_ms_max=\(self.presentationIntervalsMs.max() ?? 0, privacy: .public) callback_gaps_over_50ms=\(self.callbackGapsOver50ms, privacy: .public) pts_gaps_over_50ms=\(self.presentationGapsOver50ms, privacy: .public) avfoundation_drops=\(self.droppedFrames, privacy: .public) per_second=\(allSecondBuckets.map(String.init).joined(separator: ","), privacy: .public)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = DispatchTime.now().uptimeNanoseconds
        let callbackIntervalMs = previousReceiveTime.map { Double(now - $0) / 1_000_000 }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var ptsIntervalMs: Double?
        if let previousPresentationTime {
            let value = CMTimeGetSeconds(CMTimeSubtract(presentationTime, previousPresentationTime)) * 1_000
            if value.isFinite && value >= 0 {
                ptsIntervalMs = value
                appendBoundedMetric(value, to: &presentationIntervalsMs)
                if value > 50 {
                    presentationGapsOver50ms += 1
                    logger.error("receiver PTS gap interval_ms=\(value, privacy: .public) frame=\(self.sampleCount, privacy: .public)")
                }
            }
        }
        previousPresentationTime = presentationTime
        previousReceiveTime = now
        callbackReceiveUptimes.append(now)
        if callbackReceiveUptimes.count > 180 { callbackReceiveUptimes.removeFirst(callbackReceiveUptimes.count - 180) }
        if let callbackIntervalMs {
            appendBoundedMetric(callbackIntervalMs, to: &callbackIntervalsMs)
            if callbackIntervalMs > 50 {
                callbackGapsOver50ms += 1
                logger.error("receiver callback gap interval_ms=\(callbackIntervalMs, privacy: .public) corresponding_pts_interval_ms=\(ptsIntervalMs ?? -1, privacy: .public) frame=\(self.sampleCount, privacy: .public)")
            }
        }
        if !didLogCaptureDimensions, let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            didLogCaptureDimensions = true
            logger.notice("receiver pixel buffer width=\(CVPixelBufferGetWidth(image), privacy: .public) height=\(CVPixelBufferGetHeight(image), privacy: .public) format=\(CVPixelBufferGetPixelFormatType(image), privacy: .public) session_preset=\(self.receiverSessionPreset, privacy: .public)")
        }

        sampleCount += 1
        receiverFrameSequence &+= 1
        logger.debug("receiver frame received sequence=\(self.receiverFrameSequence, privacy: .public) pts=\(presentationTime.seconds, privacy: .public) callback_interval_ms=\(callbackIntervalMs ?? 0, privacy: .public)")
        let elapsed = startUptimeNanoseconds.map { Double(now - $0) / 1_000_000_000 } ?? 0
        let second = Int(elapsed)
        if second != currentSecond {
            logger.notice("receiver fps bucket second=\(self.currentSecond, privacy: .public) frames=\(self.currentSecondFrames, privacy: .public)")
            perSecondFrames.append(currentSecondFrames)
            currentSecondFrames = 0
            currentSecond = second
        }
        currentSecondFrames += 1
        let rollingFps: Double
        if callbackReceiveUptimes.count >= 2 {
            let latest = callbackReceiveUptimes[callbackReceiveUptimes.count - 1]
            let windowStart = latest > 2_000_000_000 ? latest - 2_000_000_000 : 0
            let window = callbackReceiveUptimes.filter { $0 >= windowStart }
            let span = window.count >= 2 ? Double(window.last! - window.first!) / 1_000_000_000 : 0
            rollingFps = span > 0 ? Double(window.count - 1) / span : 0
        } else {
            rollingFps = 0
        }
        let isStalled = callbackIntervalsMs.last.map { $0 > 500 } ?? false
        let frameCount = sampleCount
        let drops = droppedFrames
        let display = String(format: "Delivered output FPS (receiver, 2 s): %.2f | frames: %d | elapsed: %.1f s | dropped: %d", rollingFps, frameCount, elapsed, drops)
        let neutralActive = processingStatus.lowercased().contains("neutral fallback")
        let health = isStalled ? "WARNING: receiver delivery stalled" : (neutralActive ? "WARNING: neutral fallback active" : "Stream health: receiver callbacks active")
        DispatchQueue.main.async {
            self.statistics = display
            self.streamHealth = "\(health)"
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedFrames += 1
        logger.error("AVFoundation dropped a receiver frame; count=\(self.droppedFrames, privacy: .public) pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, privacy: .public)")
    }
}
