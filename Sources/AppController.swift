import AppKit

@MainActor
final class AppController {
    let displayService: DisplayService
    let presetStore: PresetStore
    let settingsStore: SettingsStore
    let displayOverrideService: DisplayOverrideService
    let modeChangeCoordinator: ModeChangeCoordinator

    private let menuBarController: MenuBarController
    private let settingsWindowController: SettingsWindowController

    init(
        displayService: DisplayService? = nil,
        presetStore: PresetStore? = nil,
        settingsStore: SettingsStore? = nil,
        displayOverrideService: DisplayOverrideService? = nil
    ) {
        let displayService = displayService ?? DisplayService()
        let presetStore = presetStore ?? PresetStore()
        let settingsStore = settingsStore ?? SettingsStore()
        let displayOverrideService = displayOverrideService ?? DisplayOverrideService()
        let modeChangeCoordinator = ModeChangeCoordinator(
            displayService: displayService,
            presetStore: presetStore,
            settingsStore: settingsStore,
            displayOverrideService: displayOverrideService
        )
        self.displayService = displayService
        self.presetStore = presetStore
        self.settingsStore = settingsStore
        self.displayOverrideService = displayOverrideService
        self.displayService.synthesizeHiDPIForEligibleModes = settingsStore.settings.synthesizeHiDPIForEligibleModes
        self.modeChangeCoordinator = modeChangeCoordinator
        self.settingsWindowController = SettingsWindowController(
            displayService: displayService,
            presetStore: presetStore,
            settingsStore: settingsStore
        )
        self.menuBarController = MenuBarController(
            displayService: displayService,
            presetStore: presetStore,
            settingsStore: settingsStore,
            modeChangeCoordinator: modeChangeCoordinator,
            onOpenSettings: { [weak settingsWindowController] in
                settingsWindowController?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
        displayService.start()
    }
}
