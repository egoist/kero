import Foundation

enum JSONFileStore {
    static func applicationSupportURL(filename: String) -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return baseURL
            .appendingPathComponent("Kero", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    static func load<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        default defaultValue: @autoclosure () -> Value
    ) -> Value {
        guard let data = try? Data(contentsOf: url) else {
            return defaultValue()
        }

        do {
            return try JSONDecoder.kero.decode(type, from: data)
        } catch {
            assertionFailure("Could not decode \(url.lastPathComponent): \(error)")
            return defaultValue()
        }
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.kero.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONEncoder {
    static var kero: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Foundation's deferred representation preserves the full Date value.
        // The decoder below also accepts the ISO-8601 strings written by the MVP.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}

private extension JSONDecoder {
    static var kero: JSONDecoder {
        let decoder = JSONDecoder()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let value = try container.decode(String.self)
            guard let date = fractionalFormatter.date(from: value)
                    ?? legacyFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }
}
