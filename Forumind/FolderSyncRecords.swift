import CryptoKit
import Foundation

// MARK: - Folder sync records
//
// Every synced item is one "record" (one file). A record is a set of *units*
// — a top-level field of the model's JSON, or a small group of fields that
// must travel together — each with a `modifiedAt` stamp. Merging two copies
// of a record picks, per unit, the one with the newest stamp (a few units
// use max/min instead). The merge is commutative and deterministic, so every
// device converges on the same plaintext bytes.
//
// Stamps come from diffing the local record against the baseline (the state
// both sides last agreed on): an unchanged unit keeps its baseline stamp, a
// changed one gets a new stamp. That is also the three-way merge: a unit
// this device did not touch cannot beat a remote edit.
//
// Dates are encoded as whole-second ISO 8601 everywhere (the local snapshot
// uses the same encoding), so a value that went through a file compares
// equal to the in-memory one.

/// A JSON value with a canonical encoding (sorted keys).
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }
}

enum FolderSyncCoding {
    /// Canonical encoder: sorted keys, no whitespace, whole-second ISO dates.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func data<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try makeDecoder().decode(JSONValue.self, from: data(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try makeDecoder().decode(type, from: data(value))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of a unit's canonical bytes.
    static func hash(_ value: JSONValue) -> String {
        hash((try? data(value)) ?? Data())
    }

    /// Stamps are whole seconds (what survives a round trip through a file).
    static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    /// An ISO date string as a `Date` (unit values keep dates as strings).
    static func date(_ value: JSONValue?) -> Date? {
        guard let string = value?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// What a record holds (and the folder it lives in).
enum SyncKind: String, Codable, CaseIterable, Comparable {
    case settings
    case forum
    case session
    case run
    case watched

    /// Folder inside the sync root; settings live in `settings.json` at the root.
    var directory: String? {
        switch self {
        case .settings: nil
        case .forum: "forums"
        case .session: "sessions"
        case .run: "runs"
        case .watched: "watched"
        }
    }

    static func < (lhs: SyncKind, rhs: SyncKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The plaintext of one file. A tombstone has `deletedAt` and no fields.
struct SyncRecord: Codable, Equatable {
    var format = 1
    var kind: SyncKind
    /// The record key (topic key, run UUID, forum site URL, "settings").
    var id: String
    var fields: [String: JSONValue]?
    var stamps: [String: Date]?
    var deletedAt: Date?

    static func tombstone(kind: SyncKind, id: String, deletedAt: Date) -> SyncRecord {
        SyncRecord(kind: kind, id: id, fields: nil, stamps: nil, deletedAt: FolderSyncCoding.stamp(deletedAt))
    }

    var isTombstone: Bool { deletedAt != nil }

    /// Newest stamp of any unit (a tombstone beats the record only if newer).
    var latestStamp: Date {
        deletedAt ?? stamps?.values.max() ?? .distantPast
    }

    func canonicalData() throws -> Data {
        try FolderSyncCoding.data(self)
    }

    /// `<root>/<dir>/<hex prefix of SHA-256(id)>.json`, or `settings.json`.
    var fileName: String { Self.fileName(kind: kind, id: id) }

    static func fileName(kind: SyncKind, id: String) -> String {
        guard kind != .settings else { return "settings.json" }
        return String(FolderSyncCoding.hash(Data(id.utf8)).prefix(32)) + ".json"
    }

    /// "kind/id": the key of this record in the baseline and in plans.
    var recordKey: String { Self.recordKey(kind: kind, id: id) }
    static func recordKey(kind: SyncKind, id: String) -> String { "\(kind.rawValue)/\(id)" }
}

/// Settings that belong to one device and never sync. Any other setting —
/// including ones added in later versions — syncs.
enum FolderSyncSettings {
    static let deviceLocalKeys: Set<String> = [
        "browserBarPosition",
        "hasCompletedOnboarding",
        "syncAPIKeys"
    ]

    /// Each provider configuration is one unit: `configurations.<provider>`.
    static let configurationPrefix = "configurations."
}

/// How the units of each kind are built and merged.
enum FolderSyncSchema {
    enum Rule {
        case newest
        case max
        case min
    }

    /// Never synced: the fetched topic text (a device-local cache) and the
    /// time of this device's last reply check, which changes on every watch
    /// check and would otherwise rewrite files on every device every 30 min.
    static let sessionExcluded: Set<String> = ["source", "rawPages", "lastCheckedAt"]
    static let watchedExcluded: Set<String> = ["lastCheckedAt"]

    /// Units made of several fields.
    static func groups(for kind: SyncKind) -> [String: [String]] {
        switch kind {
        case .session:
            // Chat as a whole (a clear or edit replaces it; never a union),
            // and the summary with what produced it.
            [
                "chat": ["history", "chatUpdatedAt"],
                "summary": ["summary", "summaryPostCount", "summaryUpdatedAt", "provider", "model"]
            ]
        default:
            [:]
        }
    }

    static func rule(kind: SyncKind, unit: String) -> Rule {
        switch (kind, unit) {
        case (.session, "updatedAt"), (.session, "lastAccessedAt"), (.session, "lastCheckedAt"): .max
        case (.session, "createdAt"): .min
        case (.watched, "knownPostCount"), (.watched, "lastCheckedAt"): .max
        case (.watched, "addedAt"): .min
        case (.forum, "lastVisitedAt"): .max
        case (.forum, "addedAt"): .min
        default: .newest
        }
    }

    /// Splits a model's JSON object into units.
    static func units(kind: SyncKind, object: [String: JSONValue]) -> [String: JSONValue] {
        if kind == .run { return ["run": .object(object)] }
        var remaining = object
        if kind == .session {
            for key in sessionExcluded { remaining.removeValue(forKey: key) }
        } else if kind == .watched {
            for key in watchedExcluded { remaining.removeValue(forKey: key) }
        }
        var units: [String: JSONValue] = [:]
        for (name, members) in groups(for: kind) {
            var group: [String: JSONValue] = [:]
            for member in members {
                if let value = remaining.removeValue(forKey: member) { group[member] = value }
            }
            units[name] = .object(group)
        }
        for (key, value) in remaining { units[key] = value }
        return units
    }

    /// Joins units back into a model's JSON object.
    static func object(kind: SyncKind, units: [String: JSONValue]) -> [String: JSONValue] {
        if kind == .run { return units["run"]?.objectValue ?? [:] }
        let groups = groups(for: kind)
        var object: [String: JSONValue] = [:]
        for (name, value) in units {
            if groups[name] != nil, let members = value.objectValue {
                for (key, member) in members { object[key] = member }
            } else if !value.isNull {
                object[name] = value
            }
        }
        return object
    }

    // MARK: Settings

    /// Synced settings units (API keys and device-local settings removed).
    static func settingsUnits(_ settings: AppSettings) throws -> [String: JSONValue] {
        guard var object = try FolderSyncCoding.json(settings.persistable).objectValue else { return [:] }
        for key in FolderSyncSettings.deviceLocalKeys { object.removeValue(forKey: key) }
        var units: [String: JSONValue] = [:]
        if let configurations = object.removeValue(forKey: "configurations")?.objectValue {
            for (provider, value) in configurations {
                var configuration = value.objectValue ?? [:]
                configuration.removeValue(forKey: "apiKey")
                units[FolderSyncSettings.configurationPrefix + provider] = .object(configuration)
            }
        }
        for (key, value) in object { units[key] = value }
        return units
    }

    /// `local` with synced units applied. API keys and device-local settings
    /// stay as they are on this device.
    static func applying(settingsUnits units: [String: JSONValue], to local: AppSettings) throws -> AppSettings {
        guard var object = try FolderSyncCoding.json(local).objectValue else { return local }
        var configurations = object["configurations"]?.objectValue ?? [:]
        for (name, value) in units where !value.isNull {
            if name.hasPrefix(FolderSyncSettings.configurationPrefix) {
                let provider = String(name.dropFirst(FolderSyncSettings.configurationPrefix.count))
                var configuration = value.objectValue ?? [:]
                configuration["apiKey"] = configurations[provider]?.objectValue?["apiKey"] ?? .string("")
                configurations[provider] = .object(configuration)
            } else if !FolderSyncSettings.deviceLocalKeys.contains(name), name != "configurations" {
                object[name] = value
            }
        }
        object["configurations"] = .object(configurations)
        var result = try FolderSyncCoding.decode(AppSettings.self, from: .object(object))
        // Keys are never read from the folder, whatever it holds.
        for provider in AIProvider.allCases {
            var configuration = result.configuration(for: provider)
            configuration.apiKey = local.configuration(for: provider).apiKey
            result.setConfiguration(configuration, for: provider)
        }
        return result
    }
}

// MARK: - Merge

enum FolderSyncMerge {
    /// Merges copies of one record (local, remote, conflict versions).
    /// Commutative and associative: the result does not depend on order.
    static func merge(_ records: [SyncRecord]) -> SyncRecord? {
        guard var result = records.first else { return nil }
        for record in records.dropFirst() {
            result = merge(result, record)
        }
        return result
    }

    static func merge(_ a: SyncRecord, _ b: SyncRecord) -> SyncRecord {
        switch (a.isTombstone, b.isTombstone) {
        case (true, true):
            return (a.deletedAt ?? .distantPast) >= (b.deletedAt ?? .distantPast) ? a : b
        case (true, false):
            // A delete wins only over a copy last changed before it.
            return (a.deletedAt ?? .distantPast) > b.latestStamp ? a : b
        case (false, true):
            return (b.deletedAt ?? .distantPast) > a.latestStamp ? b : a
        case (false, false):
            break
        }
        let aFields = a.fields ?? [:], bFields = b.fields ?? [:]
        let aStamps = a.stamps ?? [:], bStamps = b.stamps ?? [:]
        var fields: [String: JSONValue] = [:]
        var stamps: [String: Date] = [:]
        for unit in Set(aFields.keys).union(bFields.keys) {
            let aValue = aFields[unit], bValue = bFields[unit]
            let aStamp = aStamps[unit] ?? .distantPast, bStamp = bStamps[unit] ?? .distantPast
            guard let aValue else { fields[unit] = bValue; stamps[unit] = bStamp; continue }
            guard let bValue else { fields[unit] = aValue; stamps[unit] = aStamp; continue }
            stamps[unit] = max(aStamp, bStamp)
            switch FolderSyncSchema.rule(kind: a.kind, unit: unit) {
            case .max:
                fields[unit] = order(aValue, bValue) >= 0 ? aValue : bValue
            case .min:
                fields[unit] = order(aValue, bValue) <= 0 ? aValue : bValue
            case .newest:
                if aStamp != bStamp {
                    fields[unit] = aStamp > bStamp ? aValue : bValue
                } else {
                    // Same second, different values: any fixed choice works.
                    fields[unit] = bytes(aValue).lexicographicallyPrecedes(bytes(bValue)) ? bValue : aValue
                }
            }
        }
        return SyncRecord(kind: a.kind, id: a.id, fields: fields, stamps: stamps, deletedAt: nil)
    }

    /// Orders values for max/min units: null < numbers < strings (ISO dates
    /// order as strings); anything else by canonical bytes.
    static func order(_ a: JSONValue, _ b: JSONValue) -> Int {
        func number(_ value: JSONValue) -> Double? {
            switch value {
            case .int(let v): Double(v)
            case .double(let v): v
            default: nil
            }
        }
        if a == b { return 0 }
        if a.isNull { return -1 }
        if b.isNull { return 1 }
        if let x = number(a), let y = number(b) { return x < y ? -1 : (x > y ? 1 : 0) }
        if let x = a.stringValue, let y = b.stringValue { return x < y ? -1 : 1 }
        return bytes(a).lexicographicallyPrecedes(bytes(b)) ? -1 : 1
    }

    private static func bytes(_ value: JSONValue) -> Data {
        (try? FolderSyncCoding.data(value)) ?? Data()
    }
}
