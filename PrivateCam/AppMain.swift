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
                .frame(minWidth: 660, minHeight: 480)
        }
        .handlesExternalEvents(matching: ["studio"])
        .commands { CommandGroup(replacing: .newItem) {} }

        WindowGroup("About Aurevix Cam", id: "credits") {
            CreditsView()
                .frame(width: 470, height: 390)
        }

        MenuBarExtra {
            MenuBarController(controller: controller)
        } label: {
            Image("AurevixMenuMark").renderingMode(.template)
                .resizable().scaledToFit().frame(width: 8, height: 8)
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
                ForEach(BackgroundGalleryPreset.allCases) { preset in
                    Button(preset.title) { controller.selectBackground(preset.id) }
                }
                if controller.importedBackgroundPreview != nil {
                    Divider()
                    Button("Your Photo") { controller.selectImportedBackground() }
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
            Button("About Aurevix Cam & Credits") { openWindow(id: "credits") }
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
                effectsPanel.frame(width: 250)
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
                Button("Credits") { openWindow(id: "credits") }
                    .buttonStyle(.plain).help("Open background image credits and license information")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.background)
        .frame(minWidth: 760, minHeight: 510)
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
        let processingActive = controller.processingStatus.lowercased().contains("processing active")
        return HStack(spacing: 6) {
            Circle().fill(processingActive ? Color.green : (controller.isStarting || controller.isCapturing ? Color.orange : Color.secondary)).frame(width: 7, height: 7)
            Text(processingActive ? "Processing active" : (controller.isCapturing ? "Privacy fallback" : (controller.isStarting ? "Connecting" : "Ready")))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private var effectsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("EFFECTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 7) {
                effectRow("Off / Neutral", symbol: "circle.slash", selected: controller.backgroundMode == .solid && controller.backgroundRed == 0.24) {
                    controller.backgroundMode = .solid
                    controller.setBackgroundColor(red: 0.24, green: 0.27, blue: 0.30)
                }
                effectRow("Natural Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .natural) { select(.natural) }
                effectRow("Soft Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .soft) { select(.soft) }
                effectRow("Strong Blur", symbol: "camera.filters", selected: controller.backgroundMode == .blur && controller.blurPreset == .strong) { select(.strong) }
                effectRow("Solid Background", symbol: "circle.lefthalf.filled", selected: controller.backgroundMode == .solid && controller.backgroundRed != 0.24) { controller.backgroundMode = .solid }
            }
            Divider()
            HStack {
                Text("BACKGROUNDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Import Image…") { isImportingBackground = true }
                    .font(.caption).buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(BackgroundGalleryPreset.allCases) { preset in
                    backgroundCard(preset)
                }
                if let image = controller.importedBackgroundPreview {
                    importedBackgroundCard(image)
                }
            }
            Text("Photos are included under CC0. Import a personal image to use it locally.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Button("Reset Effects") {
                controller.backgroundMode = .blur
                controller.blurPreset = .natural
                controller.blurIntensity = 0.5
                controller.setBackgroundColor(red: 0.24, green: 0.27, blue: 0.30)
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

    private func backgroundCard(_ preset: BackgroundGalleryPreset) -> some View {
        let selected = preset.id == "soft-blue"
            ? (controller.backgroundMode == .blur && controller.blurPreset == .softBlue)
            : (controller.backgroundMode == .image && controller.backgroundPresetID == preset.id)
        return Button { controller.selectBackground(preset.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if preset.id == "soft-blue" {
                        LinearGradient(colors: [Color(red: 0.38, green: 0.55, blue: 0.79), Color(red: 0.88, green: 0.93, blue: 0.98)], startPoint: .top, endPoint: .bottom)
                    } else if let url = Bundle.main.url(forResource: preset.previewAssetName, withExtension: "jpg", subdirectory: "Previews"),
                              let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(height: 47).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 3) {
                    Text(preset.title).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }.font(.caption2.weight(selected ? .semibold : .regular))
            }
            .padding(5)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) background\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func importedBackgroundCard(_ image: NSImage) -> some View {
        let selected = controller.backgroundMode == .image && controller.backgroundPresetID == "imported"
        return Button { controller.selectImportedBackground() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(height: 47).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 3) {
                    Text("Your Photo").lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }.font(.caption2.weight(selected ? .semibold : .regular))
            }
            .padding(5)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your Photo background\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
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

private struct BackgroundGalleryPreset: Identifiable, CaseIterable {
    let id: String
    let title: String
    var previewAssetName: String { id }
    static let allCases = [
        Self(id: "soft-blue", title: "Soft Blue"),
        Self(id: "beach-sunrise", title: "Beach Sunrise"),
        Self(id: "quiet-office", title: "Quiet Office"),
        Self(id: "warm-lounge", title: "Warm Lounge"),
        Self(id: "coastal-morning", title: "Coastal Morning")
    ]
}

private struct CreditsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aurevix Cam").font(.title2.weight(.semibold))
            Text("A local virtual camera with on-device background processing.")
                .foregroundStyle(.secondary)
            Text("Developed by Martin")
                .font(.callout.weight(.medium))
            Divider()
            Text("Background photo credits").font(.headline)
            Text("Beach Sunrise — Umhlanga Sunrise, Greg Zaal; Quiet Office — Poly Haven Studio, Greg Zaal; Warm Lounge — Anniversary Lounge, Greg Zaal; Coastal Morning — Secluded Beach, Greg Zaal and Rico Cilliers. All supplied by Poly Haven under CC0.")
                .font(.callout)
            Link("Poly Haven CC0 license", destination: URL(string: "https://polyhaven.com/license")!)
            Text("Aurevix Cam is a working name. No trademark or exclusivity claim is made.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Icon artwork: operator supplied Aurevix Cam brand concept.")
                .font(.caption2).foregroundStyle(.secondary)
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
