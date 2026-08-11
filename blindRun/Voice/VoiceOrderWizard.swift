import Combine
import CoreLocation
import Foundation

// MARK: - Voice Order Wizard

/// 语音下单的客户端状态机：**一次说完 → 读回整单 → 确认或定点修改**。
///
/// 形态依据（调研 2026-08-03）：跳过确认环节的纯语音执行在盲人场景有已知翻车模式（语音购物研究记录了
/// 「用户说出特定商品、系统用通用确认回应了完全不同商品」的真实案例，根因是设计假设「用户会瞄一眼屏幕
/// 核对」，而这个假设对盲人不成立）；但纯分步表单也不是答案（ACM 研究显示盲人用户偏好连续指令，
/// 反感每一步重新触发）。证据指向的是**一次说完 + 强制语音复述确认**这个混合模式。
///
/// 后端能担什么，是读后端源码定的，不是猜的（`demo/src/main/java/.../VoiceSlotParser.java`）：
/// - **时间 / 时长可以整句抽**：正则用 `Matcher.find()` 搜子串而非全串匹配，且中文数字先归一成阿拉伯
///   数字；正则不中还有 Qwen-Flash 兜底。所以「明天早上八点跑一个小时」这一句能同时喂给两个槽位。
/// - **地点自 2026-08-04 起也能整句抽**：后端 `POST /api/orders/voice/parse` 先抽地名 span 再查高德，
///   不再把整句原样喂正向地理编码（那样要么返空、要么分词命中噪声词给出错地点）。此前那个常闭开关
///   `resolvesPlaceFromFullUtterance` 已随之删除，整句一次拿三个槽位。
///
/// ⚠️ **`missing` 里的 `ADDRESS` 分不出「用户没说地点」和「说了但没抽出」**（已提给后端，handoff
///   2026-08-04）。前者用当前位置是对的，后者静默用当前位置会把人约到错误起点。在后端给出区分之前，
///   靠读回环节念出实际起点兜底 —— 这是本流程目前最薄的一处。
///
/// 表单永远是可用的回退路径：向导随时可以停，停了屏幕上就是原来那张表。
@MainActor
final class VoiceOrderWizard: ObservableObject {

    /// **只有两轮。** 走「逐项追问」的独立步骤已于 2026-08-06 删除，理由见 `Command.restart`；
    /// 2026-08-10 接入后端 `current` 之后，定点修改**在读回这一轮之内完成**，
    /// 没有再回到多步骤形态 —— 屏幕不会在用户说话的中途换成另一张表单。
    enum Step: Equatable {
        /// 一次说完。用户在这一轮讲一整句。
        case freeform
        /// 起点撞了同名地点，念候选让用户挑一个（后端 2026-08-10 起返回 `candidates`，N48）。
        ///
        /// **这是唯一一个由后端文案驱动的轮次** —— 候选列表只有后端知道
        /// （名称、行政区、距您多少米），客户端拼不出来，所以 `prompt` 直接带着后端的 `ttsText`。
        ///
        /// 为什么值得为它加回一个步骤（2026-08-06 才刚删掉三个步骤）：那三个删掉的是**逐项追问**，
        /// 用户得记住「改地点/改时间/改时长」三个指令；这一轮只要记一个序数，而且刚被念过。
        /// 更重要的是它没有替代品 —— 不挑就只能静默取第一条，而那正是把人约到外省的那条路。
        case disambiguateStart(candidates: [AddressCandidate], prompt: String)
        /// 读回整单后等用户的下一句：确认、改某一项、取消、重听，或整句重说。
        case confirm

        var speechField: SpeechInputField? {
            switch self {
            case .freeform: return .voiceOrderFreeform
            // 复用既有的起点轮字段：逐项追问删掉之后它一直空着，而这一轮问的正是起点。
            // 新加一个枚举值要同步 `isAllowlisted` 的白名单，白拿一处可能漏改的地方。
            case .disambiguateStart: return .voiceOrderStartPlace
            case .confirm: return .voiceOrderConfirm
            }
        }

        /// 短句、给例子 —— WCAG 3.3.2 要求对输入格式给出示例，语音场景尤其如此。
        /// `.confirm` 的提问依赖当前整单内容，由 `confirmPrompt(for:)` 拼装，这里只留兜底。
        var prompt: String {
            switch self {
            case .freeform:
                return "请说你想从哪儿出发、什么时候跑、跑多久，比如：明天早上八点从人民广场出发跑一个小时。说完再点一下就好。"
            case .disambiguateStart(_, let prompt):
                return prompt
            case .confirm:
                return Self.confirmOutroText
            }
        }

        /// 读回结尾那句出路。**三条都要念** —— 看不见屏幕的人不会自己发现「可以只改一项」，
        /// 不教就等于没有这个功能。中间那条是 2026-08-10 接入跨轮修正后加的。
        static let confirmOutroText =
            "说「确认」就下单；要改哪一项直接说，比如「时间改成明天早上九点」；要整句重说就说「重说」。"
    }

    /// `.confirm` 轮**第 1 档**（本地直通）的判定结果。`.unrecognized` 不是终点 ——
    /// 它意味着「本地表接不住，交后端」，见 `handleConfirmCommand`。
    ///
    /// **`.restart` 取代了原来的三个 `.fix(...)`**（2026-08-06）。删除逐项修改的直接原因是真机手测：
    /// 用户说「改地点」，识别成同音的「**该地点**」——「该地点」本身就是常用词，屏幕上的字看起来
    /// 几乎一样 —— 整串精确匹配不中，于是人一直卡在读回这一轮，之后说的每个地名对
    /// 「确认 / 改X」这张表都是无效指令，每次都回「没听懂」。用户报的
    /// 「不管我说什么地点他都返回没听懂」就是这个现象。
    ///
    /// 换成「重说」有三个好处，而代价只有「只想改时间也要把整句重说一遍」（约 5 秒）：
    /// - 22 个修改词的整串匹配表整个消失，脆的东西没了
    /// - 三个只在这条路径上存在的向导步骤消失，界面不再在用户脚下换成表单
    /// - 出错时只有一个动作要记，而不是三个 —— 记忆成本对目标用户是最贵的那部分
    enum Command: Equatable {
        case confirm
        case restart
        case repeatBack
        case unrecognized
    }

    /// 同一轮连续听不清多少次就放弃语音。三次之后继续追问只会让人重复喊同一句话。
    static let maximumReasksPerSlot = 3
    /// 等 TTS 播完再开录音的上限：不等的话麦克风会把自己的播报当成用户说话。
    ///
    /// **这是上限，不是等待时长** —— 播完就立刻放行。它存在只是为了在合成器代理丢事件时不至于
    /// 无限等下去。
    ///
    /// 曾经写死 8 秒，而读回整单在默认语速下要 15~25 秒（见 `finishSpeakingOrSkipPrompt` 的说明），
    /// 于是**每一次读回都必被截断**：上限一到就开麦，而开麦会把音频会话切成允许录音的分类，
    /// 正在播的 `AVSpeechSynthesizer` 当场断掉。2026-08-06 真机手测报的「读到一半自动截断然后开始
    /// 录音」就是这条。修法不是把 8 调大一个拍脑袋的数，而是让上限跟着要念的字数走。
    ///
    /// 系数 0.35 秒/字：中文合成在 `AVSpeechUtteranceDefaultSpeechRate` 下约 3~5 字/秒，取慢的那端
    /// 再加 6 秒起步余量。下限 8 秒保持不变（短提示的行为不变），上限 45 秒防止异常长文本把人吊死。
    static func settleTimeout(forCharacterCount count: Int) -> TimeInterval {
        min(45, max(8, Double(count) * 0.35 + 6))
    }
    /// 单次解析的等待上限。**这是防网络卡死的，不是防解析慢的。**
    ///
    /// 后端建议 3.5 秒（handoff 2026-08-01 ⑤），但那个数说的是服务端解析耗时上限：大模型兜底内部
    /// 3 秒超时后自己降级成 `needReask`。客户端这层包的是整个 HTTP 往返，3.5 秒会把「服务端 3 秒
    /// 兜底成功 + 网络往返」这类**本该成功**的长尾表达判成超时，等于把后端专门为口语化表达做的兜底
    /// 一并废掉 —— 而「明天差不多这个点吧」正是最需要它的说法。
    /// ~~取 8 秒~~ **2026-08-09 提到 12 秒**：后端接终点（SPEC B1）之后，`/parse` **每次都调大模型**
    /// —— 终点没有正则实现，不调就恒为 null。后端实测 `qwen3.7-plus` + 结构化输出 3.4~4.3 秒，
    /// 服务端自己的兜底超时是 8 秒。8 秒的客户端上限正好卡在服务端兜底的边界上，
    /// 「服务端 8 秒兜底成功 + 网络往返」必然超过它 —— 那是把**本该成功**的响应判成超时，
    /// 与上一段拒绝 3.5 秒是同一个理由。
    ///
    /// 12 秒也必须小于 `APIClient` 的 idle 超时（15 秒），这样先响的是这一层：
    /// 用户听到的才是「这次没能把你说的话转成预约内容」这句人话，而不是一个网络错误。
    static let parseTimeout: TimeInterval = 12

    @Published private(set) var step: Step = .freeform
    @Published private(set) var isRunning = false
    @Published private(set) var isParsing = false
    /// 当前这一轮已经重问了几次。
    @Published private(set) var reaskCount = 0
    /// 语音路径放弃了，请用表单。带上原因，供界面展示与播报。
    @Published private(set) var fallbackMessage: String?
    /// 最近一次播报的文案，供「重复一次」使用。
    @Published private(set) var lastSpokenPrompt: String?
    /// 边说边更新的识别文本。**只用于屏幕显示，不播报** —— 一边说一边念会和用户自己的声音打架。
    @Published private(set) var partialTranscript = ""
    /// 用户在 `.freeform` 那一轮说的原话，读回时先念它，再念解析结果。
    /// 念原话是为了让用户能分辨「我说错了」和「它听错了」——只念解析结果的话这两者无从区分。
    @Published private(set) var lastUtterance: String?
    /// 下单成功后创建出的订单。视图订阅它去走既有的 `onOrderCreated` 出口，
    /// 这样语音提交和按钮提交落到同一条跳转路径上。
    @Published private(set) var createdOrder: OrderResponse?

    private weak var bookingViewModel: BlindBookingViewModel?
    private weak var speechService: SpeechService?
    private weak var speechInputService: SpeechInputService?
    private var apiClient: (any APIClientProtocol)?
    private var currentCoordinate: (() -> LocatedCoordinate?)?
    private var parseTask: Task<Void, Never>?
    /// 下一次读回前要先说的一句话（目前只有时长取整）。拼进读回而不是单独播一次，见 `moveToConfirm`。
    private var pendingNotice: String?
    /// 当前这一句最晚等到什么时候就强行开麦。由 `speak(_:)` 按字数定，见 `settleTimeout(forCharacterCount:)`。
    private var speechSettleDeadline: Date?
    /// 本轮语音**真的抽到了**开始时间。
    ///
    /// 必须与 `bookingViewModel.appointmentTime` 分开记：那个字段的初值是 `Date()`，
    /// 光看它分不出「用户说了个正好是现在的时间」和「压根没抽出来」。而这两者对盲人是天壤之别 ——
    /// 一个是他说的，另一个是系统编的。
    @Published private(set) var didCaptureStartTime = false
    /// 连续多少轮没拿到开始时间。到上限就交回表单，见 `moveToConfirm`。
    private var roundsWithoutStartTime = 0
    /// 最近一次解析失败是「这个接口根本不存在」，而不是「没听懂你说什么」。
    ///
    /// 这两者对用户的**下一步动作完全不同**：前者重说多少遍都不会变好，后者值得再说一次。
    /// 后端把未部署的端点回成带 `NOT_FOUND` 的业务信封（`/api/orders/voice/parse` 生产上
    /// 就是这个状态，见 handoff 2026-08-06），所以客户端分得出来 —— 分得出来就不该混为一谈。
    private var parseIsUnavailable = false
    /// 上一次解析的完整结果，确认轮回传给后端当 `current`（跨轮修正的全部前提）。
    ///
    /// **只从响应赋值**，理由见 `ParseVoiceOrderResponse.slotSnapshot`。
    /// `nil` 时确认轮照样发 `/parse`，只是不带 `current` —— 后端行为退回老客户端那一档，
    /// 意图判定仍然可用（`userIntent` 的正则兜底不依赖 `current`）。
    private var lastParsed: ParseVoiceOrderResponse?

    /// 连着这么多轮拿不到开始时间就不再让人重说。取 2：给一次重说的机会，不给第二次。
    static let maximumRoundsWithoutStartTime = 2

    private enum WizardError: Error { case parseTimedOut, notConfigured }

    // MARK: Wiring

    /// - Parameter currentCoordinate: 当前位置，用于给 `resolve-address` 做就近消歧。
    ///   必须是**后端坐标系（GCJ-02）**的真实采样 —— 传 `LocationService.latestBackendSample()`，
    ///   它在没有真实定位时返回 nil，正好等于「不带这两个字段」。
    func configure(
        bookingViewModel: BlindBookingViewModel,
        speechService: SpeechService,
        speechInputService: SpeechInputService,
        apiClient: any APIClientProtocol,
        currentCoordinate: (() -> LocatedCoordinate?)? = nil
    ) {
        self.bookingViewModel = bookingViewModel
        self.speechService = speechService
        self.speechInputService = speechInputService
        self.apiClient = apiClient
        self.currentCoordinate = currentCoordinate
    }

    // MARK: Lifecycle

    /// 起步前先跑一遍下单硬门槛。让盲人说完一整句才被服务端 403 拒掉是最坏的顺序 ——
    /// 门槛的唯一真源是 `OrderCreationService.createOrder`，客户端这份只是把同样的顺序提前。
    /// 返回 `false` 表示没有启动，调用方按 `fallbackMessage` 引导用户去补前置项。
    @discardableResult
    func start() -> Bool {
        guard let bookingViewModel else { return false }
        if let gate = bookingViewModel.firstMissingGate, gate != .startPoint, gate != .appointmentTime {
            fallbackMessage = gate.message
            speak(gate.message)
            return false
        }
        // 语音这条路已经在启动阶段失败过（授权被拒 / recognizer 不可用）：直接交回表单。
        // 明知打不开麦克风还走一遍重问循环，只会让人听三轮「我再问一次」才等到降级。
        if speechInputService?.isSpeechPathUnavailable == true {
            fallBack(reason: "语音输入当前不可用")
            return false
        }
        fallbackMessage = nil
        createdOrder = nil
        lastUtterance = nil
        partialTranscript = ""
        didCaptureStartTime = false
        roundsWithoutStartTime = 0
        parseIsUnavailable = false
        lastParsed = nil
        isRunning = true
        step = .freeform
        reaskCount = 0
        askCurrentStep()
        return true
    }

    func stop() {
        parseTask?.cancel()
        parseTask = nil
        speechInputService?.stopRecognition()
        isRunning = false
        isParsing = false
    }

    /// 用户主动结束这一轮录音（「再点一下」）。停止会走完成回调，后续解析由 `handle` 接手。
    ///
    /// 与 `stop()` 的区别：`stop()` 是放弃整个语音流程，这里只是「我说完了」。
    func finishSpeaking() {
        guard isRunning, speechInputService?.isListening == true else { return }
        speechInputService?.stopRecognition()
    }

    /// 向导运行期间「屏幕上那一下」的唯一入口：**在录音就是「我说完了」，在播报就是「别念了」。**
    ///
    /// 读回整单（原话 + 三项 + 两条出路）在写死的默认语速下要 15~25 秒，而读屏用户日常把语速调到
    /// 14~16 字/秒。中途没有出路，等于把最熟练的用户按在最慢的一档上听完 —— 熟练用户正是最先弃用的人。
    ///
    /// 停播之后不需要额外做什么：`listen` 里 `waitForSpeechToSettle` 的循环条件自然放行，麦克风随即打开。
    /// 所以这里没有新状态，只是提前结束等待。
    func finishSpeakingOrSkipPrompt() {
        guard isRunning else { return }
        if speechInputService?.isListening == true {
            finishSpeaking()
        } else if speechService?.isSpeaking == true {
            speechService?.stop()
        }
    }

    /// 重复当前这一轮的问题。语音消失得快，重听是基本诉求。
    func repeatCurrentPrompt() {
        speak(lastSpokenPrompt ?? step.prompt)
    }

    // MARK: Asking

    private func askCurrentStep() {
        guard isRunning, let field = step.speechField else { return }
        let prompt: String
        if step == .confirm, let bookingViewModel {
            prompt = confirmPrompt(for: bookingViewModel)
        } else {
            prompt = step.prompt
        }
        speak(prompt)
        listen(for: field)
    }

    /// 读回整单。先念用户原话，再念最终要下的单，最后给出两条出路。
    ///
    /// 三段缺一不可：没有原话，用户分不清是自己说错还是系统听错；没有整单，用户不知道默认值补了什么；
    /// 没有出路，看不见屏幕的人不会自己发现还能说「改时间」。
    private func confirmPrompt(for bookingViewModel: BlindBookingViewModel) -> String {
        var parts: [String] = []
        if let pendingNotice, !pendingNotice.isEmpty {
            parts.append(pendingNotice)
        }
        if let lastUtterance, !lastUtterance.isEmpty {
            parts.append("我听到你说：\(lastUtterance)。")
        }
        parts.append("这次的预约是：")
        parts.append(bookingViewModel.startPointSummary)
        // 紧跟起点。终点为 nil 时是空串，一个字都不会念。
        parts.append(bookingViewModel.endPointSummary)
        // 时间这一项**只在真的抽到时才念具体时刻**。
        //
        // 以前无条件念 `appointmentSummary`，而 `appointmentTime` 的初值是 `Date()` ——
        // 抽不出时间时，读回会念出一个用户从没说过的具体时刻，后面再补一句「需至少在 30 分钟后」。
        // 对听不见屏幕的人，那就是「它念了一张我没说过的单」（2026-08-06 用户原话：
        // 「他也没有经过我的同意」）。没说就说没说，不许编。
        parts.append(didCaptureStartTime ? bookingViewModel.appointmentSummary : "预约时间还没说。")
        parts.append(bookingViewModel.optionalNeedsSpeechSummary)
        parts.append(confirmOutro)
        return parts.joined()
    }

    /// 读回结尾那句出路。缺关键槽位时**不能**教用户说「确认」——
    /// 教了他会说，说了不生效，那是比不教更糟的体验。
    private var confirmOutro: String {
        if let blocked = missingRequiredSlotMessage {
            return blocked
        }
        return Step.confirmOutroText
    }

    /// 关键槽位缺失时的说明。**只有开始时间是关键的**：
    /// 起点缺失有正当默认（当前位置，且读回会念出来）；时长在产品上就是选填，
    /// 读回念「没有填写选填跑步需求」本来就是诚实的，没有编造。
    private var missingRequiredSlotMessage: String? {
        guard !didCaptureStartTime else { return nil }
        // 2026-08-10：先教「直接说时间」。跨轮修正之后补一个槽位不再需要把整句重说一遍，
        // 而对听不见屏幕的人，少说一整句就是少一次出错的机会。「重说」仍然留着当第二条出路。
        return "还没听到你说预约时间，现在不能下单。直接说时间就行，比如「明天早上八点」；要整句重说就说「重说」。"
    }

    private func listen(for field: SpeechInputField) {
        guard let speechInputService else { return }
        partialTranscript = ""
        Task { [weak self] in
            await self?.waitForSpeechToSettle()
            guard let self, self.isRunning, self.step.speechField == field else { return }
            speechInputService.startRecognition(
                field: field,
                // 实时文本只写屏，不播报：边说边念会盖住用户自己的声音，识别也会跟着跑偏。
                onTextChanged: { [weak self] text in
                    self?.partialTranscript = text
                },
                // 录音起止的可听提示由 `SpeechInputService` 统一发出，向导转交给 TTS 通道，
                // 免得两边各播一次。
                onAnnouncement: { [weak self] message in
                    self?.speechService?.announce(message)
                },
                onCompletion: { [weak self] completion in
                    self?.handle(completion)
                }
            )
        }
    }

    /// TTS 还在播时开录音，麦克风会先录到系统自己的声音，识别必然跑偏。
    private func waitForSpeechToSettle() async {
        guard let speechService else { return }
        let deadline = speechSettleDeadline
            ?? Date().addingTimeInterval(Self.settleTimeout(forCharacterCount: 0))
        while speechService.isSpeaking && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: Recognition results

    private func handle(_ completion: SpeechInputCompletion) {
        guard isRunning, completion.field == step.speechField else { return }
        let transcript = completion.recognizedText.trimmed
        partialTranscript = ""

        guard completion.reason.shouldTriggerSearchWithRecognizedText, !transcript.isEmpty else {
            // ~~整句这一轮什么都没听到：不重问，直接读回默认整单。用户可能就是想「什么都不说，
            // 按默认下单」，重问只会挡着他。~~ **2026-08-06 真机手测推翻这条。**
            //
            // 实际发生的是：用户没听到起音提示（提示音走响铃通道、被静音拨杆关掉，见
            // `RecordingCue`），根本不知道麦克风开了，于是沉默着等提示；8 秒后系统判定
            // 「他想用默认值」，念了一整单他从没说过的预约 —— 时间是 30 分钟后、时长是默认档。
            // 用户的原话是「他也没有经过我的同意」。
            //
            // 「沉默 = 同意默认值」这个假设本身就不成立，对看不见屏幕的人尤其不成立：
            // 沉默的原因绝大多数是**没听见、没听懂、还在想**，而不是「我接受你的默认值」。
            // 而这条路径的下一步就是读回 + 说「确认」成单，把一次没听清放大成一张真实订单。
            //
            // 现在整句轮和别的轮一样重问，共用 `maximumReasksPerSlot`（两次重问后交回表单）。
            // 这也与调研 §6.6 一致：识别为空一律重问、上限 3 次，那一节本来就没有给整句开口子。
            //
            // 注意这**不影响**「说了话但抽不出槽位」那条路径 —— 那时 transcript 非空，
            // 走 `parseFreeform` 用默认值补齐并读回，是对的：用户确实说了，他能在读回里听出来。
            reask(with: silenceReaskMessage(for: completion.reason))
            return
        }

        parseTask?.cancel()
        parseTask = Task { [weak self] in
            await self?.submitTranscript(transcript)
        }
    }

    /// 什么都没听到时说的那句话。
    ///
    /// 整句那一轮**带上例句**：调研 §6.6 引 Google 的错误处理规范 ——「例子比解释有效」，
    /// 而听不见屏幕的人在这里缺的正是「我到底该说什么」，不是「再说一次」这个指令。
    /// 其余轮次的提问本身就短且带例子（见 `Step.prompt`），重复一遍反而拖长。
    private func silenceReaskMessage(for reason: SpeechInputStopReason) -> String {
        if reason == .error {
            return "语音识别没能启动，我再问一次。"
        }
        if step == .freeform {
            return "没有听到你说话。请说你想从哪儿出发、什么时候跑、跑多久，比如：明天早上八点从人民广场出发跑一个小时。"
        }
        return "没有听到你说话，我再问一次。"
    }

    /// 把一段转录文本交给当前这一轮的处理逻辑。
    ///
    /// 与录音解耦是有意的：麦克风那一段由 `SpeechInputService` 自己的用例覆盖，向导这边真正要锁的是
    /// 「整句抽取落到哪些字段」「非确认绝不提交」「三次降级」，这些不需要真的说话就能验。
    func submitTranscript(_ transcript: String) async {
        switch step {
        case .freeform:
            await parseFreeform(transcript)
        case .disambiguateStart(let candidates, _):
            // 完全本地判定，一个字节都不发 —— 「第二个」不是地名，把它发回 `/parse`
            // 会被模型圈成起点 span，高德查不到又按后端口径保留下来，
            // 于是把刚挑好的地址冲掉（后端 `api_spec.yaml` 的 `candidates` 字段写死了这一条）。
            chooseCandidate(from: candidates, saying: transcript)
        case .confirm:
            await handleConfirmCommand(transcript)
        }
    }

    // MARK: Freeform

    /// 一整句一次抽三个槽位（起点 / 开始时间 / 时长），抽不出的保留默认值。
    ///
    /// **这一轮不重问、不失败。** 抽出多少算多少，剩下的由读回环节交代清楚，让用户决定要不要改。
    /// 让整句这一轮也走「没听清就重问」，会把用户按在同一句话上反复喊——而他其实只要听一遍
    /// 结果就知道该改哪一项。
    ///
    /// 所以 `missing` / `needReask` / 后端 `ttsText` 三个字段在这一轮**一个都不消费**：
    /// `missing` 等价于「这几项保持默认值」，而后端的 `ttsText` 在 `missing` 非空时是**追问**文案，
    /// 播它就等于把人拉回重问。读回一律用 `confirmPrompt` 自己拼的整单（后端 2026-08-04 确认：
    /// 抽不出的槽位保留什么默认值只有客户端知道，后端拼不出整单）。
    private func parseFreeform(_ transcript: String) async {
        enterParsing(saying: "正在识别，请稍候。")
        defer { isParsing = false }
        lastUtterance = transcript

        // 一次请求拿三个槽位。这一轮**吞掉所有错误**：整句抽不出或网络挂了都不该把用户打回表单，
        // 默认值仍然成单，让读回环节把实际内容念清楚，由用户决定改不改。
        //
        // 但**吞掉不等于不说**：原来这里是 `try?`，失败时一个槽位都不填，读回念的全是默认值，
        // 而用户听不出「语音没在工作」和「语音听懂了但你说的正好是默认值」的区别 ——
        // 没仔细听就下了一张时间地点全错的单。2026-08-06 查实 `/api/orders/voice/parse` 的 handler
        // 只在后端未部署分支上，生产恒 404，这条路径不是偶发而是常态。
        var parsed: ParseVoiceOrderResponse?
        var parseFailed = false
        parseIsUnavailable = false
        do {
            parsed = try await parseOrderResponse(transcript)
        } catch {
            parseFailed = true
            parseIsUnavailable = Self.isEndpointMissing(error)
        }

        // 端点根本不存在：连一次读回都不做，直接交回表单。
        //
        // 读回在这里没有任何价值 —— 它必然念一整套默认值，而时间抽不到就不许确认，
        // 用户唯一能做的只有重说，重说还是 404。给他一次「听起来像是可以再试试」的读回，
        // 只是把死路包装得像活路。
        if parseIsUnavailable {
            fallBack(reason: Self.parseUnavailableNotice, joinsReasonDirectly: true)
            return
        }

        var notice: String? = parseFailed ? Self.parseFailureNotice : nil
        if let parsed {
            notice = apply(parsed) ?? notice
        }

        // 起点撞了同名地点：**先让用户挑，再读回整单**。
        //
        // 排在读回之前不是顺序偏好：读回念的是「我们的最佳猜测」（候选第一条），
        // 用户听完多半就说「确认」，那批候选白算了，而如果第一条不是他要的那个，
        // 错地点已经被确认下单 —— 而他听到的读回念得很顺，无从分辨。
        if let parsed, let candidates = parsed.startCandidatesToDisambiguate {
            moveToDisambiguation(candidates, prompt: parsed.ttsText, notice: notice)
            return
        }

        moveToConfirm(notice: notice)
    }

    // MARK: Disambiguate start place

    /// 进候选消歧轮。`prompt` 用后端的 `ttsText`（候选的名称/行政区/距离只有它知道），
    /// 缺了才本地兜一句 —— 兜底那句念不出距离，是降级不是等价物。
    private func moveToDisambiguation(_ candidates: [AddressCandidate], prompt: String?, notice: String?) {
        reaskCount = 0
        // 时长夹取之类的提示**不在这一轮说**，留到读回：候选已经占满了纯听觉能记住的约 3 项，
        // 再往前面塞一句会把序数挤出记忆。挑完由 `moveToConfirm` 原样带出去。
        pendingNotice = notice
        step = .disambiguateStart(
            candidates: candidates,
            prompt: prompt?.nilIfBlank ?? Self.localCandidatePrompt(candidates)
        )
        askCurrentStep()
    }

    /// 后端 `ttsText` 缺失时的本地兜底播报。**格式跟着后端走**（「找到N个地点，请说第几个。」+ 逐条），
    /// 否则两条路径教用户说的话不一样，而他只学得会先听到的那一种。
    static func localCandidatePrompt(_ candidates: [AddressCandidate]) -> String {
        let body = candidates.enumerated()
            .map { "\(ordinalWords[$0.offset])，\($0.element.name)。" }
            .joined()
        return "找到\(candidates.count)个地点，请说第几个。" + body
    }

    /// 用户在消歧轮说的那一句。**全本地判定。**
    private func chooseCandidate(from candidates: [AddressCandidate], saying transcript: String) {
        // 出口优先：被一批他听不明白的候选卡住时，「重说」必须随时能退出去。
        // 复用确认轮那张表，不另写一份 —— 教给用户的词只有一套才记得住。
        if Self.command(for: transcript) == .restart {
            restartFromFreeform()
            return
        }
        guard let index = Self.ordinalIndex(in: transcript, count: candidates.count) else {
            reaskCount += 1
            if reaskCount >= Self.maximumReasksPerSlot {
                // 三次没挑出来**不把人丢回表单**（那是其余轮次的降级方式）：这里手上已经有一个
                // 可用的最佳猜测，而读回会把它念出来、用户仍然可以说「重说」。
                // 但**必须说出「按第一个来」** —— 静默取第一条正是这轮改动要消灭的那个失败。
                applyCandidate(candidates[0], notice: Self.pickedFirstCandidateNotice)
                return
            }
            // ⚠️ **不能图省事用 `promptAndListen`**：它开头就把 `reaskCount` 清零
            // （那是给定向追问用的「不计入重问上限」路径）。用在这里，上面那个上限永远数不到，
            // 挑不出来的用户就被**永远关在候选列表里** —— 又一个没有出口的循环。
            speak("没听清是第几个。请说「第一个」或者「第二个」，要重新讲就说「重说」。")
            if let field = step.speechField {
                listen(for: field)
            }
            return
        }
        applyCandidate(candidates[index], notice: pendingNotice)
    }

    static let pickedFirstCandidateNotice = "没听清是第几个，先按第一个来。"

    private func applyCandidate(_ candidate: AddressCandidate, notice: String?) {
        bookingViewModel?.applyVoiceResolvedStartPlace(
            address: candidate.readbackAddress,
            latitude: candidate.latitude,
            longitude: candidate.longitude
        )
        // 快照必须跟着换：确认轮会把 `lastParsed.slotSnapshot` 当 `current` 发回 `/parse`，
        // 不换的话后端按旧快照把起点继承成第一条，读回念的又变回最佳猜测 ——
        // 用户刚挑的那一下就白挑了，而且没有任何提示。
        lastParsed = lastParsed?.replacingStartPlace(with: candidate)
        moveToConfirm(notice: notice)
    }

    /// 「第二个」→ 1。认不出返回 nil。
    ///
    /// **汉字这一路是实测过的，不是假设**（2026-08-06，记在 `demo/docs/handoff.md:2072-2088`）：
    /// 「第一个」「第二个」「第三个」「就第二个吧」「选第三个」「我要第一个」**12/12 全对**，
    /// 且加不加 `contextualStrings` 偏置**逐字相同** —— 渲染出来的是汉字「第二个」，
    /// **不是**「第2个」。所以本地表按汉字整串匹配是对的。
    /// 专门测这一条，是因为本仓库被同一个坑咬过：「八点钟」被识别器渲染成 `8:00`。
    ///
    /// ⚠️ **那批数据是合成音频**。真实人声（尤其户外）召回会掉，但**渲染形式**这一条是稳的 ——
    /// 所以下面的阿拉伯数字写法不是「防版本漂移」（我们没有那种证据），
    /// 而纯粹是零成本的超集：这几个串不可能是别的意思，收下不花任何东西。
    /// 词表门禁只要求「后端念的每个词本地都认得」，本地多认几种不违反它。
    ///
    /// `count` 是护栏：只认真实存在的那几条。念了 2 个却认「第三个」等于让用户挑一个不存在的地点。
    static func ordinalIndex(in transcript: String, count: Int) -> Int? {
        let normalized = normalizedCommand(transcript)
        guard !normalized.isEmpty else { return nil }
        for (index, forms) in ordinalForms.enumerated() where index < count {
            if forms.contains(where: normalized.contains) { return index }
        }
        return nil
    }

    /// 播报用的序数词，下标即候选下标。与后端 `VoiceOrderService.ORDINALS` 同一套写法。
    static let ordinalWords = ["第一个", "第二个", "第三个"]

    /// ⚠️ 外层顺序即判定优先级，别按字典序重排：「第二个」不含任何 index 0 的写法，
    /// 所以从前往后扫是安全的；但把「第一」放到「第二个」后面就会先命中错的那条。
    private static let ordinalForms: [[String]] = [
        ["第一个", "第1个", "第一", "第1", "头一个"],
        ["第二个", "第2个", "第二", "第2"],
        ["第三个", "第3个", "第三", "第3"]
    ]

    /// 把一次解析结果落到 view model 上。**整句轮与确认轮共用这一份** ——
    /// 跨轮修正之后确认轮也会拿到完整的合并结果，两处各写一遍迟早有一边漏掉一个槽位
    /// （这正是三个可选槽位曾经被静默丢掉的成因）。
    ///
    /// - Returns: 需要在下一次读回前先说的一句话（目前只有时长夹取），没有就是 nil。
    @discardableResult
    private func apply(_ parsed: ParseVoiceOrderResponse) -> String? {
        // 快照留给下一轮的 `current`。**必须在这里存**，而不是只在整句轮存：
        // 用户连改两项时，第二轮要继承的是第一轮**合并后**的结果。
        lastParsed = parsed

        // 时间**跟着响应走**，不是只置真不置假。跨轮继承下第 2 轮响应里时间还在，
        // 标志位就该还是真；而 `RESTART` 之后响应里没有时间，就该翻回假。
        if let raw = parsed.plannedStartTime, let date = raw.backendLocalDate {
            bookingViewModel?.appointmentTime = date
            didCaptureStartTime = true
        } else {
            didCaptureStartTime = false
        }
        if let place = parsed.resolvedStartPlace {
            bookingViewModel?.applyVoiceResolvedStartPlace(
                address: place.address, latitude: place.latitude, longitude: place.longitude
            )
        }
        // 终点整体赋值（**含 nil**），不写 `if let`：本轮没说终点就该清空。
        //
        // 起点写成 `if let` 是对的 —— 抽不出起点有正当默认（当前位置），保留上一轮反而更糟。
        // 终点没有默认值，留着上一轮的就是凭空多出一个用户这次没说过的目的地，
        // 而屏幕上没有任何终点控件能让他察觉。
        //
        // 接了 `current` 之后这行**变得更对**：后端会把上一轮的终点继承回来，
        // 所以「整体赋值」不再等于「只改时间就把终点擦了」。
        bookingViewModel?.endPlace = parsed.resolvedEndPlace

        var notice: String?
        if let minutes = parsed.durationMinutes {
            let accepted = Self.acceptedDurationMinutes(minutes)
            bookingViewModel?.exactDurationMinutes = accepted
            notice = Self.durationClampNotice(spokenMinutes: minutes, accepted: accepted)
        }

        // 三个可选槽位。**抽到才写，抽不出保留原值** —— 与终点那行的「整体赋值含 nil」刻意相反。
        //
        // 分界不是「必填 / 选填」，是**屏幕上有没有对应控件**：终点没有任何控件，用户察觉不到
        // 上一轮的残留；这三项都有（开关、两个 Picker、文本框），而且读回会把它们念出来，
        // 所以留着用户自己填过的值是对的，清掉反而是替他撤销。
        //
        // ⚠️ 在此之前这三项**解出来就被丢掉了**：模型层 2026-08-04 就接了，向导一直没消费。
        // 后果是静默的 —— 用户说「带导盲犬」，读回不提，而 `hasGuideDogThisRun` 进派单**硬过滤**，
        // 候选池按档案默认值筛，盲人全程听不出来。
        if let hasGuideDog = parsed.hasGuideDog {
            // `false` 原样落，不塌缩成 nil：见 `BlindBookingViewModel.hasGuideDogThisRun`。
            bookingViewModel?.hasGuideDogThisRun = hasGuideDog
        }
        if let pace = parsed.pacePreference {
            bookingViewModel?.pacePreference = pace
        }
        if let notes = parsed.specialNotes?.nilIfBlank {
            // 后端保证非 nil 时是用户原话的子串（改写过的备注在后端就被丢弃了），
            // 所以这里直接落，不做二次清洗 —— 备注要原样给志愿者看。
            bookingViewModel?.specialNotes = notes
        }

        // 「说了一个地点，但我们没查到」—— **必须说出来**，而且要和上面那条一起说，不是二选一。
        //
        // 起点解析不出时读回念的是「当前位置」（`startPointSummary` 的默认值），
        // 而用户明明说了一个地名 —— 静默落回当前位置就是**把人约到错误的起点**，他全程听不出来。
        // `addressUnresolved` 正是为了让客户端分得开「压根没说起点」和「说了但没查到」。
        //
        // ⚠️ 后端 2026-08-10 起不再拿全国范围的正向编码兜底（那条路曾把深圳说的地名解析到海南），
        // 所以这个 `true` 会**变常见** —— 在此之前它几乎不出现，接不接看不出差别。
        if parsed.resolvedStartPlace == nil, parsed.addressUnresolved == true {
            notice = [notice, Self.startAddressUnresolvedNotice].compactMap { $0 }.joined()
        }
        return notice
    }

    /// 听见了地名却没查到时，读回前先说的那一句。
    ///
    /// 措辞的两条约束：**说清楚「没找到」而不是「没听到」**（我们听到了，是查不到），
    /// 以及**说清楚起点现在是什么**（不说的话用户得从后面那句 `startPointSummary` 里自己推）。
    static let startAddressUnresolvedNotice =
        "没找到你说的那个地点，出发地先按当前位置来，要改就说「重说」。"

    /// 整句解析失败时先说的那句话。
    ///
    /// 措辞上的三条约束：
    /// - **不说「网络」**。404、超时、鉴权过期表现相同，客户端分不出来，断言原因就是编。
    /// - **不说「没听到」**。ASR 是成功的，紧接着的「我听到你说：⋯⋯」会念出原话，说没听到自相矛盾。
    ///   失败的是把原话转成预约内容这一步。
    /// - **不给指令**。读回结尾那句「要改就说『改地点』⋯⋯」已经把出路说全了，再说一遍只是把
    ///   本就 15~25 秒的读回拖得更长。
    static let parseFailureNotice = "这次没能把你说的话转成预约内容，下面念的是默认值。"

    /// 「这个接口在服务端根本不存在」——**重说多少遍都不会变好**，与「没听懂」必须分开。
    ///
    /// 上面 `parseFailureNotice` 那三条措辞约束（不说网络、不说没听到、不给指令）针对的是
    /// **偶发**失败。端点未部署不是偶发，它是常态，而对它说「下面念的是默认值」等于邀请用户
    /// 再试一次 —— 试一万次也一样。所以这一路单独播、并且直接交回表单。
    static let parseUnavailableNotice = "语音下单暂时用不了，"

    /// 后端把未部署的端点回成 `errorCode: NOT_FOUND` 的业务信封（不是 nginx 裸 404）。
    /// 只认这一种：超时、鉴权过期、5xx 都可能是暂时的，不该被当成「功能不存在」。
    private static func isEndpointMissing(_ error: Error) -> Bool {
        guard case APIError.serverError(let response) = error else { return false }
        return response.code == "NOT_FOUND"
    }

    /// 契约允许的时长区间（`api_spec.yaml:2549`：`minimum: 10` / `maximum: 300`）。
    static let minimumDurationMinutes = 10
    static let maximumDurationMinutes = 300

    /// 语音说的分钟数**原样采用**，只在超出契约区间时夹到边界。
    ///
    /// 2026-08-06 之前这里是「就近 snap 到 6 个枚举档位」，于是「跑三个小时」变成两小时 ——
    /// 枚举存在的理由是选择器需要有限选项，而说话的人不需要选择器。契约本来就收 10–300。
    static func acceptedDurationMinutes(_ spoken: Int) -> Int {
        min(maximumDurationMinutes, max(minimumDurationMinutes, spoken))
    }

    /// 时长被夹到边界时要说的那句话；没动就返回 nil。
    ///
    /// **静默改动对听不见屏幕的人就是篡改**，这条红线不因为改动幅度变小而消失 ——
    /// 现在只有真的超出契约区间才会发生，但发生了就必须说。
    private static func durationClampNotice(spokenMinutes: Int, accepted: Int) -> String? {
        guard accepted != spokenMinutes else { return nil }
        return "你说的是\(spokenMinutes)分钟，超出了可预约范围，本次按\(BlindBookingViewModel.durationText(forMinutes: accepted))预约。"
    }

    /// - Parameter notice: 需要先说一句再读回的话（例如时长被取整）。**必须和读回拼成同一段**，
    ///   分两次 `speak` 会让 `lastSpokenPrompt` 只剩后一句，「重复一遍」就再也念不到取整提示了 ——
    ///   对听不见屏幕的人，念不到等于没发生。
    private func moveToConfirm(notice: String? = nil) {
        reaskCount = 0

        // 连着两轮都没拿到开始时间就交回表单，**不许再让人重说**。
        //
        // 这是「时间抽不出就不许确认」那条规则的必要配套。少了它，只要解析这一环是坏的
        // （例如 `/api/orders/voice/parse` 在生产上恒 404），用户就落进一个没有出口的圈：
        // 说一整句 → 抽不出时间 → 不给确认 → 「请说重说」→ 重说 → 还是抽不出 → 无限循环。
        // 2026-08-06 手测就是这么卡住的：用户第二遍明确说了时间，仍然抽不到。
        //
        // 对看不见屏幕的人，一个没有出口的循环比一条错误信息糟得多 —— 他没有别的方式发现
        // 这条路根本走不通。
        if didCaptureStartTime {
            roundsWithoutStartTime = 0
        } else {
            roundsWithoutStartTime += 1
            if roundsWithoutStartTime >= Self.maximumRoundsWithoutStartTime {
                fallBack(reason: parseIsUnavailable
                         ? "语音下单服务暂时不可用"
                         : "连续两次没听到预约时间")
                return
            }
        }

        step = .confirm
        pendingNotice = notice
        askCurrentStep()
    }

    // MARK: Confirm

    /// 读回之后用户说的那一句。**两档：本地整串直通，其余交后端。**
    ///
    /// 为什么不像后端建议的那样把本地词表整个撤掉（handoff N45 ④）：后端的确定性兜底跑在
    /// **服务端**，它挡不住网络。确认轮发一次 `/parse` 要 3.4~4.3 秒（每次都调大模型），
    /// 客户端超时 12 秒 —— 全流程最高频、最简单的那一句「确认」要等 4 秒才下单，网络一抖就
    /// 下不了单：用户刚才那一整句已经解析成功、槽位全在客户端手里，却因为一次确认往返失败被打回表单。
    /// 对看不见屏幕的人，那是把一次已经成功的语音下单在最后一步丢掉。
    ///
    /// 这**不是「两处各判一套」**：本地表是后端正则兜底的子集时，两者不可能给出不同结论。
    /// 这个子集关系由 `scripts/validate-voice-intent-words.mjs` 逐词对撞后端
    /// `VoiceSlotParser.java` 的 `INTENT_*` 正则钉住，本地表里出现一个后端判成别的意图的词就红。
    private func handleConfirmCommand(_ transcript: String) async {
        // 第 1 档：本地整串命中 → 零延迟直通，一个字节都不发。
        switch Self.command(for: transcript) {
        case .confirm:
            await confirmBooking()
            return
        case .repeatBack:
            repeatReadback()
            return
        case .restart:
            restartFromFreeform()
            return
        case .unrecognized:
            break
        }

        // 第 2 档：其余一律交后端。方言、长句、「我想改时间」全在这一档 ——
        // 这正是「只能说确认或重说」那个二选一被打开的地方。
        await handleConfirmViaBackend(transcript)
    }

    private func handleConfirmViaBackend(_ transcript: String) async {
        enterParsing(saying: "正在识别，请稍候。")
        defer { isParsing = false }

        let parsed: ParseVoiceOrderResponse
        do {
            parsed = try await parseOrderResponse(transcript, current: lastParsed?.slotSnapshot)
        } catch {
            // **不再回「没听懂」** —— 这里失败的是网络，不是听力，说成没听懂会让用户去改说法，
            // 而改说法一点用都没有。本地那几个词仍然直通，所以「确认」这条出路没有被网络挡住，
            // 提示里必须把它说出来。
            reask(with: Self.confirmRoundNetworkFailureNotice)
            return
        }

        switch parsed.userIntent {
        case .confirm:
            // ⚠️ **不播后端的「这就为您下单」**：`/parse` 无副作用，那句话说的是一个还没发生的结果。
            // 沿用 `confirmBooking()` 里的「正在提交订单。」，进行时口径与 SOS 那条红线同源。
            await confirmBooking()
            return
        case .cancel:
            // 用户要退出，不是要改。**不重问**（后端此时 `needReask` 也是 false）。
            fallBack(reason: "已取消这次语音下单")
            return
        case .restart:
            restartFromFreeform()
            return
        case .repeatBack:
            repeatReadback()
            return
        case .unknown, .none:
            break
        }

        if let target = parsed.correctionTarget {
            // 用户点名要改哪一项、还没给新值。播后端的定向追问语，再收一次音，
            // **`current` 一个字都不动** —— 后端说了本轮什么都没覆盖。
            //
            // 这一轮**不计入重问上限**：后端听懂了、用户也在正常推进，把「改三项」记成
            // 「三次没听清」会在第三项上把人降级到表单。真听不清仍然有界 ——
            // 用户接下来若沉默，`handle` 那条空转录路径走的还是 `reask`。
            promptAndListen(parsed.ttsText?.nilIfBlank ?? Self.fallbackCorrectionPrompt(for: target))
            return
        }

        if parsed.correctionUnclear == true {
            // 用户否定了读回但没说改哪一项。这一条**确实是没听懂**，计入上限。
            reask(with: parsed.ttsText?.nilIfBlank ?? "您想改哪一项？出发地、开始时间，还是时长？")
            return
        }

        // 剩下的只有一种情况：用户给了新值，后端已经把它合进整单。落槽位、重念一遍。
        let notice = apply(parsed)
        moveToConfirm(notice: notice)
    }

    /// 「确认」这条路的唯一出口 —— 本地直通与后端 `CONFIRM` 都走它，缺槽位的拦截只有一份。
    private func confirmBooking() async {
        // 缺关键槽位时「确认」不生效 —— 用户没说过时间，不能凭一句「确认」就派单。
        // 读回结尾已经念过原因（`missingRequiredSlotMessage`），这里再说一次是因为
        // 用户可能是听完很久才开的口，中间隔了多少秒我们不知道。
        if let blocked = missingRequiredSlotMessage {
            reask(with: blocked)
            return
        }
        await submitConfirmedBooking()
    }

    /// 「再念一遍」。重播上一整段读回，不改任何槽位、不计重问。
    private func repeatReadback() {
        reaskCount = 0
        askCurrentStep()
    }

    /// 确认轮网络失败时说的那句话。
    ///
    /// 三条约束与 `parseFailureNotice` 同源（不说网络、不说没听到、不编原因），
    /// 但**必须把本地还能用的那两条出路念出来** —— 网络断着的时候它们是仅存的通路。
    static let confirmRoundNetworkFailureNotice =
        "这次没能听明白你想改什么。说「确认」就按刚才念的下单，说「重说」重新说一遍。"

    /// 后端 `ttsText` 缺失时的定向追问兜底。正常情况下用不到 —— 后端保证 `correctionTarget`
    /// 非 null 时 `ttsText` 是该项的追问语；这里只防「字段在、文案空」那种线上偶发。
    private static func fallbackCorrectionPrompt(for target: VoiceCorrectionTarget) -> String {
        switch target {
        case .startAddress: return "好的，请说新的出发地点。"
        case .endAddress: return "好的，请说新的结束地点。"
        case .startTime: return "好的，请说新的开始时间，比如「明天早上八点」。"
        case .duration: return "好的，请说新的时长，比如「跑一个小时」。"
        case .guideDog: return "好的，请说这次带不带导盲犬。"
        case .pace: return "好的，请说这次的配速偏好。"
        case .notes: return "好的，请说要给志愿者的备注。"
        case .unknown: return "好的，请说新的内容。"
        }
    }

    /// 从头再说一遍。**必须把上一轮抽到的槽位清干净**，否则新的一句没提到的项会留着旧值，
    /// 而读回照样把它念出来 —— 用户会以为那是他这次说的。
    private func restartFromFreeform() {
        reaskCount = 0
        lastUtterance = nil
        pendingNotice = nil
        didCaptureStartTime = false
        // `current` 也要清 —— 留着它，用户「重说」的那一整句会被后端和上一轮的旧槽位合并，
        // 于是他这次没提的东西又原样回来了，而屏幕上一个字都不会变。
        lastParsed = nil
        bookingViewModel?.resetVoiceFilledSlots()
        step = .freeform
        askCurrentStep()
    }

    /// 用户说了「确认」：走既有的提交路径。
    ///
    /// 提交失败时不重来一遍语音 —— `BlindBookingViewModel.submit()` 已经播报并写好了 `errorMessage`，
    /// 把表单停在确认步骤，用户可以听着错误原因手动重试，这比在语音里重放一遍失败更可控。
    private func submitConfirmedBooking() async {
        // 先落 isRunning，再取 viewModel：停止录音的完成回调会再进一次 `handle`，那里靠 isRunning 挡住。
        // 顺序反过来的话，拿不到 viewModel 时向导会一直显示在跑、麦克风也不放。
        isRunning = false
        speechInputService?.stopRecognition()
        guard let bookingViewModel else { return }
        enterParsing(saying: "正在提交订单。")
        defer { isParsing = false }

        if let response = await bookingViewModel.submit() {
            createdOrder = response
        }
    }

    // MARK: Networking

    /// 整句解析。
    ///
    /// - Parameter current: 上一轮的槽位快照。整句轮传 nil（还没有「上一轮」），
    ///   确认轮传 `lastParsed?.slotSnapshot` —— 后端据此做「新抽到的覆盖、没抽到的继承」，
    ///   用户只说「时间改成九点」也能保住其余槽位。
    private func parseOrderResponse(
        _ transcript: String,
        current: VoiceSlotSnapshot? = nil
    ) async throws -> ParseVoiceOrderResponse {
        guard let apiClient else { throw WizardError.notConfigured }
        let body = parseRequest(transcript: transcript, current: current)
        return try await withParseTimeout {
            let response: ParseVoiceOrderResponse = try await apiClient.post(
                VoiceOrderEndpoint.parseOrder,
                body: body
            )
            return response
        }
    }

    /// 带上当前坐标让后端走周边搜索做就近消歧。**拿不到真实定位就不带** —— 宁可退回正向编码，
    /// 也不能拿演示坐标去消歧，那会把人约到另一座城市。
    ///
    /// 两轮共用这一份：这条红线只该有一个出处，复制第二遍迟早有一边忘了判 `system`。
    private func parseRequest(
        transcript: String,
        current: VoiceSlotSnapshot?
    ) -> ParseVoiceOrderRequest {
        let sample = currentCoordinate?()
        let coordinate = sample?.system == .gcj02Backend ? sample?.coordinate : nil
        return ParseVoiceOrderRequest(
            transcript: transcript,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            current: current
        )
    }

    /// 给一次解析请求加超时。后端的模型兜底自己有 3 秒降级，这层防的是网络卡死 ——
    /// 没有它，向导会静默地永远停在「正在识别」，而盲人听不到任何提示。
    private func withParseTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.parseTimeout * 1_000_000_000))
                throw WizardError.parseTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw WizardError.parseTimedOut }
            return result
        }
    }

    // MARK: Transitions

    private func reask(with message: String) {
        reaskCount += 1
        guard reaskCount < Self.maximumReasksPerSlot else {
            fallBack(reason: "连续\(Self.maximumReasksPerSlot)次没听清")
            return
        }
        speak(message)
        guard let field = step.speechField else { return }
        listen(for: field)
    }

    /// 播一句、再收一次音，**不计入重问上限**。
    ///
    /// 与 `reask` 的分界是「这一轮是不是没听清」：定点修改的定向追问里后端听懂了、用户也在正常
    /// 推进，把它记成没听清会让「连改三项」在第三项上被降级到表单。
    /// 计数没有因此消失 —— 用户若在追问后沉默，`handle` 那条空转录路径走的仍是 `reask`。
    private func promptAndListen(_ message: String) {
        reaskCount = 0
        speak(message)
        guard let field = step.speechField else { return }
        listen(for: field)
    }

    /// 语音路径走不通时**必须**说清楚接下来去哪 —— 看不见屏幕的人没有别的方式发现语音已经停了。
    /// - Parameter joinsReasonDirectly: `reason` 自己已经带了标点、直接拼下一句。
    ///   默认 `false` 时补一个逗号（「连续两次没听到预约时间，已切回表单⋯⋯」）。
    private func fallBack(reason: String, joinsReasonDirectly: Bool = false) {
        isRunning = false
        speechInputService?.stopRecognition()
        let message = joinsReasonDirectly
            ? "\(reason)已切回表单填写，你可以用屏幕上的输入框继续预约。"
            : "\(reason)，已切回表单填写，你可以用屏幕上的输入框继续预约。"
        fallbackMessage = message
        speak(message)
    }

    private func speak(_ text: String) {
        lastSpokenPrompt = text
        // 上限在开口的那一刻按字数定下来。放在这里而不是 `waitForSpeechToSettle` 里，是因为那边
        // 只看得到「还在不在念」，看不到念的是什么。
        speechSettleDeadline = Date().addingTimeInterval(Self.settleTimeout(forCharacterCount: text.count))
        speechService?.speak(text)
    }

    /// 进入一次网络往返，并把这件事说出来。
    ///
    /// 不说的话，全盲用户在结束音之后听到的是长达 `parseTimeout`（12 秒）的绝对静默 —— 这正是
    /// AppleVis 对语音类 App「按下之后全程没有任何反馈」的那条抱怨，和我们用来论证要做
    /// `RecordingCue` 的是同一条依据，只守住起止两端等于只守了一半。
    ///
    /// 刻意**不走** `speak(_:)`：那会把 `lastSpokenPrompt` 顶掉，「重复一遍」就再也念不回刚才的提问。
    /// 也刻意不加触觉：`RecordingCue.end()` 的震动刚在几十毫秒前发生过，再震一次是噪声不是信息。
    /// 结果回来时 `askCurrentStep` 的播报会打断这一句 —— 被打断本身就是「好了」的信号。
    ///
    /// 本地判定那一路（肯定词、定点修改指令）**不经过这里**：它零延迟，没有需要填的静默。
    private func enterParsing(saying notice: String) {
        isParsing = true
        speechService?.speak(notice)
    }

    #if DEBUG
    /// 从任意轮起步，且不碰麦克风。用例要验的是解析与推进，真录音由 `SpeechInputService` 自己的
    /// 用例覆盖（且单测环境拿不到麦克风授权）。
    /// - Parameter didCaptureStartTime: 这一轮语音是否真的抽到了开始时间。
    ///   默认 `false`（= 用户还没说过时间），此时「确认」按设计不生效 —— 想验提交路径的用例
    ///   必须显式传 `true`，否则测的是「缺时间被拦住」而不是提交。
    func startForTesting(at step: Step, didCaptureStartTime: Bool = false) {
        isRunning = true
        self.step = step
        reaskCount = 0
        fallbackMessage = nil
        self.didCaptureStartTime = didCaptureStartTime
    }

    /// 把一次录音完成回调直接喂进来，不碰麦克风。
    ///
    /// `submitTranscript` 进不了这条路径：它从**有转录文本**的地方开始，而这里要验的恰恰是
    /// 「一个字都没听到」时的分支 —— 2026-08-06 那张「没经用户同意的默认订单」就出在这里，
    /// 而它此前一条断言都没有。
    func handleCompletionForTesting(_ completion: SpeechInputCompletion) {
        handle(completion)
    }
    #endif

    // MARK: Command recognition

    /// 「确认」的肯定词。**整串匹配，不做包含匹配。**
    ///
    /// 两个方向的错误代价不对称：把「确认」误判成「非确认」只是让用户多说一轮；把「改时间」误判成
    /// 「确认」会产生一张用户没打算下的订单并触发真实派单。所以这里只认明确的肯定表达。
    ///
    /// 不做包含匹配的直接理由：「不确认」「先别确认」「确认一下时间」都含有「确认」，
    /// 而意思分别是否定、否定、要求复核。
    ///
    /// 刻意不收「嗯」：它做犹豫填充词的次数不比做肯定少，而这里的误判方向是会真下单的那一边。
    ///
    /// **2026-08-05 收窄：单音节高频应答词全部移出。**
    /// 2018 年 Portland 那起 Alexa 事故是这条规则的完整证据链 —— Amazon 官方复盘里，
    /// 助手问 "[名字], right?"，背景对话中的一句 **"right"** 满足了确认，把一段私人录音发了出去。
    /// 中文的「好」「行」「对」「是」与 "right" 完全同构，而陪跑场景还多一个加重因素：
    /// **志愿者可能就站在旁边说话**，这几个字正是中文日常应答里频率最高的。
    ///
    /// 移出的词：好 / 好的 / 行 / 可以 / 对 / 是 / 没错 / 同意 / 确定 / 提交 / 下单。
    /// 前九个是单双音节应答词；「提交」「下单」是名词性动词，会在「我要下单」「帮我提交一下」
    /// 这类叙述里命中。
    ///
    /// 保留「确认」是因为读回的出路那句念的就是「说『确认』就下单」（见 `confirmPrompt`）——
    /// **白名单必须和系统教用户说的话一致**，否则用户照着念却不生效。改任一边都要改另一边。
    ///
    /// 代价是方言与长句表达更容易被判为「非确认」，用户多说一轮。这正是可接受的失败方向。
    ///
    /// **2026-08-10 删掉「开始约跑」**：本地直通表必须是后端确定性兜底
    /// （`VoiceSlotParser.INTENT_CONFIRM`）的子集，而后端那条正则里没有任何模式能命中它
    /// （最接近的是「开始吧」）。它也从来没被 `confirmPrompt` 教给用户，删掉零损失。
    private static let affirmatives: Set<String> = [
        "确认", "确认下单", "确认预约", "确认提交",
        "没问题", "就这样", "就这么办"
    ]

    /// 「重说」的触发词。**这一组用包含匹配，不用整串匹配** —— 与 `affirmatives` 刻意相反。
    ///
    /// 两组的失败方向不对称，所以匹配严格程度也该不一样：
    /// - 把「不是确认的话」误判成确认 → 产生一张用户没打算下的真实订单。必须整串、必须严。
    /// - 把「不是重说的话」误判成重说 → 用户多说一句话。可以松。
    ///
    /// 整串匹配在这一组上已经被真机证伪：用户说「改地点」被识别成同音的「该地点」，整串不中，
    /// 人就卡在读回那一轮出不来。包含匹配对同音字仍然无能为力，所以词表里把
    /// **「重」「从」两种常见误识都收进来**，并且不依赖单个字。
    ///
    /// 🔴 **2026-08-10 把「再说一次」移出本组**，它现在归 `repeatWords`。
    /// 逐词对撞后端 `VoiceSlotParser` 时查出这是一处**方向相反**的判定分歧：本地判「重说」会把
    /// 用户刚说完的一整句清空，后端 `INTENT_REPEAT` 判的是「你把刚才那句再念一遍」。
    /// 后端 `INTENT_RESTART` 的注释写得很直白 ——「刻意不收『再说一遍』」，因为判错的代价不对称。
    /// 这一条现在由 `scripts/validate-voice-intent-words.mjs` 钉住，再漂就红。
    private static let restartWords: [String] = [
        "重说", "重新说", "从新说", "重新讲", "重来", "重新来", "从头说", "从头再说", "从头来",
        "重新预约", "重新说一遍", "重新来过"
    ]

    /// 「把刚才那段再念给我听」。**注意与 `restartWords` 的语义分界**：
    /// 这一组是「你再念一遍」，那一组是「我再说一遍」。
    ///
    /// 「再说一遍 / 再说一次」中文里两种意思都有。**2026-08-10 从「重说」改判到本组**，
    /// 依据是后端 `VoiceSlotParser.INTENT_REPEAT` 把它们收进了重播，而 `INTENT_RESTART`
    /// 注释里明说「刻意不收」。判反的代价不对称：当成重说会把用户刚说完的一整句清空，
    /// 当成重播最坏只是多念一遍 —— 而这一句正是盲人没听清读回时最自然的说法。
    ///
    /// 长句形式（「再给我念一遍呗」「你刚才说啥来着」）不进本表，交给后端 —— 本地整串表
    /// 接不住方言与长句，那正是第 2 档存在的理由。
    private static let repeatWords: Set<String> = [
        "重复", "重复一遍", "再念一遍", "没听清", "再念一次", "你再说一遍",
        "再说一遍", "再说一次"
    ]

    /// 句尾语气词不改变语义，剥掉可以显著提高召回而不牺牲安全性（「确认吧」「好的呀」）。
    /// 句首不剥：那会让「不确认」这类否定的判定变得脆弱，而多问一轮是可接受的失败方向。
    private static let trailingParticles: Set<Character> = ["吧", "啊", "呀", "了", "哦", "喔", "嘛", "呗", "咯", "啦"]

    /// ponytail: 本地整串匹配只做**第 1 档直通**，判不出来不是终点 —— 交给
    /// `handleConfirmViaBackend` 的 `userIntent` / `correctionTarget`。原来那条「方言与长句会被判成
    /// 没听懂，用户多说一轮」的天花板已经由后端接住，本地表只保留零延迟与离线可用这两件事。
    static func normalizedCommand(_ transcript: String) -> String {
        var normalized = transcript.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        while let last = normalized.last, trailingParticles.contains(last) {
            normalized.removeLast()
        }
        return normalized
    }

    static func isAffirmative(_ transcript: String) -> Bool {
        let normalized = normalizedCommand(transcript)
        guard !normalized.isEmpty else { return false }
        return affirmatives.contains(normalized)
    }

    /// 判定顺序有意义：**肯定词先判、且只认整串**，免得「重新确认一下」这种话里的「确认」被包含匹配吃掉。
    static func command(for transcript: String) -> Command {
        let normalized = normalizedCommand(transcript)
        guard !normalized.isEmpty else { return .unrecognized }
        if affirmatives.contains(normalized) { return .confirm }
        if repeatWords.contains(normalized) { return .repeatBack }
        if restartWords.contains(where: { normalized.contains($0) }) { return .restart }
        return .unrecognized
    }

    // MARK: Helpers

    // `durationOption(forMinutes:)`（就近 snap 到 6 个枚举档位）已于 2026-08-06 删除。
    // 语音说多少就是多少，只夹到契约区间，见 `acceptedDurationMinutes(_:)`。
}
