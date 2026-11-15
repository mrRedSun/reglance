import ServiceManagement
import Testing
@testable import Reglance

@MainActor
private final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var enables = 0
    var disables = 0
    var fails = false

    enum Failure: Error { case denied }

    func enable() throws {
        enables += 1
        if fails { throw Failure.denied }
        status = .enabled
    }

    func disable() async throws {
        disables += 1
        if fails { throw Failure.denied }
        status = .notRegistered
    }
}

@MainActor
@Test func loginSettingUsesSystemStatusAndDoesNotRegisterOnLaunch() async {
    let service = FakeLoginItem()
    let settings = LoginSettings(service: service)
    #expect(!settings.isEnabled && service.enables == 0)
    await settings.setEnabled(true)
    #expect(settings.isEnabled && service.enables == 1)
    await settings.setEnabled(false)
    #expect(!settings.isEnabled && service.disables == 1)
    service.status = .requiresApproval
    settings.refresh()
    #expect(settings.isEnabled && settings.status == .requiresApproval)
    service.status = .notRegistered
    settings.refresh()
    #expect(!settings.isEnabled)
}

@MainActor
@Test func loginSettingReportsErrorsWithoutSavingAFakeEnabledState() async {
    let service = FakeLoginItem()
    let settings = LoginSettings(service: service)
    service.fails = true
    await settings.setEnabled(true)
    #expect(!settings.isEnabled)
    #expect(settings.error != nil)
    #expect(!settings.isUpdating)
    service.fails = false
    await settings.setEnabled(true)
    #expect(settings.isEnabled && settings.error == nil)
}
