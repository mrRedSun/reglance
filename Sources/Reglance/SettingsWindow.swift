import AppKit
import Carbon.HIToolbox
import ChatCore
import Observation
import ServiceManagement
import SwiftUI

/// Service Management is the source of truth. A saved Boolean would get out of sync
/// when the user disables the login item in System Settings.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func enable() throws
    func disable() async throws
}

private struct MainAppLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func enable() throws { try SMAppService.mainApp.register() }
    func disable() async throws { try await SMAppService.mainApp.unregister() }
}

@MainActor
@Observable
final class LoginSettings {
    private let service: any LoginItemService
    private(set) var status: SMAppService.Status
    private(set) var isUpdating = false
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    init(service: any LoginItemService = MainAppLoginItem()) {
        self.service = service
        self.status = service.status
    }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        error = nil
        defer { refresh(); isUpdating = false }
        do {
            if enabled { try service.enable() } else { try await service.disable() }
        } catch {
            self.error = "Couldn't change the login item. \(error.localizedDescription)"
        }
    }
}

/// Health of the backends Reglance runs on.
@MainActor
@Observable
final class ProviderDoctor {
    private(set) var reports: [Backend: DoctorReport] = [:]
    private(set) var isRunning = false

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await withTaskGroup(of: (Backend, DoctorReport).self) { group in
            // A switched-off backend's CLI isn't run at all.
            for backend in Backend.allCases where ModelLibrary.shared.isEnabled(backend) {
                group.addTask { (backend, await backend.doctor()) }
            }
            for await (backend, report) in group { reports[backend] = report }
        }
        // A backend that was just installed or signed in shows up in the picker.
        await ModelLibrary.shared.refresh(force: true)
    }
}

/// Settings in toolbar tabs, like most Mac apps: each tab is as tall as its contents, up to
/// `SettingsPane.maxHeight`, and scrolls beyond that.
final class SettingsWindowController {
    private let settings = LoginSettings()
    private let hotKey: HotKeySettings
    private let doctor = ProviderDoctor()
    private(set) lazy var window: NSWindow = {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape",
                                     GeneralSettings(settings: settings, hotKey: hotKey)))
        tabs.addTabViewItem(Self.tab("Agent Mode", symbol: "folder.badge.gearshape", AgentSettings()))
        tabs.addTabViewItem(Self.tab("Providers", symbol: "cpu", ProviderSettings(doctor: doctor)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }()

    init(hotKey: HotKeySettings) { self.hotKey = hotKey }

    func show() {
        settings.refresh()
        Task { await doctor.run() }
        if !window.isVisible { window.center() }
        WindowPresentation.prepare(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func tab(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        // The tab controller shows the selected tab's title as the window's.
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// One settings tab: a grouped form as tall as its contents, up to `maxHeight`, then scrolling.
struct SettingsPane<Content: View>: View {
    static var width: CGFloat { 480 }
    static var maxHeight: CGFloat { 760 }

    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width, height: min(contentHeight ?? Self.maxHeight, Self.maxHeight))
    }
}

private struct GeneralSettings: View {
    let settings: LoginSettings
    let hotKey: HotKeySettings
    @AppStorage(NewChatAfter.defaultsKey) private var newChatAfter = NewChatAfter.defaultValue
    @AppStorage(SystemPrompt.preferencesKey) private var preferences = ""
    @AppStorage(PlayfulPrompts.defaultsKey) private var playfulPrompts = false

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Open ReGlance at login", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { value in Task { await settings.setEnabled(value) } }
                ))
                .disabled(settings.isUpdating)
                Text("Keep the chat bar a shortcut away after you sign in to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.status == .requiresApproval {
                    Text("Allow ReGlance in System Settings to finish enabling it.")
                        .font(.callout)
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = settings.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                Picker("Start a new chat after", selection: $newChatAfter) {
                    ForEach(NewChatAfter.options, id: \.seconds) { Text($0.title).tag($0.seconds) }
                }
                Text("How long the chat bar stays hidden before it reopens empty. Your draft stays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Playful prompts", isOn: $playfulPrompts)
                Text("Swap \u{201C}Ask anything\u{201D} for a different nudge, like \u{201C}Do your worst\u{201D}, each time the bar opens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show or hide the chat bar") {
                    HStack {
                        ShortcutRecorder(settings: hotKey)
                        if hotKey.combo != .default {
                            Button("Reset") { hotKey.reset() }
                        }
                    }
                }
                Text(hotKey.isRecording
                     ? "Press a shortcut that includes ⌘, ⌥ or ⌃. Esc cancels."
                     : "Works in any app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = hotKey.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Shortcut")
            }
            Section {
                TextEditor(text: $preferences)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 84)
                    .accessibilityLabel("Personal preferences")
                Text("What the model should know about you and how you like answers, such as your language, "
                     + "expertise or tone. Added to every chat, including agent chats, from your next message.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Personal Preferences")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}

private struct AgentSettings: View {
    @AppStorage(AgentMode.bypassKey, store: AgentMode.defaults) private var bypassesPermissions = false

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Bypass permissions", isOn: Binding(
                    get: { bypassesPermissions },
                    set: { bypassesPermissions = $0 ? AgentMode.confirmBypassing() : false }
                ))
                Text(bypassesPermissions
                     ? "New agent chats run every action without asking. They glow red."
                     : "New agent chats run in auto mode: Claude Code runs actions it judges safe and blocks risky ones. They glow blue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderSettings: View {
    let doctor: ProviderDoctor
    private var library: ModelLibrary { .shared }

    var body: some View {
        SettingsPane {
            ForEach(Backend.allCases) { backend in
                Section {
                    if backend != .claude {
                        Toggle("Use \(backend.displayName)", isOn: Binding(
                            get: { library.isEnabled(backend) },
                            set: { isOn in
                                library.setEnabled(backend, isOn)
                                if isOn { Task { await doctor.run() } }
                            }
                        ))
                    }
                    if library.isEnabled(backend) { checks(for: backend) }
                } header: {
                    Text(backend.displayName)
                }
            }
            Section {
                HStack {
                    Spacer()
                    if doctor.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check Again") { Task { await doctor.run() } }
                    }
                }
            }
        }
    }

    @ViewBuilder private func checks(for backend: Backend) -> some View {
        ForEach(doctor.reports[backend]?.checks ?? []) { check in
            LabeledContent {
                Text(check.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } label: {
                Label {
                    Text(check.title)
                } icon: {
                    Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                }
            }
        }
        if let fullReport = doctor.reports[backend]?.fullReport {
            DisclosureGroup("Full report") {
                ScrollView {
                    Text(fullReport)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }
        }
        if backend == .opencode { OpenCodeModelSettings() }
    }
}

private extension DoctorCheck.Status {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .failed: .red
        }
    }
}

/// Click, then press the new shortcut. Keys go to a local monitor while recording, so the
/// shortcut is captured instead of typed or run as a menu command.
private struct ShortcutRecorder: View {
    let settings: HotKeySettings
    @State private var monitor: Any?

    var body: some View {
        Button(settings.isRecording ? "Type Shortcut…" : settings.combo.displayString) {
            settings.isRecording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onDisappear { stop() }
    }

    private func start() {
        settings.startRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Escape), flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                stop()
            } else if let combo = HotKeyCombo(event: event) {
                removeMonitor()
                settings.record(combo)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        settings.cancelRecording()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
