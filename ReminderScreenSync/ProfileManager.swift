import Foundation

@MainActor
final class ProfileManager: ObservableObject {
    @Published var profiles: [SyncProfile] = []

    private let storeKey = "ReminderScreenSync.syncProfiles.v2"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
        migrateIfNeeded()
    }

    func add(_ profile: SyncProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: SyncProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            save()
        }
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func profile(id: UUID) -> SyncProfile? {
        profiles.first { $0.id == id }
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([SyncProfile].self, from: data) else {
            return
        }
        profiles = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            userDefaults.set(data, forKey: storeKey)
        }
    }

    private func migrateIfNeeded() {
        guard profiles.isEmpty else { return }

        let deviceId = userDefaults.string(forKey: "ReminderScreenSync.selectedDeviceId") ?? ""
        let listIDs = userDefaults.stringArray(forKey: "ReminderScreenSync.selectedReminderListIDs") ?? []
        let pollText = userDefaults.string(forKey: "ReminderScreenSync.pollIntervalMinutesText") ?? "1"
        let pollMinutes = Int(pollText) ?? 1

        guard !deviceId.isEmpty, !listIDs.isEmpty else { return }

        let profile = SyncProfile(
            id: UUID(),
            name: "默认同步",
            deviceId: deviceId,
            deviceName: deviceId,
            reminderListIDs: listIDs,
            pollIntervalMinutes: max(1, pollMinutes),
            isEnabled: true
        )
        profiles = [profile]
        save()
    }
}
