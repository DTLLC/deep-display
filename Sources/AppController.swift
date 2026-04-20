import Foundation
import Observation

/// Owns long-lived app services and keeps selection state stable as displays
/// appear, disappear, or refresh.
@Observable
@MainActor
final class AppController {
    let displayService: DisplayService
    let settingsStore: SettingsStore
    let displayOverrideService: DisplayOverrideService
    let modeChangeCoordinator: ModeChangeCoordinator
    var selectedDisplayID: UInt32?

    init(
        displayService: DisplayService? = nil,
        settingsStore: SettingsStore? = nil,
        displayOverrideService: DisplayOverrideService? = nil
    ) {
        let displayService = displayService ?? DisplayService()
        let settingsStore = settingsStore ?? SettingsStore()
        let displayOverrideService = displayOverrideService ?? DisplayOverrideService()
        let modeChangeCoordinator = ModeChangeCoordinator(
            displayService: displayService,
            settingsStore: settingsStore,
            displayOverrideService: displayOverrideService
        )

        self.displayService = displayService
        self.settingsStore = settingsStore
        self.displayOverrideService = displayOverrideService
        self.modeChangeCoordinator = modeChangeCoordinator

        self.displayService.synthesizeHiDPIForEligibleModes = settingsStore.settings.synthesizeHiDPIForEligibleModes
        self.displayService.start()
        self.displayService.addObserver { [weak self] _ in
            self?.synchronizeSelectionIfNeeded()
        }
        synchronizeSelectionIfNeeded()
    }

    func refreshDisplays() {
        displayService.synthesizeHiDPIForEligibleModes = settingsStore.settings.synthesizeHiDPIForEligibleModes
        displayService.refreshDisplays()
        synchronizeSelectionIfNeeded()
    }

    var selectedDisplay: DisplaySnapshot? {
        guard let selectedDisplayID else { return displayService.displays.first }
        return displayService.displays.first(where: { $0.id == selectedDisplayID }) ?? displayService.displays.first
    }

    private func synchronizeSelectionIfNeeded() {
        let displayIDs = displayService.displays.map(\.id)
        guard !displayIDs.isEmpty else {
            selectedDisplayID = nil
            return
        }

        if let selectedDisplayID, displayIDs.contains(selectedDisplayID) {
            return
        }

        selectedDisplayID = displayIDs.first
    }
}
