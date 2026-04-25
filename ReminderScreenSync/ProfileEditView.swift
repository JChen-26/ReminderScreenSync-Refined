import SwiftUI

struct ProfileEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var profile: SyncProfile?

    @State private var name: String = ""
    @State private var deviceId: String = ""
    @State private var selectedListIDs: Set<String> = []
    @State private var pollInterval: String = "1"

    private var isEditing: Bool { profile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑同步任务" : "新建同步任务")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("名称")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("例如：厨房便利贴", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("目标设备")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("目标设备", selection: $deviceId) {
                    Text("请选择设备").tag("")
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(device.deviceId)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.devices.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reminders 列表")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全选") {
                        selectedListIDs = Set(model.reminderLists.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.reminderLists.isEmpty)
                }

                if model.reminderLists.isEmpty {
                    Text("请先授权并读取 Reminders 列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.reminderLists) { list in
                                Toggle(isOn: Binding(
                                    get: { selectedListIDs.contains(list.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedListIDs.insert(list.id)
                                        } else {
                                            selectedListIDs.remove(list.id)
                                        }
                                    }
                                )) {
                                    Text(list.displayName)
                                        .font(.subheadline)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("轮询周期（分钟）")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("1", text: $pollInterval)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("分钟")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    save()
                } label: {
                    Text(isEditing ? "保存" : "创建")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let profile = profile {
                name = profile.name
                deviceId = profile.deviceId
                selectedListIDs = Set(profile.reminderListIDs)
                pollInterval = String(profile.pollIntervalMinutes)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deviceId.isEmpty
            && !selectedListIDs.isEmpty
            && (Int(pollInterval.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    private func save() {
        let minutes = Int(pollInterval.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let deviceName = model.deviceName(for: deviceId)
        if let existing = profile {
            let wasRunning = model.isProfileRunning(existing.id)
            if wasRunning {
                model.stopProfile(existing.id)
            }
            let updated = SyncProfile(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: deviceId,
                deviceName: deviceName,
                reminderListIDs: Array(selectedListIDs),
                pollIntervalMinutes: max(1, minutes),
                isEnabled: existing.isEnabled
            )
            model.profileManager.update(updated)
            if wasRunning {
                Task { await model.startProfile(updated) }
            }
        } else {
            let newProfile = SyncProfile(
                id: UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: deviceId,
                deviceName: deviceName,
                reminderListIDs: Array(selectedListIDs),
                pollIntervalMinutes: max(1, minutes),
                isEnabled: true
            )
            model.profileManager.add(newProfile)
        }
        dismiss()
    }
}
