import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import QuartzCore

/// Encapsulates the mix of public heuristics and private QuartzCore runtime
/// access used for color transport/range detection.
///
/// The public/CoreDisplay and IORegistry paths are read-only fallbacks. The
/// only write path we have verified experimentally is the private CADisplay
/// runtime, so detection prefers the same private current-mode family before
/// offering a user-selectable transport option.
enum DisplayTransportRuntime {
    static func inspect(displayID: CGDirectDisplayID) -> [DisplayTransportOption] {
        if let privateOptions = PrivateDisplayTransportAPI.inspect(displayID: displayID),
           !privateOptions.isEmpty {
            return privateOptions
        }

        return DisplayTransportInspector.inspect(displayID: displayID)
    }

    static func apply(displayID: CGDirectDisplayID, option: DisplayTransportOption) -> Bool {
        PrivateDisplayTransportAPI.apply(displayID: displayID, option: option)
    }
}

private extension Dictionary where Key == String, Value == Any {
    subscript(intKey key: String) -> Int? {
        let value = self[key]
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    subscript(boolKey key: String) -> Bool? {
        let value = self[key]
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
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

        if let registryModes = registryTransportModes(vendorID: vendorID, productID: productID),
           !registryModes.isEmpty {
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
                    modeDescriptor: nil,
                    modeMatchToken: nil
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
                modeDescriptor: nil,
                modeMatchToken: nil
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

        let dynamicRange = (hdrEnabled == true
            || hdr10Enabled == true
            || activeColorSpaceName?.containsInsensitive("pq") == true
            || activeColorSpaceName?.containsInsensitive("hlg") == true)
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
        let detail = activeColorSpaceName.map {
            "Detected via \(compositingColorSpaceName != nil ? "CoreDisplay" : "CoreGraphics"): \($0)"
        }

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
        timingElements.flatMap { $0["ColorModes"] as? [[String: Any]] ?? [] }
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

private enum PrivateDisplayTransportAPI {
    static func inspect(displayID: CGDirectDisplayID) -> [DisplayTransportOption]? {
        guard let display = cadDisplay(displayID: displayID) else { return nil }
        guard let currentMode = display.value(forKey: "currentMode") as? NSObject else { return nil }

        let resolvedWidth = intValue(currentMode.value(forKey: "width"))
        let resolvedHeight = intValue(currentMode.value(forKey: "height"))
        guard let resolvedWidth, let resolvedHeight else { return nil }

        let currentDescriptor = String(describing: currentMode)
        let currentModeToken = privateRepresentationHex(for: currentMode)
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

            // Multiple private modes can share the same human-readable
            // descriptor, so we keep the private representation as the durable
            // identity for apply/verify.
            let modeToken = privateRepresentationHex(for: mode)
            let groupKey = parsed.title
            let isCurrent = (modeToken != nil && modeToken == currentModeToken) || descriptor == currentDescriptor
            let candidate = PrivateTransportCandidate(
                option: DisplayTransportOption(
                    title: parsed.title,
                    subtitle: descriptor,
                    isCurrent: isCurrent,
                    isUserSelectable: true,
                    modeDescriptor: descriptor,
                    modeMatchToken: modeToken
                ),
                score: (isCurrent ? 10_000 : 0)
                    + (parsed.isVirtual ? 0 : 1_000)
                    + parsed.bitDepth
                    + (parsed.transport == "RGB" ? 100 : 0)
            )

            if let existing = bestByTitle[groupKey] {
                if candidate.score > existing.score {
                    bestByTitle[groupKey] = candidate
                }
            } else {
                bestByTitle[groupKey] = candidate
            }
        }

        var options = bestByTitle.values
            .map(\.option)
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        if !options.contains(where: \.isCurrent),
           let currentGroupKey = parseModeDescriptor(currentDescriptor)?.title,
           let currentIndex = bestByTitle[currentGroupKey].flatMap({ candidate in
               options.firstIndex(where: { $0.id == candidate.option.id })
           }) {
            let matched = options[currentIndex]
            options[currentIndex] = DisplayTransportOption(
                title: matched.title,
                subtitle: matched.subtitle,
                isCurrent: true,
                isUserSelectable: matched.isUserSelectable,
                modeDescriptor: matched.modeDescriptor,
                modeMatchToken: matched.modeMatchToken
            )
        }

        return options
    }

    static func apply(displayID: CGDirectDisplayID, option: DisplayTransportOption) -> Bool {
        guard let display = cadDisplay(displayID: displayID) else { return false }
        guard let modes = display.value(forKey: "availableModes") as? [NSObject] else { return false }

        let targetMode: NSObject?
        if let modeMatchToken = option.modeMatchToken {
            targetMode = modes.first { privateRepresentationHex(for: $0) == modeMatchToken }
        } else if let descriptor = option.modeDescriptor {
            targetMode = modes.first { String(describing: $0) == descriptor }
        } else {
            targetMode = nil
        }

        guard let targetMode else { return false }

        _ = display.perform(NSSelectorFromString("setCurrentMode:"), with: targetMode)
        _ = display.perform(NSSelectorFromString("update"))

        guard let currentMode = display.value(forKey: "currentMode") as? NSObject else { return false }
        if let modeMatchToken = option.modeMatchToken {
            return privateRepresentationHex(for: currentMode) == modeMatchToken
        }
        if let descriptor = option.modeDescriptor {
            return String(describing: currentMode) == descriptor
        }
        return false
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

    private static func privateRepresentationHex(for mode: NSObject) -> String? {
        guard let data = mode.perform(NSSelectorFromString("copyPrivateRepresentation"))?.takeRetainedValue() as? Data else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
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
