import Foundation
import CoreMediaIO
import IOKit.audio
import AVFoundation
import CoreImage
import Vision
import os

private let frameRate = 30
private let width = 1280
private let height = 720
private let framePeriodNanoseconds: UInt64 = 1_000_000_000 / UInt64(frameRate)
private let processedFrameFreshnessNanoseconds: UInt64 = 100_000_000
private let deviceIdentifier = UUID(uuidString: "76A10B58-2C45-4B8C-BE2A-0D6F1C286101")!
private let streamIdentifier = UUID(uuidString: "76A10B58-2C45-4B8C-BE2A-0D6F1C286102")!
private let logger = Logger(subsystem: "com.martinaziz.privatecam", category: "CameraExtension")

final class PrivateCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: PrivateCamStreamSource!
    private let queue = DispatchQueue(label: "com.martinaziz.privatecam.frames", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let captureControlQueue = DispatchQueue(label: "com.martinaziz.privatecam.physical-camera-control", qos: .userInitiated)
    private let captureOutputQueue = DispatchQueue(label: "com.martinaziz.privatecam.physical-camera-output", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "com.martinaziz.privatecam.processing", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // CoreMediaIO may call start/stop for more than one client. All ownership state
    // lives on queue, so callbacks and timer events cannot race each other.
    private var streamUsers = 0
    private var timerTickNumber: UInt64 = 0
    private var nextExpectedDeadlineUptime: UInt64?
    private var previousProducerTickUptime: UInt64?
    private var previousSentPresentationTime: CMTime?
    private var producerTickIntervalsMs: [Double] = []
    private var producerLatenessMs: [Double] = []
    private var presentationIntervalsMs: [Double] = []
    private var capturePresentationIntervalsMs: [Double] = []
    private var sendDurationsMs: [Double] = []
    private var missedProducerPeriods = 0
    private var generatedFramesThisRun = 0
    private var deliveredProcessedFramesThisRun = 0
    private var deliveredNeutralFramesThisRun = 0
    private var allocationFailuresThisRun = 0
    private var pixelBufferAllocationFailures = 0
    private var physicalCamera: AVCaptureDevice?
    private var physicalCameraFormat: AVCaptureDevice.Format?
    private var capturePixelFormat: OSType = kCVPixelFormatType_32BGRA
    // Objects below are owned exclusively by captureControlQueue.
    private var physicalCaptureSession: AVCaptureSession?
    private var physicalCaptureOutput: AVCaptureVideoDataOutput?
    private var physicalCaptureDelegate: PhysicalCameraSampleDelegate?
    private var captureSessionObservers: [NSObjectProtocol] = []
    private var didLogPhysicalSampleFormatCount = 0
    // Run generation and all delivery metrics are owned by queue.
    private var captureGeneration: UInt64 = 0
    private var previousReceivedPresentationTime: CMTime?
    private var receiverPTSIntervalsMs: [Double] = []
    private var receiverPTSByOutputSequence: [UInt64: CMTime] = [:]
    private var receiverCaptureAgesByOutputSequence: [UInt64: Double] = [:]
    private var receiverLastLoggedSequence: UInt64 = 0
    private var processedFrameSlot = ProcessedFrameSlot()
    private var nextProcessingFrameID: UInt64 = 0
    private var processedFrameIDs = Set<UInt64>()
    private var presentedProcessingFrameIDs = Set<UInt64>()
    private var repeatedOutputFramesThisRun = 0
    private var currentRepeatedFrameStreak = 0
    private var maximumRepeatedFrameStreak = 0
    private var maximumRepeatedFrameDurationMs = 0.0
    private var previousOutputProcessingFrameID: UInt64?
    private var rejectionCounts: [String: Int] = [:]
    private var outputSequenceNumber: UInt64 = 0
    private var previousReceiveUptime: UInt64?
    private var receiverArrivalIntervalsMs: [Double] = []
    private var callbackToSendLatencyMs: [Double] = []
    private var captureCallbackToRelayMs: [Double] = []
    private var relayWaitMs: [Double] = []
    private var processingQueueWaitMs: [Double] = []
    private var captureTimestampAgeMs: [Double] = []
    private var receiverCaptureFrameAgeMs: [Double] = []
    private var receivedPhysicalFrames = 0
    private var droppedPhysicalFrames = 0
    private var avFoundationDropCount = 0
    private var relayReplacementCount = 0
    private var relayContentionCount = 0
    private var producerTimeDiscontinuityCount = 0
    private var pendingDiscontinuityFlags: CMIOExtensionStream.DiscontinuityFlags = []
    private var captureRunStartUptime: UInt64?
    private var lastLiveMotionMetricsWriteUptime: UInt64 = 0
    private var activeSourceMode = "neutralFallback"
    private var captureInterrupted = false
    // Keep live segmentation inside the stream's 100 ms publication freshness
    // budget on ordinary webcam input; balanced quality regularly exceeded it.
    private let backgroundProcessor = BackgroundReplacementProcessor(quality: .fast, maskFeatherRadius: 1.25)
    private var processingSegmentationMs: [Double] = []
    private var processingCompositeMs: [Double] = []
    private var processingTotalMs: [Double] = []
    private var processingLatencyMs: [Double] = []
    private var captureToPublicationByFrameID: [UInt64: Double] = [:]
    private var frameAgeAtPublicationMs: [Double] = []
    private var processingSendCallMs: [Double] = []
    private var configReadMs: [Double] = []
    private var statusWriteMs: [Double] = []
    private var sampleBufferCreationFailures = 0
    private var sendIntervalsMs: [Double] = []
    private var previousSendUptime: UInt64?
    private var processingFallbacks = 0
    private var processingFrameAgeDrops = 0
    private var lastEngineStatus: String?
    private var engineStatusHeartbeat: DispatchSourceTimer?
    private var physicalFrameRelay: BoundedPhysicalFrameRelay!
    private var formatDescription: CMVideoFormatDescription!
    private var pixelBufferPool: CVPixelBufferPool!
    private var allocationAttributes: NSDictionary!

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
        physicalFrameRelay = BoundedPhysicalFrameRelay(label: "com.martinaziz.privatecam.physical-frame-delivery") { [weak self] frame in
            guard let self else { return }
            self.processingQueue.async {
                self.receivePhysicalFrame(frame.sampleBuffer, generation: frame.generation, captureArrivalUptime: frame.captureArrivalUptime)
            }
        }
        var cameraTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { cameraTypes.append(.external) }
        else { cameraTypes.append(.externalUnknown) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes,
            mediaType: .video,
            position: .unspecified
        )
        let cameraCandidates = discovery.devices
            .filter { $0.uniqueID != deviceIdentifier.uuidString && $0.isConnected }
            .sorted { $0.deviceType == .builtInWideAngleCamera && $1.deviceType != .builtInWideAngleCamera }
        let selectedCameraAndFormat = cameraCandidates.lazy.compactMap { camera in
            camera.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let supports720p30 = dimensions.width == Int32(width) && dimensions.height == Int32(height)
                    && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                return supports720p30 && (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            }).map { (camera, $0) }
        }.first
        if let (camera, format) = selectedCameraAndFormat {
            physicalCamera = camera
            physicalCameraFormat = format
            capturePixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            logger.notice("physical camera candidate name=\(camera.localizedName, privacy: .public) unique_id=\(camera.uniqueID, privacy: .public) format=1280x720 pixel_format=\(self.fourCC(self.capturePixelFormat), privacy: .public) fps=30")
        } else {
            logger.error("no physical camera format supports 1280x720 30fps native bi-planar 4:2:0; retaining v3 neutral fallback format")
        }
        device = CMIOExtensionDevice(
            localizedName: "Aurevix Cam",
            deviceID: deviceIdentifier,
            legacyDeviceID: nil,
            source: self
        )
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: capturePixelFormat,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: capturePixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pixelBufferPool)
        allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 16]
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(frameRate)),
            validFrameDurations: nil
        )
        streamSource = PrivateCamStreamSource(format: streamFormat, device: device)
        do { try device.addStream(streamSource.stream) }
        catch { logger.error("addStream failed: \(error.localizedDescription, privacy: .public)") }
        let cmioDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        logger.notice("CMIO advertised format count=1 active_index=0 width=\(cmioDimensions.width, privacy: .public) height=\(cmioDimensions.height, privacy: .public) pixel_format=\(self.fourCC(self.capturePixelFormat), privacy: .public) frame_duration=1/30")
        logger.notice("device initialized device_id=\(deviceIdentifier.uuidString, privacy: .public) stream_id=\(streamIdentifier.uuidString, privacy: .public) output_pixel_format=\(self.fourCC(self.capturePixelFormat), privacy: .public) physical_camera_available=\(self.physicalCamera != nil, privacy: .public)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Aurevix Cam 720p Virtual Camera" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        onStateQueue {
            let alreadyStreaming = streamUsers > 0
            streamUsers += 1
            logger.notice("stream start callback consumers=\(self.streamUsers, privacy: .public) timer_active=\(self.timer != nil, privacy: .public)")
            guard !alreadyStreaming else { return }
            resetRunMetrics()
            activeSourceMode = "processing"
            processedFrameSlot.invalidate()
            outputSequenceNumber = 0
            captureInterrupted = false
            updateEngineStatus("Starting: neutral output active; waiting for the first processed frame.")
            startEngineStatusHeartbeat()
            logger.notice("safe processing stream started; neutral output remains active until a validated composite arrives")
            startNeutralFallbackProducer()
            if physicalCamera != nil, physicalCameraFormat != nil { beginPhysicalCapture() }
            else {
                updateEngineStatus("Neutral fallback active (physical camera unavailable).")
                logger.error("processing unavailable; safe neutral output remains active")
            }
        }
    }

    func stopStreaming() {
        onStateQueue {
            guard streamUsers > 0 else {
                logger.error("unmatched stream stop callback ignored")
                return
            }
            streamUsers -= 1
            logger.notice("stream stop callback consumers=\(self.streamUsers, privacy: .public) timer_active=\(self.timer != nil, privacy: .public)")
            guard streamUsers == 0 else { return }

            engineStatusHeartbeat?.cancel()
            engineStatusHeartbeat = nil

            let endedGeneration = captureGeneration
            captureGeneration &+= 1
            stopProducerTimers()
            logRunSummary()
            // Always enqueue an idempotent stop on the capture-control queue.
            // This also cleans up a capture session after a fail-closed transition
            // changed activeSourceMode to neutral output. Never read the session
            // reference here: it is exclusively owned by captureControlQueue.
            schedulePhysicalCaptureStop(generation: endedGeneration, reason: "last stream user stopped")
            activeSourceMode = "neutralFallback"
            processedFrameSlot.invalidate()
            captureInterrupted = false
        }
    }

    func authorizeStreamClient(_ client: CMIOExtensionClient) -> Bool {
        onStateQueue {
            _ = client
            return true
        }
    }

    private func startNeutralFallbackProducer() {
        guard streamUsers > 0 else { return }
        if timer != nil { return }
        nextExpectedDeadlineUptime = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: nextExpectedDeadlineUptime!),
            repeating: .nanoseconds(Int(framePeriodNanoseconds)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.produceFrame() }
        self.timer = timer
        logger.notice("neutral fallback producer started format=1280x720 pixel_format=\(self.fourCC(self.capturePixelFormat), privacy: .public) nominal_fps=30")
        timer.resume()
    }

    private func stopProducerTimers() {
        if let timer {
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
        }
        nextExpectedDeadlineUptime = nil
    }

    private func failClosedToTestPattern(reason: ProcessingFailureReason, trigger: String) {
        let endedGeneration = captureGeneration
        captureGeneration &+= 1
        activeSourceMode = "neutral-fallback"
        processedFrameSlot.invalidate()
        updateEngineStatus("Neutral fallback active (\(reason.rawValue)).")
        logger.error("processing fail-closed transition=processed_to_neutral reason=\(reason.rawValue, privacy: .public) trigger=\(trigger, privacy: .public)")
        schedulePhysicalCaptureStop(generation: endedGeneration, reason: "privacy fail-closed: \(reason.rawValue)")
    }

    private func updateEngineStatus(_ status: String) {
        guard lastEngineStatus != status else { return }
        lastEngineStatus = status
        let start = DispatchTime.now().uptimeNanoseconds
        CameraProcessingConfiguration.writeEngineStatus(status)
        appendBounded(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, to: &statusWriteMs)
    }

    private func startEngineStatusHeartbeat() {
        guard engineStatusHeartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.streamUsers > 0, let status = self.lastEngineStatus else { return }
            CameraProcessingConfiguration.writeEngineStatus(status)
        }
        engineStatusHeartbeat = timer
        timer.resume()
    }

    private func schedulePhysicalCaptureStop(generation: UInt64, reason: String) {
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            for observer in self.captureSessionObservers { NotificationCenter.default.removeObserver(observer) }
            self.captureSessionObservers.removeAll()
            if let output = self.physicalCaptureOutput { output.setSampleBufferDelegate(nil, queue: nil) }
            self.physicalCaptureSession?.stopRunning()
            self.physicalCaptureSession = nil
            self.physicalCaptureOutput = nil
            self.physicalCaptureDelegate = nil
            logger.notice("physical capture stopped generation=\(generation, privacy: .public) reason=\(reason, privacy: .public)")
        }
    }

    private func beginPhysicalCapture() {
        captureGeneration &+= 1
        let generation = captureGeneration
        logger.notice("physical capture requested generation=\(generation, privacy: .public) device=\(self.physicalCamera?.localizedName ?? "unknown", privacy: .public)")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartPhysicalCapture(generation: generation)
        case .notDetermined:
            logger.notice("physical camera permission not determined; requesting access from extension process")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.onStateQueue {
                    guard self.streamUsers > 0, self.captureGeneration == generation else {
                        logger.notice("physical camera authorization result ignored for stopped generation=\(generation, privacy: .public)")
                        return
                    }
                    logger.notice("physical camera permission result granted=\(granted, privacy: .public)")
                    if granted { self.configureAndStartPhysicalCapture(generation: generation) }
                    else {
                        logger.error("physical capture blocked: TCC camera authorization denied for Camera Extension")
                        self.failClosedToTestPattern(reason: .physicalCameraUnavailable, trigger: "TCC request denied")
                    }
                }
            }
        case .denied:
            logger.error("physical capture blocked: AVCaptureDevice authorizationStatus=denied for Camera Extension")
            failClosedToTestPattern(reason: .physicalCameraUnavailable, trigger: "TCC denied")
        case .restricted:
            logger.error("physical capture blocked: AVCaptureDevice authorizationStatus=restricted for Camera Extension")
            failClosedToTestPattern(reason: .physicalCameraUnavailable, trigger: "TCC restricted")
        @unknown default:
            logger.error("physical capture blocked: unknown AVCaptureDevice authorization status raw=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue, privacy: .public)")
            failClosedToTestPattern(reason: .physicalCameraUnavailable, trigger: "unknown TCC authorization")
        }
    }

    private func configureAndStartPhysicalCapture(generation: UInt64) {
        guard let camera = physicalCamera, let format = physicalCameraFormat else { return }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                try camera.lockForConfiguration()
                camera.activeFormat = format
                let frameDuration = CMTime(value: 1, timescale: Int32(frameRate))
                camera.activeVideoMinFrameDuration = frameDuration
                camera.activeVideoMaxFrameDuration = frameDuration
                camera.unlockForConfiguration()
                let physicalDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                logger.notice("AVFoundation physical activeFormat width=\(physicalDimensions.width, privacy: .public) height=\(physicalDimensions.height, privacy: .public) pixel_format=\(self.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription)), privacy: .public) requested_frame_duration=1/30")

                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else {
                    throw NSError(domain: "PrivateCam.PhysicalCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession rejected the selected built-in camera input"])
                }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: self.capturePixelFormat,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else {
                    throw NSError(domain: "PrivateCam.PhysicalCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession rejected native 420v/420f video output"])
                }
                let delegate = PhysicalCameraSampleDelegate(owner: self, generation: generation, relay: self.physicalFrameRelay)
                output.setSampleBufferDelegate(delegate, queue: self.captureOutputQueue)
                session.addOutput(output)
                let configuredWidth = (output.videoSettings[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? 0
                let configuredHeight = (output.videoSettings[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? 0
                let configuredPixelFormat = (output.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? 0
                logger.notice("physical capture output settings width=\(configuredWidth, privacy: .public) height=\(configuredHeight, privacy: .public) pixel_format=\(self.fourCC(configuredPixelFormat), privacy: .public) auto_dimensions_api=unavailable_on_macos")
                session.commitConfiguration()
                self.captureSessionObservers = [
                    NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                        object: session, queue: nil) { [weak self] _ in
                            guard let self else { return }
                            self.onStateQueue {
                                guard self.captureGeneration == generation else { return }
                                self.captureInterrupted = true
                                self.processedFrameSlot.invalidate()
                                self.activeSourceMode = "neutral-fallback"
                                self.updateEngineStatus("Neutral fallback active (camera interrupted).")
                                logger.error("capture interrupted; output boundary now rejects pending frames and neutral output remains active")
                            }
                        },
                    NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                        object: session, queue: nil) { [weak self] _ in
                            guard let self else { return }
                            self.onStateQueue {
                                guard self.streamUsers > 0, self.captureInterrupted else { return }
                                self.captureInterrupted = false
                                logger.notice("capture interruption ended; processing resumed with neutral output held until next composite")
                                self.activeSourceMode = "processing"
                            }
                        },
                    NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                        object: session, queue: nil) { [weak self] notification in
                            guard let self else { return }
                            let description = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "unknown runtime error"
                            self.onStateQueue {
                                guard self.captureGeneration == generation else { return }
                                logger.error("capture runtime error: \(description, privacy: .public)")
                                self.failClosedToTestPattern(reason: .captureFailed, trigger: "AVCaptureSession runtime error")
                            }
                        }
                ]

                let current = self.onStateQueue { self.streamUsers > 0 && self.captureGeneration == generation }
                guard current else {
                    output.setSampleBufferDelegate(nil, queue: nil)
                    logger.notice("physical capture setup cancelled before start generation=\(generation, privacy: .public)")
                    return
                }
                session.startRunning()
                guard session.isRunning else {
                    throw NSError(domain: "PrivateCam.PhysicalCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession.startRunning returned but session is not running"])
                }
                self.physicalCaptureSession = session
                self.physicalCaptureOutput = output
                self.physicalCaptureDelegate = delegate
                logger.notice("physical capture running generation=\(generation, privacy: .public) device=\(camera.localizedName, privacy: .public) device_id=\(camera.uniqueID, privacy: .public) dimensions=1280x720 pixel_format=\(self.fourCC(self.capturePixelFormat), privacy: .public) requested_fps=30 late_frame_policy=discard")
                let stillCurrent = self.onStateQueue { self.streamUsers > 0 && self.captureGeneration == generation }
                if !stillCurrent {
                    output.setSampleBufferDelegate(nil, queue: nil)
                    session.stopRunning()
                    self.physicalCaptureSession = nil
                    self.physicalCaptureOutput = nil
                    self.physicalCaptureDelegate = nil
                }
            } catch {
                let nsError = error as NSError
                logger.error("physical capture setup/start failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) description=\(nsError.localizedDescription, privacy: .public) generation=\(generation, privacy: .public)")
                self.onStateQueue {
                    guard self.captureGeneration == generation, self.streamUsers > 0 else { return }
                    self.failClosedToTestPattern(reason: .captureFailed, trigger: "AVCaptureSession setup/start error")
                }
            }
        }
    }

    fileprivate func receivePhysicalFrame(_ sampleBuffer: CMSampleBuffer, generation: UInt64, captureArrivalUptime: UInt64) {
        let relayWait = Double(DispatchTime.now().uptimeNanoseconds - captureArrivalUptime) / 1_000_000
        onStateQueue { appendBounded(relayWait, to: &relayWaitMs) }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric, let pool = pixelBufferPool else {
            logger.error("processing input missing image buffer, valid PTS, or output pool; neutral stream remains active")
            return
        }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        let generationIsCurrent = onStateQueue { () -> Bool in
            guard streamUsers > 0, captureGeneration == generation, !captureInterrupted else { return false }
            if didLogPhysicalSampleFormatCount < 5 {
                didLogPhysicalSampleFormatCount += 1
                let physicalDimensions = physicalCameraFormat.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
                    ?? CMVideoDimensions(width: 0, height: 0)
                let advertisedDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                let poolAttributes = CVPixelBufferPoolGetPixelBufferAttributes(pool) as NSDictionary? ?? NSDictionary()
                let poolWidth = (poolAttributes[kCVPixelBufferWidthKey] as? NSNumber)?.intValue ?? 0
                let poolHeight = (poolAttributes[kCVPixelBufferHeightKey] as? NSNumber)?.intValue ?? 0
                let poolFormat = (poolAttributes[kCVPixelBufferPixelFormatTypeKey] as? NSNumber)?.uint32Value ?? 0
                let mismatch = sourceWidth != poolWidth ? "width" : sourceHeight != poolHeight ? "height" : sourceFormat != poolFormat ? "pixel_format" : "none"
                let line = "physical callback sample=\(didLogPhysicalSampleFormatCount) source_width=\(sourceWidth) source_height=\(sourceHeight) source_fourcc=\(fourCC(sourceFormat)) active_format_width=\(physicalDimensions.width) active_format_height=\(physicalDimensions.height) active_format_fourcc=\(fourCC(capturePixelFormat)) output_settings_width=1280 output_settings_height=720 output_settings_fourcc=\(fourCC(capturePixelFormat)) auto_dimensions_api=unavailable_on_macos advertised_width=\(advertisedDimensions.width) advertised_height=\(advertisedDimensions.height) advertised_fourcc=\(fourCC(CMFormatDescriptionGetMediaSubType(formatDescription))) pool_width=\(poolWidth) pool_height=\(poolHeight) pool_fourcc=\(fourCC(poolFormat)) mismatch=\(mismatch)"
                logger.notice("\(line, privacy: .public)")
            }
            return true
        }
        guard generationIsCurrent else { return }
        let captureAccepted = onStateQueue {
            guard streamUsers > 0, captureGeneration == generation, !captureInterrupted else { return false }
            if let previousReceiveUptime {
                appendBounded(Double(captureArrivalUptime - previousReceiveUptime) / 1_000_000,
                              to: &receiverArrivalIntervalsMs)
            }
            previousReceiveUptime = captureArrivalUptime
            if let previousReceivedPresentationTime {
                let interval = CMTimeGetSeconds(CMTimeSubtract(pts, previousReceivedPresentationTime)) * 1_000
                if interval.isFinite, interval >= 0 {
                    appendBounded(interval, to: &receiverPTSIntervalsMs)
                    appendBounded(interval, to: &capturePresentationIntervalsMs)
                    if interval > 50 { pendingDiscontinuityFlags.insert(.time) }
                }
            }
            previousReceivedPresentationTime = pts
            let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pts)) * 1_000
            if age.isFinite, age >= 0 { appendBounded(age, to: &captureTimestampAgeMs) }
            guard age.isFinite, age >= 0, age <= 100 else {
                processingFrameAgeDrops += 1
                rejectionCounts["capture_age"] = (rejectionCounts["capture_age"] ?? 0) + 1
                logger.error("capture frame rejected before processing cause_observation=unknown age_ms=\(age, privacy: .public) relay_wait_ms=\(relayWait, privacy: .public) processing_queue_wait_ms=\(self.processingQueueWaitMs.last ?? 0, privacy: .public)")
                return false
            }
            receivedPhysicalFrames += 1
            return true
        }
        guard captureAccepted else { return }
        let configReadStart = DispatchTime.now().uptimeNanoseconds
        let configuration = CameraProcessingConfiguration.read()
        onStateQueue { appendBounded(Double(DispatchTime.now().uptimeNanoseconds - configReadStart) / 1_000_000, to: &configReadMs) }
        let generationAtStart = onStateQueue { captureGeneration }
        guard generationAtStart == generation else { return }
        let treatment: BackgroundTreatment
        if configuration.mode == .solid {
            treatment = .solid(CIColor(red: configuration.red, green: configuration.green, blue: configuration.blue))
        } else if configuration.mode == .image {
            let imageURL: URL?
            let id = configuration.backgroundPresetID
            if id == "imported" {
                let candidate = URL(fileURLWithPath: configuration.backgroundFilePath)
                let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CameraProcessingConfiguration.suiteName)
                if let sharedRoot, candidate.standardizedFileURL.path.hasPrefix(sharedRoot.appendingPathComponent("Backgrounds/Imported").standardizedFileURL.path + "/") {
                    imageURL = candidate
                } else { imageURL = nil }
            } else { imageURL = nil }
            if let imageURL { treatment = .photo(id: id, url: imageURL) }
            else { treatment = .solid(BackgroundReplacementProcessor.neutralColor) }
        } else if configuration.blurPreset == .softBlue {
            treatment = .softBlue
        } else {
            treatment = .blur(radius: CGFloat(configuration.blurPreset.radius(intensity: configuration.blurRadius)))
        }
        let processStart = DispatchTime.now().uptimeNanoseconds
        onStateQueue { appendBounded(Double(processStart - captureArrivalUptime) / 1_000_000, to: &processingQueueWaitMs) }
        let beauty = SkinRefinementConfiguration.read()
        let result = backgroundProcessor.process(pixelBuffer: source, outputPool: pool, treatment: treatment,
                                                  skinRefinementIntensity: beauty.effectiveIntensity)

        // All checks that authorize publication and the send itself run on the
        // stream state queue. The raw capture buffer is never sent.
        onStateQueue {
            guard streamUsers > 0, captureGeneration == generation else { return }
            let currentConfiguration = CameraProcessingConfiguration.read()
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let frameAgeMs = CMTimeGetSeconds(CMTimeSubtract(hostNow, pts)) * 1_000
            let output = result.pixelBuffer
            let outputValid = !result.usedNeutralFallback && output !== source
                && CVPixelBufferGetWidth(output) == width
                && CVPixelBufferGetHeight(output) == height
                && CVPixelBufferGetPixelFormatType(output) == capturePixelFormat
            let preliminaryPublication = ProcessedFramePublicationConditions(
                generationIsCurrent: streamUsers > 0 && captureGeneration == generation && !captureInterrupted,
                effectConfigurationIsCurrent: configuration == currentConfiguration,
                outputIsDistinctFromCapture: output !== source,
                dimensionsMatch: CVPixelBufferGetWidth(output) == width && CVPixelBufferGetHeight(output) == height,
                pixelFormatMatches: CVPixelBufferGetPixelFormatType(output) == capturePixelFormat,
                frameAgeMilliseconds: frameAgeMs)
            guard outputValid, preliminaryPublication.mayPublish else {
                processingFrameAgeDrops += frameAgeMs > 100 ? 1 : 0
                let reason = result.usedNeutralFallback ? "processor_fallback" :
                    (configuration != currentConfiguration ? "effect_changed" :
                     (frameAgeMs > 100 ? "publication_age" : "publication_validation"))
                rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1
                if result.usedNeutralFallback {
                    processingFallbacks += 1
                    logger.error("processor neutral fallback selected reason=\(result.failureReason ?? "unspecified", privacy: .public)")
                } else {
                    logger.error("processed frame rejected before publisher slot output_valid=\(outputValid, privacy: .public) configuration_current=\(configuration == currentConfiguration, privacy: .public) age_ms=\(frameAgeMs, privacy: .public)")
                }
                processedFrameSlot.invalidate()
                pendingDiscontinuityFlags.insert(.sampleDropped)
                return
            }
            appendBounded(result.segmentationMilliseconds, to: &processingSegmentationMs)
            appendBounded(result.compositingMilliseconds, to: &processingCompositeMs)
            let processingLatency = Double(DispatchTime.now().uptimeNanoseconds - processStart) / 1_000_000
            appendBounded(processingLatency, to: &processingLatencyMs)
            let outputFormat = CMFormatDescriptionGetMediaSubType(formatDescription)
            guard CVPixelBufferGetPixelFormatType(output) == outputFormat else {
                logger.error("privacy boundary rejected pixel format mismatch output=\(self.fourCC(CVPixelBufferGetPixelFormatType(output)), privacy: .public) advertised=\(self.fourCC(outputFormat), privacy: .public)")
                return
            }
            appendBounded(processingLatency, to: &processingTotalMs)
            let finalAgeMs = CMTimeGetSeconds(CMTimeSubtract(
                CMClockGetTime(CMClockGetHostTimeClock()), pts)) * 1_000
            let finalPublication = ProcessedFramePublicationConditions(
                generationIsCurrent: streamUsers > 0 && captureGeneration == generation && !captureInterrupted,
                effectConfigurationIsCurrent: configuration == CameraProcessingConfiguration.read(),
                outputIsDistinctFromCapture: output !== source,
                dimensionsMatch: CVPixelBufferGetWidth(output) == width && CVPixelBufferGetHeight(output) == height,
                pixelFormatMatches: CVPixelBufferGetPixelFormatType(output) == outputFormat,
                frameAgeMilliseconds: finalAgeMs)
            guard finalPublication.mayPublish else {
                processingFrameAgeDrops += finalAgeMs > 100 ? 1 : 0
                let reason = finalAgeMs > 100 ? "publication_age" :
                    (configuration != CameraProcessingConfiguration.read() ? "effect_changed" : "publication_validation")
                rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1
                pendingDiscontinuityFlags.insert(.sampleDropped)
                logger.error("final output boundary rejected stale, cancelled, or mismatched frame age_ms=\(finalAgeMs, privacy: .public)")
                return
            }
            let processingFrameID = nextProcessingFrameID
            let (nextID, didOverflow) = nextProcessingFrameID.addingReportingOverflow(1)
            guard !didOverflow else {
                rejectionCounts["processing_id_exhausted"] = (rejectionCounts["processing_id_exhausted"] ?? 0) + 1
                processedFrameSlot.invalidate()
                return
            }
            nextProcessingFrameID = nextID
            processedFrameIDs.insert(processingFrameID)
            let ageAtPublicationMs = finalAgeMs + processingLatency
            captureToPublicationByFrameID[processingFrameID] = ageAtPublicationMs
            appendBounded(ageAtPublicationMs, to: &frameAgeAtPublicationMs)
            logger.debug("processed frame id=\(processingFrameID, privacy: .public) capture_age_ms=\(ageAtPublicationMs, privacy: .public) processing_latency_ms=\(processingLatency, privacy: .public)")
            let frame = ApprovedProcessedFrame(processingFrameID: processingFrameID,
                frameIdentity: ObjectIdentifier(output), generation: generation,
                configuration: configuration, captureArrivalUptime: captureArrivalUptime,
                sourcePresentationTime: pts, pixelBuffer: output)
            processedFrameSlot.offer(frame)
        }
    }

    fileprivate func notePhysicalFrameDrop(generation: UInt64) {
        queue.async {
            guard self.streamUsers > 0, self.captureGeneration == generation else { return }
            self.droppedPhysicalFrames += 1
            self.avFoundationDropCount += 1
            self.pendingDiscontinuityFlags.insert(.sampleDropped)
            logger.error("frame drop source=AVFoundation.didDrop generation=\(generation, privacy: .public) avfoundation_count=\(self.avFoundationDropCount, privacy: .public) total_physical_drops=\(self.droppedPhysicalFrames, privacy: .public)")
        }
    }

    fileprivate func noteRelayDrop(generation: UInt64, reason: String) {
        queue.async {
            guard self.streamUsers > 0, self.captureGeneration == generation else { return }
            self.droppedPhysicalFrames += 1
            if reason == "oldest_pending_frame_replaced" {
                self.relayReplacementCount += 1
                logger.error("frame drop source=bounded_relay reason=pending_replaced generation=\(generation, privacy: .public) relay_replacements=\(self.relayReplacementCount, privacy: .public) total_physical_drops=\(self.droppedPhysicalFrames, privacy: .public)")
            } else if reason == "relay_lock_busy" {
                self.relayContentionCount += 1
                logger.error("frame drop source=bounded_relay reason=lock_contention generation=\(generation, privacy: .public) relay_contentions=\(self.relayContentionCount, privacy: .public) total_physical_drops=\(self.droppedPhysicalFrames, privacy: .public)")
            }
            self.pendingDiscontinuityFlags.insert(.sampleDropped)
        }
    }

    private func appendBounded(_ value: Double, to values: inout [Double]) {
        // Retain at most ten minutes of 30 FPS samples per metric.
        if values.count == frameRate * 60 * 10 { values.removeFirst() }
        values.append(value)
    }

    private func fourCC(_ value: OSType) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    private func onStateQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    private func resetRunMetrics() {
        timerTickNumber = 0
        previousProducerTickUptime = nil
        previousSentPresentationTime = nil
        outputSequenceNumber = 0
        producerTickIntervalsMs.removeAll(keepingCapacity: true)
        producerLatenessMs.removeAll(keepingCapacity: true)
        presentationIntervalsMs.removeAll(keepingCapacity: true)
        capturePresentationIntervalsMs.removeAll(keepingCapacity: true)
        sendDurationsMs.removeAll(keepingCapacity: true)
        missedProducerPeriods = 0
        generatedFramesThisRun = 0
        allocationFailuresThisRun = 0
        previousReceivedPresentationTime = nil
        receiverPTSIntervalsMs.removeAll(keepingCapacity: true)
        previousReceiveUptime = nil
        receiverArrivalIntervalsMs.removeAll(keepingCapacity: true)
        callbackToSendLatencyMs.removeAll(keepingCapacity: true)
        captureTimestampAgeMs.removeAll(keepingCapacity: true)
        receiverCaptureFrameAgeMs.removeAll(keepingCapacity: true)
        captureCallbackToRelayMs.removeAll(keepingCapacity: true)
        relayWaitMs.removeAll(keepingCapacity: true)
        processingQueueWaitMs.removeAll(keepingCapacity: true)
        receivedPhysicalFrames = 0
        droppedPhysicalFrames = 0
        avFoundationDropCount = 0
        relayReplacementCount = 0
        relayContentionCount = 0
        producerTimeDiscontinuityCount = 0
        processingSegmentationMs.removeAll(keepingCapacity: true)
        processingCompositeMs.removeAll(keepingCapacity: true)
        processingTotalMs.removeAll(keepingCapacity: true)
        processingLatencyMs.removeAll(keepingCapacity: true)
        captureToPublicationByFrameID.removeAll(keepingCapacity: true)
        frameAgeAtPublicationMs.removeAll(keepingCapacity: true)
        processingSendCallMs.removeAll(keepingCapacity: true)
        configReadMs.removeAll(keepingCapacity: true)
        statusWriteMs.removeAll(keepingCapacity: true)
        sendIntervalsMs.removeAll(keepingCapacity: true)
        previousSendUptime = nil
        sampleBufferCreationFailures = 0
        processingFallbacks = 0
        processingFrameAgeDrops = 0
        pendingDiscontinuityFlags = []
        didLogPhysicalSampleFormatCount = 0
        deliveredProcessedFramesThisRun = 0
        deliveredNeutralFramesThisRun = 0
        nextProcessingFrameID = 0
        processedFrameIDs.removeAll(keepingCapacity: true)
        presentedProcessingFrameIDs.removeAll(keepingCapacity: true)
        repeatedOutputFramesThisRun = 0
        currentRepeatedFrameStreak = 0
        maximumRepeatedFrameStreak = 0
        maximumRepeatedFrameDurationMs = 0
        previousOutputProcessingFrameID = nil
        rejectionCounts.removeAll(keepingCapacity: true)
        processedFrameSlot.invalidate()
        captureRunStartUptime = DispatchTime.now().uptimeNanoseconds
        lastLiveMotionMetricsWriteUptime = 0
    }

    private func logRunSummary() {
        let tickP50 = percentile(producerTickIntervalsMs, 0.50)
        let tickP95 = percentile(producerTickIntervalsMs, 0.95)
        let tickP99 = percentile(producerTickIntervalsMs, 0.99)
        let segmentP50 = percentile(processingSegmentationMs, 0.50)
        let segmentP95 = percentile(processingSegmentationMs, 0.95)
        let totalP50 = percentile(processingTotalMs, 0.50)
        let totalP95 = percentile(processingTotalMs, 0.95)
        let totalP99 = percentile(processingTotalMs, 0.99)
        let processingP50 = percentile(processingLatencyMs, 0.50)
        let processingP95 = percentile(processingLatencyMs, 0.95)
        let processingP99 = percentile(processingLatencyMs, 0.99)
        let callbackSendP50 = percentile(callbackToSendLatencyMs, 0.50)
        let callbackSendP95 = percentile(callbackToSendLatencyMs, 0.95)
        let callbackSendP99 = percentile(callbackToSendLatencyMs, 0.99)
        let publisherSendP50 = percentile(sendIntervalsMs, 0.50)
        let publisherSendP95 = percentile(sendIntervalsMs, 0.95)
        let publisherSendP99 = percentile(sendIntervalsMs, 0.99)
        let relayWaitP95 = percentile(relayWaitMs, 0.95)
        let processingQueueWaitP95 = percentile(processingQueueWaitMs, 0.95)
        let runElapsed = captureRunStartUptime.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000_000 } ?? 0
        let avgFps = runElapsed > 0 ? Double(receivedPhysicalFrames) / runElapsed : 0
        let receiverCallbackGapMax = receiverArrivalIntervalsMs.max() ?? 0
        let receiverPTSGapMax = receiverPTSIntervalsMs.max() ?? 0
        let rejectionSummary = rejectionCounts.keys.sorted().map { "\($0):\(rejectionCounts[$0] ?? 0)" }.joined(separator: ",")
        logger.notice("stream stopped; source=\(self.activeSourceMode, privacy: .public) output_frames=\(self.generatedFramesThisRun, privacy: .public) processed_output_frames=\(self.deliveredProcessedFramesThisRun, privacy: .public) unique_processed_frames=\(self.processedFrameIDs.count, privacy: .public) unique_presented_processed_frames=\(self.presentedProcessingFrameIDs.count, privacy: .public) reused_output_frames=\(self.repeatedOutputFramesThisRun, privacy: .public) repeated_frame_streak_max=\(self.maximumRepeatedFrameStreak, privacy: .public) repeated_frame_duration_max_ms=\(self.maximumRepeatedFrameDurationMs, privacy: .public) neutral_output_frames=\(self.deliveredNeutralFramesThisRun, privacy: .public) processed_share_pct=\(self.generatedFramesThisRun > 0 ? Double(self.deliveredProcessedFramesThisRun) * 100 / Double(self.generatedFramesThisRun) : 0, privacy: .public) neutral_share_pct=\(self.generatedFramesThisRun > 0 ? Double(self.deliveredNeutralFramesThisRun) * 100 / Double(self.generatedFramesThisRun) : 0, privacy: .public) physical_frames_accepted=\(self.receivedPhysicalFrames, privacy: .public) physical_frame_fps=\(avgFps, privacy: .public) relay_wait_p95_ms=\(relayWaitP95, privacy: .public) processing_queue_wait_p95_ms=\(processingQueueWaitP95, privacy: .public) neutral_fallbacks=\(self.processingFallbacks, privacy: .public) rejection_counts=\(rejectionSummary, privacy: .public) capture_age_p50_ms=\(self.percentile(self.captureTimestampAgeMs, 0.50), privacy: .public) capture_age_p95_ms=\(self.percentile(self.captureTimestampAgeMs, 0.95), privacy: .public) capture_age_p99_ms=\(self.percentile(self.captureTimestampAgeMs, 0.99), privacy: .public) capture_age_max_ms=\(self.captureTimestampAgeMs.max() ?? 0, privacy: .public) capture_to_publication_age_p50_ms=\(self.percentile(self.frameAgeAtPublicationMs, 0.50), privacy: .public) capture_to_publication_age_p95_ms=\(self.percentile(self.frameAgeAtPublicationMs, 0.95), privacy: .public) capture_to_publication_age_p99_ms=\(self.percentile(self.frameAgeAtPublicationMs, 0.99), privacy: .public) stale_rejections=\(self.processingFrameAgeDrops, privacy: .public) capture_drops=\(self.droppedPhysicalFrames, privacy: .public) avfoundation_drops=\(self.avFoundationDropCount, privacy: .public) relay_replacements=\(self.relayReplacementCount, privacy: .public) relay_lock_contentions=\(self.relayContentionCount, privacy: .public) producer_missed_periods=\(self.missedProducerPeriods, privacy: .public) elapsed_s=\(runElapsed, privacy: .public) producer_tick_p50_ms=\(tickP50, privacy: .public) producer_tick_p95_ms=\(tickP95, privacy: .public) producer_tick_p99_ms=\(tickP99, privacy: .public) producer_send_interval_p50_ms=\(publisherSendP50, privacy: .public) producer_send_interval_p95_ms=\(publisherSendP95, privacy: .public) producer_send_interval_p99_ms=\(publisherSendP99, privacy: .public) producer_send_pts_gap_max_ms=\(self.presentationIntervalsMs.max() ?? 0, privacy: .public) capture_pts_gap_max_ms=\(self.capturePresentationIntervalsMs.max() ?? 0, privacy: .public) receiver_callback_gap_p50_ms=\(self.percentile(self.receiverArrivalIntervalsMs, 0.50), privacy: .public) receiver_callback_gap_p95_ms=\(self.percentile(self.receiverArrivalIntervalsMs, 0.95), privacy: .public) receiver_callback_gap_p99_ms=\(self.percentile(self.receiverArrivalIntervalsMs, 0.99), privacy: .public) receiver_callback_gap_max_ms=\(receiverCallbackGapMax, privacy: .public) receiver_pts_gap_p50_ms=\(self.percentile(self.receiverPTSIntervalsMs, 0.50), privacy: .public) receiver_pts_gap_p95_ms=\(self.percentile(self.receiverPTSIntervalsMs, 0.95), privacy: .public) receiver_pts_gap_p99_ms=\(self.percentile(self.receiverPTSIntervalsMs, 0.99), privacy: .public) receiver_pts_gap_max_ms=\(receiverPTSGapMax, privacy: .public) capture_to_publication_p50_ms=\(callbackSendP50, privacy: .public) capture_to_publication_p95_ms=\(callbackSendP95, privacy: .public) capture_to_publication_p99_ms=\(callbackSendP99, privacy: .public) processing_latency_p50_ms=\(processingP50, privacy: .public) processing_latency_p95_ms=\(processingP95, privacy: .public) processing_latency_p99_ms=\(processingP99, privacy: .public) segmentation_p50_ms=\(segmentP50, privacy: .public) segmentation_p95_ms=\(segmentP95, privacy: .public) processing_p50_ms=\(totalP50, privacy: .public) processing_p95_ms=\(totalP95, privacy: .public) processing_p99_ms=\(totalP99, privacy: .public) allocation_failures=\(self.allocationFailuresThisRun, privacy: .public) sample_buffer_failures=\(self.sampleBufferCreationFailures, privacy: .public) remaining_consumers=\(self.streamUsers, privacy: .public)")
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private func produceFrame() {
        let tickUptime = DispatchTime.now().uptimeNanoseconds
        let expectedDeadline = nextExpectedDeadlineUptime ?? tickUptime
        let latenessMs = tickUptime >= expectedDeadline ? Double(tickUptime - expectedDeadline) / 1_000_000 : 0
        appendBounded(latenessMs, to: &producerLatenessMs)
        if let previousProducerTickUptime {
            let tickIntervalMs = Double(tickUptime - previousProducerTickUptime) / 1_000_000
            appendBounded(tickIntervalMs, to: &producerTickIntervalsMs)
            if tickIntervalMs > 50 {
                logger.error("producer timer gap interval_ms=\(tickIntervalMs, privacy: .public) lateness_ms=\(latenessMs, privacy: .public) tick=\(self.timerTickNumber, privacy: .public)")
                    logger.notice("producer timer gap observation source=publisher_scheduler interval_ms=\(tickIntervalMs, privacy: .public) lateness_ms=\(latenessMs, privacy: .public) tick=\(self.timerTickNumber, privacy: .public)")
            }
        }
        previousProducerTickUptime = tickUptime
        if latenessMs > Double(framePeriodNanoseconds) / 1_000_000 * 1.5 {
            let periodsLate = max(1, Int(latenessMs / (Double(framePeriodNanoseconds) / 1_000_000)))
            missedProducerPeriods += periodsLate
        }
        timerTickNumber += 1
        nextExpectedDeadlineUptime = tickUptime &+ framePeriodNanoseconds

        guard let pixelBufferPool else { return }
        let configuration = CameraProcessingConfiguration.read()
        let selected = processedFrameSlot.takeIfCurrent(generation: captureGeneration,
            configuration: configuration, nowUptime: tickUptime,
            maximumAgeNanoseconds: processedFrameFreshnessNanoseconds)
        // Keep publishing the most recent validated composite while it remains
        // within the same 100 ms freshness window. Vision can finish just after
        // a 30 FPS publisher tick; reusing the immutable processed buffer for
        // the next tick avoids a neutral flash without ever exposing source.
        if selected == nil {
            updateEngineStatus("Neutral fallback active (awaiting a fresh processed frame).")
        }
        let isProcessed = selected != nil
        var outputBuffer = selected?.pixelBuffer
        if outputBuffer == nil {
            var neutralBuffer: CVPixelBuffer?
            let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pixelBufferPool, allocationAttributes, &neutralBuffer)
            guard allocationStatus == kCVReturnSuccess, let neutralBuffer else {
                pixelBufferAllocationFailures += 1
                allocationFailuresThisRun += 1
                processedFrameSlot.invalidate()
                logger.error("neutral output allocation failed; status=\(allocationStatus, privacy: .public) tick=\(self.timerTickNumber, privacy: .public)")
                return
            }
            CVPixelBufferLockBaseAddress(neutralBuffer, [])
            if capturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || capturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                guard CVPixelBufferGetPlaneCount(neutralBuffer) >= 2,
                      let luma = CVPixelBufferGetBaseAddressOfPlane(neutralBuffer, 0),
                      let chroma = CVPixelBufferGetBaseAddressOfPlane(neutralBuffer, 1) else {
                    CVPixelBufferUnlockBaseAddress(neutralBuffer, [])
                logger.error("neutral fallback bi-planar pixel buffer is missing image planes")
                return
            }
            let fullRange = capturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                memset(luma, fullRange ? 105 : 107, CVPixelBufferGetBytesPerRowOfPlane(neutralBuffer, 0) * height)
                memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(neutralBuffer, 1) * (height / 2))
            } else {
                CVPixelBufferUnlockBaseAddress(neutralBuffer, [])
                logger.error("neutral fallback mode does not support output pixel format=\(self.fourCC(self.capturePixelFormat), privacy: .public)")
                return
            }
            CVPixelBufferUnlockBaseAddress(neutralBuffer, [])
            outputBuffer = neutralBuffer
        }
        guard let pixelBuffer = outputBuffer,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == CMFormatDescriptionGetMediaSubType(formatDescription),
              (selected == nil || selected!.frameIdentity == ObjectIdentifier(pixelBuffer)) else {
            processedFrameSlot.invalidate()
            pendingDiscontinuityFlags.insert(.sampleDropped)
            logger.error("output boundary rejected malformed or non-distinct frame")
            return
        }
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let previousSentPresentationTime {
            let ptsIntervalMs = CMTimeGetSeconds(CMTimeSubtract(presentationTime, previousSentPresentationTime)) * 1_000
            guard CMTimeCompare(presentationTime, previousSentPresentationTime) > 0 else {
                processedFrameSlot.invalidate()
                pendingDiscontinuityFlags.insert(.time)
                logger.error("publisher host clock did not advance; frame rejected")
                return
            }
            appendBounded(ptsIntervalMs, to: &sendIntervalsMs)
            if ptsIntervalMs > 50 {
                pendingDiscontinuityFlags.insert(.time)
                let processingQueueDelayMs = processingQueueWaitMs.last ?? 0
                let recentProcessingMs = processingLatencyMs.suffix(30).max() ?? 0
                let effectChangedRecently = !configReadMs.isEmpty &&
                    (DispatchTime.now().uptimeNanoseconds - (captureRunStartUptime ?? tickUptime)) < 500_000_000
                let cause = latenessMs > 8 ? "publisher_scheduler" :
                    (processingQueueDelayMs > 15 || recentProcessingMs > 33 ? "vision_processing_contention_possible" :
                     (effectChangedRecently ? "effect_switch_possible" : "unknown"))
                logger.error("publisher PTS gap interval_ms=\(ptsIntervalMs, privacy: .public) timer_lateness_ms=\(latenessMs, privacy: .public) processing_queue_wait_ms=\(processingQueueDelayMs, privacy: .public) recent_processing_max_ms=\(recentProcessingMs, privacy: .public) cause_observation=\(cause, privacy: .public)")
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(frameRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            sampleBufferCreationFailures += 1
            if isProcessed { processedFrameSlot.invalidate() }
            logger.error("sample buffer creation failed: \(status, privacy: .public)")
            return
        }
        let sendStart = DispatchTime.now().uptimeNanoseconds
        let hostTimestamp = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        guard hostTimestamp.isNumeric, hostTimestamp.value >= 0 else { return }
        // Sole publication site: both processed and neutral buffers share the
        // same stream clock and serialized send ordering.
        streamSource.stream.send(sampleBuffer, discontinuity: pendingDiscontinuityFlags,
            hostTimeInNanoseconds: UInt64(hostTimestamp.value))
        let sendUptime = DispatchTime.now().uptimeNanoseconds
        if let previousSendUptime {
            appendBounded(Double(sendUptime - previousSendUptime) / 1_000_000, to: &sendIntervalsMs)
        }
        previousSendUptime = sendUptime
        pendingDiscontinuityFlags = []
        previousSentPresentationTime = presentationTime
        outputSequenceNumber &+= 1
        receiverPTSByOutputSequence[outputSequenceNumber] = presentationTime
        if isProcessed, let frame = selected {
            receiverCaptureAgesByOutputSequence[outputSequenceNumber] =
                CMTimeGetSeconds(CMTimeSubtract(presentationTime, frame.sourcePresentationTime)) * 1_000
            logger.debug("published frame sequence=\(self.outputSequenceNumber, privacy: .public) processing_frame_id=\(frame.processingFrameID, privacy: .public) reused=\(self.previousOutputProcessingFrameID == frame.processingFrameID, privacy: .public) capture_to_publication_ms=\(self.captureToPublicationByFrameID[frame.processingFrameID] ?? -1, privacy: .public) output_pts=\(presentationTime.seconds, privacy: .public)")
        }
            logger.notice("publisher frame sequence=\(self.outputSequenceNumber, privacy: .public) pts=\(presentationTime.seconds, privacy: .public) processed=\(isProcessed, privacy: .public) processing_frame_id=\(selected?.processingFrameID ?? 0, privacy: .public) source_pts=\(selected?.sourcePresentationTime.seconds ?? -1, privacy: .public)")
        if outputSequenceNumber > 300 {
            receiverPTSByOutputSequence.removeValue(forKey: outputSequenceNumber - 300)
            receiverCaptureAgesByOutputSequence.removeValue(forKey: outputSequenceNumber - 300)
        }
        generatedFramesThisRun += 1
        if let selected {
            deliveredProcessedFramesThisRun += 1
            if previousOutputProcessingFrameID == selected.processingFrameID {
                repeatedOutputFramesThisRun += 1
                currentRepeatedFrameStreak += 1
                maximumRepeatedFrameStreak = max(maximumRepeatedFrameStreak, currentRepeatedFrameStreak)
                maximumRepeatedFrameDurationMs = max(maximumRepeatedFrameDurationMs,
                    Double(currentRepeatedFrameStreak) * Double(framePeriodNanoseconds) / 1_000_000)
            } else {
                currentRepeatedFrameStreak = 0
                presentedProcessingFrameIDs.insert(selected.processingFrameID)
            }
            previousOutputProcessingFrameID = selected.processingFrameID
            activeSourceMode = "processed-\(selected.configuration.mode.rawValue)"
            appendBounded(Double(tickUptime - selected.captureArrivalUptime) / 1_000_000, to: &callbackToSendLatencyMs)
            let effect = effectDisplayName(for: selected.configuration)
            updateEngineStatus("\(effect) processing active.")
        } else {
            deliveredNeutralFramesThisRun += 1
            previousOutputProcessingFrameID = nil
            currentRepeatedFrameStreak = 0
            activeSourceMode = "neutralFallback"
        }
        let sendDurationMs = Double(DispatchTime.now().uptimeNanoseconds - sendStart) / 1_000_000
        appendBounded(sendDurationMs, to: &sendDurationsMs)
        if isProcessed { appendBounded(sendDurationMs, to: &processingSendCallMs) }
        updateLiveMotionMetricsIfDue(nowUptime: tickUptime)
    }

    private func updateLiveMotionMetricsIfDue(nowUptime: UInt64) {
        guard lastLiveMotionMetricsWriteUptime == 0
                || nowUptime - lastLiveMotionMetricsWriteUptime >= 1_000_000_000,
              let captureRunStartUptime, nowUptime > captureRunStartUptime else { return }
        lastLiveMotionMetricsWriteUptime = nowUptime
        let elapsed = Double(nowUptime - captureRunStartUptime) / 1_000_000_000
        let uniqueProcessedFPS = Double(processedFrameIDs.count) / elapsed
        let uniquePresentedFPS = Double(presentedProcessingFrameIDs.count) / elapsed
        let reusedPercent = deliveredProcessedFramesThisRun > 0
            ? Double(repeatedOutputFramesThisRun) * 100 / Double(deliveredProcessedFramesThisRun) : 0
        let metrics = String(format: "Unique processed-video FPS (run avg): %.2f | unique presented: %.2f FPS | reused output: %.1f%%",
                             uniqueProcessedFPS, uniquePresentedFPS, reusedPercent)
        CameraProcessingConfiguration.writeLiveMotionMetrics(metrics)
    }

    private func effectDisplayName(for configuration: CameraProcessingConfiguration) -> String {
        if configuration.mode == .solid { return "Solid background" }
        if configuration.mode == .image {
            return configuration.backgroundPresetID == "imported" ? "Imported background" : "Neutral fallback"
        }
        if configuration.blurPreset == .softBlue { return "Soft Blue" }
        return "\(configuration.blurPreset.title) blur"
    }
}

private struct PendingPhysicalFrame {
    let sampleBuffer: CMSampleBuffer
    let generation: UInt64
    let captureArrivalUptime: UInt64
}

private final class BoundedPhysicalFrameRelay {
    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private let consume: (PendingPhysicalFrame) -> Void
    private var pendingFrame: PendingPhysicalFrame?
    private var drainScheduled = false

    init(label: String, consume: @escaping (PendingPhysicalFrame) -> Void) {
        deliveryQueue = DispatchQueue(label: label, qos: .userInteractive)
        self.consume = consume
    }

    // Nonblocking producer side. At most one frame waits for the serial delivery
    // worker; when it is occupied, the waiting slot keeps only the newest frame.
    func enqueue(_ frame: PendingPhysicalFrame) -> String? {
        guard lock.try() else { return "relay_lock_busy" }
        let replaced = pendingFrame != nil
        pendingFrame = frame
        if !drainScheduled {
            drainScheduled = true
            deliveryQueue.async { [weak self] in self?.drain() }
        }
        lock.unlock()
        return replaced ? "oldest_pending_frame_replaced" : nil
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pendingFrame else {
                drainScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            lock.unlock()
            consume(frame)
        }
    }
}

private final class PhysicalCameraSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: PrivateCamDeviceSource?
    let generation: UInt64
    let relay: BoundedPhysicalFrameRelay

    init(owner: PrivateCamDeviceSource, generation: UInt64, relay: BoundedPhysicalFrameRelay) {
        self.owner = owner
        self.generation = generation
        self.relay = relay
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frame = PendingPhysicalFrame(
            sampleBuffer: sampleBuffer,
            generation: generation,
            captureArrivalUptime: DispatchTime.now().uptimeNanoseconds
        )
        if let dropReason = relay.enqueue(frame) { owner?.noteRelayDrop(generation: generation, reason: dropReason) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.notePhysicalFrameDrop(generation: generation)
    }
}

final class PrivateCamStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private let device: CMIOExtensionDevice

    private func fourCC(_ value: OSType) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    init(format: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        streamFormat = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "Aurevix Cam Stream",
            streamID: streamIdentifier,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let chars = [UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff), UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)]
        let pixelFormat = String(bytes: chars, encoding: .macOSRoman) ?? String(subtype)
        logger.notice("CMIO stream source format width=\(dimensions.width, privacy: .public) height=\(dimensions.height, privacy: .public) pixel_format=\(pixelFormat, privacy: .public) min_frame_duration=\(format.minFrameDuration.value)/\(format.minFrameDuration.timescale) max_frame_duration=\(format.maxFrameDuration.value)/\(format.maxFrameDuration.timescale)")
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: Int32(frameRate)) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index != 0 {
            throw NSError(domain: "PrivateCam", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported format index"])
        }
        if let index = streamProperties.activeFormatIndex {
            logger.notice("CMIO consumer selected active_format_index=\(index, privacy: .public) width=1280 height=720 pixel_format=\(self.fourCC(CMFormatDescriptionGetMediaSubType(self.streamFormat.formatDescription)), privacy: .public)")
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        (device.source as? PrivateCamDeviceSource)?.authorizeStreamClient(client) ?? false
    }
    func startStream() throws { (device.source as? PrivateCamDeviceSource)?.startStreaming() }
    func stopStream() throws { (device.source as? PrivateCamDeviceSource)?.stopStreaming() }
}

final class PrivateCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: PrivateCamDeviceSource

    init(clientQueue: DispatchQueue?) {
        deviceSource = PrivateCamDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        do { try provider.addDevice(deviceSource.device) }
        catch { logger.error("addDevice failed: \(error.localizedDescription, privacy: .public)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Aurevix Cam" }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
