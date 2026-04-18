import AppKit
import CoreGraphics
import Darwin
import Foundation
import Observation

private func makeDisplayModeQueryOptions() -> CFDictionary {
    [
        kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any
    ] as CFDictionary
}

/// Owns the public display inventory and mode switching flow, while delegating
/// private transport/range inspection to `DisplayTransportRuntime`.
@Observable
@MainActor
final class DisplayService: NSObject {
    var synthesizeHiDPIForEligibleModes = true

    private(set) var displays: [DisplaySnapshot] = [] {
        didSet {
            for observer in displayObservers {
                observer(displays)
            }
        }
    }

    private var reconfigurationCallbackRegistered = false
    private var pendingRefreshTask: DispatchWorkItem?
    private var displayObservers: [([DisplaySnapshot]) -> Void] = []

    func start() {
        refreshDisplays()
        registerForDisplayReconfigurationsIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
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

    @objc
    private func applicationDidBecomeActive() {
        scheduleRefresh()
    }

    @objc
    private func screenParametersDidChange() {
        scheduleRefresh()
    }

    func refreshDisplays() {
        displays = enumerateDisplays()
    }

    func addObserver(_ observer: @escaping ([DisplaySnapshot]) -> Void) {
        displayObservers.append(observer)
        observer(displays)
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
            transportOptions: transportOptions(for: displayID)
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
        // Transport and range writes are only reliable through the private
        // CADisplay runtime, so keep switching delegated to the transport layer
        // that already discovered the exact private mode identity.
        guard DisplayTransportRuntime.apply(displayID: displayID, option: option) else {
            throw DisplayServiceError.transportOptionNotFound
        }
        refreshDisplays()
    }

    private func transportOptions(for displayID: CGDirectDisplayID) -> [DisplayTransportOption] {
        DisplayTransportRuntime.inspect(displayID: displayID)
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

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let service = Unmanaged<DisplayService>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        service.refreshDisplays()
    }
}

enum DisplayServiceError: LocalizedError {
    case modeNotFound
    case unableToCreateConfiguration
    case unableToApplyMode(Int32)
    case transportOptionNotFound
    case transportOptionNotSettable

    var errorDescription: String? {
        switch self {
        case .modeNotFound:
            return "Selected display mode no longer exists."
        case .unableToCreateConfiguration:
            return "Unable to create display configuration."
        case .unableToApplyMode(let code):
            return "Unable to apply display mode. CoreGraphics error: \(code)."
        case .transportOptionNotFound:
            return "Selected color transport option is no longer available."
        case .transportOptionNotSettable:
            return "Selected color transport option cannot be changed from Deep Display."
        }
    }
}
