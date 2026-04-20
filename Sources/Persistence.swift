import Foundation
import Observation

private func appSupportFileURL(_ name: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DeepDisplay", isDirectory: true)
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

@Observable
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
