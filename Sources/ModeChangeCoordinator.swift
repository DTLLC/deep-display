import AppKit
import CoreGraphics
import Foundation
import Observation

/// Coordinates user-triggered display changes, including timed confirmation,
/// fallback restoration, and virtual-resolution helper flows.
@Observable
@MainActor
final class ModeChangeCoordinator {
    private let displayService: DisplayService
    private let presetStore: PresetStore
    private let settingsStore: SettingsStore
    private let displayOverrideService: DisplayOverrideService

    var pendingChange: PendingChangeState?
    var lastErrorMessage: String?
    var lastOverrideInstallMessage: String?

    private var countdownTimer: Timer?

    init(
        displayService: DisplayService,
        presetStore: PresetStore,
        settingsStore: SettingsStore,
        displayOverrideService: DisplayOverrideService
    ) {
        self.displayService = displayService
        self.presetStore = presetStore
        self.settingsStore = settingsStore
        self.displayOverrideService = displayOverrideService
    }

    func applyModeChange(displayID: CGDirectDisplayID, mode: DisplayModeSnapshot) {
        guard let display = displayService.snapshot(for: displayID) else { return }

        if mode.requiresOverrideInstall {
            do {
                let result = try displayOverrideService.installHiDPIOverride(for: display, requestedMode: mode)
                lastOverrideInstallMessage = overrideInstallMessage(for: display, result: result, mode: mode)
            } catch {
                lastErrorMessage = "Unable to install HiDPI override: \(error.localizedDescription)"
            }
            return
        }

        guard display.currentMode != mode else { return }

        let target = DisplayConfiguration(displayID: displayID, displayName: display.name, mode: mode)
        let fallback = DisplayConfiguration(displayID: displayID, displayName: display.name, mode: display.currentMode)

        do {
            try performChange(
                summary: "Confirm new display mode for \(display.name)",
                targets: [target],
                fallbacks: [fallback]
            )
        } catch {
            lastErrorMessage = "Unable to switch display mode: \(error.localizedDescription)"
        }
    }

    func applyPreset(_ preset: Preset) {
        let currentDisplays = displayService.displays
        let fallbacks = currentDisplays.map {
            DisplayConfiguration(displayID: $0.id, displayName: $0.name, mode: $0.currentMode)
        }

        do {
            try presetStore.updatePreset(id: preset.id) { storedPreset in
                storedPreset.updatedAt = Date()
                storedPreset.fallbackConfigurations = fallbacks
            }

            try performChange(
                summary: "Confirm preset \(preset.name)",
                targets: preset.configurations,
                fallbacks: fallbacks
            )
        } catch {
            lastErrorMessage = "Unable to apply preset: \(error.localizedDescription)"
        }
    }

    func installVirtualResolutions(displayID: CGDirectDisplayID) {
        guard let display = displayService.snapshot(for: displayID) else { return }

        do {
            let result = try displayOverrideService.installAllVirtualResolutions(for: display)
            lastOverrideInstallMessage = """
            \(result.didInstall ? "Installed" : "Already installed") virtual resolutions for \(display.name).

            Added \(result.installedModeCount) vHiDPI entries.
            Override file: \(result.installedURL.path)

            No full machine reboot needed. Unplug and reconnect display, or log out to reload desktop session.
            """
        } catch {
            lastErrorMessage = "Unable to install virtual resolutions: \(error.localizedDescription)"
        }
    }

    func resetVirtualResolutions(displayID: CGDirectDisplayID) {
        guard let display = displayService.snapshot(for: displayID) else { return }

        do {
            let removedURL = try displayOverrideService.resetVirtualResolutions(for: display)
            lastOverrideInstallMessage = removedURL.map {
                """
                Reset virtual resolutions for \(display.name).

                Removed override: \($0.path)

                Log out or reconnect display to make WindowServer reload display modes.
                """
            } ?? """
            No installed virtual-resolution override found for \(display.name).
            """
        } catch {
            lastErrorMessage = "Unable to reset virtual resolutions: \(error.localizedDescription)"
        }
    }

    func reloadDesktopSession() {
        do {
            try displayOverrideService.reloadDesktopSession()
        } catch {
            lastErrorMessage = "Unable to reload desktop session: \(error.localizedDescription)"
        }
    }

    func confirmPendingChange() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        pendingChange = nil
    }

    func revertPendingChange() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        if let pendingChange {
            try? revert(configurations: pendingChange.fallbacks)
        }

        self.pendingChange = nil
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func dismissOverrideInstallMessage() {
        lastOverrideInstallMessage = nil
    }

    private func performChange(
        summary: String,
        targets: [DisplayConfiguration],
        fallbacks: [DisplayConfiguration]
    ) throws {
        if pendingChange != nil {
            revertPendingChange()
        }

        let appliedFallbacks = try applyConfigurations(targets, fallbackSource: fallbacks)
        startConfirmation(summary: summary, fallbacks: appliedFallbacks)
    }

    private func applyConfigurations(
        _ configurations: [DisplayConfiguration],
        fallbackSource: [DisplayConfiguration]
    ) throws -> [DisplayConfiguration] {
        var appliedFallbacks: [DisplayConfiguration] = []

        for configuration in configurations {
            guard let mode = configuration.mode else { continue }
            guard let currentDisplay = displayService.snapshot(for: configuration.displayID) else { continue }
            guard currentDisplay.currentMode != mode else { continue }

            let fallback = fallbackSource.first { $0.displayID == configuration.displayID }
                ?? DisplayConfiguration(
                    displayID: configuration.displayID,
                    displayName: currentDisplay.name,
                    mode: currentDisplay.currentMode
                )

            do {
                try displayService.switchMode(mode, for: configuration.displayID)
                appliedFallbacks.append(fallback)
            } catch {
                try revert(configurations: appliedFallbacks.reversed())
                throw error
            }
        }

        return appliedFallbacks
    }

    private func startConfirmation(summary: String, fallbacks: [DisplayConfiguration]) {
        guard !fallbacks.isEmpty else { return }

        let timeout = max(5, Int(settingsStore.settings.autoRevertTimeout.rounded()))
        pendingChange = PendingChangeState(
            summary: summary,
            fallbacks: fallbacks,
            secondsRemaining: timeout
        )

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleCountdownTick()
            }
        }
    }

    private func handleCountdownTick() {
        guard var pendingChange else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }

        pendingChange.secondsRemaining -= 1
        self.pendingChange = pendingChange

        if pendingChange.secondsRemaining <= 0 {
            revertPendingChange()
        }
    }

    private func revert(configurations: some Sequence<DisplayConfiguration>) throws {
        for configuration in configurations {
            guard let mode = configuration.mode else { continue }
            try? displayService.switchMode(mode, for: configuration.displayID)
        }
    }

    private func overrideInstallMessage(
        for display: DisplaySnapshot,
        result: DisplayOverrideInstallResult,
        mode: DisplayModeSnapshot
    ) -> String {
        let status = result.didInstall
            ? "Installed HiDPI override for \(display.name)."
            : "HiDPI override was already installed for \(display.name)."

        return """
        \(status)

        Logical mode: \(mode.resolutionLabel) \(mode.hidpiLabel ?? "")
        Virtual backing: \(mode.backingResolutionLabel)
        Override file: \(result.installedURL.path)

        The virtual profile is installed, but macOS will not use it until WindowServer reloads display overrides. Reconnect the display or log out and back in, then reopen Deep Display and pick the real vHiDPI mode.
        """
    }
}

struct PendingChangeState {
    let summary: String
    let fallbacks: [DisplayConfiguration]
    var secondsRemaining: Int
}
