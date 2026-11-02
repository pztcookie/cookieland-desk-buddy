import AppKit
import SwiftUI
import Foundation
import CoreText
import AVFoundation
import Speech

private enum Palette {
    static let ink = Color(red: 0.09, green: 0.25, blue: 0.52)
    static let softInk = Color(red: 0.22, green: 0.37, blue: 0.57)
    static let cream = Color(red: 1.00, green: 0.98, blue: 0.94)
    static let pink = Color(red: 0.98, green: 0.82, blue: 0.88)
    static let mint = Color(red: 0.79, green: 0.92, blue: 0.83)
    static let lavender = Color(red: 0.87, green: 0.83, blue: 0.97)
    static let stroke = Color(red: 0.31, green: 0.51, blue: 0.79)
}

private func workURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          url.host != nil else { return nil }
    return url
}

struct PlanTask: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var area: String
    var due: String
    var done: Bool
    var url: String? = nil
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: String
    var role: String
    var text: String
}

struct DayBlock: Codable, Identifiable, Equatable {
    var id: String
    var time: String
    var title: String
}

struct CompanionState: Codable {
    var tasks: [PlanTask]
    var ideas: [String]
    var messages: [ChatMessage]
    var mood: String?
    var weekStart: String?
    var dayStart: String?
    var todayTaskIDs: [String]?
    var dayBlocks: [DayBlock]?
    var spotifyURI: String?

    static let starter = CompanionState(
        tasks: [
            .init(id: "postcard", title: "画好一张小卡片", area: "week", due: "已完成", done: true),
            .init(id: "sketch", title: "给新角色画一张草稿", area: "week", due: "本周", done: false),
            .init(id: "little-world", title: "想想小世界的下一步", area: "later", due: "有空再说", done: false)
        ],
        ideas: ["一朵路过的云", "想去的咖啡店"],
        messages: [
            .init(id: UUID().uuidString, role: "assistant",
                  text: "我在这里。想到什么就说给我听，乱一点也没关系；我会帮你放好。")
        ],
        mood: "gentle",
        weekStart: nil,
        dayStart: nil,
        todayTaskIDs: ["sketch"],
        dayBlocks: [],
        spotifyURI: nil
    )
}

@MainActor
final class CompanionStore: ObservableObject {
    @Published var state: CompanionState

    private let fileURL = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("cookie-companion-state.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(CompanionState.self, from: data) {
            state = saved
        } else {
            state = .starter
        }
        rollWeekIfNeeded()
        rollDayIfNeeded()
        save()
    }

    private func rollWeekIfNeeded() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        format.timeZone = calendar.timeZone
        let current = format.string(from: monday)
        if state.weekStart == nil { state.weekStart = current }
        guard state.weekStart != current else { return }
        for index in state.tasks.indices where state.tasks[index].area == "week" {
            if state.tasks[index].done {
                state.tasks[index].area = "archive"
            } else {
                state.tasks[index].area = "later"
                state.tasks[index].due = "上周留下 · 重新安排"
            }
        }
        state.weekStart = current
        state.mood = "gentle"
    }

    func rollDayIfNeeded() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let today = formatter.string(from: Date())
        guard state.dayStart != today else { return }
        state.dayStart = today
        state.todayTaskIDs = state.tasks.first(where: { $0.area == "week" && !$0.done })
            .map { [$0.id] } ?? []
        state.dayBlocks = []
        save()
    }

    func addToToday(_ task: PlanTask) {
        var ids = state.todayTaskIDs ?? []
        guard !ids.contains(task.id), ids.count < 2 else { return }
        ids.append(task.id)
        state.todayTaskIDs = ids
        save()
    }

    func removeFromToday(_ task: PlanTask) {
        state.todayTaskIDs?.removeAll { $0 == task.id }
        save()
    }

    func setSpotifyURI(_ value: String) {
        state.spotifyURI = value
        save()
    }

    func removeDayBlock(_ block: DayBlock) {
        state.dayBlocks?.removeAll { $0.id == block.id }
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func toggle(_ task: PlanTask) {
        guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        state.tasks[index].done.toggle()
        state.mood = state.tasks[index].done ? "goofy" : "focused"
        save()
    }

    func cycleMood() {
        let moods = ["gentle", "playful", "goofy", "focused"]
        let index = moods.firstIndex(of: state.mood ?? "gentle") ?? 0
        state.mood = moods[(index + 1) % moods.count]
        save()
    }

    func addMessage(_ role: String, _ text: String) {
        state.messages.append(.init(id: UUID().uuidString, role: role, text: text))
        if state.messages.count > 80 { state.messages.removeFirst(state.messages.count - 80) }
        save()
    }

    func apply(_ answer: AgentAnswer) {
        let knownAreas = Set(["week", "later", "joy", "archive"])
        if Set(["gentle", "playful", "goofy", "focused"]).contains(answer.mood) {
            state.mood = answer.mood
        }
        for change in answer.updates {
            guard let index = state.tasks.firstIndex(where: { $0.id == change.id }),
                  knownAreas.contains(change.area) else { continue }
            state.tasks[index].done = change.done
            state.tasks[index].area = change.area
        }
        for addition in answer.additions {
            let title = addition.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, ["week", "later", "joy"].contains(addition.area),
                  !state.tasks.contains(where: { $0.title == title }) else { continue }
            state.tasks.append(.init(id: UUID().uuidString, title: title,
                                     area: addition.area, due: addition.due, done: false))
        }
        for link in answer.links {
            guard let url = workURL(link.url),
                  let index = state.tasks.firstIndex(where: {
                      $0.id == link.id || $0.title == link.id
                  }) else { continue }
            state.tasks[index].url = url.absoluteString
        }
        for idea in answer.ideas {
            let value = idea.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !state.ideas.contains(value) { state.ideas.append(value) }
        }
        if !answer.today.isEmpty {
            state.todayTaskIDs = answer.today.prefix(2).compactMap { value in
                state.tasks.first(where: { $0.id == value || $0.title == value })?.id
            }
        }
        if !answer.schedule.isEmpty {
            state.dayBlocks = answer.schedule.prefix(6).map {
                DayBlock(id: UUID().uuidString, time: $0.time, title: $0.title)
            }
        }
        addMessage("assistant", answer.reply)
    }
}

struct AgentAnswer: Codable, Sendable {
    struct Update: Codable, Sendable {
        var id: String
        var done: Bool
        var area: String
    }
    struct Addition: Codable, Sendable {
        var title: String
        var area: String
        var due: String
    }
    struct ScheduleItem: Codable, Sendable {
        var time: String
        var title: String
    }
    struct LinkUpdate: Codable, Sendable {
        var id: String
        var url: String
    }
    var reply: String
    var mood: String
    var updates: [Update]
    var additions: [Addition]
    var ideas: [String]
    var today: [String]
    var schedule: [ScheduleItem]
    var links: [LinkUpdate]
}

enum ChatEngine {
    static func answer(to userText: String, state: CompanionState) async throws -> AgentAnswer {
        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "yyyy 年 M 月 d 日"
        dateFormat.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let today = dateFormat.string(from: Date())
        let compactTasks = state.tasks.map {
            "\($0.id) | \($0.area) | \($0.done ? "完成" : "未完成") | \($0.due) | \($0.title) | 链接:\($0.url ?? "无")"
        }.joined(separator: "\n")
        let context = state.messages.suffix(6).map {
            "\($0.role == "user" ? "用户" : "Cookie")：\($0.text)"
        }.joined(separator: "\n")
        let prompt = """
        你是 Cookie 的 Cookieland 生活小助手。请用简短自然的中文直接回应用户，像温柔可靠的同伴，不说教、不催促。
        职责：接住散乱想法；把有明确期限且用户想完成的放到 week，游戏完成后或未来再决定的放到 later，纯粹想玩的放到 joy/ideas。每天最多建议一件主线和一件可选小事。做完可打勾，没做不补作业。不要把所有想法自动变成任务。
        今天是 \(today)。以用户这次说的话和当前计划为准；不要擅自假设固定截止日、职业安排或发布进度。画画、手工、旅行等灵感也可以只是乐趣。
        只在用户明确说某项完成时，才用 updates 标记 done=true；不要把上传、发布、收费或其他外部动作说成已完成。更新已有任务时使用原 id；没有变动就让 updates 为空。新承诺才加 additions；普通新念头放 ideas。不要调用工具，也不要声称同步了外部清单。
        reply 最多 120 个汉字，先接住感受，再给一个具体、很小的下一步；用户只想聊天时可以不安排任务。mood 请选择 gentle（安静接住）、playful（调皮）、goofy（完成后搞笑庆祝）、focused（认真梳理），要和回应内容相配。输出必须符合 JSON Schema。
        如果用户明确要安排今天，today 填今天选中的任务，最多两件，优先一个主线、一个可选。已有任务请填上面给出的原 id；这次新增的任务才填 additions 中的准确标题。否则 today 留空数组，不改今天安排。
        如果用户想排今天的课程表或工作时间，schedule 填完整的今天时间段，最多 6 段；用户说了具体上课时间就原样保留，没说具体时间只用「上午」「下午」「晚上」这样的宽松时段，不编造精确时间。普通聊天时 schedule 留空数组，不改变现有时间表。
        如果用户给了某个工作的网页链接，links 填对应任务原 id 与完整 http(s) URL；新任务可用 additions 里的准确标题。没有链接就留空，不要编造链接。任务标题旁的「打开」只会打开已保存的链接。

        当前计划周：\(state.weekStart ?? "未设置")，新一周开始时，已完成的上周任务归档，未完成的先移到 later 待重新安排。
        现有任务：
        \(compactTasks)
        想法花园：\(state.ideas.joined(separator: "、"))
        今天已安排的任务 ID：\((state.todayTaskIDs ?? []).joined(separator: "、"))
        今天已安排的时间段：\((state.dayBlocks ?? []).map { "\($0.time) \($0.title)" }.joined(separator: "；"))
        最近对话：
        \(context)
        用户这次说：\(userText)
        """
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run(prompt)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func run(_ prompt: String) throws -> AgentAnswer {
        let resources = Bundle.main.resourceURL!
        let schema = resources.appendingPathComponent("agent-response.schema.json")
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-answer-\(UUID().uuidString).json")
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-codex-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: result)
            try? FileManager.default.removeItem(at: log)
        }
        let preferred = URL(fileURLWithPath:
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let process = Process()
        process.executableURL = preferred
        process.currentDirectoryURL = Bundle.main.bundleURL.deletingLastPathComponent()
        process.arguments = [
            "exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
            "-s", "read-only", "-m", "gpt-6-luna", "-c", "model_reasoning_effort=low",
            "--output-schema", schema.path, "-o", result.path, "-"
        ]
        let input = Pipe()
        process.standardInput = input
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            throw NSError(domain: "CookieCompanion", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 Codex，请先打开或安装 ChatGPT 桌面版。"])
        }
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        try? logHandle.close()
        guard process.terminationStatus == 0 else {
            let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let errors = logText.split(separator: "\n").filter {
                $0.localizedCaseInsensitiveContains("error") ||
                $0.localizedCaseInsensitiveContains("failed")
            }.suffix(3).joined(separator: " ")
            let detail = errors.isEmpty ? "退出码 \(process.terminationStatus)" : String(errors.prefix(180))
            throw NSError(domain: "CookieCompanion", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "连接暂时没有完成（\(detail)）。你的话已保存，可点重试。"])
        }
        let data = try Data(contentsOf: result)
        return try JSONDecoder().decode(AgentAnswer.self, from: data)
    }
}

@MainActor
final class SpeechCapture: ObservableObject {
    @Published var isRecording = false
    @Published var message: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func toggle(onText: @escaping (String) -> Void) {
        if isRecording {
            stop()
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
                Task { @MainActor in
                    guard status == .authorized, microphoneAllowed else {
                        self.message = "需要在系统设置中允许麦克风和语音识别，才能直接说给 Cookie 听。"
                        return
                    }
                    do { try self.start(onText: onText) }
                    catch { self.message = "麦克风暂时没能启动，可以重试或用系统听写。" }
                }
            }
        }
    }

    private func start(onText: @escaping (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            message = "中文语音识别暂时不可用，可以用系统听写。"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        message = nil
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result { onText(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
    }
}

private func bundledImage(_ name: String) -> NSImage {
    guard let path = Bundle.main.path(forResource: name, ofType: "png"),
          let image = NSImage(contentsOfFile: path) else { return NSImage() }
    return image
}

private func registerHandwrittenFont() {
    guard let url = Bundle.main.url(forResource: "Xiaolai-Regular", withExtension: "ttf") else { return }
    var error: Unmanaged<CFError>?
    _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

@MainActor
enum PetAction: String {
    case strolling, focused, goofy, prank, dancing, listening, resting

    var label: String {
        switch self {
        case .strolling: "散步"
        case .focused: "认真工作"
        case .goofy: "搞怪"
        case .prank: "眨眼恶作剧"
        case .dancing: "跳舞"
        case .listening: "戴耳机听歌"
        case .resting: "休息"
        }
    }
}

@MainActor
final class DesktopPetController: ObservableObject {
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "cookieWalkingSpeed") }
    }
    @Published var sizeScale: Double {
        didSet { UserDefaults.standard.set(sizeScale, forKey: "cookieDesktopSize") }
    }
    @Published var paused = false
    @Published var facingRight = true
    @Published private(set) var action: PetAction = .strolling
    @Published private(set) var phase = 0.0
    @Published private(set) var gaitPhase = 0.0
    @Published private(set) var walkingSpeed = 0.0
    weak var window: NSWindow?
    private var petX: CGFloat?
    private var petY: CGFloat?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var suppressClickUntil = 0.0
    private var compact = true
    private var configuredSize: Double?
    private var routineIndex = 0
    private var routineTime = 0.0
    private var specialAction: PetAction?
    private var specialUntil = 0.0
    var musicActive = false {
        didSet {
            if oldValue != musicActive { action = musicActive ? .listening : .strolling }
        }
    }
    var reduceMotion = false
    private let routine: [(PetAction, Double)] = [
        (.strolling, 15), (.focused, 4), (.strolling, 15), (.prank, 3),
        (.strolling, 18), (.goofy, 4), (.strolling, 12), (.dancing, 5)
    ]

    init() {
        speed = UserDefaults.standard.object(forKey: "cookieWalkingSpeed") as? Double ?? 38
        let savedSize = UserDefaults.standard.object(forKey: "cookieDesktopSize") as? Double ?? 1
        sizeScale = min(max(savedSize, 0.6), 1.6)
        if let x = UserDefaults.standard.object(forKey: "cookiePetX") as? Double,
           let y = UserDefaults.standard.object(forKey: "cookiePetY") as? Double {
            petX = x
            petY = y
        }
    }

    func drag(to mouse: NSPoint, translation: CGSize) {
        guard compact, let window else { return }
        if dragStartMouse == nil {
            dragStartMouse = NSPoint(x: mouse.x - translation.width,
                                     y: mouse.y + translation.height)
            dragStartOrigin = window.frame.origin
            walkingSpeed = 0
            action = .goofy
        }
        guard let start = dragStartMouse, let origin = dragStartOrigin else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ??
            window.screen ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let left = bounds.minX + 8
        let right = max(left, bounds.maxX - window.frame.width - 8)
        let bottom = bounds.minY + 8
        let top = max(bottom, bounds.maxY - window.frame.height - 8)
        let x = min(max(origin.x + mouse.x - start.x, left), right)
        let y = min(max(origin.y + mouse.y - start.y, bottom), top)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        petX = x
        petY = y
    }

    func endDrag() {
        guard dragStartMouse != nil else { return }
        dragStartMouse = nil
        dragStartOrigin = nil
        suppressClickUntil = Date().timeIntervalSinceReferenceDate + 0.2
        if let petX, let petY {
            UserDefaults.standard.set(Double(petX), forKey: "cookiePetX")
            UserDefaults.standard.set(Double(petY), forKey: "cookiePetY")
        }
        routineIndex = 0
        routineTime = 0
        action = musicActive ? .listening : paused ? .resting : .strolling
    }

    var canOpenOnClick: Bool {
        dragStartMouse == nil && Date().timeIntervalSinceReferenceDate >= suppressClickUntil
    }

    func perform(_ action: PetAction, for seconds: Double = 4) {
        specialAction = action
        specialUntil = phase + seconds
        self.action = action
    }

    func configure(_ window: NSWindow, compact: Bool) {
        guard self.window !== window || self.compact != compact ||
              (compact && configuredSize != sizeScale) else { return }
        self.window = window
        self.compact = compact
        if compact {
            configuredSize = sizeScale
            window.styleMask = [.borderless]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let width = 175 * sizeScale
            let height = 190 * sizeScale
            window.setContentSize(NSSize(width: width, height: height))
            let bounds = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let x = petX ?? (bounds.minX + 65)
            let right = max(bounds.minX + 8, bounds.maxX - width - 8)
            let y = petY ?? (bounds.minY + 16)
            let top = max(bounds.minY + 8, bounds.maxY - height - 8)
            window.setFrameOrigin(NSPoint(x: min(max(x, bounds.minX + 8), right),
                                          y: min(max(y, bounds.minY + 8), top)))
            window.orderFrontRegardless()
        } else {
            petX = window.frame.minX
            petY = window.frame.minY
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isOpaque = true
            window.backgroundColor = .white
            window.hasShadow = true
            window.level = .normal
            window.collectionBehavior = []
            window.title = "Cookie 的小日子"
            window.setContentSize(NSSize(width: 510, height: 750))
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func tick() {
        guard compact else { return }
        if dragStartMouse != nil { return }
        if reduceMotion {
            action = musicActive ? .listening : .resting
            return
        }
        phase += 0.05
        if let specialAction, phase < specialUntil {
            action = specialAction
        } else {
            specialAction = nil
            if musicActive {
                action = Int(phase / 5) % 3 == 2 ? .dancing : .listening
            } else if paused {
                action = .resting
            } else {
                routineTime += 0.05
                if routineTime >= routine[routineIndex].1 {
                    routineTime = 0
                    routineIndex = (routineIndex + 1) % routine.count
                }
                action = routine[routineIndex].0
            }
        }
        let targetSpeed = !paused && action == .strolling ? speed : 0
        let response = targetSpeed > walkingSpeed ? 0.14 : 0.11
        walkingSpeed += (targetSpeed - walkingSpeed) * response
        if walkingSpeed < 0.3 { walkingSpeed = 0 }
        guard walkingSpeed > 0, let window,
              let bounds = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let left = bounds.minX + 8
        let right = max(left, bounds.maxX - window.frame.width - 8)
        let spaceToEdge = facingRight ? right - window.frame.minX : window.frame.minX - left
        let edgeEase = min(1, max(0.15, spaceToEdge / 55))
        let step = CGFloat(walkingSpeed * 0.05 * edgeEase) * (facingRight ? 1 : -1)
        let candidate = window.frame.minX + step
        if candidate >= right - 0.5 { facingRight = false; walkingSpeed = 0 }
        if candidate <= left + 0.5 { facingRight = true; walkingSpeed = 0 }
        let x = min(max(candidate, left), right)
        window.setFrameOrigin(NSPoint(x: x, y: petY ?? (bounds.minY + 16)))
        petX = x
        gaitPhase += abs(step) / 8
    }
}

@MainActor
final class SpotifyController: ObservableObject {
    @Published var status = "可连接这台 Mac 上的 Spotify。"
    @Published var isPlaying = false
    @Published var musicMode: Bool {
        didSet { UserDefaults.standard.set(musicMode, forKey: "cookieMusicMode") }
    }
    private var checkingPlayback = false
    private let scriptQueue = DispatchQueue(label: "land.cookieland.spotify-script", qos: .userInitiated)
    private var playbackTimer: Timer?

    init() {
        musicMode = UserDefaults.standard.bool(forKey: "cookieMusicMode")
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPlayback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private var spotifyPath: String? {
        let path = "/Applications/Spotify.app"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func open() {
        guard let spotifyPath else { status = "这台 Mac 还没有安装 Spotify。"; return }
        NSWorkspace.shared.open(URL(fileURLWithPath: spotifyPath))
        status = "Spotify 已打开。"
    }

    func togglePlayback() {
        guard spotifyPath != nil else { status = "这台 Mac 还没有安装 Spotify。"; return }
        musicMode = true
        run("playpause") {
            self.isPlaying.toggle()
            self.refreshPlayback()
        }
    }

    func next() { run("next track") }

    func play(_ input: String) {
        guard let uri = Self.spotifyURI(input) else {
            status = "请贴 Spotify 歌曲、专辑或歌单链接。"
            return
        }
        if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
        musicMode = true
        if uri.hasPrefix("spotify:track:") {
            run("play track \"\(uri)\"") {
                self.isPlaying = true
                self.refreshPlayback()
            }
        } else {
            status = "已在 Spotify 打开；从那边选一首就能播放。"
        }
    }

    func refreshPlayback() {
        guard musicMode, spotifyPath != nil, !checkingPlayback else { return }
        checkingPlayback = true
        let source = "tell application id \"com.spotify.client\"\nwith timeout of 8 seconds\nif player state is playing then\nreturn \"playing\"\nelse\nreturn \"paused\"\nend if\nend timeout\nend tell"
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let code = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingPlayback = false
                if error == nil, let value {
                    self.isPlaying = value == "playing"
                    self.status = value == "playing" ? "Spotify 正在播放，Cookie 在听歌。" :
                        "Spotify 已连接，当前暂停。"
                } else {
                    self.status = "Spotify 播放状态暂时没读到（\(code.map(String.init) ?? "未知")）。"
                }
            }
        }
    }

    static func spotifyURI(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = ["track", "album", "playlist"]
        if value.hasPrefix("spotify:") {
            let parts = value.split(separator: ":")
            guard parts.count == 3, types.contains(String(parts[1])),
                  parts[2].allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return value
        }
        guard let url = URL(string: value), url.host == "open.spotify.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, types.contains(parts[0]),
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "spotify:\(parts[0]):\(parts[1])"
    }

    private func run(_ command: String, onSuccess: (() -> Void)? = nil) {
        guard spotifyPath != nil else { status = "这台 Mac 还没有安装 Spotify。"; return }
        let source = "tell application id \"com.spotify.client\"\nwith timeout of 20 seconds\n\(command)\nend timeout\nend tell"
        status = "正在连接 Spotify…"
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let code = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.status = code == -1743 ? "请允许 Cookie 控制 Spotify 后再试一次。" :
                        "Spotify 暂时没响应（\(code.map(String.init) ?? "未知")），请先在 Spotify 选一首歌。"
                } else {
                    self.status = "已连接 Spotify。"
                    onSuccess?()
                }
            }
        }
    }
}

struct CompanionView: View {
    @StateObject private var store = CompanionStore()
    @StateObject private var speech = SpeechCapture()
    @StateObject private var pet = DesktopPetController()
    @StateObject private var spotify = SpotifyController()
    @State private var compact = true
    @State private var tab = 0
    @State private var blinking = false
    @State private var spotifyInput = ""
    @State private var draft = ""
    @State private var sending = false
    @State private var lastFailedText: String?
    @State private var errorText: String?
    @State private var floating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var weekTasks: [PlanTask] { store.state.tasks.filter { $0.area == "week" } }
    private var completed: Int { weekTasks.filter(\.done).count }
    private var todayTasks: [PlanTask] {
        (store.state.todayTaskIDs ?? []).compactMap { id in
            store.state.tasks.first(where: { $0.id == id })
        }
    }
    private var weekRange: String {
        guard let start = store.state.weekStart else { return "本周" }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = format.date(from: start),
              let sunday = Calendar(identifier: .iso8601).date(byAdding: .day, value: 6, to: date)
        else { return "本周" }
        let display = DateFormatter()
        display.dateFormat = "M 月 d 日"
        display.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return display.string(from: date) + "至" + display.string(from: sunday)
    }
    private var avatarName: String {
        if tab == 3 && spotify.isPlaying { return "cookie-music" }
        switch store.state.mood {
        case "playful": return "cookie-playful"
        case "goofy": return "cookie-goofy"
        case "focused": return "cookie-focused"
        default: return "cookie"
        }
    }
    private var desktopAvatarName: String {
        if pet.walkingSpeed > 4 &&
            (pet.action == .strolling || pet.action == .focused || pet.action == .goofy || pet.action == .resting) {
            switch Int(pet.gaitPhase) % 4 {
            case 1: return "cookie-walk-a"
            case 3: return "cookie-walk-b"
            default: return "cookie"
            }
        }
        switch pet.action {
        case .focused: return "cookie-focused"
        case .goofy: return "cookie-goofy"
        case .prank: return "cookie-playful"
        case .dancing: return "cookie-dance"
        case .listening: return "cookie-music"
        case .strolling, .resting: return blinking ? "cookie-blink" : "cookie"
        }
    }
    private var petOffset: CGSize {
        guard !reduceMotion else { return .zero }
        let phase = pet.phase
        switch pet.action {
        case .strolling: return CGSize(width: 0, height: -3 * abs(sin(pet.gaitPhase * .pi / 2)))
        case .dancing: return CGSize(width: 2 * sin(phase * 10), height: -8 * abs(sin(phase * 10)))
        case .prank: return CGSize(width: 4 * sin(phase * 13), height: -2)
        case .goofy: return CGSize(width: 0, height: -4 * abs(sin(phase * 8)))
        case .listening: return CGSize(width: 0, height: -2 * abs(sin(phase * 5)))
        case .focused, .resting: return .zero
        }
    }
    private var petRotation: Double {
        guard !reduceMotion else { return 0 }
        switch pet.action {
        case .dancing: return sin(pet.phase * 10) * 7
        case .goofy: return sin(pet.phase * 8) * 3
        case .prank: return sin(pet.phase * 13) * 4
        default: return 0
        }
    }
    private var headerLine: String {
        let value = store.state.messages.last(where: { $0.role == "assistant" })?.text
            ?? "想法很多也没关系，我帮你放好。"
        return value.count > 29 ? String(value.prefix(29)) + "…" : value
    }

    var body: some View {
        Group {
            if compact { compactView } else { expandedView }
        }
        .frame(width: compact ? 175 * pet.sizeScale : 510,
               height: compact ? 190 * pet.sizeScale : 750)
        .animation(.easeInOut(duration: 0.28), value: compact)
        .preferredColorScheme(.light)
        .background(WindowReader { window in pet.configure(window, compact: compact) })
        .onAppear {
            NSApplication.shared.applicationIconImage = bundledImage("cookie")
            pet.reduceMotion = reduceMotion
            pet.musicActive = spotify.musicMode && spotify.isPlaying
            store.rollDayIfNeeded()
            spotifyInput = store.state.spotifyURI ?? ""
            if spotify.musicMode { spotify.refreshPlayback() }
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    floating = true
                }
            }
        }
        .onChange(of: compact) { _, value in
            if let window = pet.window { pet.configure(window, compact: value) }
        }
        .onChange(of: pet.sizeScale) { _, _ in
            if compact, let window = pet.window { pet.configure(window, compact: true) }
        }
        .onChange(of: reduceMotion) { _, value in pet.reduceMotion = value }
        .onChange(of: spotify.isPlaying) { _, value in
            pet.musicActive = spotify.musicMode && value
        }
        .onChange(of: spotify.musicMode) { _, value in
            pet.musicActive = value && spotify.isPlaying
            if value { spotify.refreshPlayback() }
        }
        .onChange(of: store.state.mood) { _, value in
            switch value {
            case "focused": pet.perform(.focused, for: 4)
            case "goofy": pet.perform(.goofy, for: 4)
            case "playful": pet.perform(.prank, for: 4)
            default: break
            }
        }
        .onReceive(Timer.publish(every: 7.5, on: .main, in: .common).autoconnect()) { _ in
            guard !reduceMotion else { return }
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { blinking = false }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            store.rollDayIfNeeded()
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            pet.tick()
        }
    }

    private var compactView: some View {
        Button {
            guard pet.canOpenOnClick else { return }
            tab = 2
            compact = false
        } label: {
            Image(nsImage: bundledImage(desktopAvatarName))
                .resizable().scaledToFit()
                .frame(width: 171 * pet.sizeScale, height: 185 * pet.sizeScale)
                .scaleEffect(x: pet.facingRight ? 1 : -1, y: 1)
                .rotationEffect(.degrees(petRotation))
                .offset(petOffset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    pet.drag(to: NSEvent.mouseLocation, translation: value.translation)
                }
                .onEnded { _ in pet.endDrag() }
        )
        .accessibilityLabel("Cookie 正在\(pet.action.label)。点开对话，安排今天和本周")
        .contextMenu {
            Button("和 Cookie 聊") { tab = 2; compact = false }
            Button("打开今天安排") { tab = 0; compact = false }
            Button("打开本周进展") { tab = 1; compact = false }
            Button("一起听音乐") { tab = 3; compact = false }
            Divider()
            Button("跳支舞") { pet.perform(.dancing, for: 6) }
            Button("恶作剧一下") { pet.perform(.prank, for: 5) }
            Button(pet.paused ? "继续散步" : "停下休息") { pet.paused.toggle() }
            Button("慢慢走") { pet.speed = 20; pet.paused = false }
            Button("轻快走") { pet.speed = 65; pet.paused = false }
            Divider()
            Button("小小只（70%）") { pet.sizeScale = 0.7 }
            Button("标准大小（100%）") { pet.sizeScale = 1 }
            Button("大只 Cookie（140%）") { pet.sizeScale = 1.4 }
        }
    }

    private var expandedView: some View {
        ZStack {
            Image(nsImage: bundledImage("brunch-background"))
                .resizable().scaledToFill().frame(width: 510, height: 750).clipped()
            Color.white.opacity(0.08)
            VStack(spacing: 13) {
                header
                switch tab {
                case 0: todayView
                case 1: weekView
                case 2: chatView
                default: musicView
                }
                tabBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { store.cycleMood() } label: {
                Image(nsImage: bundledImage(avatarName))
                    .resizable().scaledToFit()
                    .frame(width: 118, height: 144)
                    .offset(y: floating ? -4 : 3)
                    .id(avatarName)
                    .transition(.opacity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("点 Cookie 换一个表情")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cookie 的小日子")
                        .font(.custom("Xiaolai", size: 25))
                        .fontWeight(.bold)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button { compact = true } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("缩回桌面小角色")
                }
                Text(headerLine)
                    .font(.custom("Xiaolai", size: 15))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.cream.opacity(0.94), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.stroke.opacity(0.55), lineWidth: 1))
            }
        }
        .frame(height: 150)
    }

    private var todayView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今天，轻轻做一点")
                            .font(.custom("Xiaolai", size: 23)).fontWeight(.bold)
                        Text("一件主线就很好；有余力再做可选项。")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Palette.softInk)
                    }
                    Spacer()
                    Text("\(todayTasks.filter(\.done).count) / \(todayTasks.count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
                if todayTasks.isEmpty {
                    Text("今天还没有安排。挑一件想做的，或直接和 Cookie 说。")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Palette.softInk)
                        .padding(.vertical, 10)
                }
                ForEach(Array(todayTasks.enumerated()), id: \.element.id) { index, task in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(index == 0 ? "今天的主线" : "可选的小事")
                                .font(.custom("Xiaolai", size: 17)).fontWeight(.bold)
                            Spacer()
                            Button { store.removeFromToday(task) } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("从今天移走 \(task.title)")
                        }
                        taskRow(task)
                    }
                }
                if todayTasks.count < 2 {
                    Menu {
                        ForEach(store.state.tasks.filter {
                            ($0.area == "week" || $0.area == "later") && !$0.done &&
                            !(store.state.todayTaskIDs ?? []).contains($0.id)
                        }) { task in
                            Button(task.title) { store.addToToday(task) }
                        }
                    } label: {
                        Label("从计划里挑一件", systemImage: "plus.circle")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .foregroundStyle(Palette.ink)
                    .background(Palette.pink.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { tab = 2 } label: {
                    Label("直接说给 Cookie 听，让它帮我安排", systemImage: "bubble.left")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)

                Text("今天的课程与时间")
                    .font(.custom("Xiaolai", size: 19)).fontWeight(.bold)
                if let blocks = store.state.dayBlocks, !blocks.isEmpty {
                    ForEach(blocks) { block in
                        HStack(spacing: 12) {
                            Text(block.time)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 64, alignment: .leading)
                            Text(block.title)
                                .font(.system(size: 13, design: .rounded))
                            Spacer()
                            Button { store.removeDayBlock(block) } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移走时间段 \(block.time) \(block.title)")
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
                    }
                } else {
                    Text("有课或固定时间？直接告诉 Cookie，它会排进这里。")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.softInk)
                }

                Divider().overlay(Palette.stroke.opacity(0.45))
                Text("桌面 Cookie")
                    .font(.custom("Xiaolai", size: 19)).fontWeight(.bold)
                HStack {
                    Text("散步速度")
                    Slider(value: $pet.speed, in: 0...100)
                        .accessibilityLabel("Cookie 散步速度")
                    Text(pet.speed < 1 ? "停" : "\(Int(pet.speed))")
                        .frame(width: 28, alignment: .trailing)
                }
                .font(.system(size: 13, design: .rounded))
                HStack {
                    Text("桌面大小")
                    Slider(value: $pet.sizeScale, in: 0.6...1.6)
                        .accessibilityLabel("桌面 Cookie 大小")
                    Text("\(Int((pet.sizeScale * 100).rounded()))%")
                        .frame(width: 42, alignment: .trailing)
                }
                .font(.system(size: 13, design: .rounded))
                Button(pet.paused ? "继续散步" : "停下休息") { pet.paused.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("点小箭头回到桌面；按住 Cookie 拖动，可以把它搬到喜欢的位置。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.softInk)
            }
            .foregroundStyle(Palette.ink)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.opacity(0.94), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Palette.stroke.opacity(0.65), lineWidth: 1.5))
    }

    private var musicView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: bundledImage("cookie-music"))
                        .resizable().scaledToFit().frame(width: 105, height: 118)
                        .accessibilityLabel("戴耳机听音乐的 Cookie")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cookie 的音乐角落")
                            .font(.custom("Xiaolai", size: 23)).fontWeight(.bold)
                        Text("放点喜欢的音乐，Cookie 会跟着听。")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Palette.softInk)
                    }
                }
                Toggle("听歌模式：播放时让桌面 Cookie 戴上耳机", isOn: $spotify.musicMode)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, design: .rounded))
                HStack(spacing: 12) {
                    Button { spotify.open() } label: {
                        Label("打开 Spotify", systemImage: "music.note")
                    }
                    Button { spotify.togglePlayback() } label: {
                        Label("播放 / 暂停", systemImage: "playpause.fill")
                    }
                    Button { spotify.next() } label: {
                        Label("下一首", systemImage: "forward.end.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Text("想听指定的歌或歌单？贴 Spotify 链接就好。")
                    .font(.system(size: 13, design: .rounded))
                TextField("Spotify 歌曲、专辑或歌单链接", text: $spotifyInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Spotify 链接")
                Button {
                    if let uri = SpotifyController.spotifyURI(spotifyInput) {
                        store.setSpotifyURI(uri)
                    }
                    spotify.play(spotifyInput)
                } label: {
                    Label("在 Spotify 播放或打开", systemImage: "play.circle.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
                Text(spotify.status)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.softInk)
                Text("首次控制播放时，macOS 可能会请你允许 Cookie 控制 Spotify。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.softInk)
            }
            .foregroundStyle(Palette.ink)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.opacity(0.94), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Palette.stroke.opacity(0.65), lineWidth: 1.5))
    }

    private var weekView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("这一周的小进展")
                            .font(.custom("Xiaolai", size: 23)).fontWeight(.bold)
                        Text("\(weekRange) · 完成一件就算一件")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Palette.softInk)
                    }
                    Spacer()
                    Text("\(completed) / \(weekTasks.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                }
                .foregroundStyle(Palette.ink)

                if weekTasks.isEmpty {
                    Text("这一周还没有要赶的事。和 Cookie 说一句想做什么，就从那里开始。")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Palette.softInk)
                } else {
                    VStack(spacing: 9) {
                        ForEach(weekTasks) { task in taskRow(task) }
                    }
                }

                HStack {
                    Image(systemName: "sparkle").foregroundStyle(Palette.stroke)
                    Text("做完一件就打个勾；没做也不欠账。")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Palette.ink)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint.opacity(0.67), in: RoundedRectangle(cornerRadius: 13))

                if !store.state.tasks.filter({ $0.area == "later" }).isEmpty {
                    Text("完成游戏之后")
                        .font(.custom("Xiaolai", size: 19)).fontWeight(.bold)
                        .foregroundStyle(Palette.ink)
                    ForEach(store.state.tasks.filter { $0.area == "later" }) { task in
                        taskRow(task)
                    }
                }

                Text("想法花园")
                    .font(.custom("Xiaolai", size: 19)).fontWeight(.bold)
                    .foregroundStyle(Palette.ink)
                Text(store.state.ideas.prefix(6).joined(separator: "  ·  "))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Palette.softInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !store.state.tasks.filter({ $0.area == "archive" }).isEmpty {
                    Text("做成过的事")
                        .font(.custom("Xiaolai", size: 19)).fontWeight(.bold)
                        .foregroundStyle(Palette.ink)
                    ForEach(store.state.tasks.filter { $0.area == "archive" }) { task in
                        Label(task.title, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Palette.softInk)
                    }
                }
                Button { tab = 2 } label: {
                    Label("把新想法告诉 Cookie", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
                .background(Palette.pink, in: RoundedRectangle(cornerRadius: 13))
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.opacity(0.94), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Palette.stroke.opacity(0.65), lineWidth: 1.5))
    }

    private func taskRow(_ task: PlanTask) -> some View {
        HStack(spacing: 12) {
            Button { store.toggle(task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(task.done ? Palette.stroke : Palette.softInk)
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.done ? "已完成" : "未完成")，\(task.title)，点按切换完成状态")
            Button {
                if let value = task.url, let url = workURL(value) {
                    NSWorkspace.shared.open(url)
                } else {
                    draft = "给「\(task.title)」添加工作链接："
                    tab = 2
                }
            } label: {
                HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .strikethrough(task.done)
                    Text(task.due)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Palette.softInk)
                }
                Spacer()
                    Label(task.url == nil ? "加链接" : "打开", systemImage:
                          task.url == nil ? "link.badge.plus" : "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.stroke)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.url == nil ? "给\(task.title)添加工作链接" : "打开\(task.title)的工作链接")
        }
        .foregroundStyle(Palette.ink)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(task.done ? Palette.mint.opacity(0.53) : Color.white.opacity(0.68),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("和 Cookie 聊聊")
                    .font(.custom("Xiaolai", size: 22)).fontWeight(.bold)
                Spacer()
                Text("随便说，不用整理")
                    .font(.system(size: 12, design: .rounded))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.state.messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 55) }
                                Text(message.text)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                    .padding(11)
                                    .background(message.role == "user" ? Palette.lavender.opacity(0.85) :
                                                Color.white.opacity(0.91),
                                                in: RoundedRectangle(cornerRadius: 14))
                                if message.role != "user" { Spacer(minLength: 55) }
                            }
                            .id(message.id)
                        }
                        if sending {
                            Text("Cookie 正在想一想…")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Palette.softInk)
                                .id("sending")
                        }
                    }
                    .padding(.horizontal, 15).padding(.bottom, 12)
                }
                .onChange(of: store.state.messages.count) { _, _ in
                    if let last = store.state.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let errorText {
                HStack {
                    Text(errorText)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    if let lastFailedText {
                        Button("重试") { send(lastFailedText, record: false) }
                            .buttonStyle(.plain).fontWeight(.bold)
                    }
                }
                .padding(9)
                .background(Palette.pink.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14)
            }
            if speech.isRecording || speech.message != nil {
                Text(speech.isRecording ? "正在听你说…" : speech.message!)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.softInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
            }
            HStack(alignment: .bottom, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("说或写都可以，想到什么就告诉我…")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Palette.softInk)
                            .padding(.leading, 12).padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 64)
                        .accessibilityLabel("把想法告诉 Cookie")
                }
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke, lineWidth: 1))
                Button {
                    let prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    speech.toggle { recognized in
                        draft = prefix.isEmpty ? recognized : prefix + " " + recognized
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 40, height: 40)
                        .background(speech.isRecording ? Palette.mint : Palette.lavender, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "停止语音输入" : "开始语音输入")
                Button { send(draft, record: true) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 40, height: 40)
                        .background(Palette.pink, in: Circle())
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("发送给 Cookie")
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.opacity(0.96), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Palette.stroke.opacity(0.65), lineWidth: 1.5))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("今天", icon: "sun.max", value: 0)
            tabButton("本周", icon: "checkmark.circle", value: 1)
            tabButton("聊天", icon: "bubble.left", value: 2)
            tabButton("音乐", icon: "music.note", value: 3)
        }
        .padding(6)
        .background(Palette.cream.opacity(0.93), in: Capsule())
        .overlay(Capsule().stroke(Palette.stroke.opacity(0.6), lineWidth: 1))
    }

    private func tabButton(_ label: String, icon: String, value: Int) -> some View {
        Button { tab = value } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(tab == value ? Palette.lavender.opacity(0.75) : Color.clear,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func send(_ text: String, record: Bool) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !sending else { return }
        if record {
            if speech.isRecording { speech.stop() }
            store.addMessage("user", value)
            draft = ""
        }
        sending = true
        errorText = nil
        lastFailedText = nil
        let snapshot = store.state
        Task {
            do {
                let answer = try await ChatEngine.answer(to: value, state: snapshot)
                store.apply(answer)
            } catch {
                lastFailedText = value
                errorText = error.localizedDescription
            }
            sending = false
        }
    }
}

@main
struct CookieCompanionApp: App {
    init() { registerHandwrittenFont() }

    var body: some Scene {
        WindowGroup("Cookie 的小日子") {
            CompanionView()
        }
        .windowResizability(.contentSize)
    }
}
