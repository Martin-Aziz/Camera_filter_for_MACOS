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
        }
        .handlesExternalEvents(matching: ["studio"])
        .defaultSize(width: 900, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
        }

        Window("Aurevix Cam Settings", id: "settings") {
            SettingsView(controller: controller)
        }
        .windowResizability(.contentSize)

        WindowGroup("About Aurevix Cam", id: "credits") {
            CreditsView().frame(width: 530, height: 470)
        }

        MenuBarExtra {
            MenuBarController(controller: controller)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon. Its view exists from launch, so it also makes sure a
/// manual launch always shows Studio (SwiftUI restores no window when the
/// previous session ended with all windows closed).
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // System-sized template symbol, matching other menu bar extras.
        Image(systemName: "camera")
            .accessibilityLabel("Aurevix Cam")
            .onAppear {
                StudioWindowOpener.open = { openWindow(id: "studio") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { StudioWindowOpener.show() }
            }
    }
}

/// ⌘, opens the Settings window (a plain Window scene; works on macOS 13).
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",", modifiers: .command)
    }
}

/// Opens the Studio window from AppKit callbacks; set by SwiftUI views that
/// hold an `openWindow` action.
enum StudioWindowOpener {
    static var open: (() -> Void)?

    static func show() {
        if let window = studioWindow {
            bringForward(window)
        } else {
            open?()
            // The new window exists on the next run-loop turn.
            DispatchQueue.main.async { if let window = studioWindow { bringForward(window) } }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var studioWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("studio") == true })
    }

    /// Shows the window on the current desktop, in front, even when it was
    /// created on another Space (for example behind a full-screen app).
    private static func bringForward(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

enum DockVisibility {
    static let key = "aurevixShowInDock"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static func apply(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}

private final class AurevixApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockVisibility.apply(DockVisibility.isEnabled)
        DispatchQueue.main.async {
            NSApp.mainMenu?.items.first?.title = "Aurevix Cam"
        }
    }

    /// Launching again from Finder, Launchpad or Spotlight brings Studio back,
    /// so the app stays reachable when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("studio") == true }) {
            StudioWindowOpener.show()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        // No Studio window: returning true lets SwiftUI create one.
        return true
    }
}

// MARK: - Shared effect controls

/// One user-facing blur amount (0...1) spread across the three tuned presets.
extension CameraController {
    var blurAmount: Double {
        get {
            switch blurPreset {
            case .natural, .softBlue: return blurIntensity / 3
            case .soft: return (1 + blurIntensity) / 3
            case .strong: return (2 + blurIntensity) / 3
            }
        }
        set {
            let value = min(max(newValue, 0), 1) * 3
            let band = min(Int(value), 2)
            blurPreset = [.natural, .soft, .strong][band]
            blurIntensity = value - Double(band)
        }
    }

    var isOriginalBackground: Bool { backgroundMode == .original }
    var isBlurBackground: Bool { backgroundMode == .blur && blurPreset != .softBlue }
    var isPhotoBackground: Bool { backgroundMode == .image }

    func importPhotoWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try importBackground(from: url)
            selectImportedBackground()
        } catch {
            status = "Couldn’t add photo: \(error.localizedDescription)"
        }
    }
}

/// "Ready for calls", or a plain problem with the action that fixes it.
private struct StatusPill: View {
    @ObservedObject var controller: CameraController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.setupState {
            case .checking, .settingUp:
                ProgressView().controlSize(.small)
            default:
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(title).font(.callout.weight(.medium)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300, alignment: .leading)
            switch controller.setupState {
            case .missing, .failed:
                Button("Fix") { controller.fixCamera() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .needsApproval:
                Button("Open System Settings") { controller.openExtensionSettings() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
        .background(.thinMaterial, in: Capsule())
        // Keep the Fix / Open System Settings buttons reachable (VoiceOver too).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String { controller.setupState.title }

    private var color: Color {
        switch controller.setupState {
        case .ready: return .green
        case .failed: return .red
        case .checking, .settingUp: return .secondary
        case .missing, .needsApproval, .needsRestart: return .orange
        }
    }
}

extension CameraSetupState {
    var title: String {
        switch self {
        case .checking: return "Checking camera…"
        case .ready: return "Ready for calls"
        case .settingUp: return "Setting up camera…"
        case .needsApproval: return "Approve in System Settings"
        case .needsRestart: return "Restart your Mac to finish setup"
        case .failed(let message): return message
        case .missing: return "Camera not set up"
        }
    }
}

// MARK: - Menu bar popup

private struct MenuBarController: View {
    @ObservedObject var controller: CameraController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(controller.setupState == .ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                    .accessibilityLabel(controller.setupState.title).help(controller.setupState.title)
                Text("Effects").font(.headline)
                Spacer()
                Toggle("Effects", isOn: $controller.effectsEnabled).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            row("Background") {
                iconChoice("person.crop.rectangle", "None", selected: controller.isOriginalBackground) { controller.selectOriginalBackground() }
                iconChoice("camera.filters", "Blur", selected: controller.isBlurBackground) { controller.selectBlurBackground() }
                iconChoice("photo", "Photo", selected: controller.isPhotoBackground) {
                    if let first = controller.personalBackgrounds.first { controller.selectPersonalBackground(first) }
                    else { controller.importPhotoWithPanel() }
                }
            }
            row("Look") {
                Picker("Look", selection: $controller.skinPreset) {
                    ForEach(SkinRefinementPreset.visiblePresets) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            row("Lighting") {
                Spacer()
                Toggle("Lighting", isOn: $controller.lightToneEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Divider()
            MenuRowButton(title: "Open Aurevix Cam…", shortcut: "⌘O") {
                StudioWindowOpener.open = { openWindow(id: "studio") }
                StudioWindowOpener.show()
            }
            .keyboardShortcut("o")
            MenuRowButton(title: "Quit Aurevix Cam", shortcut: "⌘Q") {
                controller.stopCapture()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!controller.effectsEnabled)
        .opacity(controller.effectsEnabled ? 1 : 0.4)
    }

    private func iconChoice(_ symbol: String, _ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 40, height: 24)
                .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Plain menu-style row with hover highlight.
private struct MenuRowButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(hovering ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Studio

struct ContentView: View {
    @ObservedObject var controller: CameraController
    @Environment(\.openWindow) private var openWindow
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Aurevix Cam").font(.title3.weight(.semibold))
                Spacer()
                StatusPill(controller: controller)
                Button { openWindow(id: "settings") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings (⌘,)").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            preview.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 14) {
                section("Background") { backgroundTiles }
                if controller.isBlurBackground {
                    labeledSlider("Blur", value: $controller.blurAmount, low: "less", high: "more")
                }
                Divider()
                section("Look your best") {
                    Picker("Look your best", selection: $controller.skinPreset) {
                        ForEach(SkinRefinementPreset.visiblePresets) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    if controller.skinPreset != .off {
                        labeledSlider("Strength", value: $controller.skinStrength, low: "subtle", high: "strong")
                        HStack(spacing: 10) {
                            Text("Makeup").frame(width: 74, alignment: .leading)
                            Toggle("Makeup", isOn: $controller.makeupEnabled).toggleStyle(.switch).labelsHidden()
                                .controlSize(.small)
                            Text("a faint lip and cheek tint").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Lighting").font(.headline)
                        Toggle("Lighting", isOn: $controller.lightToneEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    if controller.lightToneEnabled {
                        labeledSlider("Brightness", value: $controller.lightToneIntensity, low: "soft", high: "bright")
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 700)
        .background(.background)
        .onAppear {
            StudioWindowOpener.open = { openWindow(id: "studio") }
            controller.refreshDevices()
            controller.startMonitoringEngineStatus()
            // The preview follows the window: it runs while Studio is open.
            if !controller.captureRequested && !controller.isCapturing { controller.startCapture() }
        }
        .onDisappear {
            controller.stopCapture()
            controller.stopMonitoringEngineStatus()
        }
        .alert("Couldn’t Add Photo", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
    }

    /// The Aurevix Cam output itself (what call apps receive), mirrored like a mirror.
    private var preview: some View {
        Group {
            if let session = controller.session {
                CameraPreview(session: session).scaleEffect(x: -1, y: 1)
            } else {
                Rectangle().fill(.black.opacity(0.85)).overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "video").font(.system(size: 30)).foregroundStyle(.white.opacity(0.75))
                        Text(controller.isDeviceAvailable ? "Starting preview…" : "Waiting for the camera…")
                            .font(.callout).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Live preview")
    }

    private var backgroundTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "person.crop.rectangle", title: "None", selected: controller.isOriginalBackground) {
                    controller.selectOriginalBackground()
                }
                SymbolTile(symbol: "camera.filters", title: "Blur", selected: controller.isBlurBackground) {
                    controller.selectBlurBackground()
                }
                ForEach(controller.personalBackgrounds, id: \.path) { url in
                    PhotoTile(url: url,
                              selected: controller.isPhotoBackground && controller.backgroundFilePath == url.path,
                              select: { controller.selectPersonalBackground(url) },
                              remove: {
                                  do { try controller.removePersonalBackground(url) }
                                  catch { importError = error.localizedDescription }
                              })
                }
                SymbolTile(symbol: "plus", title: "Add photo", selected: false) { controller.importPhotoWithPanel() }
            }
            .padding(.vertical, 2)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, low: String, high: String) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 74, alignment: .leading)
            Text(low).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1).accessibilityLabel(title).frame(maxWidth: 360)
            Text(high).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private let tileSize = CGSize(width: 96, height: 60)

private struct SymbolTile: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Thumbnail only; remove from the hover ✕ or right-click.
private struct PhotoTile: View {
    let url: URL
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: tileSize.width, height: tileSize.height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(4).help("Remove photo").accessibilityLabel("Remove photo")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove Photo", role: .destructive, action: remove) }
        .accessibilityLabel("Background photo")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var controller: CameraController
    @State private var diagnosticsExpanded = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { controller.launchAtLoginEnabled },
                                                      set: { controller.setLaunchAtLogin($0) }))
                Toggle("Show in Dock", isOn: $controller.showInDock)
            }
            Section("More backgrounds") {
                HStack {
                    Button("Use Soft Blue") { controller.selectBackground("soft-blue") }
                    Button("Use solid color") { controller.selectSolidBackground() }
                }
                ColorPicker("Solid color", selection: Binding(
                    get: { Color(red: controller.backgroundRed, green: controller.backgroundGreen, blue: controller.backgroundBlue) },
                    set: { color in
                        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .darkGray
                        controller.setBackgroundColor(red: converted.redComponent, green: converted.greenComponent,
                                                      blue: converted.blueComponent)
                    }))
            }
            Section("Camera setup") {
                LabeledContent("Status", value: controller.setupState.title)
                HStack {
                    Button("Reinstall camera") { controller.fixCamera(force: true) }
                    Button("Check again") { controller.refreshDevices() }
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                    let text = [controller.processingStatus, controller.streamHealth, controller.statistics,
                                controller.motionStatistics, controller.deviceList].joined(separator: "\n")
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
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
