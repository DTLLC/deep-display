import CoreGraphics
import Foundation

enum DisplayModeSource: String, Codable, Hashable {
    case publicAPI
    case legacyAPI
    case syntheticOverride
}

struct DisplaySnapshot: Identifiable, Codable, Equatable {
    let id: UInt32
    let name: String
    let isOnline: Bool
    let frame: DisplayFrame
    let currentMode: DisplayModeSnapshot?
    let availableModes: [DisplayModeSnapshot]
    let transportOptions: [DisplayTransportOption]

    var cgDirectDisplayID: CGDirectDisplayID {
        id
    }

    var selectionSyncToken: String {
        [
            String(id),
            currentMode?.id ?? "no-mode",
            availableModes.map(\.id).joined(separator: ","),
            transportOptions.map { "\($0.id):\($0.isCurrent)" }.joined(separator: ",")
        ].joined(separator: "|")
    }
}

struct DisplayTransportOption: Identifiable, Codable, Equatable {
    let title: String
    let subtitle: String?
    let isCurrent: Bool
    let isUserSelectable: Bool
    let modeDescriptor: String?

    var id: String {
        modeDescriptor ?? "\(title)|\(subtitle ?? "")|\(isUserSelectable)"
    }
}

struct DisplayFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

struct DisplayModeSnapshot: Identifiable, Codable, Equatable, Hashable {
    let width: Int
    let height: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let isLowResolution: Bool
    let isUsableForDesktopGUI: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let backingWidth: Int
    let backingHeight: Int
    let ioFlags: UInt32
    let ioDisplayModeID: Int32?
    let source: DisplayModeSource?
    let isSafeForHardware: Bool?
    let isStretched: Bool?
    let isInterlaced: Bool?
    let isHiddenAlternative: Bool?
    let requiresOverrideInstall: Bool

    func replacing(
        isHiDPI: Bool? = nil,
        isHiddenAlternative: Bool? = nil,
        source: DisplayModeSource? = nil,
        backingWidth: Int? = nil,
        backingHeight: Int? = nil,
        requiresOverrideInstall: Bool? = nil
    ) -> DisplayModeSnapshot {
        DisplayModeSnapshot(
            width: width,
            height: height,
            refreshRate: refreshRate,
            isHiDPI: isHiDPI ?? self.isHiDPI,
            isLowResolution: isLowResolution,
            isUsableForDesktopGUI: isUsableForDesktopGUI,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingWidth: backingWidth ?? self.backingWidth,
            backingHeight: backingHeight ?? self.backingHeight,
            ioFlags: ioFlags,
            ioDisplayModeID: ioDisplayModeID,
            source: source ?? self.source,
            isSafeForHardware: isSafeForHardware,
            isStretched: isStretched,
            isInterlaced: isInterlaced,
            isHiddenAlternative: isHiddenAlternative ?? self.isHiddenAlternative,
            requiresOverrideInstall: requiresOverrideInstall ?? self.requiresOverrideInstall
        )
    }

    var id: String {
        "\(width)x\(height)@\(refreshRate)-hidpi:\(isHiDPI)-low:\(isLowResolution)-gui:\(isUsableForDesktopGUI)-pixel:\(pixelWidth)x\(pixelHeight)-backing:\(backingWidth)x\(backingHeight)-flags:\(ioFlags)-mode:\(ioDisplayModeID ?? -1)-src:\(source?.rawValue ?? "unknown")-hidden:\(isHiddenAlternative ?? false)-override:\(requiresOverrideInstall)"
    }

    var resolutionLabel: String {
        "\(width) x \(height)"
    }

    var aspectRatioLabel: String {
        let divisor = gcd(width, height)
        guard divisor != 0 else { return "" }
        return "\(width / divisor):\(height / divisor)"
    }

    var backingResolutionLabel: String {
        "\(backingWidth) x \(backingHeight)"
    }

    var resolutionVariantLabel: String {
        var parts = [resolutionLabel]
        if let hidpiLabel {
            parts.append(hidpiLabel)
        }
        if isLowResolution {
            parts.append("Low Res")
        }
        if isHiddenAlternative == true {
            parts.append("Hidden")
        }
        if isInterlaced == true {
            parts.append("Interlaced")
        }
        if isStretched == true {
            parts.append("Stretched")
        }
        return parts.joined(separator: " • ")
    }

    var refreshLabel: String {
        if refreshRate == 0 {
            return "Unknown Hz"
        }

        return String(format: refreshRate.rounded(.toNearestOrAwayFromZero) == refreshRate ? "%.0f Hz" : "%.2f Hz", refreshRate)
    }

    var summaryLabel: String {
        var parts = [resolutionLabel, refreshLabel]
        if let hidpiLabel {
            parts.append(hidpiLabel)
        }
        if isLowResolution {
            parts.append("Low Res")
        }
        if isHiddenAlternative == true {
            parts.append("Hidden")
        }
        if isSafeForHardware == true && source == .legacyAPI {
            parts.append("Safe")
        }
        if isInterlaced == true {
            parts.append("Interlaced")
        }
        if isStretched == true {
            parts.append("Stretched")
        }
        return parts.joined(separator: " • ")
    }

    var hidpiLabel: String? {
        guard isHiDPI else { return nil }
        return isVirtualHiDPI ? "vHiDPI" : "HiDPI"
    }

    var isVirtualHiDPI: Bool {
        requiresOverrideInstall || source == .syntheticOverride
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

extension DisplayModeSnapshot {
    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case refreshRate
        case isHiDPI
        case isLowResolution
        case isUsableForDesktopGUI
        case pixelWidth
        case pixelHeight
        case backingWidth
        case backingHeight
        case ioFlags
        case ioDisplayModeID
        case source
        case isSafeForHardware
        case isStretched
        case isInterlaced
        case isHiddenAlternative
        case requiresOverrideInstall
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        let pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)

        self.init(
            width: width,
            height: height,
            refreshRate: try container.decode(Double.self, forKey: .refreshRate),
            isHiDPI: try container.decode(Bool.self, forKey: .isHiDPI),
            isLowResolution: try container.decode(Bool.self, forKey: .isLowResolution),
            isUsableForDesktopGUI: try container.decode(Bool.self, forKey: .isUsableForDesktopGUI),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingWidth: try container.decodeIfPresent(Int.self, forKey: .backingWidth) ?? pixelWidth,
            backingHeight: try container.decodeIfPresent(Int.self, forKey: .backingHeight) ?? pixelHeight,
            ioFlags: try container.decode(UInt32.self, forKey: .ioFlags),
            ioDisplayModeID: try container.decodeIfPresent(Int32.self, forKey: .ioDisplayModeID),
            source: try container.decodeIfPresent(DisplayModeSource.self, forKey: .source),
            isSafeForHardware: try container.decodeIfPresent(Bool.self, forKey: .isSafeForHardware),
            isStretched: try container.decodeIfPresent(Bool.self, forKey: .isStretched),
            isInterlaced: try container.decodeIfPresent(Bool.self, forKey: .isInterlaced),
            isHiddenAlternative: try container.decodeIfPresent(Bool.self, forKey: .isHiddenAlternative),
            requiresOverrideInstall: try container.decodeIfPresent(Bool.self, forKey: .requiresOverrideInstall) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(refreshRate, forKey: .refreshRate)
        try container.encode(isHiDPI, forKey: .isHiDPI)
        try container.encode(isLowResolution, forKey: .isLowResolution)
        try container.encode(isUsableForDesktopGUI, forKey: .isUsableForDesktopGUI)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(backingWidth, forKey: .backingWidth)
        try container.encode(backingHeight, forKey: .backingHeight)
        try container.encode(ioFlags, forKey: .ioFlags)
        try container.encodeIfPresent(ioDisplayModeID, forKey: .ioDisplayModeID)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(isSafeForHardware, forKey: .isSafeForHardware)
        try container.encodeIfPresent(isStretched, forKey: .isStretched)
        try container.encodeIfPresent(isInterlaced, forKey: .isInterlaced)
        try container.encodeIfPresent(isHiddenAlternative, forKey: .isHiddenAlternative)
        try container.encode(requiresOverrideInstall, forKey: .requiresOverrideInstall)
    }
}

struct DisplayConfiguration: Codable, Equatable {
    let displayID: UInt32
    let displayName: String
    let mode: DisplayModeSnapshot?
}

struct Preset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var configurations: [DisplayConfiguration]
    var fallbackConfigurations: [DisplayConfiguration]
}

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool
    var openHotkeyEnabled: Bool
    var autoRevertTimeout: TimeInterval
    var showUnsafeModes: Bool
    var synthesizeHiDPIForEligibleModes: Bool

    static let `default` = AppSettings(
        launchAtLogin: false,
        openHotkeyEnabled: false,
        autoRevertTimeout: 15,
        showUnsafeModes: true,
        synthesizeHiDPIForEligibleModes: true
    )
}
