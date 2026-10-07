import Foundation

// MARK: - Purpose

/// 需要**单独同意**的处理目的。
///
/// **这不是产品文案，是合规文本。** PIPL 第 14 条要求告知后取得同意，第 29 条要求处理敏感个人信息
/// 取得**单独**同意 —— 「单独」的意思是：一次概括的「同意隐私政策」不能覆盖身份证号、人脸、
/// 行踪轨迹这三类，到收集它们的那一步必须再问一次。
///
/// 已有的 `RunPlanShareConsent` 走的就是这条路（轨迹→第三方）。本枚举补齐另外两个收集点：
/// 首次启动的整体告知，以及两端实名认证收集身份证号（志愿者还叠一次人脸活体）。
///
/// ponytail: `RunPlanShareConsentStore` 与这里的 `PrivacyConsentStore` 形状相同。没有合并是因为
/// 前者已发布且有自己的用例；下一次动到那块时再合，不要为了对称去改跑着的代码。
enum PrivacyConsentPurpose: String, CaseIterable, Sendable {
    /// 首次启动的整体告知。按**设备**记 —— 同意发生在登录之前，那时还没有账号。
    case appLaunch
    /// 视障跑者实名认证：姓名 + 身份证号。
    case blindIdentity
    /// 志愿者实名认证：姓名 + 身份证号，下一步还有人脸活体与证件照。
    case volunteerIdentity
    /// 视障跑者的**视力状况**与**是否使用导盲犬**。
    ///
    /// 2026-09-10 确证为敏感个人信息，依据链三层：PIPL 第二十八条「特定身份」→
    /// 网信办《个人信息保护政策法规问答（2026年1月）》点名「**残障人士身份信息**」→
    /// 国标 GB/T 45574-2025 附录 A。完整依据在后端
    /// `demo/docs/research/compliance-gap-20260910.md` 的 **CG-2**。
    ///
    /// 🔴 **只盖视力状况与导盲犬，不盖引导方式（`tetherPreference`）。**
    /// 引导方式是偏好不是身份信息，不敏感 —— 把它一起关进这道门，用户拒绝之后
    /// 志愿者就完全不知道该怎么带他，「拒绝」实际等于服务不可用。
    /// 反过来说也有依据：GB/T 42574-2023 允许「多字段一次性单独同意」的前提是
    /// 「**逐项拆分字段后无法达成处理目的**」，而我们恰恰拆得开
    /// （拒绝视力状况，靠引导方式仍能完成引导）⇒ 打包反而不满足那条豁免。
    /// 调研见 `docs/research/vision-level-collection-ui-20260910.md` §4.2。
    case blindVisionProfile

    /// 告知内容的版本。版本号进存储 key，+1 之后旧记录自然失效、用户会被重新问一次。
    ///
    /// **判据是「告知的处理行为变没变」，不是「这几个字变没变」：**
    /// - 新收集一类信息、换用途、换接收方、改保留或删除规则 → **必须 +1**。
    ///   旧同意没有覆盖到新内容，继续拿它当同意是合规漏洞。
    /// - 同一个行为**换一种说法**（更准、更好懂、错别字）→ **不 +1**，
    ///   只更新 `PrivacyConsentTests` 里的指纹，并在那条用例旁写清这次属于哪一种。
    ///
    /// `PrivacyConsentTests.testDisclosureFingerprintIsPinnedToItsVersion` 会在文案一变就失败 ——
    /// 它的作用是**逼一次上面这个判断**，不是自动要求 +1。
    ///
    /// 2026-09-30 的反例（`appLaunch` 1 → 2）：跑后运动记录开始采集步数、步频、爬升高度，
    /// 是**新收集一类信息**，落在上面第一档。v1 从未对外分发（无 TestFlight / 上架构建），
    /// 所以这次 +1 没有拦住任何真实老用户 —— 这也是它现在做比上架后做便宜的原因。
    ///
    /// 2026-08-20 的例子（删除账户那句改成正面列举）：后端逐句核过代码，
    /// `UserService.cascadeDeletePii` 的删除行为一个字节都没改，变的只是我们把它描述得更准。
    /// 曾一度按「用户此前以为位置被删干净了」的理由 +1 到 2，同日回退 —— 处理行为没变，
    /// 就不该把全部老用户拦在同意页前面重来一次。**该版本从未随任何构建对外发布过**
    /// （`CURRENT_PROJECT_VERSION` 至今为 1，没有上传过 TestFlight），所以回退零影响。
    var disclosureVersion: Int {
        switch self {
        case .appLaunch: return 3
        case .blindIdentity: return 1
        case .volunteerIdentity: return 1
        case .blindVisionProfile: return 1
        }
    }

    var title: String {
        switch self {
        case .appLaunch:
            return "开始前，先说清楚我们会收集什么"
        case .blindIdentity:
            return "提交实名信息前，请先确认"
        case .volunteerIdentity:
            return "提交实名信息前，请先确认"
        case .blindVisionProfile:
            return "填写视力状况前，请先确认"
        }
    }

    /// 每条都是完整的一句话，且在 UI 上是**独立的 VoiceOver 焦点**。
    /// 挤进一段长文本等于没有告知：读屏会一口气念完，用户记不住也回不去。
    var disclosures: [String] {
        switch self {
        case .appLaunch:
            return [
                "登录用你的手机号。视障跑者预约前要先实名认证，会收集姓名和身份证号；志愿者还要提供证件照并做一次人脸核验。",
                "陪跑服务进行中会持续获取你的位置，用来把双方位置显示给对方、记录这次的路线；锁屏后仍在定位。",
                "语音下单会录下你说的话并转成文字，只用于识别这一单的内容。",
                // 2026-09-30 加入运动数据（后端隐私政策 v1.2 §2.5）。**这次 +1 `disclosureVersion`**：
                // 新收集一类信息（步数 / 步频 / 爬升高度，跑后运动记录 #189 起随位置上传），
                // 旧同意没有覆盖到 —— 与 09-10 那次「换分类说法」性质相反。独立一条是为了
                // 读屏用户把它当成单独的焦点听到，而不是埋在位置那句里。
                "陪跑服务进行中，手机的运动传感器还会记录你的步数、步频和爬升高度，跑完后只显示在你自己的跑步记录里，另一方看不到。不同意「运动与健身」权限也不影响陪跑。",
                // 2026-10-07 加入高德 SDK（#355，与安卓 #54 逐字一致，负责人同意）。**+1 `disclosureVersion`（2 → 3）**：
                // 新的接收方。`AMapManager.configurePrivacyCompliance` 一直在向高德声明「告知已含高德条款」，此前不属实。
                // 细项在内置隐私政策「第三方 SDK」一节（按高德 iOS 地图合包条目列）。
                // ⚠️ 「Wi-Fi、基站」是安卓合包的收集项，高德 iOS 条目里没有 —— 这句按负责人要求与安卓逐字一致，偏差已在 #355 提出。
                "地图、定位和地址搜索由高德开放平台 SDK（北京高德图强科技有限公司）提供。为此它会在你的手机上收集位置、搜索词，以及 Wi-Fi、基站、传感器等设备与网络信息，发送给高德的服务器。详见隐私政策「第三方 SDK」一节。",
                // 2026-09-10 加入「视力状况」。**刻意不 +1 `disclosureVersion`**：
                // 按本文件上面那条判据，+1 的触发条件是「告知的**处理行为**变没变」——
                // 这两个字段的收集、用途、接收方、保留规则一个字节都没改，
                // 变的只是我们把它的**分类**说准了（PIPL 第二十八条「特定身份」）。
                // 属于「换一种说法」那一档 ⇒ 只更新指纹用例，不把老用户拦回同意页重来一次。
                "身份证号、人脸、位置轨迹和视力状况属于敏感个人信息。到收集它们的那一步，我们会再单独问你一次。",
                // 「不卖给第三方」→「不出售给任何人」：上一条刚说第三方 SDK 会收集，原措辞读起来像自相矛盾；承诺的实质不变。
                "这些信息只用于完成陪跑服务，不做广告、不出售给任何人。你随时可以在设置里删除账户：实名资料、紧急联系人、运动轨迹和跑步记录会被删除。",
                "订单、评价和求助记录会保留用于纠纷复核。里面仍有每次陪跑的起终点位置、你填写的备注和求助时的位置，但没有你的姓名、身份证号和紧急联系人。"
            ]
        case .blindIdentity:
            return [
                "提交后，你的姓名和身份证号会发给助盲跑的服务器做实名核验。",
                "身份证号属于敏感个人信息，只用于核验身份和判断预约资格，不会展示给志愿者。",
                "身份证号不会保存在这台手机上。删除账户时，实名资料会一并删除。"
            ]
        case .volunteerIdentity:
            return [
                "提交后，你的姓名和身份证号会发给助盲跑的服务器做实名核验，下一步还要做一次人脸活体核验。",
                "身份证号和人脸属于敏感个人信息，只用于核验身份和审核接单资格，不会展示给视障跑者。",
                "身份证号不会保存在这台手机上。删除账户时，实名资料和证件照会一并删除。"
            ]
        case .blindVisionProfile:
            return [
                "视力状况和是否使用导盲犬属于敏感个人信息，填不填由你决定。",
                "它只用来让志愿者知道该怎么准备：你能不能看见他挥手、要不要带牵引绳。它不参与排序打分。",
                // 🚩 后端点名要求写进同意文案的事实（`compliance-gap-20260910.md` CG-2）。
                // 强度说明：把「会被谁看到、什么阶段看到」写进同意界面，是对 PIPL 第三十条
                // 「对个人权益的影响」的**文义推导 + 后端要求**，**不是**查到的官方明确条款要求。
                // 但事实本身是硬的：`AvailableOrderResponse` 在接单前就下发这两项，
                // 后端有意如此、不打算改（志愿者要能提前准备），用户有权在同意之前知道。
                "志愿者在接单前就能看到这两项，包括最后没有接你单的那些人。这是为了让他到场前能做好准备。",
                // 🔴 这一条是本次分层设计对用户的可见承诺，删了它整套设计就退回捆绑同意。
                // `BlindEscortPreferencesTests` 钉住。
                "不填也能约跑。你可以只告诉志愿者希望怎么被引导，那一项不需要单独同意。"
            ]
        }
    }

    var agreeButtonTitle: String {
        switch self {
        case .appLaunch: return "同意并开始使用"
        case .blindIdentity, .volunteerIdentity: return "同意并提交"
        case .blindVisionProfile: return "同意并填写"
        }
    }

    /// 拒绝按钮与同意按钮**同样大、同样整行铺满**（理由见 `RunPlanShareConsentView`）：
    /// 把拒绝做小是在用视觉权重替用户做决定，而这里的用户看不见视觉权重。
    var declineButtonTitle: String {
        switch self {
        case .appLaunch: return "先不同意"
        case .blindIdentity, .volunteerIdentity: return "先不提交"
        case .blindVisionProfile: return "不填这一项"
        }
    }

    /// 拒绝后的反馈。不劝、不重试 —— 拒绝是一个完整的答案。
    /// 首启这条要说清后果，否则用户按下去只会看到一个没有反应的页面。
    var declinedFeedback: String {
        switch self {
        case .appLaunch:
            return "没有同意就无法使用助盲跑的服务。你可以先看隐私政策全文，想好了再按同意。"
        case .blindIdentity, .volunteerIdentity:
            return "没有提交。你可以随时回到这一页再提交。"
        case .blindVisionProfile:
            // **不劝返**（`docs/research/face-verify-decline-alternative-path-ux-20260908.md`：
            // GB/T 41819-2022 把「48 小时内提示 >1 次」举为反面做法）。这句只做两件事：
            // 确认拒绝是一个完整的答案，以及把人指向那条**真的还能走**的路。
            return "没有填。你仍然可以约跑，也可以在上面告诉志愿者希望怎么被引导。"
        }
    }

    /// 播报脚本。标题也念 —— 听的人没有视觉分段。
    var spokenScript: String {
        ([title] + disclosures).joined(separator: " ")
    }

    /// 首启页正文：**摘要**，不是告知本身。完整的逐条告知仍是 `disclosures`，放在二级页「完整收集清单」里。
    ///
    /// 为什么要有这一段：首启页原先把整张清单摊在首屏、按钮排在最底下，与常规 App
    /// 「一段摘要 + 隐私政策链接 + 同意 / 不同意」的形态不同（issue #277）。
    /// 摘要只能**点名**类别与承诺，不能引入 `disclosures` 里没有的处理行为 ——
    /// `PrivacyConsentTests` 钉住它必须点名的关键词。其余目的没有摘要，仍整页逐条告知。
    var launchSummary: String? {
        switch self {
        case .appLaunch:
            return "助盲跑会收集你的手机号、位置、语音和运动数据；实名认证时还会收集身份证号，志愿者另需人脸核验。"
                + "地图、定位和地址搜索由高德开放平台 SDK 提供。"
                + "这些信息只用于陪跑服务，不做广告、不出售给任何人。"
                + "身份证号、人脸、位置轨迹和视力状况属于敏感个人信息，收集前会再单独问你。"
        case .blindIdentity, .volunteerIdentity, .blindVisionProfile:
            return nil
        }
    }

    /// 首启弹窗的标题。**与 `title` 分开**：`title` 是完整清单页的标题，进了指纹，改它要过一遍版本判断；
    /// 弹窗标题按常规 App 的叫法写短（「个人信息保护提示」），不属于告知内容。
    var launchTitle: String? {
        switch self {
        case .appLaunch: return "个人信息保护提示"
        case .blindIdentity, .volunteerIdentity, .blindVisionProfile: return nil
        }
    }

    /// 首启弹窗的自动播报：弹窗标题 + 摘要，不念 7 条全文（那在二级页里，每条可单独听）。
    var launchSpokenScript: String {
        [launchTitle ?? title, launchSummary].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Scope

/// 同意的归属。首启那条按设备（同意时还没有账号），实名那两条按账号 ——
/// 同一台手机换人用不是罕见场景，视障用户的设备常由家人协助设置。
enum PrivacyConsentScope: Equatable, Sendable {
    case device
    case user(String)

    var storageComponent: String {
        switch self {
        case .device: return "device"
        case .user(let id): return "user.\(id)"
        }
    }
}

// MARK: - Store

struct PrivacyConsentStore {
    private let persistence: any AppStatePersistence

    init(persistence: any AppStatePersistence) {
        self.persistence = persistence
    }

    static func storageKey(
        purpose: PrivacyConsentPurpose,
        scope: PrivacyConsentScope,
        version: Int? = nil
    ) -> String {
        let resolvedVersion = version ?? purpose.disclosureVersion
        return "com.aidrun.mvp.privacyConsent.\(purpose.rawValue).v\(resolvedVersion).\(scope.storageComponent)"
    }

    func hasConsented(to purpose: PrivacyConsentPurpose, scope: PrivacyConsentScope) -> Bool {
        persistence.object(forKey: Self.storageKey(purpose: purpose, scope: scope)) as? Bool == true
    }

    func recordConsent(to purpose: PrivacyConsentPurpose, scope: PrivacyConsentScope) {
        persistence.set(true, forKey: Self.storageKey(purpose: purpose, scope: scope))
    }
}
