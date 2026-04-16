import Foundation

private func appSupportFileURL(_ name: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacRes", isDirectory: true)
        .appendingPathComponent(name)
}

private func loadJSON<Value: Codable>(from fileURL: URL, defaultValue: Value) -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard
        let data = try? Data(contentsOf: fileURL),
        let decoded = try? decoder.decode(Value.self, from: data)
    else {
        return defaultValue
    }

    return decoded
}

private func saveJSON<Value: Codable>(_ value: Value, to fileURL: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    guard let data = try? encoder.encode(value) else { return }

    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
}

@MainActor
final class PresetStore {
    private(set) var presets: [Preset]
    private let fileURL = appSupportFileURL("presets.json")

    init() {
        self.presets = loadJSON(from: fileURL, defaultValue: [])
    }

    func createPreset(named name: String, from displays: [DisplaySnapshot]) {
        let configurations = displays.map {
            DisplayConfiguration(displayID: $0.id, displayName: $0.name, mode: $0.currentMode)
        }
        let preset = Preset(
            id: UUID(),
            name: name,
            createdAt: Date(),
            updatedAt: Date(),
            configurations: configurations,
            fallbackConfigurations: configurations
        )
        presets.append(preset)
        saveJSON(presets, to: fileURL)
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        saveJSON(presets, to: fileURL)
    }

    func updatePreset(id: UUID, mutate: (inout Preset) -> Void) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw PresetStoreError.presetNotFound
        }

        mutate(&presets[index])
        saveJSON(presets, to: fileURL)
    }
}

@MainActor
final class SettingsStore {
    private(set) var settings: AppSettings
    private let fileURL = appSupportFileURL("settings.json")

    init() {
        self.settings = loadJSON(from: fileURL, defaultValue: .default)
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        saveJSON(settings, to: fileURL)
    }
}

enum PresetStoreError: LocalizedError {
    case presetNotFound

    var errorDescription: String? {
        switch self {
        case .presetNotFound:
            return "Preset not found."
        }
    }
}
