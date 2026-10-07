import XCTest
@testable import blindRun

/// 首次启动告知与两个实名收集点的**单独同意**。
///
/// 守的是合规约束，不是体验约束：PIPL 第 14 条要求告知后取得同意，第 29 条要求处理敏感个人信息
/// （身份证号、人脸、行踪轨迹）取得**单独**同意。「同意页没弹出来」这类缺陷在 UI 里几乎测不出来，
/// 所以判定被抽成纯逻辑放在这里。
@MainActor
final class PrivacyConsentTests: XCTestCase {

    // MARK: - Store

    func testConsentIsNotGrantedUntilItIsRecorded() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }
        let store = PrivacyConsentStore(persistence: persistence)

        for purpose in PrivacyConsentPurpose.allCases {
            XCTAssertFalse(store.hasConsented(to: purpose, scope: .device), "\(purpose) 不该默认已同意")
        }

        store.recordConsent(to: .appLaunch, scope: .device)
        XCTAssertTrue(store.hasConsented(to: .appLaunch, scope: .device))
    }

    /// 三个目的互不相干：同意首启告知**不等于**同意交出身份证号，这正是「单独同意」的含义。
    func testOnePurposeDoesNotGrantAnother() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }
        let store = PrivacyConsentStore(persistence: persistence)

        store.recordConsent(to: .appLaunch, scope: .device)

        XCTAssertFalse(store.hasConsented(to: .blindIdentity, scope: .user("42")))
        XCTAssertFalse(store.hasConsented(to: .volunteerIdentity, scope: .user("42")))
    }

    /// 实名那两条按**人**记。同一台手机换人用不是罕见场景，视障用户的设备常由家人协助设置。
    func testIdentityConsentDoesNotCarryOverToAnotherAccount() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }
        let store = PrivacyConsentStore(persistence: persistence)

        store.recordConsent(to: .blindIdentity, scope: .user("42"))

        XCTAssertTrue(store.hasConsented(to: .blindIdentity, scope: .user("42")))
        XCTAssertFalse(store.hasConsented(to: .blindIdentity, scope: .user("43")), "另一个账号不该继承同意")
        XCTAssertFalse(store.hasConsented(to: .blindIdentity, scope: .device))
    }

    /// 告知内容一改，旧同意就没有覆盖到新内容，必须重新征得。版本号进 key，旧记录自然失效。
    func testBumpingTheDisclosureVersionInvalidatesOldConsent() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }
        let store = PrivacyConsentStore(persistence: persistence)

        store.recordConsent(to: .appLaunch, scope: .device)

        let nextVersionKey = PrivacyConsentStore.storageKey(
            purpose: .appLaunch,
            scope: .device,
            version: PrivacyConsentPurpose.appLaunch.disclosureVersion + 1
        )
        XCTAssertNil(persistence.object(forKey: nextVersionKey), "改版后不该读到上一版的同意")
    }

    // MARK: - AppState 接线

    /// 全新安装：没同意过就是没同意。`ContentView` 靠这个标志决定要不要挡在路由前面。
    func testFreshInstallHasNotAcceptedTheLaunchDisclosure() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }

        let appState = AppState(persistence: persistence)

        XCTAssertFalse(appState.didAcceptPrivacyConsent)
    }

    /// 「同意」必须是一个主动动作，且要落盘 —— 只改内存的话下次冷启动又会挡一遍。
    func testAcceptingTheLaunchDisclosurePersistsAcrossRelaunch() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }

        let appState = AppState(persistence: persistence)
        appState.acceptPrivacyConsent()
        XCTAssertTrue(appState.didAcceptPrivacyConsent)

        // 同一个持久化域上重建 AppState = 下一次冷启动。
        let relaunched = AppState(persistence: persistence)
        XCTAssertTrue(relaunched.didAcceptPrivacyConsent, "同意应当跨启动保留")
    }

    /// UI 用例默认跳过同意门，专测它的那条用 `FORCE` 走真实首启路径。
    /// 写反的表现是**全部 UI 用例被同意页挡住**，而真机 UI 通道时好时坏，坏的时候没人会发现。
    func testUITestLaunchSkipsTheGateUnlessItIsTheOneUnderTest() {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        defer { persistence.reset() }

        XCTAssertTrue(
            AppState.resolveInitialPrivacyConsent(
                persistence: persistence,
                environment: ["AIDRUN_UI_TEST_RESET_STATE": "1"]
            ),
            "普通 UI 用例应当跳过同意门"
        )
        XCTAssertFalse(
            AppState.resolveInitialPrivacyConsent(
                persistence: persistence,
                environment: [
                    "AIDRUN_UI_TEST_RESET_STATE": "1",
                    "AIDRUN_UI_TEST_FORCE_PRIVACY_CONSENT": "1"
                ]
            ),
            "专测同意门的用例必须真的看到它"
        )
        XCTAssertFalse(
            AppState.resolveInitialPrivacyConsent(persistence: persistence, environment: [:]),
            "真实安装没有这些环境变量，一律要同意"
        )
    }

    // MARK: - 告知文案

    /// 每条告知在 UI 上是**独立的 VoiceOver 焦点**，拼成一段长文本等于没有告知：
    /// 读屏会一口气念完，用户记不住也回不去。
    func testEveryPurposeHasDistinctWholeSentenceDisclosures() {
        for purpose in PrivacyConsentPurpose.allCases {
            let disclosures = purpose.disclosures
            XCTAssertGreaterThanOrEqual(disclosures.count, 3, "\(purpose) 的告知太少")
            XCTAssertEqual(Set(disclosures).count, disclosures.count, "\(purpose) 的告知有重复")
            for text in disclosures {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
                XCTAssertTrue(text.hasSuffix("。"), "每条告知都该是完整的一句话：\(text)")
            }
            XCTAssertFalse(purpose.title.isEmpty)
            XCTAssertFalse(purpose.agreeButtonTitle.isEmpty)
            XCTAssertFalse(purpose.declineButtonTitle.isEmpty)
            XCTAssertFalse(purpose.declinedFeedback.isEmpty)
        }
    }

    /// 首启页正文是摘要（issue #277）。摘要不是告知本身，但它是用户首屏**唯一读到的文字**，
    /// 所以必须点名与完整清单同一批关键词，且比完整清单短 —— 否则「摘要」要么漏告知、要么没起到摘要作用。
    /// 另外三个目的没有摘要，仍整页逐条告知。
    func testLaunchSummaryNamesTheSameCategoriesAndIsShorterThanTheFullList() throws {
        let summary = try XCTUnwrap(PrivacyConsentPurpose.appLaunch.launchSummary)
        for keyword in ["身份证号", "人脸", "位置", "手机号", "视力状况", "敏感个人信息", "不做广告"] {
            XCTAssertTrue(summary.contains(keyword), "首启摘要漏了「\(keyword)」")
        }
        XCTAssertLessThan(
            summary.count,
            PrivacyConsentPurpose.appLaunch.disclosures.joined().count / 2,
            "摘要不比完整清单短一半以上，就失去了摘要的意义"
        )
        XCTAssertFalse(
            PrivacyConsentPurpose.appLaunch.launchSpokenScript.contains(PrivacyConsentPurpose.appLaunch.disclosures[1]),
            "首启自动播报只念标题 + 摘要，不念 6 条全文"
        )
        for purpose in PrivacyConsentPurpose.allCases where purpose != .appLaunch {
            XCTAssertNil(purpose.launchSummary, "\(purpose) 是收集点的单独同意，必须逐条摊开，不许有摘要")
            XCTAssertNil(purpose.launchTitle, "\(purpose) 没有首启弹窗")
        }
        XCTAssertEqual(PrivacyConsentPurpose.appLaunch.launchTitle, "个人信息保护提示")
        XCTAssertTrue(
            PrivacyConsentPurpose.appLaunch.launchSpokenScript.hasPrefix("个人信息保护提示"),
            "自动播报以弹窗标题开头"
        )
    }

    /// 二级页「完整收集清单」必须原样带出 `disclosures`，一条不少、一个字不改 ——
    /// 摘要只是把它们挪到了下一步，不是替代。
    func testFullDisclosureDocumentCarriesEveryDisclosureVerbatim() {
        let document = PrivacyConsentGateView.fullDisclosureDocument(for: .appLaunch)
        XCTAssertEqual(document.sections.flatMap(\.bullets), PrivacyConsentPurpose.appLaunch.disclosures)
    }

    /// 两个实名收集点必须逐字说出「身份证号」，首启那条必须说出三类敏感信息 ——
    /// 告知里不点名，用户无从判断自己在同意什么。
    func testSensitiveItemsAreNamedInTheDisclosures() {
        let launch = PrivacyConsentPurpose.appLaunch.disclosures.joined()
        // 「视力状况」2026-09-10 加入：它是 PIPL 第二十八条的「特定身份」（残障人士身份信息），
        // 与身份证号 / 人脸 / 行踪轨迹同档，首启就该点名。
        for keyword in ["身份证号", "人脸", "位置", "手机号", "视力状况"] {
            XCTAssertTrue(launch.contains(keyword), "首启告知漏了「\(keyword)」")
        }

        XCTAssertTrue(PrivacyConsentPurpose.blindIdentity.disclosures.joined().contains("身份证号"))
        let volunteer = PrivacyConsentPurpose.volunteerIdentity.disclosures.joined()
        XCTAssertTrue(volunteer.contains("身份证号"))
        XCTAssertTrue(volunteer.contains("人脸"), "志愿者下一步就是活体认证，必须在这一屏说清")

        let vision = PrivacyConsentPurpose.blindVisionProfile.disclosures.joined()
        XCTAssertTrue(vision.contains("敏感个人信息"), "不点名「敏感」，用户无从判断自己在同意什么")
        XCTAssertTrue(vision.contains("导盲犬"), "导盲犬与视力状况同属这道门，不能只说一半")
    }

    // MARK: - 视力状况这道门的两条红线

    /// 🚩 **「志愿者接单前就能看到，包括最后没接你单的那些人」必须写在同意界面里。**
    ///
    /// 这是后端点名要求的（`demo/docs/research/compliance-gap-20260910.md` CG-2），
    /// 事实本身是硬的：`AvailableOrderResponse` 在接单前就下发这两项，后端有意如此、
    /// 不打算改（志愿者要能提前准备牵引绳）。用户有权在同意**之前**知道这件事。
    ///
    /// ⚠️ 强度说明，别在文档里升格：把「会被谁看到」写进同意界面是对 PIPL 第三十条
    /// 「对个人权益的影响」的**文义推导 + 后端要求**，不是查到的官方明确条款。
    func testBlindVisionConsentDisclosesPreAcceptVisibilityIncludingDecliners() {
        let disclosures = PrivacyConsentPurpose.blindVisionProfile.disclosures.joined()

        XCTAssertTrue(
            disclosures.contains("接单前"),
            "没说清是「接单前」就能看到 —— 用户会以为只有最终接单的那个人拿得到"
        )
        XCTAssertTrue(
            disclosures.contains("没有接你单"),
            "没说清「包括最后没有接你单的那些人」—— 那正是用户想不到、而后端确实会做的事"
        )
    }

    /// 🔴 **「不填也能约跑」是本次分层设计对用户的可见承诺，删了它整套设计就退回捆绑同意。**
    ///
    /// 分层：敏感的（视力状况 / 导盲犬）走这道门，不敏感的引导方式（`tetherPreference`）
    /// 在门外。拒绝的人仍然填得了引导方式、仍然约得了跑 —— 这句话就是在告诉用户这件事。
    /// 少了它，用户面对一个「同意 / 不填」的二选一时，只能假设不填就用不了。
    ///
    /// 配套的行为断言在 `BlindEscortPreferencesTests`：那边验的是**真的还能填**，
    /// 这边验的是**我们真的这么告诉了用户**。两条都要在，缺任一条都是「说到没做到」或「做到没说」。
    func testBlindVisionConsentPromisesBookingStillWorksWithoutIt() {
        let disclosures = PrivacyConsentPurpose.blindVisionProfile.disclosures.joined()

        XCTAssertTrue(
            disclosures.contains("不填也能约跑"),
            "这句是分层设计对用户的承诺，不能删也不能软化"
        )
        XCTAssertTrue(
            disclosures.contains("希望怎么被引导"),
            "要把人指向那条**真的还能走**的路，否则「不填也能约跑」只是一句安慰"
        )

        // 拒绝后的反馈同样不许劝返，且要重复指路
        // （`docs/research/face-verify-decline-alternative-path-ux-20260908.md`：
        // GB/T 41819-2022 把「48 小时内提示 >1 次」举为反面做法）。
        let declined = PrivacyConsentPurpose.blindVisionProfile.declinedFeedback
        XCTAssertTrue(declined.contains("仍然可以约跑"), "拒绝后要先确认「你还能用」")
        for nagging in ["建议", "请重新", "为了你的安全请", "再考虑"] {
            XCTAssertFalse(declined.contains(nagging), "拒绝后不许劝返：「\(nagging)」")
        }
    }

    /// 告知内容改了而 `disclosureVersion` 该 +1 却没 +1，旧同意会被当成对新内容的同意 ——
    /// 那是合规上的漏洞，且没有任何运行时表现，只能靠这条钉住。
    ///
    /// ⚠️ **这条红了不是「去 +1 版本号」，是「去做一次判断」**（判据见
    /// `PrivacyConsentPurpose.disclosureVersion` 的文档注释）：
    /// - 告知的**处理行为**变了（新收集一类信息、换用途、换接收方、改删除规则）→ +1 版本号，再换指纹
    /// - 同一个行为**换一种说法**（更准、更好懂、错别字）→ 版本号不动，只换指纹，
    ///   并在下面 `pinned` 里那一行写清这次属于哪一种
    ///
    /// 无脑 +1 的代价不是零：每个老用户下次冷启动都会被拦在同意页前面重来一次，
    /// 而对读屏用户那是一整屏要逐条听完的文本。
    /// #355：首启告知点名高德、措辞不再与「第三方 SDK 会收集」自相矛盾；
    /// 隐私政策有「第三方 SDK」一节，高德与阿里云的隐私政策链接都**可点**（高德合规方案原话「透出且用户可点击」）。
    func testLaunchDisclosureNamesAMapAndThePolicyLinksBothSDKPolicies() throws {
        let disclosures = PrivacyConsentPurpose.appLaunch.disclosures
        XCTAssertTrue(disclosures.contains { $0.hasPrefix("地图、定位和地址搜索由高德开放平台 SDK（北京高德图强科技有限公司）提供。") })
        XCTAssertTrue(disclosures.contains { $0.contains("不出售给任何人") })
        XCTAssertFalse(disclosures.joined().contains("不卖给第三方"), "上一条刚说第三方 SDK 会收集，这句读起来自相矛盾")
        let summary = try XCTUnwrap(PrivacyConsentPurpose.appLaunch.launchSummary)
        XCTAssertTrue(summary.contains("高德"), "首屏摘要没点名高德")
        XCTAssertFalse(summary.contains("不卖给第三方"))

        let policy = LegalFallbackCopy.document(for: .privacyPolicy)
        let sdk = try XCTUnwrap(policy.sections.first { $0.heading == "第三方 SDK" })
        XCTAssertEqual(sdk.links.map(\.url.absoluteString), [
            "https://lbs.amap.com/pages/privacy/",
            LegalFallbackCopy.aliyunCloudAuthPrivacyURL.absoluteString
        ])
        // 高德 iOS 合包条目里没有 Wi-Fi / 基站 / IP —— 照抄安卓那份就是这条红。
        let amapItems = try XCTUnwrap(sdk.bullets.first { $0.hasPrefix("收集的个人信息：经纬度、搜索词") })
        XCTAssertFalse(amapItems.contains("WiFi") || amapItems.contains("Wi-Fi") || amapItems.contains("基站"), amapItems)
        // 其余文档的节没有链接：`links` 默认空，不影响旧调用方。
        XCTAssertTrue(LegalFallbackCopy.document(for: .userAgreement).sections.allSatisfy { $0.links.isEmpty })
    }

    func testDisclosureFingerprintIsPinnedToItsVersion() {
        // 指纹自己算，不用 `hashValue`：Swift 的 Hasher 每个进程重新播种，跨进程不稳定。
        func fingerprint(_ purpose: PrivacyConsentPurpose) -> Int {
            ([purpose.title] + purpose.disclosures)
                .joined(separator: "\u{1}")
                .unicodeScalars
                .reduce(into: 5381) { $0 = ($0 &* 33 &+ Int($1.value)) % 1_000_000_007 }
        }

        let pinned: [PrivacyConsentPurpose: (version: Int, fingerprint: Int)] = [
            // 2026-08-20 指纹变了而版本号没变，是**有意的**：删除账户那句改成正面列举保留了什么、
            // 并拆成两条独立焦点，但后端 `UserService.cascadeDeletePii` 的删除行为一个字节都没改
            // （handoff 2026-08-19 逐句核过）—— 属「同一行为换个说法」，不属「行为变了」。
            // 2026-09-30 指纹变了**且版本号 1 → 2**，这次是「行为变了」那一档：跑后运动记录开始采集
            // 步数 / 步频 / 爬升高度（新的一类信息，随位置上传），旧同意没有覆盖到。
            // v1 从未对外分发，+1 不会拦住任何真实老用户。
            // 2026-10-07 指纹变了**且版本号 2 → 3**，「行为变了」那一档：新的接收方高德 SDK（#355，与安卓 #54 逐字一致）。
            // 同批「不卖给第三方」→「不出售给任何人」属换说法，跟着这次一起进指纹。
            .appLaunch: (3, 527_488_023),
            // 2026-09-10 指纹又变了而版本号仍不动，同样是**有意的**：
            // 第 4 条里把「视力状况」加进敏感信息那一句。这两个字段的收集、用途、接收方、
            // 保留规则一个字节都没改（iOS 侧此前压根没有采集入口，值来自后端建档默认值），
            // 变的只是我们把它的**分类**说准了 —— PIPL 第二十八条「特定身份」，
            // 依据链见 `docs/research/vision-level-collection-ui-20260910.md`。
            // 属「同一行为换个说法」，不属「行为变了」。
            .blindIdentity: (1, 997_349_647),
            .volunteerIdentity: (1, 57_319_275),
            .blindVisionProfile: (1, 237_038_544)
        ]

        for purpose in PrivacyConsentPurpose.allCases {
            guard let expected = pinned[purpose] else {
                return XCTFail("新增了处理目的 \(purpose) 却没有钉住它的告知内容")
            }
            XCTAssertEqual(purpose.disclosureVersion, expected.version, "\(purpose) 的版本号变了，更新这里的指纹")
            XCTAssertEqual(
                fingerprint(purpose),
                expected.fingerprint,
                """
                \(purpose) 的告知文案变了。先判一次这次属于哪一种：
                ① 告知的处理行为变了 → 把 disclosureVersion +1，再把新指纹填进来；
                ② 同一行为换个说法 → 版本号不动，只换指纹，并在 pinned 那一行写清理由。
                """
            )
        }
    }

    // MARK: - 内置隐私政策全文

    /// 后端 `privacyPolicyUrl` 目前返回 null，**用户和审核员读到的就是这份内置文案**。
    /// 漏列一项等于「未公开收集使用规则」，是中国区上架的直接违规项。
    func testBuiltInPrivacyPolicyListsEveryCollectedItem() {
        let text = LegalFallbackCopy.document(for: .privacyPolicy)
            .sections
            .flatMap(\.bullets)
            .joined()

        for item in ["手机号", "身份证号", "位置", "轨迹", "麦克风", "相机", "人脸", "紧急联系人", "步数", "运动与健身"] {
            XCTAssertTrue(text.contains(item), "内置隐私政策漏列了「\(item)」")
        }
        XCTAssertTrue(text.contains("敏感个人信息"), "敏感项要点名，不能混在普通收集项里")
    }
}
