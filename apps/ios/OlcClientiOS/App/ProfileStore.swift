import Combine
import Foundation

struct VPNProfile: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var subscription: Subscription?
    var bootstrap: BootstrapDescriptor? = nil
    var isBuiltIn: Bool

    var isConfigured: Bool {
        subscription != nil || bootstrap != nil
    }
}

private struct ManagedEnrollment: Codable {
    let id: String
    let name: String
    let bootstrap: BootstrapDescriptor
}

enum BuiltInProfiles {
    static func make() -> [VPNProfile] {
        make(bundle: .main)
    }

    static func make(bundle: Bundle) -> [VPNProfile] {
        guard let url = bundle.url(forResource: "BuiltInProfiles.local", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data) else {
            return []
        }

        return profiles.map { profile in
            VPNProfile(
                id: profile.id,
                name: profile.name,
                subscription: profile.subscription,
                bootstrap: profile.bootstrap,
                isBuiltIn: true
            )
        }
    }
}

final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [VPNProfile] = []
    @Published private(set) var selectedProfileID: String = ""

    private let defaults: UserDefaults
    private let builtInProfiles: [VPNProfile]
    private let customProfilesKey = "vpnProfiles.custom.v1"
    private let selectedProfileKey = "vpnProfiles.selectedProfileID.v1"

    init(defaults: UserDefaults = .standard, builtInProfiles: [VPNProfile] = BuiltInProfiles.make()) {
        self.defaults = defaults
        self.builtInProfiles = builtInProfiles
        reload()
    }

    var selectedProfile: VPNProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func selectProfile(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        defaults.set(id, forKey: selectedProfileKey)
    }

    @discardableResult
    func addProfile(name: String, subscription: Subscription) -> VPNProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = VPNProfile(
            id: "custom-\(UUID().uuidString)",
            name: trimmedName.isEmpty ? subscription.carrier : trimmedName,
            subscription: subscription,
            bootstrap: nil,
            isBuiltIn: false
        )
        var customProfiles = loadCustomProfiles()
        customProfiles.append(profile)
        saveCustomProfiles(customProfiles)
        reload(preferredSelection: profile.id)
        return profile
    }

    @discardableResult
    func addProfileFromJSON(name: String, json: String) throws -> VPNProfile {
        let data = Data(json.utf8)
        let subscription = try JSONDecoder().decode(Subscription.self, from: data)
        return addProfile(name: name, subscription: subscription)
    }

    @discardableResult
    func addManagedProfileFromJSON(json: String) throws -> VPNProfile {
        guard let profile = try addManagedProfilesFromJSON(json: json).first else {
            throw managedEnrollmentError()
        }
        return profile
    }

    @discardableResult
    func addManagedProfilesFromJSON(json: String) throws -> [VPNProfile] {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let enrollments: [ManagedEnrollment]
        if let batch = try? decoder.decode([ManagedEnrollment].self, from: data) {
            enrollments = batch
        } else {
            enrollments = [try decoder.decode(ManagedEnrollment.self, from: data)]
        }
        guard !enrollments.isEmpty else { throw managedEnrollmentError() }

        let allowedIDs = Set(builtInProfiles.map(\.id))
        let ids = enrollments.map(\.id)
        guard Set(ids).count == ids.count,
              enrollments.allSatisfy({ enrollment in
                  allowedIDs.contains(enrollment.id) &&
                      !enrollment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      enrollment.bootstrap.isValid
              }) else {
            throw managedEnrollmentError()
        }

        let profiles = enrollments.map { enrollment in
            VPNProfile(
                id: enrollment.id,
                name: enrollment.name,
                subscription: nil,
                bootstrap: enrollment.bootstrap,
                isBuiltIn: false
            )
        }
        let importedIDs = Set(profiles.map(\.id))
        var customProfiles = loadCustomProfiles().filter { !importedIDs.contains($0.id) }
        customProfiles.append(contentsOf: profiles)
        saveCustomProfiles(customProfiles)
        reload(preferredSelection: profiles.first?.id)
        return profiles
    }

    @discardableResult
    func restoreManagedProfile(id: String, name: String, bootstrap: BootstrapDescriptor) -> Bool {
        guard profiles.first(where: { $0.id == id })?.bootstrap == nil,
              builtInProfiles.contains(where: { $0.id == id }),
              bootstrap.isValid else {
            return false
        }
        let restored = VPNProfile(
            id: id,
            name: name,
            subscription: nil,
            bootstrap: bootstrap,
            isBuiltIn: false
        )
        var customProfiles = loadCustomProfiles().filter { $0.id != id }
        customProfiles.append(restored)
        saveCustomProfiles(customProfiles)
        reload(preferredSelection: id)
        return true
    }

    @discardableResult
    func restoreManagedEnrollment(from descriptor: ManagedTunnelDescriptor) -> [String] {
        var restored: [String] = []
        for template in builtInProfiles {
            let bootstrap: BootstrapDescriptor?
            if template.id == descriptor.profileID {
                bootstrap = descriptor.bootstrap
            } else {
                bootstrap = descriptor.bootstrap.sibling(
                    from: descriptor.profileID,
                    to: template.id
                )
            }
            if let bootstrap,
               restoreManagedProfile(id: template.id, name: template.name, bootstrap: bootstrap) {
                restored.append(template.id)
            }
        }
        return restored
    }

    func deleteProfile(id: String) {
        guard !builtInProfiles.contains(where: { $0.id == id }) else { return }
        let customProfiles = loadCustomProfiles().filter { $0.id != id }
        saveCustomProfiles(customProfiles)
        let preferred = selectedProfileID == id ? profiles.first?.id : selectedProfileID
        reload(preferredSelection: preferred)
    }

    func reload(preferredSelection: String? = nil) {
        let customProfiles = loadCustomProfiles()
        let customByID = Dictionary(uniqueKeysWithValues: customProfiles.map { ($0.id, $0) })
        let builtInIDs = Set(builtInProfiles.map(\.id))
        profiles = builtInProfiles.map { customByID[$0.id] ?? $0 }
            + customProfiles.filter { !builtInIDs.contains($0.id) }

        let persistedSelection = preferredSelection ?? defaults.string(forKey: selectedProfileKey)
        if let persistedSelection, profiles.contains(where: { $0.id == persistedSelection }) {
            selectedProfileID = persistedSelection
        } else {
            selectedProfileID = profiles.first?.id ?? ""
        }

        if !selectedProfileID.isEmpty {
            defaults.set(selectedProfileID, forKey: selectedProfileKey)
        }
    }

    private func loadCustomProfiles() -> [VPNProfile] {
        guard let data = defaults.data(forKey: customProfilesKey) else { return [] }
        return (try? JSONDecoder().decode([VPNProfile].self, from: data))?
            .map { profile in
                VPNProfile(
                    id: profile.id,
                    name: profile.name,
                    subscription: profile.subscription,
                    bootstrap: profile.bootstrap,
                    isBuiltIn: false
                )
            } ?? []
    }

    private func saveCustomProfiles(_ profiles: [VPNProfile]) {
        let data = try? JSONEncoder().encode(profiles.filter { !$0.isBuiltIn })
        defaults.set(data, forKey: customProfilesKey)
    }

    private func managedEnrollmentError() -> NSError {
        NSError(
            domain: "olc.profile",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "некорректный managed enrollment"]
        )
    }
}
