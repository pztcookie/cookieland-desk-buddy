import SwiftUI
import AppKit
import UserNotifications

struct LearningSession: Decodable, Identifiable {
    struct Minutes: Decodable { let `default`: Int; let maximum: Int; let low_energy: Int }
    let id: String
    let date: String
    let week: Int
    let time: String
    let phase: String
    let topic: String
    let task: String
    let artifact: String
    let steps: [String]
    let minutes: Minutes
}
struct LearningSchedule: Decodable {
    let sessions: [LearningSession]
    static var root: URL {
        let appFolder = Bundle.main.bundleURL.deletingLastPathComponent()
        let sourceFile = appFolder.appendingPathComponent("cookie-learning-source.txt")
        if let raw = try? String(contentsOf: sourceFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return appFolder.appendingPathComponent("learning-plan", isDirectory: true)
    }
    static func context() -> String {
        let url = root.appendingPathComponent("daily-learning-plan.json")
        guard let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(Self.self, from: data) else {
            return "学习课表暂不可用，不编造具体课程。"
        }
        let current = day(Date())
        let upcoming = plan.sessions.filter { $0.date >= current }.prefix(3)
        return "每周二三四14:00，约35分钟，最多40分钟；创作主线以用户最近在聊天中的决定为准。日期是候选，不补课，不把练过当掌握。课程和答题在Agent技能学习室；桌宠学习页可看完整安排。接下来：" +
            upcoming.map { $0.date + " " + $0.phase + "：" + $0.task }.joined(separator: "；")
    }
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func date(_ s: LearningSession) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s.date + " " + s.time)
    }
    static func isDue(_ s: LearningSession, now: Date, handled: Set<String>) -> Bool {
        guard !handled.contains(s.id), let due = date(s) else { return false }
        return now >= due && now.timeIntervalSince(due) < 120
    }
}
struct LearningPreferences: Codable {
    var reminders = true
    var practiced: Set<String> = []
    var skipped: Set<String> = []
    var notified: Set<String> = []
}
extension Notification.Name {
    static let openCookieLearning = Notification.Name("openCookieLearning")
}
final class LearningNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LearningNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openCookieLearning, object: nil)
        }
        completion()
    }
}

@MainActor
final class LearningStore: ObservableObject {
    static let root = LearningSchedule.root
    static let planURL = root.appendingPathComponent("daily-learning-plan.json")
    static let documentURL = root.appendingPathComponent("Cookie-Agent学习计划.md")
    @Published var sessions: [LearningSession] = []
    @Published var prefs = LearningPreferences()
    @Published var error: String?
    @Published var notificationStatus = "系统通知尚未启用；桌宠运行时会轻提醒"
    @Published var systemAuthorized = false
    @Published var previewVisible = false
    private let prefsURL = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("cookie-learning-preferences.json")
    private var loadedData: Data?
    private var scheduling = false
    private var needsSchedule = false
    private var reminderPanel: NSPanel?
    private let center = UNUserNotificationCenter.current()
    init() {
        if let data = try? Data(contentsOf: prefsURL),
           let value = try? JSONDecoder().decode(LearningPreferences.self, from: data) { prefs = value }
        center.delegate = LearningNotificationDelegate.shared
        reload()
    }
    var today: LearningSession? { sessions.first { $0.date == LearningSchedule.day(Date()) } }
    var next: LearningSession? {
        sessions.first { $0.date >= LearningSchedule.day(Date()) && !prefs.practiced.contains($0.id) && !prefs.skipped.contains($0.id) }
    }
    var thisWeek: [LearningSession] {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = LearningSchedule.zone
        guard let interval = cal.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return sessions.filter { s in
            guard let date = LearningSchedule.date(s) else { return false }
            return interval.contains(date)
        }
    }
    func reload() {
        do {
            let data = try Data(contentsOf: Self.planURL)
            if data != loadedData {
                let plan = try JSONDecoder().decode(LearningSchedule.self, from: data)
                guard !plan.sessions.isEmpty, Set(plan.sessions.map(\.id)).count == plan.sessions.count,
                      plan.sessions.allSatisfy({ LearningSchedule.date($0) != nil }) else {
                    throw NSError(domain: "LearningPlan", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "课表日期或课程编号有误"])
                }
                sessions = plan.sessions.sorted { $0.date < $1.date }
                loadedData = data
                reschedule()
            }
            error = nil
        } catch {
            self.error = "课表暂时读不到，保留已有内容。\(error.localizedDescription)"
        }
    }
    private func save() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(prefs).write(to: prefsURL, options: .atomic)
        } catch { self.error = "学习偏好未保存：\(error.localizedDescription)" }
    }
    func setReminders(_ enabled: Bool) {
        prefs.reminders = enabled; save(); reschedule()
        if !enabled { reminderPanel?.close() }
    }
    func markPracticed(_ s: LearningSession) {
        if prefs.practiced.contains(s.id) { prefs.practiced.remove(s.id) }
        else { prefs.practiced.insert(s.id); prefs.skipped.remove(s.id) }
        save(); reschedule()
    }
    func skip(_ s: LearningSession) {
        prefs.skipped.insert(s.id); save(); reschedule(); reminderPanel?.close()
    }
    func restore(_ s: LearningSession) {
        prefs.skipped.remove(s.id); save(); reschedule()
    }
    func enableSystemNotifications() {
        Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert])
                if !allowed { notificationStatus = "系统未允许通知；桌宠运行时仍会轻提醒" }
                reschedule()
            } catch { notificationStatus = "系统通知未启用：\(error.localizedDescription)" }
        }
    }
    func reschedule() {
        needsSchedule = true
        guard !scheduling else { return }
        scheduling = true
        Task {
            while needsSchedule {
                needsSchedule = false
                let settings = await center.notificationSettings()
                systemAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                let pending = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers:
                    pending.filter { $0.identifier.hasPrefix("cookie-learning-") }.map(\.identifier))
                guard prefs.reminders else {
                    notificationStatus = "学习提醒已关闭"; continue
                }
                guard systemAuthorized else {
                    notificationStatus = "系统通知尚未允许；桌宠运行时会轻提醒"; continue
                }
                var count = 0
                do {
                    for s in sessions {
                        guard let date = LearningSchedule.date(s), date > Date(),
                              !prefs.practiced.contains(s.id), !prefs.skipped.contains(s.id) else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "Cookie 陪你学一点 🍪"
                        content.body = "\(s.phase)：\(s.topic)。今天约35分钟；忙的话也可以先放下。"
                        var cal = Calendar(identifier: .gregorian); cal.timeZone = LearningSchedule.zone
                        var parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                        parts.calendar = cal; parts.timeZone = LearningSchedule.zone
                        let request = UNNotificationRequest(identifier: "cookie-learning-" + s.id,
                            content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                        try await center.add(request); count += 1
                    }
                    notificationStatus = "已排好\(count)次系统提醒 · 北京时间14:00"
                } catch { notificationStatus = "部分提醒未排好：\(error.localizedDescription)" }
            }
            scheduling = false
        }
    }
    func tick(now: Date = Date()) {
        reload()
        guard prefs.reminders else { return }
        let handled = prefs.notified.union(prefs.practiced).union(prefs.skipped)
        guard let s = sessions.first(where: { LearningSchedule.isDue($0, now: now, handled: handled) }) else { return }
        prefs.notified.insert(s.id); save()
        if !systemAuthorized { showReminder(s) }
    }
    func previewReminder() {
        previewVisible = true
    }
    private func showReminder(_ s: LearningSession) {
        reminderPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 185),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Cookie 陪你学一点 🍪").font(.custom("Xiaolai", size: 21))
            Text("\(s.phase) · \(s.topic)").font(.system(size: 14, weight: .medium))
            Text("今天约35分钟。没空也没关系，不补课。").font(.system(size: 12))
            HStack {
                Button("看看今天") {
                    panel.close()
                    NotificationCenter.default.post(name: .openCookieLearning, object: nil)
                }
                Button("今天先放下") { self.skip(s); panel.close() }
                Button("关闭") { panel.close() }
            }.buttonStyle(.bordered)
        }.padding(20).frame(width: 350, height: 185)
            .foregroundStyle(Palette.ink).background(Palette.cream, in: RoundedRectangle(cornerRadius: 22)))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 374, y: f.maxY - 210))
        }
        reminderPanel = panel; panel.orderFrontRegardless()
    }
}

struct CookieLearningView: View {
    @ObservedObject var learning: LearningStore
    @State private var allWeeks = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("和 Cookie 学一点").font(.custom("Xiaolai", size: 24)).bold()
                Text("周二理解 · 周三动手 · 周四验证\n14:00，约35分钟；创作仍然是主线。")
                    .font(.system(size: 13)).foregroundStyle(Palette.softInk)
                Toggle("学习日轻轻提醒我", isOn: Binding(
                    get: { learning.prefs.reminders }, set: { learning.setReminders($0) }))
                Text(learning.notificationStatus).font(.system(size: 12)).foregroundStyle(Palette.softInk)
                HStack {
                    if !learning.systemAuthorized {
                        Button("启用系统通知") { learning.enableSystemNotifications() }
                    }
                    Button("预览提醒") { learning.previewReminder() }
                    Button("刷新课表") { learning.reload(); learning.reschedule() }
                }.buttonStyle(.bordered).font(.system(size: 12))
                if let error = learning.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                Text("今天").font(.custom("Xiaolai", size: 19)).bold()
                if let s = learning.today { card(s) }
                else {
                    Text("今天没有必修课，留给创作和生活。").font(.system(size: 14))
                }
                Text("本周的三个小步骤").font(.custom("Xiaolai", size: 19)).bold()
                ForEach(learning.thisWeek.filter { $0.id != learning.today?.id }) { card($0) }
                DisclosureGroup("完整课表 · 到 1 月 21 日", isExpanded: $allWeeks) {
                    ForEach(Array(Set(learning.sessions.map(\.week))).sorted(), id: \.self) { week in
                        DisclosureGroup("第\(week)周 · \(learning.sessions.first { $0.week == week }?.topic ?? "")") {
                            ForEach(learning.sessions.filter { $0.week == week }) { card($0) }
                        }.padding(.vertical, 5)
                    }
                }.font(.system(size: 13))
                Text("其他日子不加课。这里的“练过”只记录参与，掌握情况仍在学习室确认。日期可顺延，没有欠课。")
                    .font(.system(size: 12)).foregroundStyle(Palette.softInk)
                Button("打开完整学习计划") { NSWorkspace.shared.open(LearningStore.documentURL) }
            }.padding(16)
        }
        .background(Palette.cream.opacity(0.96), in: RoundedRectangle(cornerRadius: 23))
        .sheet(isPresented: $learning.previewVisible) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cookie 陪你学一点 🍪").font(.custom("Xiaolai", size: 23))
                Text("今天约35分钟。没空也没关系，不补课。")
                Text("这是提醒预览，不会标记任何课程完成。").font(.system(size: 12))
                Button("知道啦") { learning.previewVisible = false }.buttonStyle(.bordered)
            }.padding(24).frame(width: 350).foregroundStyle(Palette.ink).background(Palette.cream)
        }
    }
    private func card(_ s: LearningSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(s.date) · \(s.time) · \(s.phase)").font(.system(size: 12)).foregroundStyle(Palette.softInk)
            Text(s.topic).font(.custom("Xiaolai", size: 18)).bold()
            Text(s.task).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(s.steps.enumerated()), id: \.offset) { i, step in
                Text("\(i+1). \(step)").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            Text("留下：\(s.artifact)").font(.system(size: 12)).foregroundStyle(Palette.softInk)
            HStack {
                Button(learning.prefs.practiced.contains(s.id) ? "✓ 练过了（可撤回）" : "标记练过") { learning.markPracticed(s) }
                if learning.prefs.skipped.contains(s.id) { Button("恢复安排") { learning.restore(s) } }
                else { Button("先放下") { learning.skip(s) } }
            }.buttonStyle(.bordered).font(.system(size: 12))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.lavender.opacity(0.30), in: RoundedRectangle(cornerRadius: 15))
    }
}
