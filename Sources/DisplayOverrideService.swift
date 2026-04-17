import CoreGraphics
import Foundation

@MainActor
final class DisplayOverrideService {
    private let fileManager = FileManager.default
    private let stagingRoot: URL

    init() {
        stagingRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeepDisplay", isDirectory: true)
            .appendingPathComponent("Overrides", isDirectory: true)
    }

    func installHiDPIOverride(
        for display: DisplaySnapshot,
        requestedMode: DisplayModeSnapshot
    ) throws -> DisplayOverrideInstallResult {
        guard requestedMode.requiresOverrideInstall, requestedMode.isHiDPI else {
            throw DisplayOverrideError.modeDoesNotNeedOverride
        }

        return try installAllVirtualResolutions(for: display)
    }

    func installAllVirtualResolutions(for display: DisplaySnapshot) throws -> DisplayOverrideInstallResult {
        let descriptor = descriptor(for: display)
        let installableModes = display.availableModes
            .filter { $0.requiresOverrideInstall && $0.isHiDPI }
        guard !installableModes.isEmpty else {
            throw DisplayOverrideError.noInstallableHiDPIModes
        }

        let overrideDictionary = buildOverrideDictionary(
            for: descriptor,
            displayName: display.name,
            modes: installableModes
        )
        let stagedURL = try writeOverrideFile(dictionary: overrideDictionary, descriptor: descriptor)
        let installOutcome = try installStagedOverride(from: stagedURL, descriptor: descriptor)

        return DisplayOverrideInstallResult(
            stagedURL: stagedURL,
            installedURL: installOutcome.url,
            didInstall: installOutcome.didInstall,
            installedModeCount: installableModes.count
        )
    }

    func activationStatus(for display: DisplaySnapshot, requestedMode: DisplayModeSnapshot?) -> VirtualResolutionActivationStatus {
        guard let requestedMode, requestedMode.requiresOverrideInstall, requestedMode.isHiDPI else {
            return .notRequired
        }

        let descriptor = descriptor(for: display)
        if let installedURL = installedOverrideURL(for: descriptor) {
            return .installedNeedsDesktopReload(installedURL)
        }

        return .notInstalled
    }

    func resetVirtualResolutions(for display: DisplaySnapshot) throws -> URL? {
        let descriptor = descriptor(for: display)
        let installedURL = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
            .appendingPathComponent(descriptor.vendorDirectoryName, isDirectory: true)
            .appendingPathComponent(descriptor.productFileName, isDirectory: false)

        guard fileManager.fileExists(atPath: installedURL.path) else {
            return nil
        }

        let installDirectory = installedURL.deletingLastPathComponent().path
        let shellCommand = """
        set -e
        rm -f \(shellQuoted(installedURL.path))
        rmdir \(shellQuoted(installDirectory)) 2>/dev/null || true
        """

        try runPrivilegedShell(shellCommand)
        return installedURL
    }

    func reloadDesktopSession() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            #"tell application "System Events" to log out"#
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisplayOverrideError.desktopReloadFailed(message?.isEmpty == false ? message! : "macOS refused to log out the desktop session.")
        }
    }

    private func descriptor(for display: DisplaySnapshot) -> DisplayOverrideDescriptor {
        let vendorID = Int(CGDisplayVendorNumber(display.id))
        let productID = Int(CGDisplayModelNumber(display.id))
        let nativeWidth = display.availableModes.map(\.backingWidth).max() ?? Int(display.frame.width)
        let nativeHeight = display.availableModes.map(\.backingHeight).max() ?? Int(display.frame.height)
        let screenSize = CGDisplayScreenSize(display.id)

        return DisplayOverrideDescriptor(
            displayID: display.id,
            vendorID: vendorID,
            productID: productID,
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            screenWidthMillimeters: screenSize.width,
            screenHeightMillimeters: screenSize.height
        )
    }

    private func buildOverrideDictionary(
        for descriptor: DisplayOverrideDescriptor,
        displayName: String,
        modes: [DisplayModeSnapshot]
    ) -> [String: Any] {
        var dictionary = loadBaseOverrideDictionary(for: descriptor) ?? [:]
        dictionary["DisplayVendorID"] = descriptor.vendorID
        dictionary["DisplayProductID"] = descriptor.productID
        if dictionary["DisplayProductName"] == nil {
            dictionary["DisplayProductName"] = displayName
        }

        let sortedModes = modes.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.refreshRate > $1.refreshRate
        }

        var mergedEntries: [Data] = existingScaleResolutionEntries(from: dictionary)
        for mode in sortedModes {
            mergedEntries.append(encodeBackingScaleEntry(width: mode.backingWidth, height: mode.backingHeight))
            mergedEntries.append(encodeHiDPIEntry12(width: mode.width, height: mode.height))
            mergedEntries.append(encodeHiDPIEntry16(width: mode.width, height: mode.height, modeFlag: 1))
            mergedEntries.append(encodeHiDPIEntry16(width: mode.width, height: mode.height, modeFlag: 9))
        }
        dictionary["scale-resolutions"] = uniquedDataEntries(mergedEntries)

        if dictionary["target-default-ppmm"] == nil,
           descriptor.screenWidthMillimeters > 0,
           descriptor.nativeWidth > 0 {
            dictionary["target-default-ppmm"] = Double(descriptor.nativeWidth) / descriptor.screenWidthMillimeters
        }

        return dictionary
    }

    private func loadBaseOverrideDictionary(for descriptor: DisplayOverrideDescriptor) -> [String: Any]? {
        for url in [installedOverrideURL(for: descriptor), systemOverrideURL(for: descriptor)] {
            guard let url else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                continue
            }
            return plist
        }
        return nil
    }

    private func existingScaleResolutionEntries(from dictionary: [String: Any]) -> [Data] {
        dictionary["scale-resolutions"] as? [Data] ?? []
    }

    private func writeOverrideFile(
        dictionary: [String: Any],
        descriptor: DisplayOverrideDescriptor
    ) throws -> URL {
        let vendorDirectory = stagingRoot.appendingPathComponent(descriptor.vendorDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)

        let fileURL = vendorDirectory.appendingPathComponent(descriptor.productFileName, isDirectory: false)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func installStagedOverride(
        from stagedURL: URL,
        descriptor: DisplayOverrideDescriptor
    ) throws -> (url: URL, didInstall: Bool) {
        let installedURL = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
            .appendingPathComponent(descriptor.vendorDirectoryName, isDirectory: true)
            .appendingPathComponent(descriptor.productFileName, isDirectory: false)

        if let stagedData = try? Data(contentsOf: stagedURL),
           let existingData = try? Data(contentsOf: installedURL),
           stagedData == existingData {
            return (installedURL, false)
        }

        let installDirectory = installedURL.deletingLastPathComponent().path
        let shellCommand = """
        set -e
        mkdir -p \(shellQuoted(installDirectory))
        cp \(shellQuoted(stagedURL.path)) \(shellQuoted(installedURL.path))
        /usr/bin/defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true
        """

        try runPrivilegedShell(shellCommand)
        return (installedURL, true)
    }

    private func runPrivilegedShell(_ shellCommand: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptQuoted(shellCommand)) with administrator privileges"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisplayOverrideError.installFailed(message?.isEmpty == false ? message! : "macOS refused the privileged override install.")
        }
    }

    private func encodeBackingScaleEntry(width: Int, height: Int) -> Data {
        dataFromBigEndianWords([
            UInt32(width),
            UInt32(height)
        ])
    }

    private func encodeHiDPIEntry12(width: Int, height: Int) -> Data {
        dataFromBigEndianWords([
            UInt32(width),
            UInt32(height),
            1
        ])
    }

    private func encodeHiDPIEntry16(width: Int, height: Int, modeFlag: UInt32) -> Data {
        dataFromBigEndianWords([
            UInt32(width),
            UInt32(height),
            modeFlag,
            0x00A0_0000
        ])
    }

    private func dataFromBigEndianWords(_ words: [UInt32]) -> Data {
        var data = Data(capacity: words.count * MemoryLayout<UInt32>.size)
        for word in words {
            var bigEndianWord = word.bigEndian
            withUnsafeBytes(of: &bigEndianWord) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func uniquedDataEntries(_ entries: [Data]) -> [Data] {
        var seen = Set<Data>()
        var unique: [Data] = []
        for entry in entries {
            if seen.insert(entry).inserted {
                unique.append(entry)
            }
        }
        return unique
    }

    private func installedOverrideURL(for descriptor: DisplayOverrideDescriptor) -> URL? {
        let url = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
            .appendingPathComponent(descriptor.vendorDirectoryName, isDirectory: true)
            .appendingPathComponent(descriptor.productFileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func systemOverrideURL(for descriptor: DisplayOverrideDescriptor) -> URL? {
        let url = URL(fileURLWithPath: "/System/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
            .appendingPathComponent(descriptor.vendorDirectoryName, isDirectory: true)
            .appendingPathComponent(descriptor.productFileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

struct DisplayOverrideInstallResult {
    let stagedURL: URL
    let installedURL: URL
    let didInstall: Bool
    let installedModeCount: Int
}

enum VirtualResolutionActivationStatus: Equatable {
    case notRequired
    case notInstalled
    case installedNeedsDesktopReload(URL)
}

private struct DisplayOverrideDescriptor {
    let displayID: CGDirectDisplayID
    let vendorID: Int
    let productID: Int
    let nativeWidth: Int
    let nativeHeight: Int
    let screenWidthMillimeters: Double
    let screenHeightMillimeters: Double

    var vendorDirectoryName: String {
        "DisplayVendorID-\(String(vendorID, radix: 16))"
    }

    var productFileName: String {
        "DisplayProductID-\(String(productID, radix: 16))"
    }
}

enum DisplayOverrideError: LocalizedError {
    case modeDoesNotNeedOverride
    case noInstallableHiDPIModes
    case installFailed(String)
    case desktopReloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modeDoesNotNeedOverride:
            return "This mode can already be applied directly and does not need a display override."
        case .noInstallableHiDPIModes:
            return "No installable HiDPI override modes were generated for this display."
        case .installFailed(let message):
            return message
        case .desktopReloadFailed(let message):
            return message
        }
    }
}
