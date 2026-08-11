import Foundation

// MARK: - Voice Order (语音下单)

/// 语音下单的三个后端端点（`api_spec.yaml`，均需 JWT + `BLIND` 角色）。
///
/// 分工：**后端只收文本、不收音频、不存状态**。录音、ASR、TTS、以及「下一个字段问不问」的向导状态机
/// 全在客户端；后端提供无状态的解析原语。所以这里只有 DTO，状态机在 `VoiceOrderWizard`。
enum VoiceOrderEndpoint {
    /// 整句一次抽三槽（起点 / 开始时间 / 时长）。**请求体是 `ParseVoiceOrderRequest`，不再与
    /// `resolveAddress` 共用** —— 2026-08-10 接入跨轮修正的 `current` 之后两者不再逐字相同。
    static let parseOrder = "/api/orders/voice/parse"
    static let resolveAddress = "/api/orders/voice/resolve-address"
    static let parseSlot = "/api/orders/voice/parse-slot"
}

struct ResolveAddressRequest: Codable, Sendable {
    /// 原始 ASR 转录文本，**不要做客户端清洗**：后端的正则与大模型兜底对「呃」「吧」这类语气词有容错，
    /// 前端去标点反而可能删掉断句信息（`语音下单交接说明.md` 第五节）。
    let transcript: String
    /// 当前位置（GCJ-02，可选，2026-08-01 后端新增）。
    ///
    /// 不传时后端走正向地理编码取 `geocodes[0]`，「人民广场」这类全国重名地点等于撞运气；传了则改走
    /// 周边搜索按距离取最近一个。语音路径没有候选列表可挑，消歧只能靠这两个数 —— **有定位就一定要带**。
    let latitude: Double?
    let longitude: Double?

    init(transcript: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.transcript = transcript
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 起点解析结果。坐标已经是 **GCJ-02**，与全系统一致，可直接用于下单，不需要再转换。
struct ResolveAddressResponse: Codable, Sendable, Equatable {
    let address: String?
    let latitude: Double?
    let longitude: Double?
    /// `true` 表示「没听清」，是 **HTTP 200 的正常业务状态**，不是错误：播 `ttsText` 原地重问，
    /// 既不推进向导，也不弹错误 UI。
    let needReask: Bool?
    /// 后端渲染好的确认/追问文案，直接喂 TTS。
    let ttsText: String?

    var isUsable: Bool {
        needReask != true && latitude != nil && longitude != nil && address?.trimmed.isEmpty == false
    }
}

/// 不做未知值兜底：只出现在 `ParseSlotRequest`（**只出不进**），由客户端决定这一轮问哪个字段。
enum VoiceSlotField: String, Codable, Sendable {
    case startTime = "START_TIME"
    case duration = "DURATION"
}

/// `ParseVoiceOrderResponse.missing` 的元素。**刻意不复用 `VoiceSlotField`**：那个是请求侧、只出不进、
/// 且只有两个值（`ADDRESS` 传给 `parse-slot` 会返 400）；这个是响应侧、只进不出、多一个 `ADDRESS`。
/// 两个方向合并成一个枚举，迟早有人把 `ADDRESS` 发去 `parse-slot`。
///
/// 未知值退化成 `.unknown` 而不是抛 —— 后端往这个枚举加值时不该让整条响应解不出来（与
/// `RunOrderStatus` / `BlindVerifyStatus` 同一套写法）。
enum VoiceOrderMissingSlot: String, Codable, Sendable, Equatable {
    case address = "ADDRESS"
    case startTime = "START_TIME"
    case duration = "DURATION"
    /// 后端新增槽位时的兜底，不是后端会发的值。
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = VoiceOrderMissingSlot(rawValue: rawValue) ?? .unknown
    }
}

/// 用户对读回确认的**表态**（后端 2026-08-09 新增）。`nil` = 没表态。
///
/// 此前这一判断没有契约，每个客户端各写一套关键词匹配，用户实际被限制在「说『确认』或整句重说」
/// 二选一里。现在后端用大模型 + 正则确定性兜底给出结论，客户端照字段分支。
///
/// ⚠️ `REPEAT` 与 `RESTART` 的界线是「**重听** vs **重说**」，判反的代价不对称：
/// 把 `REPEAT` 当成 `RESTART` 会把用户刚说完的一整句清空。
///
/// 未知值退化成 `.unknown` 而不是抛 —— 与 `VoiceOrderMissingSlot` 同一套写法。
enum VoiceUserIntent: String, Codable, Sendable, Equatable {
    case confirm = "CONFIRM"
    case cancel = "CANCEL"
    case restart = "RESTART"
    case repeatBack = "REPEAT"
    /// 后端新增取值时的兜底，不是后端会发的值。
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = VoiceUserIntent(rawValue: rawValue) ?? .unknown
    }
}

/// 用户点名要改的那一项 —— 他说了「改哪一项」但**没给新值**（后端 2026-08-09 新增）。
///
/// **刻意不复用 `VoiceSlotField`**（那个只有两个值、且是 `parse-slot` 的请求入参）：
/// 这是响应侧的独立枚举，读回里念到的每一项都能被点名，包括终点和三个可选槽位。
///
/// ⚠️ 非 nil 时**不改任何槽位的值，只决定问句问什么** —— 模型判错的代价只是问错一句话。
enum VoiceCorrectionTarget: String, Codable, Sendable, Equatable {
    case startAddress = "START_ADDRESS"
    case endAddress = "END_ADDRESS"
    case startTime = "START_TIME"
    case duration = "DURATION"
    case guideDog = "GUIDE_DOG"
    case pace = "PACE"
    case notes = "NOTES"
    /// 后端新增取值时的兜底，不是后端会发的值。
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = VoiceCorrectionTarget(rawValue: rawValue) ?? .unknown
    }
}

/// 同名候选地点（后端 2026-08-10 新增，N48）。
///
/// 后端在**请求带了坐标**时用高德 POI 周边搜索 + 拼音重排取前 3 个。没有坐标就没有候选 ——
/// 那时后端连搜都不搜，因为算不出 `distanceMeters`，而缺了距离的同名地点列表更难选。
struct AddressCandidate: Codable, Sendable, Equatable {
    /// POI 名称（「五角场」），播报的主体。
    let name: String
    /// 街道地址（「邯郸路」），高德可能不返回。
    let address: String?
    /// 区县名（「杨浦区」）。
    let adname: String?
    /// 商圈名（「五角场商圈」），高德常常不返回。
    let business: String?
    /// 距请求里坐标的直线距离（米）。
    let distanceMeters: Int?
    let latitude: Double
    let longitude: Double

    /// 存进订单、给志愿者看的完整地址 —— **POI 名 + 街道地址**。
    ///
    /// ⚠️ 这条拼法**镜像后端 `VoiceOrderService.readback`**：后端返回的平铺 `address`
    /// （= 第一个候选）就是这么拼的，用户挑了第二个之后必须拼出同样的形态，
    /// 否则「挑第一个」和「挑第二个」两条路会得到结构不同的地址串，
    /// 而下游 `spokenAddress` 靠空格切 POI 名 —— 形态不一致它就切错。
    var readbackAddress: String {
        guard let address = address?.nilIfBlank, !name.contains(address) else { return name }
        return "\(name) \(address)"
    }
}

/// 上一轮已确认的槽位快照。**服务端不存对话状态**，「上一轮说到哪了」完全由客户端带回来。
///
/// 字段全部可选：只带已经确认过的那几项。后端的合并口径是
/// **本轮正则 > 本轮模型 > `current`**（新抽到的覆盖旧值，没抽到的继承）。
///
/// ⚠️ 起点与终点是**同一档规则**（`api_spec.yaml` 的 `VoiceSlotSnapshot`，2026-08-09 起点跟着放宽）：
/// 允许「有地址、无坐标」—— 高德查不到时后端就是这么返回的，客户端把响应原样放进下一轮
/// 必然会回传上来，按旧的严格规则校会把用户卡死在一个他自己解不开的循环里。
/// **反过来仍返 400**：只有坐标没有文字地址是客户端 bug，所以 `init` 里坐标缺地址一律整组丢弃。
///
/// ⚠️ `demo/docs/frontend-guide.md` 里那句「起点三项必须同时提供或同时缺省」是放宽之前的旧文，
/// 与 `api_spec.yaml` 矛盾。契约唯一源是 `api_spec.yaml`（`AGENTS.md` 第 7 节），按放宽版写。
struct VoiceSlotSnapshot: Codable, Sendable, Equatable {
    let plannedStartTime: String?
    let durationMinutes: Int?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let endAddress: String?
    let endLatitude: Double?
    let endLongitude: Double?
    let hasGuideDog: Bool?
    let pacePreference: PacePreference?
    let specialNotes: String?
}

/// `POST /api/orders/voice/parse` 的请求体。
///
/// **不再复用 `ResolveAddressRequest`**：在没有 `current` 的世界里两个端点的请求体确实逐字相同，
/// 复用是对的；接了跨轮修正之后不再成立。
struct ParseVoiceOrderRequest: Codable, Sendable {
    /// 原始 ASR 转录文本，**不要做客户端清洗**，理由同 `ResolveAddressRequest.transcript`。
    let transcript: String
    /// 当前位置（GCJ-02，可选），用于同名地点就近消歧。**与 `longitude` 必须成对**，只传一半返 400。
    let latitude: Double?
    let longitude: Double?
    /// 上一轮的槽位快照。`nil` = 整句那一轮（还没有「上一轮」），后端行为与老客户端完全一致。
    let current: VoiceSlotSnapshot?

    init(
        transcript: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        current: VoiceSlotSnapshot? = nil
    ) {
        self.transcript = transcript
        self.latitude = latitude
        self.longitude = longitude
        self.current = current
    }
}

/// 整句解析结果：一句话同时抽起点、开始时间、时长。
///
/// **地点这一路是 2026-08-04 才有的**。此前只有 `resolve-address`，它把整个 transcript 原样喂高德正向
/// 地理编码，整句进去必然返「没听清地点」；`/parse` 改成先抽地名 span 再查，整句里说的起点才第一次可用。
///
/// 与 `ParseSlotResponse` 一样，`plannedStartTime` 是无时区 `yyyy-MM-ddTHH:mm:ss`（**可能带小数秒**，
/// 用 `String.backendLocalDate` 解），可直接透传给 `CreateOrderRequest`；坐标已是 GCJ-02。
///
/// `missing` / `needReask` / `ttsText` 在 spec 里标 required，这里**一律放宽成可选** —— 线上偶发缺字段
/// 应该退化成「当没听清处理」，而不是整条解码炸掉。语音是盲人唯一的下单通道，这里要比 spec 松一档。
struct ParseVoiceOrderResponse: Codable, Sendable, Equatable {
    let plannedStartTime: String?
    let durationMinutes: Int?
    let address: String?
    let latitude: Double?
    let longitude: Double?

    // MARK: 终点（可选槽位，2026-08-08 后端 SPEC B1 新增）

    /// 解析出的终点地址；原话没说终点时 `nil`。
    ///
    /// **终点永远不进 `missing`，也不会触发追问**（`api_spec.yaml:2841`）—— 它是可选的，
    /// 一个可选字段不该把用户卡在追问循环里。所以 `VoiceOrderMissingSlot` 里没有 `END_ADDRESS`。
    ///
    /// ⚠️ 终点**只由大模型抽取，没有正则链路**：百炼不可用时本字段恒为 `nil`，
    /// 起点/时间/时长照常解析。这是后端明确接受的降级，**不能当契约**。
    let endAddress: String?
    /// ⚠️ 可能为 `nil` 而 `endAddress` 非 `nil`（说了地名、高德查不到坐标）。
    let endLatitude: Double?
    let endLongitude: Double?
    /// 后端声明它恒等于「`endAddress` 非 null 且 `endLatitude` 为 null」。
    ///
    /// **解它是为了漂移可见，判断一律用 `resolvedEndPlace` 自己算** ——
    /// 同一事实有两个来源时只信结构：这个字段 2026-08-09 刚因为算错被后端修过一次（N39），
    /// 而三元组本身当时是对的。
    let endAddressUnresolved: Bool?

    /// 还缺（或校验不通过）的槽位。**客户端把它当作「这几项保持默认值」**，不据此重问 ——
    /// 理由见 `VoiceOrderWizard.parseFreeform`。
    let missing: [VoiceOrderMissingSlot]?
    let needReask: Bool?
    /// `missing` 非空时这是**追问**文案，不是整单读回，所以整句轮不播它（后端 2026-08-04 确认：
    /// 抽不出的槽位保留什么默认值只有客户端知道，后端拼不出整单）。
    ///
    /// 确认轮**只在 `correctionTarget` / `correctionUnclear` 两个分支播它** —— 那两句是定向追问与
    /// 消歧问句，正是本地拼不出来的东西；其余分支仍用客户端自己的读回。
    let ttsText: String?

    // MARK: 确认轮的表态与定点修改（可选，2026-08-09 后端新增；iOS 2026-08-10 接入）

    /// 用户对读回确认的表态。三个可空字段一律**放宽成可选**，理由同上面那段：
    /// 线上偶发缺字段应该退化成「没表态」，而不是让整条响应解不出来。
    let userIntent: VoiceUserIntent?
    /// 用户点名要改的那一项（没给新值）。与 `userIntent` **互斥**。
    let correctionTarget: VoiceCorrectionTarget?
    /// 用户否定了读回但没说改哪一项，且模型也没识别出他想改什么。
    /// ⚠️ 用户**点了名**时这是 `false`，那一项由 `correctionTarget` 回报。
    let correctionUnclear: Bool?

    // MARK: 起点候选与「说了但没查到」（后端 2026-08-10 新增，N48）

    /// **起点**的同名候选，有序。长度 **≥2 = 这一轮是候选消歧轮**；没歧义时后端发空数组。
    ///
    /// 长度恒为 0 或 2~3，**不会是 1** —— 只有一个结果还问用户选哪个，
    /// 对听不见屏幕的人是纯粹的多一轮。
    ///
    /// ⚠️ **终点永远没有候选**：一次播 6 项超过纯听觉工作记忆的约 3 项上限。
    /// 终点抽错走读回 + `correctionTarget == .endAddress`。
    let candidates: [AddressCandidate]?

    /// 「听见了一个地名，但没能把它变成可用的起点」。
    ///
    /// 仅在 `missing` 含 `.address` 时有意义。区分两件对用户来说**该做的事完全相反**的情况：
    /// - `true` —— 用户**确实说了**一个地点，是我们没解析出来。此时静默把起点落回「当前位置」
    ///   就是**把人约到错误的起点**，必须说出来。
    /// - `false` —— 两道抽取都没拿到地名，用户很可能压根没说起点，落回当前位置是对的。
    ///
    /// ⚠️ 2026-08-10 起这个 `true` 会**变常见**：后端不再把搜不到的地名丢给全国范围的正向编码
    /// （那条路径曾把深圳说的地名解析到海南），改成诚实认输。所以这个字段从「可以不接」变成必须接。
    let addressUnresolved: Bool?

    // MARK: 额外需求槽位（可选，2026-08-04 后端新增）
    //
    // 三者都是「抽不出不追问」的可选槽位：解析不出不会进 `missing`，也不会单独触发大模型兜底
    // （大多数人不提导盲犬，那样每单都要白付一次调用）。

    /// 本次是否携带导盲犬。
    ///
    /// ⚠️ **`nil` ≠ `false`，两者在下单时的处理完全不同**：
    /// - `nil` —— 原话没提。下单时**不要传** `hasGuideDogThisRun`，让后端回落
    ///   `BlindProfile.hasGuideDog` 档案默认值。
    /// - `false` —— 本次明确不带（「今天不带导盲犬」）。要原样传。
    ///
    /// 传错的后果不是文案问题：这个字段进派单的**硬过滤**（不接受导盲犬的志愿者被直接踢出候选池），
    /// 把 `nil` 当 `false` 传，会让档案里登记了导盲犬的用户被静默按「不带」派单。
    let hasGuideDog: Bool?

    /// 本次配速偏好；`nil` 表示原话没提，下单时不传即回落档案默认配速。
    let pacePreference: PacePreference?

    /// 本次备注；`nil` 表示原话没提。
    ///
    /// 非 nil 时后端保证是用户原话的子串 —— 备注原样展示给志愿者，模型编出来的「我行动不便」
    /// 会直接误导对方，所以改写过的备注在后端就被丢弃了。
    let specialNotes: String?

    /// 终点四项与三个额外槽位默认 `nil`（＝原话没提），让只关心三个必填槽位的调用点不必逐个写 `nil`。
    /// 解码走 `Codable` 合成路径，不受这里的默认值影响。
    init(
        plannedStartTime: String?,
        durationMinutes: Int?,
        address: String?,
        latitude: Double?,
        longitude: Double?,
        missing: [VoiceOrderMissingSlot]?,
        needReask: Bool?,
        ttsText: String?,
        endAddress: String? = nil,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil,
        endAddressUnresolved: Bool? = nil,
        hasGuideDog: Bool? = nil,
        pacePreference: PacePreference? = nil,
        specialNotes: String? = nil,
        userIntent: VoiceUserIntent? = nil,
        correctionTarget: VoiceCorrectionTarget? = nil,
        correctionUnclear: Bool? = nil,
        candidates: [AddressCandidate]? = nil,
        addressUnresolved: Bool? = nil
    ) {
        self.plannedStartTime = plannedStartTime
        self.durationMinutes = durationMinutes
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.endAddress = endAddress
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
        self.endAddressUnresolved = endAddressUnresolved
        self.missing = missing
        self.needReask = needReask
        self.ttsText = ttsText
        self.hasGuideDog = hasGuideDog
        self.pacePreference = pacePreference
        self.specialNotes = specialNotes
        self.userIntent = userIntent
        self.correctionTarget = correctionTarget
        self.correctionUnclear = correctionUnclear
        self.candidates = candidates
        self.addressUnresolved = addressUnresolved
    }

    /// 起点三项要么全有要么当没抽到 —— 只有地址没有坐标下不了单，只有坐标没有地址读回时没法念。
    var resolvedStartPlace: (address: String, latitude: Double, longitude: Double)? {
        guard let address = address?.nilIfBlank, let latitude, let longitude else { return nil }
        return (address, latitude, longitude)
    }

    /// 终点：**规则比起点松一档**，有地名就算数、坐标可缺（`api_spec.yaml:3007-3019` 明确两边不同）。
    ///
    /// 反过来不行：只有坐标没有地名一律当没抽到 —— 那是客户端 bug，
    /// 而且读回时没有任何东西可念，盲人根本不知道被约到了哪。
    /// 半个坐标由 `BookingEndPlace.init` 降级成「只有地名」。
    var resolvedEndPlace: BookingEndPlace? {
        guard let address = endAddress?.nilIfBlank else { return nil }
        return BookingEndPlace(address: address, latitude: endLatitude, longitude: endLongitude)
    }

    /// 需要让用户挑一个的候选；不需要消歧时为 `nil`。
    ///
    /// 判据只看**数量 ≥2**，不看 `needReask`：后端在这一轮同时可能报 `missing`
    /// （时间/时长还没说），而 `needReask` 那时也为 true —— 两者混在一起分不出「该消歧」
    /// 还是「该追问」。数量是这一轮唯一无歧义的信号。
    var startCandidatesToDisambiguate: [AddressCandidate]? {
        guard let candidates, candidates.count >= 2 else { return nil }
        return candidates
    }

    /// 用户在消歧轮挑定一条之后的结果：**起点三项换成他挑的那个，其余字段逐字不变**。
    ///
    /// `candidates` 清空是必须的，不是顺手 —— 留着的话，这份结果被存进 `lastParsed`、
    /// 下一轮又被 `startCandidatesToDisambiguate` 读到，用户会为同一批候选被问第二遍。
    func replacingStartPlace(with candidate: AddressCandidate) -> ParseVoiceOrderResponse {
        ParseVoiceOrderResponse(
            plannedStartTime: plannedStartTime,
            durationMinutes: durationMinutes,
            address: candidate.readbackAddress,
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            missing: missing,
            needReask: needReask,
            ttsText: ttsText,
            endAddress: endAddress,
            endLatitude: endLatitude,
            endLongitude: endLongitude,
            endAddressUnresolved: endAddressUnresolved,
            hasGuideDog: hasGuideDog,
            pacePreference: pacePreference,
            specialNotes: specialNotes,
            userIntent: userIntent,
            correctionTarget: correctionTarget,
            correctionUnclear: correctionUnclear,
            candidates: [],
            // 挑定了就等于有坐标了，「说了但没查到」不再成立
            addressUnresolved: false
        )
    }

    /// 下一轮 `/parse` 要回传的 `current`。
    ///
    /// **快照唯一从响应派生，绝不从 view model 派生。** 契约本身说的就是「把响应原样放进下一轮
    /// `current`」，而 view model 那边分不出「用户说的」和「初值」—— `appointmentTime` 的初值是
    /// `Date()`，从它取会把一个用户从没说过的时刻当成「已确认槽位」发给后端，
    /// 后端再原样继承回来、读回念出来，一张没人说过的单就这么成立了。
    ///
    /// 坐标缺地址一律整组丢弃：只有坐标没有文字地址后端返 400，而那是客户端 bug，
    /// 不是该在运行时发出去试试看的东西。
    var slotSnapshot: VoiceSlotSnapshot {
        let startAddress = address?.nilIfBlank
        let endAddress = self.endAddress?.nilIfBlank
        return VoiceSlotSnapshot(
            plannedStartTime: plannedStartTime,
            durationMinutes: durationMinutes,
            address: startAddress,
            // 地址在就带坐标，地址不在就连坐标一起丢。允许「有地址无坐标」，禁止反过来。
            latitude: startAddress == nil ? nil : latitude,
            longitude: startAddress == nil ? nil : longitude,
            endAddress: endAddress,
            endLatitude: endAddress == nil ? nil : endLatitude,
            endLongitude: endAddress == nil ? nil : endLongitude,
            hasGuideDog: hasGuideDog,
            pacePreference: pacePreference,
            specialNotes: specialNotes
        )
    }
}

/// 一次只能解析一个字段 —— 这是接口层面的约束，不是产品选择。
struct ParseSlotRequest: Codable, Sendable {
    let transcript: String
    let field: VoiceSlotField
}

/// 时间/时长解析结果。
///
/// `plannedStartTime` 是 `yyyy-MM-ddTHH:mm:ss`（无时区），与 `CreateOrderRequest.plannedStartTime`
/// 同格式，**直接透传**，客户端不做二次格式化。提前量（≥30 分钟）和时长范围（10~300 分钟）由后端
/// 校验，不满足时同样返回 `needReask: true` + 提示文案，而不是错误分支。
struct ParseSlotResponse: Codable, Sendable, Equatable {
    let plannedStartTime: String?
    let durationMinutes: Int?
    let needReask: Bool?
    let ttsText: String?
}
