import Foundation

final class SyncRecordStore {
    private let userDefaults: UserDefaults
    private let storageKey = "ReminderScreenSync.syncRecords.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load(deviceId: String) -> [SyncRecord] {
        allRecords().filter { $0.deviceId == deviceId }
    }

    func save(_ records: [SyncRecord], deviceId: String) {
        var all = allRecords().filter { $0.deviceId != deviceId }
        all.append(contentsOf: records)

        if let data = try? JSONEncoder().encode(all) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func allRecords() -> [SyncRecord] {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([SyncRecord].self, from: data) else {
            return []
        }
        return records
    }
}
