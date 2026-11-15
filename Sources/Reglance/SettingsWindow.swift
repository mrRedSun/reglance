import AppKit
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

final class SettingsWindowController {
    private let settings = LoginSettings()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Reglance Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    func show() {
        settings.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct SettingsView: View {
    let settings: LoginSettings

    var body: some View {
        Form {
            Section {
                Toggle("Open Reglance at login", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { value in Task { await settings.setEnabled(value) } }
                ))
                .disabled(settings.isUpdating)
                Text("Keep the chat bar a shortcut away after you sign in to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.status == .requiresApproval {
                    Text("Allow Reglance in System Settings to finish enabling it.")
                        .font(.callout)
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = settings.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
