import Foundation

/// The small snapshot the app hands to the home-screen widget. The page builds it, the widget only reads it.
struct WidgetSnapshot: Codable {
    struct Item: Codable {
        var name: String
        var done: Bool
    }

    struct Day: Codable {
        var date: String   // yyyy-MM-dd, local time
        var on: Bool       // checked in that day
    }

    var date: String
    var checkedIn: Bool
    var month: String        // yyyy-MM, the month monthCount belongs to
    var monthCount: Int      // days checked in during that month
    var week: [Day]
    var session: String
    var items: [Item]

    static let sample = WidgetSnapshot(
        date: "", checkedIn: true, month: "", monthCount: 12,
        week: [],
        session: "Push",
        items: [
            Item(name: "Bench Press", done: true),
            Item(name: "Overhead Press", done: true),
            Item(name: "Incline Dumbbell Press", done: false),
            Item(name: "Triceps Pushdown", done: false),
        ]
    )
}

/// Shares the snapshot between the app and the widget through an App Group container.
/// Compiled into both targets.
enum WidgetStore {
    static let baseGroup = "group.Lift.Lift"
    private static let fileName = "widget.json"

    /// The App Groups this build was really signed with, read from its embedded provisioning profile.
    /// SideStore and AltStore sign with their own copy of the group id (a team id gets added), so the plain
    /// id from the source code is not the one that exists on the phone.
    private static func profileGroups(_ bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return [] }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }

    /// Candidate group ids, best first: the signed profile, the `ALTAppGroups` key that SideStore/AltStore
    /// add to Info.plist, then the plain id (Xcode and paid accounts).
    /// From inside the widget the host app is read as well.
    static var groupIDs: [String] {
        var ids: [String] = []
        func collect(_ bundle: Bundle) {
            ids += profileGroups(bundle)
            if let list = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
                ids += list
            }
        }
        collect(Bundle.main)
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let hostBundle = Bundle(url: host) {
                collect(hostBundle)
            }
        }
        ids.append(baseGroup)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func containerURL() -> URL? {
        for id in groupIDs {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return url
            }
        }
        return nil
    }

    /// Stores the JSON the page sent and says what happened: "ok", or the reason it did not work.
    /// The page shows this text in Settings so a broken App Group is visible instead of silent.
    static func write(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              (try? JSONDecoder().decode(WidgetSnapshot.self, from: data)) != nil else {
            return "The widget data was not valid."
        }
        guard let dir = containerURL() else {
            return "No App Group is available in this install. Tried: " + groupIDs.joined(separator: ", ")
        }
        do {
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
            return "ok"
        } catch {
            return "Could not write the widget data: " + error.localizedDescription
        }
    }

    /// One line the widget shows when it has nothing to draw.
    static func status() -> String {
        guard let dir = containerURL() else {
            return "No App Group. Tried: " + groupIDs.joined(separator: ", ")
        }
        let file = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: file.path)
            ? "Data found but it could not be read."
            : "App Group works. Waiting for data from the app."
    }

    static func read() -> WidgetSnapshot? {
        guard let dir = containerURL(),
              let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
