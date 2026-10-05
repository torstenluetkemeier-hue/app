import BackgroundTasks
import UIKit
import UserNotifications
import WochenleichtCore

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskId = "de.wochenleicht.app.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            NotificationService.shared.registerCategories()
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            Self.handleRefresh(task)
        }
        return true
    }

    /// Plant die nächste Hintergrundaktualisierung (frische Erinnerungen, neuer Tag im Plan).
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            AppEnvironment.shared.model?.refreshForNewDay()
            await AppEnvironment.shared.model?.rescheduleNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // Erinnerungen auch anzeigen, wenn die App offen ist – penetrant eben.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let info = content.userInfo
        await MainActor.run {
            let model = AppEnvironment.shared.model
            switch response.actionIdentifier {
            case NotificationService.Action.water250:
                model?.logWater(250)
            case NotificationService.Action.water500:
                model?.logWater(500)
            case NotificationService.Action.mealEaten:
                if let dayString = info["day"] as? String, let day = DayKey(string: dayString),
                   let mealString = info["mealId"] as? String, let mealId = UUID(uuidString: mealString) {
                    model?.setEaten(true, day: day, mealId: mealId)
                }
            default:
                break
            }
        }
        if response.actionIdentifier == NotificationService.Action.snooze {
            await NotificationService.shared.snooze(content)
        }
    }
}
