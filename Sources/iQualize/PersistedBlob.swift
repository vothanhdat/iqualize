import Foundation
import os.log

/// JSON blobs in UserDefaults, shared by the stores that keep one (`PresetStore`,
/// `RoomCorrectionStore`). A blob that fails to decode is never the only copy of the user's
/// data: its raw bytes are preserved under a timestamped backup key before the caller falls
/// back to its default, so a later save can't silently destroy it.
enum PersistedBlob {
    /// Decodes the blob at `key`. A missing key is normal (fresh install) and returns nil
    /// silently. A decode failure preserves the raw bytes (see `backUpCorrupt`), logs, appends
    /// a user-facing message to `failures`, and returns nil.
    static func load<T: Decodable>(
        _ type: T.Type,
        key: String,
        describedAs description: String,
        from defaults: UserDefaults,
        log: OSLog,
        failures: inout [String]
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let backupKey = backUpCorrupt(data, key: key, in: defaults)
            os_log(.error, log: log,
                   "failed to decode %{public}@ (%{public}@): %{public}@ — raw data preserved under %{public}@",
                   key, description, String(describing: error), backupKey)
            failures.append("\(description) couldn't be read — original data preserved")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    /// Writes the corrupt raw bytes under `<key>.corrupt.<ISO8601 timestamp>`. Backup keys
    /// are disjoint from every primary key, so later saves can never clobber them.
    /// Returns the backup key used.
    static func backUpCorrupt(_ data: Data, key: String, in defaults: UserDefaults) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var backupKey = "\(key).corrupt.\(timestamp)"
        // A stored object at the candidate key means an earlier corruption was already
        // preserved this second — suffix rather than overwrite an existing backup.
        var n = 2
        while defaults.object(forKey: backupKey) != nil {
            backupKey = "\(key).corrupt.\(timestamp).\(n)"
            n += 1
        }
        defaults.set(data, forKey: backupKey)
        return backupKey
    }
}
