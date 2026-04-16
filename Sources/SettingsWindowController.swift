import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        displayService: DisplayService,
        presetStore: PresetStore,
        settingsStore: SettingsStore
    ) {
        let viewController = SettingsViewController(
            displayService: displayService,
            presetStore: presetStore,
            settingsStore: settingsStore
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Deep Display Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let displayService: DisplayService
    private let presetStore: PresetStore
    private let settingsStore: SettingsStore

    private let displaysTextView = NSTextView()
    private let presetsTextView = NSTextView()
    private var displayObserverID: UUID?

    init(
        displayService: DisplayService,
        presetStore: PresetStore,
        settingsStore: SettingsStore
    ) {
        self.displayService = displayService
        self.presetStore = presetStore
        self.settingsStore = settingsStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Deep Display")
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "Live display inventory, main-list mode switching, persisted presets, and override-backed HiDPI installation.")
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.textColor = .secondaryLabelColor

        let autoRevertLabel = NSTextField(labelWithString: "Auto-revert timeout")
        let autoRevertValue = NSTextField(labelWithString: "\(Int(settingsStore.settings.autoRevertTimeout)) seconds")

        let displaysHeader = NSTextField(labelWithString: "Displays")
        displaysHeader.font = .systemFont(ofSize: 16, weight: .semibold)

        let presetsHeader = NSTextField(labelWithString: "Presets")
        presetsHeader.font = .systemFont(ofSize: 16, weight: .semibold)

        configure(textView: displaysTextView)
        configure(textView: presetsTextView)

        let displaysScrollView = NSScrollView()
        displaysScrollView.documentView = displaysTextView
        displaysScrollView.hasVerticalScroller = true
        displaysScrollView.borderType = .bezelBorder

        let presetsScrollView = NSScrollView()
        presetsScrollView.documentView = presetsTextView
        presetsScrollView.hasVerticalScroller = true
        presetsScrollView.borderType = .bezelBorder

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            autoRevertLabel,
            autoRevertValue,
            displaysHeader,
            displaysScrollView,
            presetsHeader,
            presetsScrollView
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            displaysScrollView.heightAnchor.constraint(equalToConstant: 180),
            presetsScrollView.heightAnchor.constraint(equalToConstant: 100)
        ])

        self.view = root
        refreshContent()

        displayObserverID = displayService.addObserver { [weak self] _ in
            self?.refreshContent()
        }
    }

    private func configure(textView: NSTextView) {
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
    }

    private func refreshContent() {
        displaysTextView.string = displayService.displays
            .map { display in
                let modes = display.availableModes.prefix(12).map(\.summaryLabel).joined(separator: "\n  - ")
                let current = display.currentMode?.summaryLabel ?? "Unknown"
                return """
                \(display.name)
                ID: \(display.id)
                Frame: \(Int(display.frame.width)) x \(Int(display.frame.height))
                Current: \(current)
                Modes:
                  - \(modes)
                """
            }
            .joined(separator: "\n\n")

        presetsTextView.string = presetStore.presets.isEmpty
            ? "No presets saved yet."
            : presetStore.presets.map { "\($0.name) (\($0.configurations.count) displays)" }.joined(separator: "\n")
    }
}
