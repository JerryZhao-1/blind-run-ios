import Foundation

// MARK: - Legal Links Response

/// `GET /api/misc/legal-links` 响应体（`APIClient` 已自动解包 `{success, data}` 外层信封）。
///
/// 后端 `SecurityConfig` 对该端点 permitAll：未登录用户和 App Store 审核员都能访问，
/// 因此请求时必须传 `requiresAuth: false`。
///
/// 两个字段都可能为 `null`：后端从 `app.legal.privacy-policy-url` /
/// `app.legal.user-agreement-url` 配置注入，生产 URL 未上线时默认返回 `null`。
/// 此时入口必须回退到应用内置文案页（App Store 审核 5.1.1 / 5.1.2 阻塞项）。
struct LegalLinksResponse: Codable, Sendable, Equatable {
    let privacyPolicyUrl: String?
    let userAgreementUrl: String?
}

// MARK: - Legal Document Kind

/// 两类法律文档入口。
/// 不做未知值兜底：这是客户端自己的入口枚举，后端只返回两个 URL 字符串，没有对应字段被解码成它。
enum LegalDocumentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case privacyPolicy
    case userAgreement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: return "隐私政策"
        case .userAgreement: return "用户协议"
        }
    }

    /// 从响应中取出本类型对应的原始 URL 字符串。
    func rawURLString(in links: LegalLinksResponse?) -> String? {
        switch self {
        case .privacyPolicy: return links?.privacyPolicyUrl
        case .userAgreement: return links?.userAgreementUrl
        }
    }
}

// MARK: - Legal Document Destination

/// 一个法律文档入口点击后的落点。
///
/// 抽成独立枚举 + 纯函数（而不是把判断埋在 View body 里），
/// 以便单测直接覆盖「外链」和「内置回退文案」两条分支。
enum LegalDocumentDestination: Equatable, Sendable {
    /// 后端下发了可用的 http(s) URL，点击后在浏览器打开。
    case remote(URL)
    /// URL 为 null / 空 / 非法，或请求失败：点击后打开应用内置文案页。
    /// 绝不允许出现空白页、报错弹窗或禁用的灰按钮。
    case builtInFallback

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var remoteURL: URL? {
        if case .remote(let url) = self { return url }
        return nil
    }
}

extension LegalDocumentKind {
    /// 决定该入口走外链还是走内置回退文案。纯函数，无副作用。
    ///
    /// `links` 为 `nil` 表示尚未加载完成或请求失败 —— 一律回退到内置文案，
    /// 这样入口在任何时刻都是可点且有内容的。
    func destination(in links: LegalLinksResponse?) -> LegalDocumentDestination {
        guard let url = Self.validatedWebURL(rawURLString(in: links)) else {
            return .builtInFallback
        }
        return .remote(url)
    }

    /// 校验后端下发的字符串是否是可安全打开的网页地址。
    ///
    /// 后端配置是外部输入，不可信：必须挡掉空串、纯空白、字面量 "null"、
    /// 相对路径，以及 `javascript:` / `file:` / 自定义 scheme 等非网页地址。
    static func validatedWebURL(_ rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.lowercased() != "null",
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

// MARK: - Built-in Fallback Copy

/// 内置回退文案。
///
/// 正式法律文本未上线时的过渡版本：只陈述本应用当前真实的数据处理方式和使用要点，
/// 不编造法律条款，不承诺尚未实现的能力。
enum LegalFallbackCopy {

    struct Section: Identifiable, Equatable, Sendable {
        let id = UUID()
        let heading: String
        /// 每条单独成段，VoiceOver 可逐条浏览。
        let bullets: [String]
        /// 排在本节末尾、可以点开的链接。第三方 SDK 的隐私政策必须「透出且用户可点击」（高德合规方案原话），
        /// 写成正文里的一串网址点不开。
        var links: [Link] = []
    }

    struct Link: Equatable, Sendable {
        let title: String
        let url: URL
    }

    static let amapPrivacyURL = URL(string: "https://lbs.amap.com/pages/privacy/")!
    static let aliyunCloudAuthPrivacyURL = URL(string: "https://terms.aliyun.com/legal-agreement/terms/suit_bu1_ali_cloud/suit_bu1_ali_cloud202107281509_18386.html")!

    struct Document: Equatable, Sendable {
        let title: String
        /// 页首的状态说明，明确告知用户这是过渡版本。
        let notice: String
        let sections: [Section]
    }

    static func document(for kind: LegalDocumentKind) -> Document {
        switch kind {
        case .privacyPolicy: return privacyPolicy
        case .userAgreement: return userAgreement
        }
    }

    private static let privacyPolicy = Document(
        title: "隐私政策",
        notice: "正式版隐私政策全文正在上线中。以下是本应用当前版本实际收集和使用信息的说明。",
        sections: [
            // 这份文案不是摆设：后端的 `privacyPolicyUrl` 目前返回 null，**用户和 App Store
            // 审核员实际读到的就是这一份**。漏列一项等于「未公开收集使用规则」——
            // 收集项有增减时先改这里，不要等正式文本。
            Section(
                heading: "我们收集的信息",
                bullets: [
                    "手机号：用于登录和账户识别。",
                    "昵称和资料：用于向本次服务的另一方展示必要的身份信息。",
                    "姓名和身份证号：视障跑者预约前、志愿者接单资格审核前各做一次实名核验；提交前会单独征求你的同意，不会展示给服务的另一方。",
                    "位置信息与运动轨迹：仅在你创建预约、接单或服务进行中使用，用于匹配附近的志愿者、计算距离、展示地图并记录本次路线；服务进行中锁屏后仍会继续定位。",
                    "运动数据：仅在陪跑服务进行中，由手机的运动传感器记录步数、步频和爬升高度，随位置一起上传，用来在跑完后生成你的跑步记录；只显示给你自己，另一方看不到。",
                    "麦克风与语音内容：语音下单时把你说的话转成文字，只用于识别这一单的内容。",
                    "相机与人脸信息：仅志愿者做活体核验时使用，由阿里云活体认证完成。",
                    "紧急联系人姓名和电话：由视障跑者填写，用于紧急情况下联系。",
                    "志愿者身份认证资料与证书照片：用于审核志愿者接单资格。"
                ]
            ),
            Section(
                heading: "敏感个人信息",
                bullets: [
                    "身份证号、人脸信息和位置轨迹属于敏感个人信息。",
                    "收集它们的每一步都会单独征求你的同意；不同意不影响使用不依赖这些信息的功能。",
                    "把行程分享给家人时，任何拿到链接的人都能看到你的实时位置，你可以随时停止分享。"
                ]
            ),
            Section(
                heading: "我们如何使用这些信息",
                bullets: [
                    "仅用于完成陪跑服务的匹配、进行和结束。",
                    "服务开始后，向已接单的志愿者展示视障跑者的联系方式；接单前不展示。",
                    "不用于广告投放，不向第三方出售个人信息。"
                ]
            ),
            // #355：首启告知第 5 条指向这一节。字段逐项取自厂商原文（2026-10-07 核，
            // 见 `docs/research/third-party-sdk-disclosure-ios-20261007.md`），**别照抄安卓那份** ——
            // 高德 iOS 合包的收集项与安卓不同（没有 Wi-Fi、基站、IP），且本应用用的是 NO-IDFA 基础库。
            // SDK 换版本、换 pod、开关扩展功能时回那两页重核这一节。
            Section(
                heading: "第三方 SDK",
                bullets: [
                    "高德开放平台地图 SDK（含定位、搜索），提供方：北京高德图强科技有限公司。",
                    "使用目的：为你提供地图展示、定位和地址搜索。",
                    "收集的个人信息：经纬度、搜索词、传感器信息（矢量、加速度、压力）、当前应用信息（应用名、应用版本号）、设备参数及系统信息（设备品牌及型号、操作系统、运营商信息、屏幕分辨率）。本应用使用的是不采集 IDFA（广告标识符）的版本。",
                    "收集方式：SDK 在你的手机上采集，发送给高德的服务器，用于计算位置和返回地图、搜索结果。",
                    "高德的「安全保障」和「数据用于统计分析」两项扩展功能，本应用都没有开启。",
                    "阿里云金融级实人认证 SDK，提供方：杭州阿里云智能科技有限公司。只在志愿者做人脸核验时使用。",
                    "使用目的：核验志愿者是不是本人，识别虚假设备。",
                    "收集的个人信息：姓名、身份证号、人脸图片和视频流；设备基础信息（设备制造商、品牌、类型及型号、名称、操作系统、内存及存储大小、电池及电量、基带、开机时间、屏幕亮度及分辨率、CPU、时区、语言、充电状态、系统内核、传感器列表、光线传感器）、设备标识（IDFV）、网络信息（BSSID、SSID、运营商、网络类型、SIM 卡状态）、本应用的名称、版本和安装时间，以及核验过程的操作日志。",
                    "收集方式：SDK 在你的手机上采集，发送给阿里云的服务器完成核验。"
                ],
                links: [
                    Link(title: "高德地图开放平台隐私权政策", url: amapPrivacyURL),
                    Link(title: "阿里云金融级实人认证 SDK 隐私政策", url: aliyunCloudAuthPrivacyURL)
                ]
            ),
            Section(
                heading: "你的选择",
                bullets: [
                    // 与隔壁麦克风那条同一个写法：说清关闭后**少了什么、还能怎么办**。
                    // 「关闭后无法创建预约」是 2026-08-18 之前的实现，现在手动搜索地点仍可预约，
                    // 留着就是在隐私说明里写一句不实陈述。
                    "可以在系统设置中关闭定位权限。关闭后无法自动获取出发地点，仍可以在预约页手动搜索地点下单；但陪跑过程中志愿者看不到你的实时位置，紧急求助也可能发不出去。志愿者需要开启定位才能接单。",
                    "可以在系统设置中关闭「运动与健身」权限。关闭后跑步记录里的步数、步频和爬升高度显示为空，陪跑不受影响。",
                    "可以在系统设置中关闭麦克风权限。关闭后语音下单不可用，仍可以在预约页手动填写。",
                    "可以在本应用「设置 - 删除账户」中删除账户。删除后所有登录令牌立即失效，手机号可以重新注册。",
                    "删除账户会删除实名资料、紧急联系人、常用地点、轨迹记录和跑步记录。",
                    // 正面列举保留了什么，不要写「其中不含上述资料」这类否定式列举 ——
                    // 后者只在读者和我们对「上述资料」的范围理解一致时才准确，而那恰恰是用户
                    // 最不可能对齐的地方。保留的订单里存着精确起终点坐标与用户口述的身体状况，
                    // 求助记录里存着按下 SOS 那一刻的 GPS 单点（后端 2026-08-19 逐句核过）。
                    "订单、评价和求助记录会保留用于纠纷复核，其中仍包含每次陪跑的起终点位置、你填写的备注和评价、求助时的位置以及客服的处理记录，但不包含你的姓名、身份证号和紧急联系人。"
                ]
            ),
            Section(
                heading: "关于本说明",
                bullets: [
                    "本说明为正式文本上线前的过渡版本，内容与应用当前行为一致。",
                    "正式隐私政策和对外联系方式将随正式文本一同发布。在此之前，你可以使用「设置 - 删除账户」自助删除账户及相关数据。"
                ]
            )
        ]
    )

    private static let userAgreement = Document(
        title: "用户协议",
        notice: "正式版用户协议全文正在上线中。以下是本应用当前版本的使用要点。",
        sections: [
            Section(
                heading: "服务内容",
                bullets: [
                    "本应用为视障跑者和志愿者提供陪跑服务的预约与匹配。",
                    "本应用不提供医疗、康复或急救服务。"
                ]
            ),
            Section(
                heading: "使用规则",
                bullets: [
                    "请填写真实的手机号、昵称和紧急联系人信息。",
                    "视障跑者需要完成实名认证后才能预约；志愿者需要通过身份认证、上传资质证书并通过审核后才能接单。",
                    // 原文写的是「一个手机号可以同时拥有两个身份，有进行中的订单时不能切换身份」——
                    // 与实现相反：后端 `POST /api/user/role` 角色一经设定即抛 `ROLE_ALREADY_SET`，
                    // 全仓没有任何改角色的路径，App 里的切换入口也已删除。这段会被审核员读到，不能留错的。
                    "一个手机号只能选择一种身份（视障跑者或志愿者），选定后无法更改。如需更换身份，请删除账户后重新注册。"
                ]
            ),
            Section(
                heading: "安全与责任",
                bullets: [
                    "陪跑服务由用户之间线下完成，参与前请自行评估身体状况和路线安全。",
                    "遇到紧急情况，请优先联系当地急救服务。"
                ]
            ),
            Section(
                heading: "账户",
                bullets: [
                    "你可以随时在「设置 - 删除账户」中删除账户。",
                    "本要点为正式协议上线前的过渡版本，内容与应用当前行为一致。"
                ]
            )
        ]
    )
}
