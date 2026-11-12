import Foundation
import UserNotifications

/// Daily creatine reminder. The phone holds the next 30 days of one-off notifications, so the one for today
/// can be left out once creatine is already taken. The page asks for a refresh whenever the app opens or
/// anything changes, which keeps the 30 days rolling forward.
enum Reminders {
    private static let prefix = "creatine-"
    private static let days = 30

    /// `json` is {"on": Bool, "time": "HH:mm", "taken": Bool}. Returns "ok", "denied" (no permission) or "bad".
    static func apply(_ json: String) async -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "bad" }
        let on = object["on"] as? Bool ?? false
        let time = object["time"] as? String ?? "08:00"
        let taken = object["taken"] as? Bool ?? false

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        guard on else { return "ok" }

        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return "bad" }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { return "denied" }
        case .denied:
            return "denied"
        default:
            break
        }

        let calendar = Calendar.current
        let now = Date()
        for offset in 0..<days {
            if offset == 0 && taken { continue }
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            var parts2 = calendar.dateComponents([.year, .month, .day], from: day)
            parts2.hour = parts[0]
            parts2.minute = parts[1]
            guard let fire = calendar.date(from: parts2), fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Creatine"
            content.body = "Time to take it."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts2, repeats: false)
            let id = prefix + String(format: "%04d-%02d-%02d", parts2.year ?? 0, parts2.month ?? 0, parts2.day ?? 0)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        return "ok"
    }
}
