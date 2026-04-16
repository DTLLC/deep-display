import AppKit
import CoreGraphics
import Foundation

@MainActor
final class ModeChangeCoordinator {
    private let displayService: DisplayService
    private let presetStore: PresetStore
    private let settingsStore: SettingsStore
    private let displayOverrideService: DisplayOverrideService

    private var confirmationController: ModeConfirmationWindowController?
    private var countdownTimer: Timer?
    private var pendingChange: PendingChange?

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
                presentOverrideInstalled(for: display, result: result, mode: mode)
            } catch {
                presentError(title: "Unable to install HiDPI override", error: error)
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
            presentError(title: "Unable to switch display mode", error: error)
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
            presentError(title: "Unable to apply preset", error: error)
        }
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
        let confirmationController = ModeConfirmationWindowController(
            summary: summary,
            secondsRemaining: timeout
        )

        confirmationController.onKeepChanges = { [weak self] in
            self?.confirmPendingChange()
        }
        confirmationController.onRevertChanges = { [weak self] in
            self?.revertPendingChange()
        }

        self.confirmationController = confirmationController
        self.pendingChange = PendingChange(
            fallbacks: fallbacks,
            secondsRemaining: timeout
        )

        confirmationController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

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
        confirmationController?.update(secondsRemaining: pendingChange.secondsRemaining)

        if pendingChange.secondsRemaining <= 0 {
            revertPendingChange()
        }
    }

    private func confirmPendingChange() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        pendingChange = nil
        confirmationController?.close()
        confirmationController = nil
    }

    private func revertPendingChange() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        if let pendingChange {
            try? revert(configurations: pendingChange.fallbacks)
        }

        pendingChange = nil
        confirmationController?.close()
        confirmationController = nil
    }

    private func revert(configurations: some Sequence<DisplayConfiguration>) throws {
        for configuration in configurations {
            guard let mode = configuration.mode else { continue }
            try? displayService.switchMode(mode, for: configuration.displayID)
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func presentOverrideInstalled(
        for display: DisplaySnapshot,
        result: DisplayOverrideInstallResult,
        mode: DisplayModeSnapshot
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = result.didInstall
            ? "Installed HiDPI override for \(display.name)"
            : "HiDPI override already installed for \(display.name)"
        alert.informativeText = """
        Logical mode: \(mode.resolutionLabel) HiDPI
        Virtual backing: \(mode.backingResolutionLabel)

        The override file is at:
        \(result.installedURL.path)

        Unplug and reconnect the display, or log out / restart, so WindowServer reloads the override. Then reopen MacRes and select the real HiDPI mode from the main Resolution list.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct PendingChange {
    let fallbacks: [DisplayConfiguration]
    var secondsRemaining: Int
}

@MainActor
final class ModeConfirmationWindowController: NSWindowController {
    var onKeepChanges: (() -> Void)?
    var onRevertChanges: (() -> Void)?

    private let summary: String
    private let titleLabel = NSTextField(labelWithString: "Keep these display changes?")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")

    init(summary: String, secondsRemaining: Int) {
        self.summary = summary

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Confirm Display Change"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        summaryLabel.stringValue = summary
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.textColor = .secondaryLabelColor

        let keepButton = NSButton(title: "Keep Changes", target: self, action: #selector(keepChanges))
        keepButton.bezelStyle = .rounded

        let revertButton = NSButton(title: "Revert Now", target: self, action: #selector(revertChanges))
        revertButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [keepButton, revertButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let stack = NSStackView(views: [titleLabel, summaryLabel, countdownLabel, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])

        window.contentView = root
        update(secondsRemaining: secondsRemaining)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(secondsRemaining: Int) {
        countdownLabel.stringValue = "Auto-revert in \(max(0, secondsRemaining)) seconds."
    }

    @objc
    private func keepChanges() {
        onKeepChanges?()
    }

    @objc
    private func revertChanges() {
        onRevertChanges?()
    }
}
