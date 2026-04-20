import SwiftUI

struct DeepDisplayMainView: View {
    let appController: AppController

    @Environment(\.openWindow) private var openWindow
    @State private var pendingSelection: PendingDisplaySelection?
    @State private var draftResetToken = 0

    var body: some View {
        @Bindable var modeChangeCoordinator = appController.modeChangeCoordinator

        VStack(spacing: 0) {
            if let pendingChange = modeChangeCoordinator.pendingChange {
                PendingChangeBanner(
                    pendingChange: pendingChange,
                    onKeepChanges: appController.modeChangeCoordinator.confirmPendingChange,
                    onRevertChanges: appController.modeChangeCoordinator.revertPendingChange
                )
            }

            if let message = modeChangeCoordinator.lastErrorMessage {
                MessageBanner(
                    title: "Action Failed",
                    message: message,
                    tint: Color.red.opacity(0.14),
                    dismiss: appController.modeChangeCoordinator.dismissError
                )
            }

            if let message = modeChangeCoordinator.lastOverrideInstallMessage {
                MessageBanner(
                    title: "Virtual Resolutions",
                    message: message,
                    tint: Color.accentColor.opacity(0.10),
                    dismiss: appController.modeChangeCoordinator.dismissOverrideInstallMessage
                )
            }

            if let pendingSelection,
               modeChangeCoordinator.pendingChange == nil {
                DraftChangeBanner(
                    pendingSelection: pendingSelection,
                    apply: { applyPendingSelection(pendingSelection) },
                    reloadDesktopSession: appController.modeChangeCoordinator.reloadDesktopSession,
                    dismiss: dismissPendingSelection
                )
            }

            NavigationSplitView {
                DisplaySidebar(appController: appController)
            } detail: {
                if let display = appController.selectedDisplay {
                    DisplayDetailView(
                        display: display,
                        settingsStore: appController.settingsStore,
                        modeChangeCoordinator: appController.modeChangeCoordinator,
                        displayOverrideService: appController.displayOverrideService,
                        resetToken: draftResetToken,
                        onDraftChange: handleDraftChange(_:)
                    )
                } else {
                    ContentUnavailableView(
                        "No Display Selected",
                        systemImage: "display",
                        description: Text("Choose a display from the sidebar.")
                    )
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Deep Display")
        .onChange(of: appController.selectedDisplayID) { _, _ in
            pendingSelection = nil
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh", action: appController.refreshDisplays)

                Button("Settings") {
                    openWindow(id: "settings")
                }

                Button("Virtual Resolutions") {
                    openWindow(id: "virtual-resolutions")
                }
            }
        }
    }

    private func applyPendingSelection(_ pendingSelection: PendingDisplaySelection) {
        switch pendingSelection.virtualStatus {
        case .notRequired:
            if let mode = pendingSelection.selectedMode,
               pendingSelection.hasModeChange {
                appController.modeChangeCoordinator.applyModeChange(
                    displayID: pendingSelection.displayID,
                    mode: mode
                )
            }

            if !pendingSelection.hasModeChange,
               pendingSelection.hasTransportChange,
               let transport = pendingSelection.selectedTransport {
                do {
                    try appController.displayService.switchTransportOption(transport, for: pendingSelection.displayID)
                } catch {
                    appController.modeChangeCoordinator.lastErrorMessage = "Unable to switch range: \(error.localizedDescription)"
                }
            }

            self.pendingSelection = nil

        case .notInstalled:
            if let mode = pendingSelection.selectedMode {
                appController.modeChangeCoordinator.applyModeChange(displayID: pendingSelection.displayID, mode: mode)
            }

        case .installedNeedsDesktopReload:
            appController.modeChangeCoordinator.lastOverrideInstallMessage = pendingSelection.bannerMessage
        }
    }

    private func dismissPendingSelection() {
        pendingSelection = nil
        draftResetToken += 1
    }

    private func handleDraftChange(_ draft: PendingDisplaySelection?) {
        // A new draft means the previous live change is now the accepted base
        // state, so stale keep/revert UI should disappear immediately.
        if draft != nil,
           appController.modeChangeCoordinator.pendingChange != nil {
            appController.modeChangeCoordinator.confirmPendingChange()
        }
        pendingSelection = draft
    }
}

struct WorkspaceSettingsWindowView: View {
    let appController: AppController

    var body: some View {
        Form {
            Section("Display Filtering") {
                Toggle(
                    "Show unsafe or non-GUI modes",
                    isOn: Binding(
                        get: { appController.settingsStore.settings.showUnsafeModes },
                        set: { newValue in
                            appController.settingsStore.update { $0.showUnsafeModes = newValue }
                        }
                    )
                )

                Toggle(
                    "Synthesize virtual HiDPI candidates",
                    isOn: Binding(
                        get: { appController.settingsStore.settings.synthesizeHiDPIForEligibleModes },
                        set: { newValue in
                            appController.settingsStore.update { $0.synthesizeHiDPIForEligibleModes = newValue }
                            appController.refreshDisplays()
                        }
                    )
                )
            }

            Section("Safety") {
                LabeledContent("Auto-revert timeout") {
                    Text("\(Int(appController.settingsStore.settings.autoRevertTimeout)) seconds")
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { appController.settingsStore.settings.autoRevertTimeout },
                        set: { newValue in
                            appController.settingsStore.update { $0.autoRevertTimeout = newValue.rounded() }
                        }
                    ),
                    in: 5...60,
                    step: 1
                )
            }

            Section("Workspace") {
                LabeledContent("Displays") {
                    Text("\(appController.displayService.displays.count)")
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct VirtualResolutionWindowView: View {
    let appController: AppController

    var body: some View {
        Group {
            if let display = appController.selectedDisplay {
                let installationState = appController.displayOverrideService.installationState(for: display)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(display.name)
                            .font(.title2.weight(.semibold))

                        Text(virtualResolutionDescription(for: installationState))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            SummaryChip(title: "Display", value: "\(display.id)")
                            SummaryChip(title: "vHiDPI Modes", value: "\(installableModeCount(for: display))")
                            SummaryChip(title: "Status", value: installationStatusLabel(for: installationState))
                        }

                        HStack(spacing: 12) {
                            switch installationState {
                            case .unavailable:
                                Button("No Virtual Resolutions Available") {}
                                    .buttonStyle(.bordered)
                                    .disabled(true)

                            case .notInstalled:
                                Button("Install Virtual Resolutions") {
                                    appController.modeChangeCoordinator.installVirtualResolutions(displayID: display.id)
                                }
                                .buttonStyle(.borderedProminent)

                            case .installed:
                                Button("Uninstall Virtual Resolutions") {
                                    appController.modeChangeCoordinator.resetVirtualResolutions(displayID: display.id)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Button("Reload Desktop Session") {
                                appController.modeChangeCoordinator.reloadDesktopSession()
                            }
                            .buttonStyle(.bordered)
                        }

                        if installableModeCount(for: display) > 0 {
                            GroupBox("Generated vHiDPI Modes") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(display.availableModes.filter { $0.requiresOverrideInstall && $0.isHiDPI }.prefix(12)) { mode in
                                        Text(mode.summaryLabel)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "No Display Selected",
                    systemImage: "display",
                    description: Text("Select a display in main window, then open Virtual Resolutions.")
                )
            }
        }
    }

    private func installableModeCount(for display: DisplaySnapshot) -> Int {
        display.availableModes.filter { $0.requiresOverrideInstall && $0.isHiDPI }.count
    }

    private func installationStatusLabel(for state: VirtualResolutionInstallationState) -> String {
        switch state {
        case .unavailable:
            return "Unavailable"
        case .notInstalled:
            return "Not Installed"
        case .installed:
            return "Installed"
        }
    }

    private func virtualResolutionDescription(for state: VirtualResolutionInstallationState) -> String {
        switch state {
        case .unavailable:
            return "This display does not currently have generated vHiDPI entries to install."
        case .notInstalled:
            return "Virtual resolutions are currently not installed for this display. Install them before trying to use vHiDPI modes after a restart or reconnect."
        case .installed:
            return "Virtual resolutions are installed for this display. You can uninstall them if you want to remove the generated vHiDPI entries, and log out or reconnect the display when macOS needs to reload overrides."
        }
    }
}

private struct DisplaySidebar: View {
    let appController: AppController

    var body: some View {
        List(selection: selection) {
            ForEach(appController.displayService.displays) { display in
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.name)
                        .font(.body.weight(.medium))
                    Text(display.currentMode?.summaryLabel ?? "No active mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(Optional(display.id))
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<UInt32?> {
        Binding(
            get: { appController.selectedDisplayID },
            set: { appController.selectedDisplayID = $0 }
        )
    }
}

private struct DisplayDetailView: View {
    let display: DisplaySnapshot
    let settingsStore: SettingsStore
    let modeChangeCoordinator: ModeChangeCoordinator
    let displayOverrideService: DisplayOverrideService
    let resetToken: Int
    let onDraftChange: (PendingDisplaySelection?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisplayHeaderView(display: display)
                DisplayControlCard(
                    display: display,
                    settingsStore: settingsStore,
                    modeChangeCoordinator: modeChangeCoordinator,
                    displayOverrideService: displayOverrideService,
                    onDraftChange: onDraftChange
                )
                .id("\(display.selectionSyncToken)|reset:\(resetToken)")
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }
}

private struct DisplayHeaderView: View {
    let display: DisplaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(display.name)
                .font(.largeTitle.weight(.semibold))

            Text("Current mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(display.currentMode?.summaryLabel ?? "Unknown")
                .font(.title3.weight(.medium))

            HStack(spacing: 12) {
                SummaryChip(title: "Display ID", value: "\(display.id)")
                SummaryChip(title: "Native Frame", value: "\(Int(display.frame.width)) × \(Int(display.frame.height))")
                SummaryChip(title: "Status", value: display.isOnline ? "Online" : "Offline")
            }
        }
    }
}

private struct DisplayControlCard: View {
    let display: DisplaySnapshot
    let settingsStore: SettingsStore
    let modeChangeCoordinator: ModeChangeCoordinator
    let displayOverrideService: DisplayOverrideService
    let onDraftChange: (PendingDisplaySelection?) -> Void

    @State private var selectedResolutionID: ResolutionOptionKey?
    @State private var hiDPIEnabled = true
    @State private var selectedRefreshModeID = ""
    @State private var selectedTransportID = ""

    private var visibleModes: [DisplayModeSnapshot] {
        display.availableModes.filter {
            settingsStore.settings.showUnsafeModes || $0.isUsableForDesktopGUI
        }
    }

    private var resolutionOptions: [ResolutionOption] {
        makeResolutionOptions(from: visibleModes)
    }

    private var selectedResolution: ResolutionOption? {
        resolutionOptions.first(where: { $0.id == selectedResolutionID }) ?? resolutionOptions.first
    }

    private var refreshOptions: [DisplayModeSnapshot] {
        guard let selectedResolution else { return [] }
        return modesForHiDPISelection(selectedResolution.modes, hiDPIEnabled: hiDPIEnabled)
            .sorted(by: refreshSort)
    }

    private var selectedMode: DisplayModeSnapshot? {
        refreshOptions.first(where: { $0.id == selectedRefreshModeID }) ?? refreshOptions.first
    }

    private var selectedTransportOption: DisplayTransportOption? {
        display.transportOptions.first(where: { $0.id == selectedTransportID }) ?? display.transportOptions.first
    }

    private var currentTransportOption: DisplayTransportOption? {
        display.transportOptions.first(where: \.isCurrent) ?? display.transportOptions.first
    }

    private var hasModeChange: Bool {
        selectedMode != display.currentMode
    }

    private var hasTransportChange: Bool {
        selectedTransportOption?.id != currentTransportOption?.id
    }

    private var isResolutionCurrent: Bool {
        selectedResolution?.contains(display.currentMode) == true
    }

    private var isHiDPICurrent: Bool {
        hiDPIEnabled == (display.currentMode?.isHiDPI ?? true)
    }

    private var isRefreshCurrent: Bool {
        selectedMode.map(refreshMatchesCurrent(_:)) ?? false
    }

    private var isTransportCurrent: Bool {
        selectedTransportOption?.id == currentTransportOption?.id
    }

    private var hasResolutionChange: Bool {
        !isResolutionCurrent || !isHiDPICurrent
    }

    private var hasRefreshChange: Bool {
        !isRefreshCurrent
    }

    private var hasRangeChange: Bool {
        !isTransportCurrent
    }

    private var pendingSelection: PendingDisplaySelection? {
        let draft = PendingDisplaySelection(
            displayID: display.id,
            displayName: display.name,
            selectedMode: selectedMode,
            currentMode: display.currentMode,
            selectedTransport: selectedTransportOption,
            currentTransport: currentTransportOption,
            virtualStatus: displayOverrideService.activationStatus(for: display, requestedMode: selectedMode)
        )

        return draft.hasChanges ? draft : nil
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                ControlRow("Resolution", highlighted: hasResolutionChange) {
                    HStack(spacing: 16) {
                        Picker("Resolution", selection: resolutionSelection) {
                            ForEach(resolutionOptions) { option in
                                Text(option.title)
                                    .tag(Optional(option.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280, alignment: .leading)

                        Text(hiDPIToggleLabel)
                            .fontWeight(isHiDPICurrent ? .regular : .bold)
                            .foregroundStyle(
                                selectedResolutionSupportsHiDPI
                                ? (isHiDPICurrent ? Color.primary : Color.accentColor)
                                : Color.secondary
                            )

                        Toggle(hiDPIToggleLabel, isOn: hiDPISelection)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!selectedResolutionSupportsHiDPI)
                    }
                }

                ControlRow("Refresh Rate", highlighted: hasRefreshChange) {
                    Picker("Refresh Rate", selection: refreshSelection) {
                        ForEach(refreshOptions) { mode in
                            Text(refreshMenuLabel(for: mode))
                                .tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                ControlRow("Range", highlighted: hasRangeChange) {
                    Picker("Range", selection: transportSelection) {
                        ForEach(display.transportOptions) { option in
                            Text(transportMenuLabel(for: option))
                                .tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 330, alignment: .leading)
                    .disabled(display.transportOptions.isEmpty || hasModeChange)
                }

                HStack(spacing: 12) {
                    SummaryChip(title: "Backing", value: selectedMode?.backingResolutionLabel ?? "Unknown")
                    SummaryChip(title: "Aspect", value: selectedMode?.aspectRatioLabel ?? "Unknown")
                    SummaryChip(title: "Scale", value: selectedMode?.hidpiLabel ?? "Standard")
                }

                Text(transportDetailText(for: selectedTransportOption))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasModeChange {
                    Text("Apply the resolution change first, then range will refresh from the live display mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Text("Display Controls")
                .font(.headline)
        }
        .onAppear {
            synchronizeSelections()
            publishDraftState()
        }
    }

    private var selectedResolutionSupportsHiDPI: Bool {
        selectedResolution?.modes.contains(where: \.isHiDPI) == true
    }

    private func refreshMenuLabel(for mode: DisplayModeSnapshot) -> String {
        var parts = [mode.refreshLabel]
        if let hidpiLabel = mode.hidpiLabel {
            parts.append(hidpiLabel)
        }
        return parts.joined(separator: " • ")
    }

    private func transportMenuLabel(for option: DisplayTransportOption) -> String {
        option.title
    }

    private func transportDetailText(for option: DisplayTransportOption?) -> String {
        guard let option else { return "Current transport profile for this resolution." }
        if option.isCurrent {
            return "Current transport profile for this resolution."
        }
        return "Applies this exact transport profile variant at the current resolution."
    }

    private func refreshMatchesCurrent(_ mode: DisplayModeSnapshot) -> Bool {
        guard let currentMode = display.currentMode else { return false }
        return abs(mode.refreshRate - currentMode.refreshRate) < 0.01
    }

    private func preferredRefreshModeID(preferredRate: Double?) -> String {
        if let preferredRate,
           let matchingMode = refreshOptions.first(where: { abs($0.refreshRate - preferredRate) < 0.01 }) {
            return matchingMode.id
        }

        if let selectedRefresh = refreshOptions.first(where: { $0.id == selectedRefreshModeID }) {
            return selectedRefresh.id
        }

        return refreshOptions.first?.id ?? ""
    }

    private var resolutionSelection: Binding<ResolutionOptionKey?> {
        Binding(
            get: { selectedResolutionID },
            set: { newValue in
                let preferredRefreshRate = selectedMode?.refreshRate ?? display.currentMode?.refreshRate
                selectedResolutionID = newValue
                if selectedResolutionSupportsHiDPI {
                    hiDPIEnabled = true
                }
                selectedRefreshModeID = preferredRefreshModeID(preferredRate: preferredRefreshRate)
                publishDraftState()
            }
        )
    }

    private var hiDPISelection: Binding<Bool> {
        Binding(
            get: { hiDPIEnabled },
            set: { newValue in
                let preferredRefreshRate = selectedMode?.refreshRate ?? display.currentMode?.refreshRate
                hiDPIEnabled = newValue
                selectedRefreshModeID = preferredRefreshModeID(preferredRate: preferredRefreshRate)
                publishDraftState()
            }
        )
    }

    private var refreshSelection: Binding<String> {
        Binding(
            get: { selectedRefreshModeID },
            set: { newValue in
                selectedRefreshModeID = newValue
                publishDraftState()
            }
        )
    }

    private var transportSelection: Binding<String> {
        Binding(
            get: { selectedTransportID },
            set: { newValue in
                selectedTransportID = newValue
                publishDraftState()
            }
        )
    }

    private func synchronizeSelections() {
        let currentMode = display.currentMode
        selectedResolutionID = resolutionOptions.first(where: { $0.contains(currentMode) })?.id ?? resolutionOptions.first?.id
        hiDPIEnabled = currentMode?.isHiDPI ?? true
        selectedRefreshModeID = refreshOptions.first(where: { $0 == currentMode })?.id ?? refreshOptions.first?.id ?? ""
        selectedTransportID = display.transportOptions.first(where: \.isCurrent)?.id ?? display.transportOptions.first?.id ?? ""
        if currentMode?.requiresOverrideInstall != true {
            modeChangeCoordinator.dismissOverrideInstallMessage()
        }
    }

    private var hiDPIToggleLabel: String {
        guard let selectedResolution else { return "HiDPI" }
        return selectedResolution.hiDPILabel
    }

    private func publishDraftState() {
        onDraftChange(pendingSelection)
    }
}

private struct DraftChangeBanner: View {
    let pendingSelection: PendingDisplaySelection
    let apply: () -> Void
    let reloadDesktopSession: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pendingSelection.bannerTitle)
                    .font(.headline)
                Text(pendingSelection.bannerMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            switch pendingSelection.virtualStatus {
            case .notRequired:
                Button("Apply Changes", action: apply)
                    .buttonStyle(.borderedProminent)

            case .notInstalled:
                Button("Install Virtual Profile", action: apply)
                    .buttonStyle(.borderedProminent)

            case .installedNeedsDesktopReload:
                Button("Reload Desktop Session", action: reloadDesktopSession)
                    .buttonStyle(.borderedProminent)
            }

            Button("Dismiss", action: dismiss)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(pendingSelection.bannerTint)
    }
}

private struct PendingChangeBanner: View {
    let pendingChange: PendingChangeState
    let onKeepChanges: () -> Void
    let onRevertChanges: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep these display changes?")
                    .font(.headline)
                Text("\(pendingChange.summary) • Reverting in \(pendingChange.secondsRemaining)s")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Revert Now", action: onRevertChanges)
                .buttonStyle(.bordered)
            Button("Keep Changes", action: onKeepChanges)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.orange.opacity(0.15))
    }
}

private struct MessageBanner: View {
    let title: String
    let message: String
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Dismiss", action: dismiss)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(tint)
    }
}

private struct SummaryChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ControlRow<Content: View>: View {
    let title: String
    let highlighted: Bool
    @ViewBuilder let content: Content

    init(_ title: String, highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .fontWeight(highlighted ? .bold : .regular)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
                .frame(width: 120, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct PendingDisplaySelection: Equatable {
    let displayID: UInt32
    let displayName: String
    let selectedMode: DisplayModeSnapshot?
    let currentMode: DisplayModeSnapshot?
    let selectedTransport: DisplayTransportOption?
    let currentTransport: DisplayTransportOption?
    let virtualStatus: VirtualResolutionActivationStatus

    var hasModeChange: Bool {
        selectedMode != currentMode
    }

    var hasTransportChange: Bool {
        selectedTransport?.id != currentTransport?.id
    }

    var hasChanges: Bool {
        hasModeChange || hasTransportChange
    }

    var bannerTitle: String {
        switch virtualStatus {
        case .notRequired:
            return "Apply Pending Changes"
        case .notInstalled:
            return "Virtual Profile Needed"
        case .installedNeedsDesktopReload:
            return "Virtual Profile Installed"
        }
    }

    var bannerMessage: String {
        switch virtualStatus {
        case .notRequired:
            var parts: [String] = []
            if hasModeChange, let selectedMode {
                parts.append("Mode: \(selectedMode.summaryLabel)")
            }
            if hasTransportChange, let selectedTransport {
                parts.append("Range: \(selectedTransport.title)")
            }
            return parts.joined(separator: "\n")

        case .notInstalled:
            if let selectedMode {
                return """
                \(selectedMode.summaryLabel) is a virtual profile for \(displayName).
                It is not installed yet, so macOS cannot apply it directly. Install the profile first.
                """
            }
            return "Selected virtual profile is not installed yet."

        case .installedNeedsDesktopReload(let installedURL):
            return """
            Virtual profile already installed for \(displayName), but macOS is not using it yet.
            WindowServer must reload display overrides. Reconnect the display or log out and back in.
            Override file: \(installedURL.path)
            """
        }
    }

    var bannerTint: Color {
        switch virtualStatus {
        case .notRequired:
            return Color.accentColor.opacity(0.10)
        case .notInstalled:
            return Color.orange.opacity(0.15)
        case .installedNeedsDesktopReload:
            return Color.yellow.opacity(0.14)
        }
    }
}

private struct ResolutionOption: Identifiable {
    let key: ResolutionOptionKey
    let modes: [DisplayModeSnapshot]

    var id: ResolutionOptionKey {
        key
    }

    var title: String {
        "\(key.width) × \(key.height) • \(key.aspectRatioLabel)"
    }

    var hiDPILabel: String {
        let hiDPIModes = modes.filter(\.isHiDPI)
        guard !hiDPIModes.isEmpty else { return "HiDPI" }

        if hiDPIModes.contains(where: \.isVirtualHiDPI) {
            return "vHiDPI"
        }

        if modes.contains(where: \.isHiDPI) && modes.contains(where: { !$0.isHiDPI }) {
            return "vHiDPI"
        }

        return "HiDPI"
    }

    func contains(_ mode: DisplayModeSnapshot?) -> Bool {
        guard let mode else { return false }
        return modes.contains(mode)
    }
}

private struct ResolutionOptionKey: Hashable {
    let width: Int
    let height: Int

    var aspectRatioLabel: String {
        let divisor = gcd(width, height)
        guard divisor != 0 else { return "" }
        return "\(width / divisor):\(height / divisor)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return x
    }
}

private func makeResolutionOptions(from modes: [DisplayModeSnapshot]) -> [ResolutionOption] {
    var groupsByKey: [ResolutionOptionKey: [DisplayModeSnapshot]] = [:]

    for mode in modes {
        let key = ResolutionOptionKey(width: mode.width, height: mode.height)
        groupsByKey[key, default: []].append(mode)
    }

    return groupsByKey
        .map { ResolutionOption(key: $0.key, modes: $0.value) }
        .sorted(by: resolutionOptionSort)
}

private func resolutionOptionSort(lhs: ResolutionOption, rhs: ResolutionOption) -> Bool {
    if lhs.key.width != rhs.key.width { return lhs.key.width > rhs.key.width }
    if lhs.key.height != rhs.key.height { return lhs.key.height > rhs.key.height }
    return lhs.title < rhs.title
}

private func modesForHiDPISelection(_ modes: [DisplayModeSnapshot], hiDPIEnabled: Bool) -> [DisplayModeSnapshot] {
    let preferred = modes.filter { hiDPIEnabled ? $0.isHiDPI : !$0.isHiDPI }
    return preferred.isEmpty ? modes : preferred
}

private func refreshSort(lhs: DisplayModeSnapshot, rhs: DisplayModeSnapshot) -> Bool {
    if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
    if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI && !rhs.isHiDPI }
    if lhs.isVirtualHiDPI != rhs.isVirtualHiDPI { return !lhs.isVirtualHiDPI && rhs.isVirtualHiDPI }
    return lhs.id < rhs.id
}
