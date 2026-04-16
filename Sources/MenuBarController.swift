import AppKit
import CoreGraphics

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let displayService: DisplayService
    private let presetStore: PresetStore
    private let settingsStore: SettingsStore
    private let modeChangeCoordinator: ModeChangeCoordinator
    private let onOpenSettings: () -> Void

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var displayObserverID: UUID?
    private var resolutionRowViews: [Int: ResolutionMenuRowView] = [:]

    init(
        displayService: DisplayService,
        presetStore: PresetStore,
        settingsStore: SettingsStore,
        modeChangeCoordinator: ModeChangeCoordinator,
        onOpenSettings: @escaping () -> Void
    ) {
        self.displayService = displayService
        self.presetStore = presetStore
        self.settingsStore = settingsStore
        self.modeChangeCoordinator = modeChangeCoordinator
        self.onOpenSettings = onOpenSettings
        super.init()

        statusItem.button?.title = "MacRes"
        statusItem.menu = menu
        menu.delegate = self

        displayObserverID = displayService.addObserver { [weak self] displays in
            self?.rebuildMenu(with: displays)
        }
    }

    private func rebuildMenu(with displays: [DisplaySnapshot]) {
        menu.removeAllItems()
        resolutionRowViews.removeAll()

        if displays.isEmpty {
            let item = NSMenuItem(title: "No active displays detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for display in displays {
                menu.addItem(makeDisplayHeaderItem(for: display))

                let visibleModes = display.availableModes.filter {
                    settingsStore.settings.showUnsafeModes || $0.isUsableForDesktopGUI
                }

                let groups = groupedModes(visibleModes)
                let selectedGroup = selectedGroup(in: groups, currentMode: display.currentMode)

                menu.addItem(makeSectionHeaderItem("Resolution"))
                for group in groups {
                    let item = makeResolutionItem(
                        group: group,
                        displayID: display.id,
                        isSelected: group.contains(display.currentMode)
                    )
                    menu.addItem(item)
                }

                let sortedRefreshModes = selectedGroup?.modes.sorted(by: refreshSort) ?? []
                let distinctRefreshModes = distinctRefreshModes(from: sortedRefreshModes)
                if distinctRefreshModes.count > 1 {
                    menu.addItem(.separator())
                    menu.addItem(makeSectionHeaderItem("Refresh Rate"))

                    for mode in distinctRefreshModes {
                        let item = NSMenuItem(
                            title: mode.refreshLabel,
                            action: #selector(applyDisplayMode(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.state = mode == display.currentMode ? .on : .off
                        item.representedObject = ModeSelection(displayID: display.id, mode: mode)
                        menu.addItem(item)
                    }
                }

                if !display.transportOptions.isEmpty {
                    menu.addItem(.separator())
                    menu.addItem(makeSectionHeaderItem("Range"))
                    for option in display.transportOptions {
                        let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                        item.state = option.isCurrent ? .on : .off
                        item.isEnabled = option.isUserSelectable
                        if let subtitle = option.subtitle {
                            item.toolTip = subtitle
                        }
                        menu.addItem(item)
                    }
                }
                menu.addItem(.separator())
            }
        }

        let savePresetItem = NSMenuItem(title: "Save Current Setup as Preset", action: #selector(savePreset), keyEquivalent: "")
        savePresetItem.target = self
        menu.addItem(savePresetItem)

        if !presetStore.presets.isEmpty {
            let presetsMenuItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            let presetsMenu = NSMenu()
            for preset in presetStore.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                presetsMenu.addItem(item)
            }
            presetsMenuItem.submenu = presetsMenu
            menu.addItem(presetsMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(title: "Refresh Displays", action: #selector(refreshDisplays), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit MacRes", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeDisplayHeaderItem(for display: DisplaySnapshot) -> NSMenuItem {
        let title: String
        if let currentMode = display.currentMode {
            title = "\(display.name)  (\(currentMode.summaryLabel))"
        } else {
            title = display.name
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeSectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func makeUnavailableItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeResolutionItem(
        group: ResolutionGroup,
        displayID: CGDirectDisplayID,
        isSelected: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: group.label, action: #selector(applyResolutionVariant(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ResolutionSelection(displayID: displayID, group: group)

        let rowView = ResolutionMenuRowView()
        rowView.configure(
            title: group.title,
            badges: group.badges,
            isSelected: isSelected,
            onSelect: { [weak self, weak item] in
                guard let self, let item else { return }
                self.applyResolutionVariant(item)
                item.menu?.cancelTracking()
            }
        )
        item.view = rowView
        resolutionRowViews[item.hash] = rowView
        return item
    }

    @objc
    private func applyResolutionVariant(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ResolutionSelection else { return }
        let targetMode = preferredMode(in: selection.group)
        modeChangeCoordinator.applyModeChange(displayID: selection.displayID, mode: targetMode)
    }

    @objc
    private func applyDisplayMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModeSelection else { return }
        modeChangeCoordinator.applyModeChange(displayID: selection.displayID, mode: selection.mode)
    }

    @objc
    private func savePreset() {
        presetStore.createPreset(named: "Preset \(presetStore.presets.count + 1)", from: displayService.displays)
        rebuildMenu(with: displayService.displays)
    }

    @objc
    private func applyPreset(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? UUID else { return }
        guard let preset = presetStore.presets.first(where: { $0.id == presetID }) else { return }
        modeChangeCoordinator.applyPreset(preset)
    }

    @objc
    private func openSettings() {
        onOpenSettings()
    }

    @objc
    private func refreshDisplays() {
        displayService.refreshDisplays()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func groupedModes(_ modes: [DisplayModeSnapshot]) -> [ResolutionGroup] {
        var groupsByKey: [ResolutionGroupKey: [DisplayModeSnapshot]] = [:]

        for mode in modes {
            let key = ResolutionGroupKey(
                width: mode.width,
                height: mode.height,
                isHiDPI: mode.isHiDPI,
                isLowResolution: mode.isLowResolution,
                isHiddenAlternative: mode.isHiddenAlternative ?? false,
                isInterlaced: mode.isInterlaced ?? false,
                isStretched: mode.isStretched ?? false
            )
            groupsByKey[key, default: []].append(mode)
        }

        return groupsByKey
            .map { ResolutionGroup(key: $0.key, modes: $0.value) }
            .sorted(by: resolutionGroupSort)
    }

    private func selectedGroup(in groups: [ResolutionGroup], currentMode: DisplayModeSnapshot?) -> ResolutionGroup? {
        guard let currentMode else { return groups.first }
        return groups.first { $0.contains(currentMode) } ?? groups.first
    }

    private func preferredMode(in group: ResolutionGroup) -> DisplayModeSnapshot {
        return group.modes.sorted(by: refreshSort).first ?? group.modes[0]
    }

    private func resolutionGroupSort(lhs: ResolutionGroup, rhs: ResolutionGroup) -> Bool {
        if lhs.key.width != rhs.key.width { return lhs.key.width > rhs.key.width }
        if lhs.key.height != rhs.key.height { return lhs.key.height > rhs.key.height }
        if lhs.key.isHiDPI != rhs.key.isHiDPI { return lhs.key.isHiDPI && !rhs.key.isHiDPI }
        return lhs.label < rhs.label
    }

    private func refreshSort(lhs: DisplayModeSnapshot, rhs: DisplayModeSnapshot) -> Bool {
        if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
        if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI && !rhs.isHiDPI }
        return lhs.id < rhs.id
    }

    private func distinctRefreshModes(from modes: [DisplayModeSnapshot]) -> [DisplayModeSnapshot] {
        var seen: Set<String> = []
        var distinct: [DisplayModeSnapshot] = []

        for mode in modes {
            let key = String(format: "%.2f", mode.refreshRate)
            if seen.insert(key).inserted {
                distinct.append(mode)
            }
        }

        return distinct
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            guard let view = resolutionRowViews[menuItem.hash] else { continue }
            view.setHighlighted(menuItem === item)
        }
    }
}

private struct ModeSelection {
    let displayID: CGDirectDisplayID
    let mode: DisplayModeSnapshot
}

private struct ResolutionSelection {
    let displayID: CGDirectDisplayID
    let group: ResolutionGroup
}

private struct ResolutionGroupKey: Hashable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let isLowResolution: Bool
    let isHiddenAlternative: Bool
    let isInterlaced: Bool
    let isStretched: Bool
}

private struct ResolutionGroup {
    let key: ResolutionGroupKey
    let modes: [DisplayModeSnapshot]

    var title: String {
        "\(key.width) x \(key.height)"
    }

    var label: String {
        modes.first?.resolutionVariantLabel ?? "\(key.width) x \(key.height)"
    }

    var badges: [String] {
        var values: [String] = []
        if key.isHiDPI {
            values.append("HiDPI")
        }
        if !key.label.isEmpty {
            values.append(key.label)
        }
        return values
    }

    func contains(_ mode: DisplayModeSnapshot?) -> Bool {
        guard let mode else { return false }
        return modes.contains(mode)
    }
}

private extension ResolutionGroupKey {
    var label: String {
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

@MainActor
private final class ResolutionMenuRowView: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgesStack = NSStackView()
    private var badgeViews: [BadgeView] = []
    private var onSelect: (() -> Void)?
    private var isSelected = false
    private var isRowHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .labelColor

        badgesStack.orientation = .horizontal
        badgesStack.alignment = .centerY
        badgesStack.spacing = 6

        let contentStack = NSStackView(views: [titleLabel, NSView(), badgesStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 28)
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, badges: [String], isSelected: Bool, onSelect: @escaping () -> Void) {
        titleLabel.stringValue = title
        self.isSelected = isSelected
        self.onSelect = onSelect

        for view in badgeViews {
            badgesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        badgeViews = badges.map(BadgeView.init(text:))
        for view in badgeViews {
            badgesStack.addArrangedSubview(view)
        }

        updateAppearance()
    }

    func setHighlighted(_ highlighted: Bool) {
        isRowHighlighted = highlighted
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        onSelect?()
    }

    private func updateAppearance() {
        let active = isRowHighlighted || isSelected
        layer?.cornerRadius = 6
        layer?.backgroundColor = active ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = active ? .selectedMenuItemTextColor : .labelColor
        for badge in badgeViews {
            badge.setHighlighted(active)
        }
    }
}

@MainActor
private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4

        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        setHighlighted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = (highlighted ? NSColor.white.withAlphaComponent(0.24) : NSColor.white.withAlphaComponent(0.18)).cgColor
        label.textColor = highlighted ? .selectedMenuItemTextColor : NSColor.white.withAlphaComponent(0.92)
    }
}
