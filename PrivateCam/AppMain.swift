import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PrivateCamApp: App {
    @NSApplicationDelegateAdaptor(AurevixApplicationDelegate.self) private var appDelegate
    @StateObject private var controller = CameraController()
    var body: some Scene {
        WindowGroup("Aurevix Cam", id: "studio") {
            ContentView(controller: controller)
                .frame(minWidth: 800, minHeight: 480)
        }
        .handlesExternalEvents(matching: ["studio"])
        .commands { CommandGroup(replacing: .newItem) {} }

        WindowGroup("About Aurevix Cam", id: "credits") {
            CreditsView().frame(width: 530, height: 470)
        }

        MenuBarExtra {
            MenuBarController(controller: controller)
        } label: {
            Image(systemName: "camera").font(.system(size: 15, weight: .regular))
                .accessibilityLabel("Aurevix Cam")
        }
        .menuBarExtraStyle(.window)
    }
}

private final class AurevixApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.mainMenu?.items.first?.title = "Aurevix Cam"
        }
    }
}

private struct MenuBarController: View {
    @ObservedObject var controller: CameraController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading) {
                    Text("Aurevix Cam").font(.headline)
                    Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Divider()
            Button(controller.isCapturing || controller.isStarting || controller.captureRequested ? "Stop Local Preview" : "Start Local Preview") {
                controller.toggleCapture()
            }
            .disabled(!controller.isCapturing && !controller.isStarting && !controller.isDeviceAvailable)
            Menu("Background") {
                ForEach(controller.personalBackgrounds, id: \.path) { url in
                    Divider()
                    Button(url.deletingPathExtension().lastPathComponent) { controller.selectPersonalBackground(url) }
                }
                Divider()
                ForEach([CameraBlurPreset.natural, .soft, .strong]) { preset in
                    Button("\(preset.title) Blur") {
                        controller.backgroundMode = .blur
                        controller.blurPreset = preset
                    }
                }
            }
            if controller.backgroundMode == .blur && controller.blurPreset != .softBlue {
                Slider(value: $controller.blurIntensity, in: 0...1) { Text("Blur intensity") }
                    .accessibilityLabel("Blur intensity")
            }
            if controller.backgroundMode == .solid {
                ColorPicker("Background", selection: Binding(
                    get: { Color(red: controller.backgroundRed, green: controller.backgroundGreen, blue: controller.backgroundBlue) },
                    set: { color in
                        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .darkGray
                        controller.setBackgroundColor(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
                    }
                ))
            }
            Label(controller.processingStatus, systemImage: controller.processingStatus.lowercased().contains("neutral") ? "lock.shield" : "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(controller.isDeviceAvailable ? "Virtual camera available" : "Virtual camera unavailable")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at Login", isOn: Binding(
                get: { controller.launchAtLoginEnabled },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .help("Starts Aurevix Cam controls only. It never starts camera capture automatically.")
            if !controller.loginItemStatus.isEmpty {
                Text(controller.loginItemStatus).font(.caption2).foregroundStyle(.secondary)
            }
            Button("Open Studio") {
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
            }
                .keyboardShortcut("o")
            Button("About Aurevix Cam") { openWindow(id: "credits") }
            Button("Quit Aurevix Cam") {
                controller.stopCapture()
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

struct ContentView: View {
    @ObservedObject var controller: CameraController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var isImportingBackground = false
    @State private var importError: String?
    @State private var isPersonalPhotosExpanded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aurevix Cam").font(.headline)
                    Text(controller.isDeviceAvailable ? "Virtual camera available" : "Waiting for virtual camera")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
                Menu {
                    Button("Activate Camera Extension") { controller.activateExtension() }
                    Button("Refresh Devices") { controller.refreshDevices() }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).help("More camera options")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            HStack(spacing: 20) {
                VStack(spacing: 12) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let session = controller.session {
                                CameraPreview(session: session).scaleEffect(x: -1, y: 1)
                            } else {
                                RoundedRectangle(cornerRadius: 13).fill(.black.opacity(0.82))
                                    .overlay {
                                        VStack(spacing: 10) {
                                            Image(systemName: "video.badge.waveform").font(.system(size: 32)).foregroundStyle(.white.opacity(0.8))
                                            Text(controller.isStarting ? "Connecting to Aurevix Cam…" : "Your processed preview will appear here")
                                                .font(.callout).foregroundStyle(.white.opacity(0.8))
                                        }.padding()
                                    }
                            }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        HStack(spacing: 7) {
                            Circle().fill(controller.isCapturing ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            Text(controller.isCapturing ? "PREVIEW LIVE" : "PREVIEW OFF").font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule()).padding(12)
                    }
                    HStack {
                        Label(controller.isCapturing ? "Local preview running" : "Local preview idle", systemImage: "camera")
                        Spacer()
                        Text(controller.statistics.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? "Receiver waiting")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                    HStack {
                        Text(controller.motionStatistics).monospacedDigit()
                        Spacer(minLength: 0)
                    }.font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(controller.motionStatistics)
                }
                .frame(maxWidth: .infinity)
                effectsPanel.frame(width: 300)
            }
            .padding(20)
            Divider()
            HStack(spacing: 12) {
                Button {
                    controller.toggleCapture()
                } label: {
                    Label(controller.captureRequested || controller.isCapturing || controller.isStarting ? "Stop Preview" : "Start Preview",
                          systemImage: controller.captureRequested || controller.isCapturing || controller.isStarting ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent).disabled(!controller.captureRequested && !controller.isCapturing && !controller.isStarting && !controller.isDeviceAvailable)
                Label(controller.isInterrupted ? "Interrupted — recovering" : controller.status,
                      systemImage: controller.isInterrupted ? "arrow.clockwise" : (controller.isCapturing ? "checkmark.circle.fill" : "info.circle"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu("Diagnostics") {
                    Text(controller.processingStatus)
                    Text(controller.streamHealth)
                    Divider()
                    Text(controller.deviceList)
                }
                .menuStyle(.borderlessButton)
                Button("About Aurevix Cam") { openWindow(id: "credits") }
                    .buttonStyle(.plain).help("About Aurevix Cam")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.background)
        .frame(minWidth: 920, minHeight: 510)
        .onAppear {
            controller.refreshDevices()
            controller.startMonitoringEngineStatus()
        }
        .onDisappear {
            controller.stopCapture()
            controller.stopMonitoringEngineStatus()
        }
        .fileImporter(isPresented: $isImportingBackground, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            do {
                let selected = try result.get()
                guard let url = selected.first else { throw CocoaError(.fileNoSuchFile) }
                try controller.importBackground(from: url)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Couldn’t Import Image", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
    }

    private var statusBadge: some View {
        let operationalState = controller.operationalState
        let processingActive = operationalState == .previewRunning
        return HStack(spacing: 6) {
            Circle().fill(processingActive ? Color.green : (controller.isStarting ? Color.orange : Color.secondary)).frame(width: 7, height: 7)
            Text(operationalState.title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private var effectsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("SKIN REFINEMENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Skin refinement", selection: $controller.skinPreset) {
                ForEach(SkinRefinementPreset.allCases) { preset in Text(preset.title).tag(preset) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Skin refinement preset")
            if controller.skinPreset == .custom {
                HStack { Text("Smoothing"); Spacer(); Text("\(Int(controller.skinIntensity / 0.4 * 100))%").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                Slider(value: $controller.skinIntensity, in: 0...0.4).accessibilityLabel("Custom skin smoothing intensity")
            }
            Divider()
            Text("BACKGROUND FILTERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 7) {
                effectRow("Off / Neutral", symbol: "circle.slash", selected: controller.backgroundMode == .solid && controller.backgroundPresetID == "neutral") {
                    controller.selectBackground("neutral")
                }
                effectRow("Soft Blue", symbol: "rectangle.fill", selected: controller.backgroundMode == .blur && controller.blurPreset == .softBlue) {
                    controller.selectBackground("soft-blue")
                }
                effectRow("Natural Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .natural) { select(.natural) }
                effectRow("Soft Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .soft) { select(.soft) }
                effectRow("Strong Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .strong) { select(.strong) }
                effectRow("Solid Background", symbol: "circle.lefthalf.filled", selected: controller.backgroundMode == .solid && controller.backgroundPresetID == "solid") { controller.selectSolidBackground() }
            }
            Divider()
            if controller.backgroundMode == .blur && controller.blurPreset != .softBlue {
                HStack { Text("Blur strength"); Spacer(); Text("\(Int(controller.blurIntensity * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                    .font(.caption)
                Slider(value: $controller.blurIntensity, in: 0...1)
                    .accessibilityLabel("Blur intensity")
            }
            if controller.backgroundMode == .solid {
                ColorPicker("Background color", selection: Binding(
                    get: { Color(red: controller.backgroundRed, green: controller.backgroundGreen, blue: controller.backgroundBlue) },
                    set: { color in
                        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .darkGray
                        controller.setBackgroundColor(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
                    }
                ))
            }
            Divider()
            DisclosureGroup(isExpanded: $isPersonalPhotosExpanded) {
                if controller.personalBackgrounds.isEmpty {
                    Text("No personal photos yet. Add a photo to use it as your background.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                } else {
                    ForEach(controller.personalBackgrounds, id: \.path) { url in
                        HStack(spacing: 8) {
                            Button { controller.selectPersonalBackground(url) } label: {
                                HStack(spacing: 8) {
                                    if let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image).resizable().scaledToFill().frame(width: 42, height: 32).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    Text(url.deletingPathExtension().lastPathComponent.prefix(18)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if controller.backgroundMode == .image && controller.backgroundFilePath == url.path { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                }.font(.caption)
                            }.buttonStyle(.plain).accessibilityLabel("Select photo \(url.lastPathComponent)")
                            Button { try? controller.removePersonalBackground(url) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help("Remove Photo")
                        }
                    }
                }
            } label: {
                Text("My Photos (\(controller.personalBackgrounds.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Button("Add Photo") { isImportingBackground = true }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Button("Reset Effects") {
                controller.backgroundMode = .blur
                controller.blurPreset = .natural
                controller.blurIntensity = 0.5
                controller.setBackgroundColor(red: 0.24, green: 0.27, blue: 0.30)
                controller.skinPreset = .off
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(15)
        }
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 14).fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
    }

    private func select(_ preset: CameraBlurPreset) {
        controller.backgroundMode = .blur
        controller.blurPreset = preset
    }

    private func effectRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .font(.callout).padding(.horizontal, 9).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CreditsView: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aurevix Cam").font(.title2.weight(.semibold))
            Text("Created by Martin Aziz.").font(.callout.weight(.medium))
            Text("Aurevix Cam is a native macOS virtual-camera application created to make video communication more comfortable, private, and personal.")
            Text("The application allows users to customize their camera background, use their own photographs, and gently refine their on-camera appearance while keeping video processing on their device.")
            Text("The goal is to provide a simple, reliable, and elegant camera experience without unnecessary complexity, accounts, or cloud-based video processing.")
            Divider()
            Text("Creator: Martin Aziz")
            Text("Platform: macOS")
            Text("Processing: Local, on-device")
            Text("Version \(version) (\(build))").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.padding(22)
    }
}

import AVFoundation

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        return view
    }
    func updateNSView(_ nsView: PreviewNSView, context: Context) { nsView.previewLayer.session = session }
}

final class PreviewNSView: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
    var previewLayer: AVCaptureVideoPreviewLayer {
        if let current = layer as? AVCaptureVideoPreviewLayer { return current }
        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspect
        layer = preview
        return preview
    }
}
