import CoreLocation
import Foundation
import UserNotifications
import WochenleichtCore

/// Plant die (penetranten) lokalen Erinnerungen.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    enum Action {
        static let water250 = "WATER_250"
        static let water500 = "WATER_500"
        static let mealEaten = "MEAL_EATEN"
        static let snooze = "SNOOZE_15"
    }

    private let center = UNUserNotificationCenter.current()
    private static let maxPending = 64
    private static let maxStoreRegions = 6

    func registerCategories() {
        let water = UNNotificationCategory(
            identifier: PlannedReminder.waterCategory,
            actions: [
                UNNotificationAction(identifier: Action.water250, title: "+250 ml getrunken", options: []),
                UNNotificationAction(identifier: Action.water500, title: "+500 ml getrunken", options: []),
                UNNotificationAction(identifier: Action.snooze, title: "In 15 Min. erneut", options: []),
            ],
            intentIdentifiers: [], options: []
        )
        let meal = UNNotificationCategory(
            identifier: PlannedReminder.mealCategory,
            actions: [
                UNNotificationAction(identifier: Action.mealEaten, title: "Gegessen ✓", options: []),
                UNNotificationAction(identifier: Action.snooze, title: "In 15 Min. erneut", options: []),
            ],
            intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([water, meal])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Ersetzt alle geplanten Erinnerungen durch die neu berechneten.
    func reschedule(reminders makeReminders: (Int) -> [PlannedReminder], stores: [Supermarket], openShoppingItems: Int,
                    proximityAlerts: Bool) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        center.removeAllPendingNotificationRequests()

        var locationRequests: [UNNotificationRequest] = []
        let locationStatus = CLLocationManager().authorizationStatus
        if proximityAlerts, openShoppingItems > 0,
           locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways {
            for store in stores.prefix(Self.maxStoreRegions) {
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: store.latitude, longitude: store.longitude),
                                              radius: 150, identifier: "store-\(store.id)")
                region.notifyOnEntry = true
                region.notifyOnExit = false
                let content = UNMutableNotificationContent()
                content.title = "🛒 Du bist bei \(store.name)"
                content.body = "Auf deiner Einkaufsliste stehen noch \(openShoppingItems) Artikel. Kauf nur, was auf der Liste steht!"
                content.sound = .default
                content.userInfo = ["storeId": store.id]
                locationRequests.append(UNNotificationRequest(identifier: "store-\(store.id)", content: content,
                                                              trigger: UNLocationNotificationTrigger(region: region, repeats: true)))
            }
        }

        let reminders = makeReminders(Self.maxPending - locationRequests.count)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.userInfo = reminder.userInfo
            if let category = reminder.categoryIdentifier {
                content.categoryIdentifier = category
            }
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let request = UNNotificationRequest(identifier: reminder.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
        for request in locationRequests {
            try? await center.add(request)
        }
    }

    /// Wiederholt eine Benachrichtigung in 15 Minuten.
    func snooze(_ content: UNNotificationContent) async {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        let request = UNNotificationRequest(identifier: "snooze-\(UUID().uuidString)", content: copy,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false))
        try? await center.add(request)
    }

    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "💧 So sehen deine Erinnerungen aus"
        content.body = "Halte die Benachrichtigung gedrückt, um direkt Wasser einzutragen."
        content.sound = .default
        content.categoryIdentifier = PlannedReminder.waterCategory
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        try? await center.add(request)
    }
}
