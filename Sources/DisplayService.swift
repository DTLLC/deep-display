import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import QuartzCore

private func makeDisplayModeQueryOptions() -> CFDictionary {
    [
        kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any
    ] as CFDictionary
}

@MainActor
final class DisplayService: NSObject {
    var synthesizeHiDPIForEligibleModes = true

    private(set) var displays: [DisplaySnapshot] = [] {
        didSet {
            for observer in displayObservers.values {
                observer(displays)
            }
        }
    }

    private var reconfigurationCallbackRegistered = false
    private var pendingRefreshTask: DispatchWorkItem?
    private var displayObservers: [UUID: ([DisplaySnapshot]) -> Void] = [:]

    func start() {
        refreshDisplays()
        registerForDisplayReconfigurationsIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func workspaceDidWake() {
        scheduleRefresh()
    }

    func refreshDisplays() {
        displays = enumerateDisplays()
    }

    @discardableResult
    func addObserver(_ observer: @escaping ([DisplaySnapshot]) -> Void) -> UUID {
        let id = UUID()
        displayObservers[id] = observer
        observer(displays)
        return id
    }

    func removeObserver(_ id: UUID) {
        displayObservers.removeValue(forKey: id)
    }

    func snapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot? {
        displays.first { $0.id == displayID }
    }

    func switchMode(_ mode: DisplayModeSnapshot, for displayID: CGDirectDisplayID) throws {
        if let targetMode = (CGDisplayCopyAllDisplayModes(displayID, makeDisplayModeQueryOptions()) as? [CGDisplayMode])?
            .first(where: { resolvedModeMatch(snapshot(for: $0), requested: mode) }) {
            try switchPublicMode(targetMode, for: displayID)
            refreshDisplays()
            return
        }

        if let legacyMode = legacyModeDictionaries(for: displayID).first(where: {
            resolvedModeMatch(legacySnapshot(from: $0, hiddenAlternative: true), requested: mode)
        }) {
            let result = LegacyDisplayModeAPI.switchToMode(displayID, mode: legacyMode) ?? .failure
            guard result == .success else {
                throw DisplayServiceError.unableToApplyMode(result.rawValue)
            }
            refreshDisplays()
            return
        }

        throw DisplayServiceError.modeNotFound
    }

    private func switchPublicMode(_ mode: CGDisplayMode, for displayID: CGDirectDisplayID) throws {
        let configuration = UnsafeMutablePointer<CGDisplayConfigRef?>.allocate(capacity: 1)
        defer { configuration.deallocate() }

        guard CGBeginDisplayConfiguration(configuration) == .success, let configRef = configuration.pointee else {
            throw DisplayServiceError.unableToCreateConfiguration
        }

        let configureResult = CGConfigureDisplayWithDisplayMode(configRef, displayID, mode, nil)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configRef)
            throw DisplayServiceError.unableToApplyMode(configureResult.rawValue)
        }

        let completeResult = CGCompleteDisplayConfiguration(configRef, .permanently)
        guard completeResult == .success else {
            throw DisplayServiceError.unableToApplyMode(completeResult.rawValue)
        }
    }

    private func registerForDisplayReconfigurationsIfNeeded() {
        guard !reconfigurationCallbackRegistered else { return }
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        reconfigurationCallbackRegistered = true
    }

    private func scheduleRefresh() {
        pendingRefreshTask?.cancel()

        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshDisplays()
            }
        }
        pendingRefreshTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }

    private func enumerateDisplays() -> [DisplaySnapshot] {
        var activeDisplayIDs = Array(repeating: CGDirectDisplayID(), count: 16)
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(UInt32(activeDisplayIDs.count), &activeDisplayIDs, &displayCount)

        guard result == .success else {
            return []
        }

        return activeDisplayIDs
            .prefix(Int(displayCount))
            .map(buildSnapshot(for:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func buildSnapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot {
        let currentMode = CGDisplayCopyDisplayMode(displayID)
        let currentSnapshot = currentMode.map(snapshot(for:))
        let availableModes = mergedModeSnapshots(for: displayID)
            .sorted(by: compareModes)

        return DisplaySnapshot(
            id: displayID,
            name: displayName(for: displayID),
            isOnline: CGDisplayIsOnline(displayID) != 0,
            frame: DisplayFrame(rect: CGDisplayBounds(displayID)),
            currentMode: currentSnapshot,
            availableModes: availableModes,
            transportOptions: transportOptions(for: displayID, currentMode: currentSnapshot)
        )
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == displayID {
                return screen.localizedName
            }
        }

        return "Display \(displayID)"
    }

    private func compareModes(lhs: DisplayModeSnapshot, rhs: DisplayModeSnapshot) -> Bool {
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
        if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI && !rhs.isHiDPI }
        if lhs.requiresOverrideInstall != rhs.requiresOverrideInstall {
            return !lhs.requiresOverrideInstall && rhs.requiresOverrideInstall
        }
        if (lhs.isHiddenAlternative ?? false) != (rhs.isHiddenAlternative ?? false) {
            return (lhs.isHiddenAlternative ?? false) && !(rhs.isHiddenAlternative ?? false)
        }
        if (lhs.isSafeForHardware ?? false) != (rhs.isSafeForHardware ?? false) {
            return (lhs.isSafeForHardware ?? false) && !(rhs.isSafeForHardware ?? false)
        }
        return lhs.id < rhs.id
    }

    private func snapshot(for mode: CGDisplayMode) -> DisplayModeSnapshot {
        let ioFlags = mode.ioFlags
        return DisplayModeSnapshot(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            isHiDPI: mode.pixelWidth > mode.width || mode.pixelHeight > mode.height,
            isLowResolution: false,
            isUsableForDesktopGUI: mode.isUsableForDesktopGUI(),
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            backingWidth: mode.pixelWidth,
            backingHeight: mode.pixelHeight,
            ioFlags: ioFlags,
            ioDisplayModeID: mode.ioDisplayModeID,
            source: .publicAPI,
            isSafeForHardware: nil,
            isStretched: nil,
            isInterlaced: nil,
            isHiddenAlternative: false,
            requiresOverrideInstall: false
        )
    }

    private func mergedModeSnapshots(for displayID: CGDirectDisplayID) -> [DisplayModeSnapshot] {
        let publicModes = (CGDisplayCopyAllDisplayModes(displayID, makeDisplayModeQueryOptions()) as? [CGDisplayMode] ?? [])
            .map(snapshot(for:))
        let legacyModes = legacyModeDictionaries(for: displayID)
            .map { legacySnapshot(from: $0, hiddenAlternative: true) }

        var mergedByID: [String: DisplayModeSnapshot] = [:]
        for mode in publicModes {
            mergedByID[mode.id] = mode
        }

        for legacy in legacyModes {
            if let publicMatch = publicModes.first(where: { sameModeID($0, legacy) }) {
                mergedByID[publicMatch.id] = publicMatch
            } else {
                let shouldPromoteToHiDPI = shouldPromoteLegacyModeToHiDPI(
                    legacy,
                    publicModes: publicModes
                )
                let preservedLegacy = legacy.replacing(
                    isHiDPI: shouldPromoteToHiDPI ? true : nil,
                    isHiddenAlternative: true
                )
                mergedByID[preservedLegacy.id] = preservedLegacy
            }
        }

        var mergedModes = Array(mergedByID.values)

        if synthesizeHiDPIForEligibleModes {
            let syntheticModes = mergedModes.compactMap {
                syntheticHiDPIMode(from: $0, existingModes: mergedModes)
            }
            for synthetic in syntheticModes {
                mergedByID[synthetic.id] = synthetic
            }
            mergedModes = Array(mergedByID.values)
        }

        return mergedModes
    }

    private func sameModeID(_ lhs: DisplayModeSnapshot, _ rhs: DisplayModeSnapshot) -> Bool {
        guard let lhsID = lhs.ioDisplayModeID, let rhsID = rhs.ioDisplayModeID else {
            return false
        }
        return lhsID == rhsID
    }

    private func shouldPromoteLegacyModeToHiDPI(
        _ legacy: DisplayModeSnapshot,
        publicModes: [DisplayModeSnapshot]
    ) -> Bool {
        guard legacy.isHiDPI == false else { return false }

        let sameResolutionModes = publicModes.filter {
            $0.width == legacy.width
                && $0.height == legacy.height
                && abs($0.refreshRate - legacy.refreshRate) < 0.01
        }

        guard !sameResolutionModes.contains(where: \.isHiDPI) else { return false }

        if sameResolutionModes.contains(where: { !$0.isHiDPI }) {
            return true
        }

        return legacy.isHiddenAlternative == true
    }

    private func syntheticHiDPIMode(
        from mode: DisplayModeSnapshot,
        existingModes: [DisplayModeSnapshot]
    ) -> DisplayModeSnapshot? {
        guard synthesizeHiDPIForEligibleModes else { return nil }
        guard mode.isHiDPI == false else { return nil }
        guard mode.isUsableForDesktopGUI else { return nil }

        let sameResolutionModes = existingModes.filter {
            $0.width == mode.width
                && $0.height == mode.height
                && abs($0.refreshRate - mode.refreshRate) < 0.01
        }
        guard !sameResolutionModes.contains(where: \.isHiDPI) else { return nil }

        return mode.replacing(
            isHiDPI: true,
            isHiddenAlternative: false,
            source: .syntheticOverride,
            backingWidth: max(mode.backingWidth, mode.width * 2),
            backingHeight: max(mode.backingHeight, mode.height * 2),
            requiresOverrideInstall: true
        )
    }

    private func resolvedModeMatch(_ candidate: DisplayModeSnapshot, requested: DisplayModeSnapshot) -> Bool {
        guard !requested.requiresOverrideInstall else { return false }

        if candidate == requested {
            return true
        }

        if let candidateModeID = candidate.ioDisplayModeID,
           let requestedModeID = requested.ioDisplayModeID,
           candidateModeID == requestedModeID,
           abs(candidate.refreshRate - requested.refreshRate) < 0.01 {
            return candidate.width == requested.width
                && candidate.height == requested.height
                && candidate.isHiDPI == requested.isHiDPI
                && candidate.backingWidth == requested.backingWidth
                && candidate.backingHeight == requested.backingHeight
        }

        return candidate.width == requested.width
            && candidate.height == requested.height
            && abs(candidate.refreshRate - requested.refreshRate) < 0.01
            && candidate.isHiDPI == requested.isHiDPI
            && candidate.backingWidth == requested.backingWidth
            && candidate.backingHeight == requested.backingHeight
            && candidate.source == requested.source
    }

    private func legacyModeDictionaries(for displayID: CGDirectDisplayID) -> [[String: Any]] {
        LegacyDisplayModeAPI.availableModes(displayID) ?? []
    }

    private func legacySnapshot(from dictionary: [String: Any], hiddenAlternative: Bool) -> DisplayModeSnapshot {
        let width = dictionary[intKey: kCGDisplayWidth] ?? 0
        let height = dictionary[intKey: kCGDisplayHeight] ?? 0
        let refreshRate = dictionary[doubleKey: kCGDisplayRefreshRate] ?? 0
        let ioFlags = UInt32(dictionary[intKey: kCGDisplayIOFlags] ?? 0)
        let modeID = Int32(dictionary[intKey: kCGIODisplayModeID] ?? -1)
        let pixelWidth = dictionary[intKey: kCGDisplayWidth] ?? width
        let pixelHeight = dictionary[intKey: kCGDisplayHeight] ?? height
        let safe = dictionary[boolKey: kCGDisplayModeIsSafeForHardware] ?? false
        let stretched = dictionary[boolKey: kCGDisplayModeIsStretched] ?? false
        let interlaced = dictionary[boolKey: kCGDisplayModeIsInterlaced] ?? false

        return DisplayModeSnapshot(
            width: width,
            height: height,
            refreshRate: refreshRate,
            isHiDPI: false,
            isLowResolution: false,
            isUsableForDesktopGUI: dictionary[boolKey: kCGDisplayModeUsableForDesktopGUI] ?? true,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingWidth: pixelWidth,
            backingHeight: pixelHeight,
            ioFlags: ioFlags,
            ioDisplayModeID: modeID >= 0 ? modeID : nil,
            source: .legacyAPI,
            isSafeForHardware: safe,
            isStretched: stretched,
            isInterlaced: interlaced,
            isHiddenAlternative: hiddenAlternative,
            requiresOverrideInstall: false
        )
    }

    func switchTransportOption(_ option: DisplayTransportOption, for displayID: CGDirectDisplayID) throws {
        guard option.isUserSelectable else {
            throw DisplayServiceError.transportOptionNotSettable
        }
        guard PrivateDisplayTransportAPI.apply(displayID: displayID, option: option) else {
            throw DisplayServiceError.transportOptionNotFound
        }
        refreshDisplays()
    }

    private func transportOptions(
        for displayID: CGDirectDisplayID,
        currentMode: DisplayModeSnapshot?
    ) -> [DisplayTransportOption] {
        if let privateOptions = PrivateDisplayTransportAPI.inspect(
            displayID: displayID,
            targetWidth: currentMode?.width,
            targetHeight: currentMode?.height
        ), !privateOptions.isEmpty {
            return privateOptions
        }

        return DisplayTransportInspector.inspect(displayID: displayID)
    }
}

private extension Dictionary where Key == String, Value == Any {
    subscript(intKey key: String) -> Int? {
        let value = self[key]
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    subscript(doubleKey key: String) -> Double? {
        let value = self[key]
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    subscript(boolKey key: String) -> Bool? {
        let value = self[key]
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }
}

private enum LegacyDisplayModeAPI {
    private typealias AvailableModesFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFArray>?
    private typealias SwitchToModeFunction = @convention(c) (CGDirectDisplayID, CFDictionary?) -> CGError

    static func availableModes(_ displayID: CGDirectDisplayID) -> [[String: Any]]? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
            let functionPointer = dlsym(handle, "CGDisplayAvailableModes")
        else {
            return nil
        }

        let function = unsafeBitCast(functionPointer, to: AvailableModesFunction.self)
        return function(displayID)?.takeUnretainedValue() as? [[String: Any]]
    }

    static func switchToMode(_ displayID: CGDirectDisplayID, mode: [String: Any]) -> CGError? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
            let functionPointer = dlsym(handle, "CGDisplaySwitchToMode")
        else {
            return nil
        }

        let function = unsafeBitCast(functionPointer, to: SwitchToModeFunction.self)
        return function(displayID, mode as CFDictionary)
    }
}

private enum DisplayTransportInspector {
    private typealias GetServiceIDForDisplayIDFn = @convention(c) (CGDirectDisplayID) -> UInt64
    private typealias DisplayIsHDRModeEnabledFn = @convention(c) (UInt64) -> Bool
    private typealias DisplayIsHDR10Fn = @convention(c) (UInt64) -> Bool
    private typealias DisplayGetCompositingColorSpaceFn = @convention(c) (UInt64) -> Unmanaged<CGColorSpace>?

    static func inspect(displayID: CGDirectDisplayID) -> [DisplayTransportOption] {
        let currentState = currentTransportState(displayID: displayID)
        let vendorID = Int(CGDisplayVendorNumber(displayID))
        let productID = Int(CGDisplayModelNumber(displayID))

        if let registryModes = registryTransportModes(vendorID: vendorID, productID: productID), !registryModes.isEmpty {
            let dedupedModes = dedupeRegistryModes(registryModes)
            let currentIndex = currentState.flatMap { state in
                dedupedModes.firstIndex(where: { $0.title == state.summary })
            }

            return dedupedModes.enumerated().map { index, mode in
                DisplayTransportOption(
                    title: mode.title,
                    subtitle: mode.detail,
                    isCurrent: currentIndex == index,
                    isUserSelectable: false,
                    modeDescriptor: nil
                )
            }
        }

        guard let currentState else { return [] }
        return [
            DisplayTransportOption(
                title: currentState.summary,
                subtitle: currentState.detail,
                isCurrent: true,
                isUserSelectable: false,
                modeDescriptor: nil
            )
        ]
    }

    private static func currentTransportState(displayID: CGDirectDisplayID) -> TransportState? {
        let publicColorSpace = CGDisplayCopyColorSpace(displayID)
        let publicName = colorSpaceName(publicColorSpace)

        let serviceID = coreDisplayGetServiceID(displayID)
        let hdrEnabled = serviceID.flatMap(coreDisplayHDRModeEnabled)
        let hdr10Enabled = serviceID.flatMap(coreDisplayHDR10Enabled)
        let compositingColorSpaceName = serviceID.flatMap(coreDisplayCompositingColorSpaceName)
        let activeColorSpaceName = compositingColorSpaceName ?? publicName

        guard hdrEnabled != nil || hdr10Enabled != nil || activeColorSpaceName != nil else {
            return nil
        }

        let dynamicRange = (hdrEnabled == true || hdr10Enabled == true || activeColorSpaceName?.containsInsensitive("pq") == true || activeColorSpaceName?.containsInsensitive("hlg") == true)
            ? "HDR"
            : "SDR"

        let transport: String
        if activeColorSpaceName?.containsInsensitive("itur") == true
            || activeColorSpaceName?.containsInsensitive("2020") == true
            || activeColorSpaceName?.containsInsensitive("709") == true
            || activeColorSpaceName?.containsInsensitive("601") == true
            || activeColorSpaceName?.containsInsensitive("ycbcr") == true
            || activeColorSpaceName?.containsInsensitive("yuv") == true {
            transport = "YCbCr"
        } else {
            transport = "RGB"
        }

        let range = transport == "YCbCr" ? "Limited Range" : "Full Range"
        let hdrFlavor = hdr10Enabled == true ? "HDR10" : dynamicRange
        let summary = "\(hdrFlavor) - \(transport) - \(range)"
        let detail = activeColorSpaceName.map { "Detected via \(compositingColorSpaceName != nil ? "CoreDisplay" : "CoreGraphics"): \($0)" }

        return TransportState(summary: summary, detail: detail)
    }

    private static func registryTransportModes(vendorID: Int, productID: Int) -> [RegistryTransportMode]? {
        let serviceNames = ["AppleCLCD2", "AppleDisplay", "IODPDevice"]

        for serviceName in serviceNames {
            guard let matching = IOServiceMatching(serviceName) else { continue }

            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var modes: [RegistryTransportMode] = []
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let properties = registryProperties(for: service) else { continue }
                guard matchesDisplay(properties: properties, vendorID: vendorID, productID: productID) else { continue }

                let colorElements = properties["ColorElements"] as? [[String: Any]]
                    ?? timingElements(properties: properties).flatMap(extractColorModes(from:))
                guard let colorElements else { continue }

                modes.append(contentsOf: colorElements.compactMap(registryTransportMode(from:)))
            }

            if !modes.isEmpty {
                return modes
            }
        }

        return nil
    }

    private static func registryProperties(for service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func matchesDisplay(properties: [String: Any], vendorID: Int, productID: Int) -> Bool {
        if let displayAttributes = properties["DisplayAttributes"] as? [String: Any],
           let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any] {
            let candidateVendor = (productAttributes["LegacyManufacturerID"] as? NSNumber)?.intValue
                ?? (productAttributes["ManufacturerID"] as? NSNumber)?.intValue
            let candidateProduct = (productAttributes["ProductID"] as? NSNumber)?.intValue
            return candidateVendor == vendorID && candidateProduct == productID
        }

        let candidateVendor = (properties["DisplayVendorID"] as? NSNumber)?.intValue
        let candidateProduct = (properties["DisplayProductID"] as? NSNumber)?.intValue
        return candidateVendor == vendorID && candidateProduct == productID
    }

    private static func timingElements(properties: [String: Any]) -> [[String: Any]]? {
        properties["TimingElements"] as? [[String: Any]]
    }

    private static func extractColorModes(from timingElements: [[String: Any]]) -> [[String: Any]]? {
        timingElements
            .flatMap { $0["ColorModes"] as? [[String: Any]] ?? [] }
    }

    private static func registryTransportMode(from element: [String: Any]) -> RegistryTransportMode? {
        let depth = element[intKey: "Depth"] ?? 0
        let pixelEncoding = element[intKey: "PixelEncoding"] ?? -1
        let eotf = element[intKey: "EOTF"] ?? 0
        let dynamicRange = element[intKey: "DynamicRange"] ?? 0
        let colorimetry = element[intKey: "Colorimetry"] ?? 0
        let score = element[intKey: "Score"] ?? 0
        let isVirtual = element[boolKey: "IsVirtual"] ?? false

        guard let encoding = pixelEncodingDescription(pixelEncoding) else { return nil }

        var parts = ["\(depth)-bit", eotfDescription(eotf), encoding.transport]
        if let chroma = encoding.chroma {
            parts.append(chroma)
        }
        if let range = rangeDescription(dynamicRange, transport: encoding.transport) {
            parts.append(range)
        }

        let detail = "IORegistry ColorElements: pixelEncoding \(pixelEncoding), colorimetry \(colorimetry), \(isVirtual ? "virtual" : "native")"
        return RegistryTransportMode(
            title: parts.joined(separator: " - "),
            detail: detail,
            score: score,
            isVirtual: isVirtual
        )
    }

    private static func dedupeRegistryModes(_ modes: [RegistryTransportMode]) -> [RegistryTransportMode] {
        var bestByTitle: [String: RegistryTransportMode] = [:]

        for mode in modes {
            if let existing = bestByTitle[mode.title] {
                if mode.score > existing.score || (existing.isVirtual && !mode.isVirtual) {
                    bestByTitle[mode.title] = mode
                }
            } else {
                bestByTitle[mode.title] = mode
            }
        }

        return Array(bestByTitle.values).sorted { lhs, rhs in
            if lhs.title != rhs.title { return lhs.title > rhs.title }
            return lhs.score > rhs.score
        }
    }

    private static func pixelEncodingDescription(_ value: Int) -> (transport: String, chroma: String?)? {
        switch value {
        case 0, 1:
            return ("RGB", nil)
        case 2:
            return ("YCbCr", "4:2:2")
        case 3:
            return ("YCbCr", "4:4:4")
        case 6:
            return ("YCbCr", "4:2:0")
        default:
            return nil
        }
    }

    private static func eotfDescription(_ value: Int) -> String {
        switch value {
        case 2:
            return "HDR10"
        case 3:
            return "HLG"
        case 1:
            return "HDR"
        default:
            return "SDR"
        }
    }

    private static func rangeDescription(_ value: Int, transport: String) -> String? {
        switch value {
        case 0:
            return "Full Range"
        case 1:
            return "Limited Range"
        default:
            return transport == "RGB" ? "Unknown Range" : nil
        }
    }

    private static func coreDisplayGetServiceID(_ displayID: CGDirectDisplayID) -> UInt64? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDisplay_GetServiceIDForDisplayID")
        else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: GetServiceIDForDisplayIDFn.self)
        return function(displayID)
    }

    private static func coreDisplayHDRModeEnabled(_ serviceID: UInt64) -> Bool? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDisplay_Display_IsHDRModeEnabled")
        else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: DisplayIsHDRModeEnabledFn.self)
        return function(serviceID)
    }

    private static func coreDisplayHDR10Enabled(_ serviceID: UInt64) -> Bool? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDisplay_Display_IsHDR10")
        else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: DisplayIsHDR10Fn.self)
        return function(serviceID)
    }

    private static func coreDisplayCompositingColorSpaceName(_ serviceID: UInt64) -> String? {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDisplay_Display_GetCompositingColorSpace")
        else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: DisplayGetCompositingColorSpaceFn.self)
        return function(serviceID).flatMap { colorSpaceName($0.takeUnretainedValue()) }
    }

    private static func colorSpaceName(_ colorSpace: CGColorSpace) -> String? {
        guard let name = colorSpace.name else { return nil }
        return name as String
    }
}

private struct TransportState {
    let summary: String
    let detail: String?
}

private struct RegistryTransportMode {
    let title: String
    let detail: String
    let score: Int
    let isVirtual: Bool
}

private enum PrivateDisplayTransportAPI {
    static func inspect(
        displayID: CGDirectDisplayID,
        targetWidth: Int?,
        targetHeight: Int?
    ) -> [DisplayTransportOption]? {
        guard let display = cadDisplay(displayID: displayID) else { return nil }
        guard let currentMode = display.value(forKey: "currentMode") as? NSObject else { return nil }

        let resolvedWidth = targetWidth ?? intValue(currentMode.value(forKey: "width"))
        let resolvedHeight = targetHeight ?? intValue(currentMode.value(forKey: "height"))
        guard let resolvedWidth, let resolvedHeight else { return nil }

        let currentDescriptor = String(describing: currentMode)
        let modes = (display.value(forKey: "availableModes") as? [NSObject] ?? [])
            .filter { mode in
                intValue(mode.value(forKey: "width")) == resolvedWidth
                    && intValue(mode.value(forKey: "height")) == resolvedHeight
            }

        guard !modes.isEmpty else { return nil }

        var bestByTitle: [String: PrivateTransportCandidate] = [:]

        for mode in modes {
            let descriptor = String(describing: mode)
            guard let parsed = parseModeDescriptor(descriptor) else { continue }

            let isCurrent = descriptor == currentDescriptor
            let candidate = PrivateTransportCandidate(
                option: DisplayTransportOption(
                    title: parsed.title,
                    subtitle: descriptor,
                    isCurrent: isCurrent,
                    isUserSelectable: true,
                    modeDescriptor: descriptor
                ),
                score: (isCurrent ? 10_000 : 0)
                    + (parsed.isVirtual ? 0 : 1_000)
                    + parsed.bitDepth
                    + (parsed.transport == "RGB" ? 100 : 0)
            )

            if let existing = bestByTitle[parsed.title] {
                if candidate.score > existing.score {
                    bestByTitle[parsed.title] = candidate
                }
            } else {
                bestByTitle[parsed.title] = candidate
            }
        }

        return bestByTitle.values
            .map(\.option)
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func apply(displayID: CGDirectDisplayID, option: DisplayTransportOption) -> Bool {
        guard let descriptor = option.modeDescriptor else { return false }
        guard let display = cadDisplay(displayID: displayID) else { return false }
        guard let modes = display.value(forKey: "availableModes") as? [NSObject] else { return false }
        guard let targetMode = modes.first(where: { String(describing: $0) == descriptor }) else { return false }

        _ = display.perform(NSSelectorFromString("setCurrentMode:"), with: targetMode)
        _ = display.perform(NSSelectorFromString("update"))

        guard let currentMode = display.value(forKey: "currentMode") as? NSObject else { return false }
        return String(describing: currentMode) == descriptor
    }

    private static func cadDisplay(displayID: CGDirectDisplayID) -> NSObject? {
        guard let cadDisplayClass = NSClassFromString("CADisplay") as? NSObject.Type else { return nil }
        let displays = cadDisplayClass.perform(NSSelectorFromString("displays"))?.takeUnretainedValue() as? [NSObject] ?? []
        return displays.first {
            UInt32(intValue($0.value(forKey: "displayId")) ?? -1) == displayID
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func parseModeDescriptor(_ descriptor: String) -> ParsedPrivateTransportMode? {
        guard let formatRange = descriptor.range(of: "fmt:") else { return nil }
        guard let rangeRange = descriptor.range(of: " range:") else { return nil }

        let formatToken = String(descriptor[formatRange.upperBound..<rangeRange.lowerBound])
        let rangeToken = String(descriptor[rangeRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: ">"))

        let isVirtual = descriptor.contains("virtual")
        guard let transport = transportDetails(for: formatToken) else { return nil }

        let dynamicRange = formatToken.contains("_PQ_") ? "HDR10" : "SDR"
        let rangeLabel: String
        switch rangeToken {
        case "full":
            rangeLabel = "Full Range"
        case "limited":
            rangeLabel = "Limited Range"
        default:
            rangeLabel = "\(rangeToken.capitalized) Range"
        }

        var parts = ["\(transport.bitDepth)-bit", dynamicRange, transport.transport]
        if let chroma = transport.chroma {
            parts.append(chroma)
        }
        parts.append(rangeLabel)

        return ParsedPrivateTransportMode(
            title: parts.joined(separator: " - "),
            transport: transport.transport,
            bitDepth: transport.bitDepth,
            isVirtual: isVirtual
        )
    }

    private static func transportDetails(for formatToken: String) -> (transport: String, chroma: String?, bitDepth: Int)? {
        let bitDepth: Int
        switch true {
        case formatToken.contains("16bit"):
            bitDepth = 16
        case formatToken.contains("12bit"):
            bitDepth = 12
        case formatToken.contains("10bit"):
            bitDepth = 10
        case formatToken.contains("8bit"):
            bitDepth = 8
        default:
            bitDepth = 8
        }

        if formatToken.hasPrefix("RGB") {
            return ("RGB", nil, bitDepth)
        }
        if formatToken.hasPrefix("YCbCr444") {
            return ("YCbCr", "4:4:4", bitDepth)
        }
        if formatToken.hasPrefix("YCbCr422") {
            return ("YCbCr", "4:2:2", bitDepth)
        }
        if formatToken.hasPrefix("YCbCr420") {
            return ("YCbCr", "4:2:0", bitDepth)
        }

        return nil
    }
}

private struct PrivateTransportCandidate {
    let option: DisplayTransportOption
    let score: Int
}

private struct ParsedPrivateTransportMode {
    let title: String
    let transport: String
    let bitDepth: Int
    let isVirtual: Bool
}

private extension String {
    func containsInsensitive(_ needle: String) -> Bool {
        range(of: needle, options: .caseInsensitive) != nil
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let service = Unmanaged<DisplayService>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        service.refreshDisplays()
    }
}

enum DisplayServiceError: LocalizedError {
    case unableToListModes
    case modeNotFound
    case unableToCreateConfiguration
    case unableToApplyMode(Int32)
    case transportOptionNotFound
    case transportOptionNotSettable

    var errorDescription: String? {
        switch self {
        case .unableToListModes:
            return "Unable to list display modes."
        case .modeNotFound:
            return "Selected display mode no longer exists."
        case .unableToCreateConfiguration:
            return "Unable to create display configuration."
        case .unableToApplyMode(let code):
            return "Unable to apply display mode. CoreGraphics error: \(code)."
        case .transportOptionNotFound:
            return "Selected color transport option is no longer available."
        case .transportOptionNotSettable:
            return "Selected color transport option cannot be changed from MacRes."
        }
    }
}
