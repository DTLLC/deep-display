import Foundation
import Observation

@Observable
@MainActor
final class AppController {
    let displayService: DisplayService
    let presetStore: PresetStore
    let settingsStore: SettingsStore
    let displayOverrideService: DisplayOverrideService
    let modeChangeCoordinator: ModeChangeCoordinator
    var selectedDisplayID: UInt32?

    private var displayObserverID: UUID?

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
        self.modeChangeCoordinator = modeChangeCoordinator

        self.displayService.synthesizeHiDPIForEligibleModes = settingsStore.settings.synthesizeHiDPIForEligibleModes
        self.displayService.start()
        self.displayObserverID = self.displayService.addObserver { [weak self] _ in
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
