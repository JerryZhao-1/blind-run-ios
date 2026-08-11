import CoreLocation
import XCTest
@testable import blindRun

/// 语音下单向导的状态机。录音那一段由 `SpeechInputService` 自己的用例覆盖，这里锁的是向导独有的三条
/// 规则：`needReask` 不推进、连续听不清要降级回表单、解析结果落到正确的表单字段。
@MainActor
final class VoiceOrderWizardTests: XCTestCase {

    // MARK: - 一句话确认

    /// 两个方向的错误代价不对称：漏判「确认」只是多说两轮，误判「修改」为「确认」会产生一张
    /// 用户没打算下的订单并触发真实派单。这一组是本变更的核心安全断言。
    func testOnlyExplicitAffirmativesAreTreatedAsConfirmation() {
        let affirmatives = [
            "确认", "确认下单", "确认预约", "确认提交",
            "没问题", "就这样", "就这么办"
        ]
        for word in affirmatives {
            XCTAssertTrue(
                VoiceOrderWizard.isAffirmative(word),
                "「\(word)」应被判为确认"
            )
        }
        XCTAssertEqual(affirmatives.count, 7, "白名单每加一个词都要先问：它会不会出现在旁人的闲聊里")
        // 2026-08-10 删掉的那一个。本地直通表必须是后端 `INTENT_CONFIRM` 的子集，而后端那条
        // 正则里没有任何模式能命中它；它也从来没被读回教给用户。逐词对撞由
        // `scripts/validate-voice-intent-words.mjs` 做，这里只钉住「删了就别加回来」。
        XCTAssertFalse(
            VoiceOrderWizard.isAffirmative("开始约跑"),
            "后端确定性兜底不认这个词，本地直通表不许比它宽"
        )
    }

    /// 单音节高频应答词**必须**判为非确认。
    ///
    /// 2018 年 Portland 事故：Alexa 问 "[名字], right?"，背景对话里的 "right" 满足了确认，
    /// 一段私人录音被发了出去（Amazon 官方复盘）。中文这几个字与 "right" 同构，
    /// 而陪跑场景里志愿者可能就站在旁边说话。
    ///
    /// 「确定」一并移出：它是 iOS 弹窗按钮的常用词，用户容易顺口说，但也同样容易在
    /// 「我不确定」这类叙述里被截出来 —— 读回教的是「确认」，照着念就行。
    func testSingleSyllableBackchannelsAreNotConfirmation() {
        for word in ["好", "好的", "行", "可以", "对", "是", "没错", "同意", "确定", "提交", "下单"] {
            XCTAssertFalse(
                VoiceOrderWizard.isAffirmative(word),
                "「\(word)」是日常应答词，旁人一句闲聊就能触发下单，不得判为确认"
            )
        }
    }

    /// 白名单必须和读回教用户说的那句话一致，否则用户照着念却不生效。
    func testConfirmPromptTeachesAWordThatIsActuallyOnTheWhitelist() {
        XCTAssertTrue(VoiceOrderWizard.isAffirmative("确认"))
    }

    func testTrailingParticlesAndPunctuationDoNotBlockConfirmation() {
        for word in ["确认吧", "没问题呀", "就这样了", "就这样吧", "确认。", "确认下单，", "确 认"] {
            XCTAssertTrue(
                VoiceOrderWizard.isAffirmative(word),
                "句尾语气词和标点不改变语义：「\(word)」"
            )
        }
    }

    /// 这些串**都含有**肯定词，但意思分别是否定、否定、要求复核。整串匹配的存在理由就是它们。
    func testNegationsContainingAffirmativeWordsAreNotConfirmation() {
        for word in [
            "不确认", "先别确认", "不要确认", "确认一下时间", "我要修改",
            "改一下", "不对", "不是", "取消", "重说", "换个地方",
            "确认个啥", "还不能确认",
            // 旁人闲聊被麦克风收进来的样子 —— 一对一陪跑里志愿者就在身边。
            "好啊我知道了", "对了你等一下", "行我先走了", "是这样没错"
        ] {
            XCTAssertFalse(
                VoiceOrderWizard.isAffirmative(word),
                "「\(word)」不得被当成确认"
            )
        }
    }

    /// 「嗯」刻意不在白名单里：犹豫填充词不该下单。
    func testEmptyOrUnrelatedTranscriptIsNotConfirmation() {
        for word in ["", "   ", "。", "嗯", "嗯那个", "明天早上八点半", "人民广场地铁站"] {
            XCTAssertFalse(
                VoiceOrderWizard.isAffirmative(word),
                "「\(word)」不得被当成确认"
            )
        }
    }

    /// 本地表接不住的那一句**交给后端**，而不是就地回一句「没听懂」。
    ///
    /// 2026-08-10 之前这里断言的是 `stub.paths.isEmpty` —— 那正是「只能说确认或重说」二选一的
    /// 那道墙：用户说「把时间改成九点」会被本地表判成没听懂，而他说得完全清楚。
    /// 现在第 1 档判不出来只意味着「本地接不住」，第 2 档发 `/parse` 由后端分意图。
    func testUnrecognizedConfirmCommandGoesToTheBackendInsteadOfGivingUp() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(ttsText: "您想改哪一项？", correctionUnclear: true)]
        let wizard = makeWizard(stub: stub, startingAt: .confirm)

        await wizard.submitTranscript("嗯那个啊")

        XCTAssertEqual(wizard.step, .confirm, "没听懂只能原地重问")
        XCTAssertNil(wizard.createdOrder, "没听懂绝不能提交")
        XCTAssertEqual(wizard.reaskCount, 1, "消歧问句这一条确实是没听懂，要计入上限")
        XCTAssertEqual(stub.paths, [VoiceOrderEndpoint.parseOrder], "本地接不住就该交后端")
    }

    /// 确认轮的网络失败**不许说成「没听懂」** —— 失败的是网络，改说法一点用都没有；
    /// 而本地那几个词仍然直通，所以提示里必须把这两条仅存的出路念出来。
    func testConfirmRoundNetworkFailureKeepsTheLocalEscapeHatchesAudible() async {
        let stub = VoiceOrderAPIClientStub()
        stub.error = .serverError(ErrorResponse(code: "INTERNAL_ERROR", message: "boom"))
        let wizard = makeWizard(stub: stub, startingAt: .confirm, didCaptureStartTime: true)

        await wizard.submitTranscript("把时间往后挪一挪吧")

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertFalse(spoken.contains("没听懂"), "失败的是网络不是听力：\(spoken)")
        XCTAssertTrue(spoken.contains("确认"), "本地直通的出路必须念出来：\(spoken)")
        XCTAssertTrue(spoken.contains("重说"), "本地直通的出路必须念出来：\(spoken)")
        XCTAssertEqual(wizard.step, .confirm)
        XCTAssertNil(wizard.createdOrder)

        // 网络还是坏的，但「确认」不经过网络 —— 一次已经解析成功的语音下单不该死在最后一步。
        await wizard.submitTranscript("确认")
        XCTAssertFalse(wizard.isRunning, "本地确认必须能在断网时下单")
    }

    /// 确认走的是提交路径而不是解析端点。
    ///
    /// `didCaptureStartTime: true` 不能省 —— 没抽到时间时「确认」按设计不生效（见
    /// `testConfirmIsRefusedWhenTheStartTimeWasNeverSpoken`），不传就变成在测拦截而不是提交。
    func testAffirmativeTakesTheSubmitPathInsteadOfParsing() async {
        let stub = VoiceOrderAPIClientStub()
        let wizard = makeWizard(stub: stub, startingAt: .confirm, didCaptureStartTime: true)

        await wizard.submitTranscript("确认")

        XCTAssertFalse(wizard.isRunning, "提交后不得继续占着麦克风")
        XCTAssertTrue(stub.paths.isEmpty, "确认判定不走后端：\(stub.paths)")
    }

    /// 「重说」回到整句那一轮，而不是跳进某个逐项流程（逐项修改已于 2026-08-06 删除）。
    func testRestartGoesBackToTheFullUtteranceRound() async {
        for transcript in ["重说", "重新说", "重来", "从头再说", "重新说一遍"] {
            let stub = VoiceOrderAPIClientStub()
            let wizard = makeWizard(stub: stub, startingAt: .confirm)

            await wizard.submitTranscript(transcript)

            XCTAssertEqual(wizard.step, .freeform, "「\(transcript)」应回到整句轮")
            XCTAssertTrue(wizard.isRunning)
            XCTAssertNil(wizard.createdOrder, "重说绝不能提交")
            XCTAssertTrue(stub.paths.isEmpty, "重说是本地判定，不走后端")
        }
    }

    /// 「重说」必须**把上一轮抽到的槽位清干净**。
    ///
    /// 不清的话，新一句里没提到的项会留着旧值，读回照样念出来 —— 用户会以为那是他这次说的，
    /// 而看不见屏幕的人无从察觉这是上一轮的残留。
    func testRestartClearsSlotsCapturedInThePreviousRound() async {
        let bookingViewModel = BlindBookingViewModel()
        bookingViewModel.duration = .sixty
        let wizard = makeWizard(
            stub: VoiceOrderAPIClientStub(),
            bookingViewModel: bookingViewModel,
            startingAt: .confirm
        )

        await wizard.submitTranscript("重说")

        XCTAssertEqual(bookingViewModel.duration, .none, "上一轮的时长留着，用户会以为是这次说的")
        XCTAssertNil(bookingViewModel.selectedStartPlace)
        XCTAssertFalse(wizard.didCaptureStartTime)
    }

    /// 肯定词与「重说」的匹配严格程度**刻意不同** —— 两者的失败方向不对称：
    /// 误判成确认会产生一张用户没打算下的真实订单；误判成重说只是让人多说一句话。
    func testCommandClassificationIsStrictForConfirmAndLenientForRestart() {
        XCTAssertEqual(VoiceOrderWizard.command(for: "确认"), .confirm)
        XCTAssertEqual(VoiceOrderWizard.command(for: "确认吧"), .confirm)
        XCTAssertEqual(VoiceOrderWizard.command(for: "重复"), .repeatBack)

        // 🔴 「再说一遍 / 再说一次」是**重听**，不是重说。2026-08-10 从 `.restart` 改判过来 ——
        // 逐词对撞后端 `VoiceSlotParser` 时查出这是一处方向相反的分歧：本地判重说会把用户刚说完的
        // 一整句清空，后端 `INTENT_REPEAT` 判的是重播。判反的代价不对称，以代价小的那边为准。
        for transcript in ["再说一遍", "再说一次", "你再说一遍", "没听清"] {
            XCTAssertEqual(
                VoiceOrderWizard.command(for: transcript), .repeatBack,
                "「\(transcript)」是要求重播，不是要求清空重说"
            )
        }

        // 重说用包含匹配：真机上「改地点」被听成同音的「该地点」，整串精确匹配把人卡死在读回轮，
        // 之后说什么都是「没听懂」。宽一点的代价只是偶尔多重说一轮。
        for transcript in ["重说", "那我重说一遍", "我想重新说", "重来吧", "算了重新来过"] {
            XCTAssertEqual(
                VoiceOrderWizard.command(for: transcript), .restart,
                "「\(transcript)」应判为重说"
            )
        }

        // 肯定词仍然整串：含肯定词的否定与复核请求一个都不许放行。
        for transcript in ["不确认", "先别确认", "确认一下时间", "还不能确认", "嗯"] {
            XCTAssertEqual(
                VoiceOrderWizard.command(for: transcript), .unrecognized,
                "「\(transcript)」不得被判成任何指令"
            )
        }
    }

    // MARK: - 确认轮的跨轮定点修改

    /// **本变更的核心用例。** 读回之后只说要改的那一项，其余槽位一个都不能丢。
    ///
    /// 2026-08-10 之前用户只有两条路：说「确认」，或者把整句重说一遍。想把时间从八点改成九点，
    /// 就得连出发地、终点、时长一起重念 —— 每重说一次都是一次新的识别错误机会，而对听不见屏幕的
    /// 人，错在哪一项他只能靠听完整段读回去分辨。
    func testCorrectionInTheConfirmRoundKeepsEverySlotTheUserDidNotMention() async {
        let stub = VoiceOrderAPIClientStub()
        let viewModel = BlindBookingViewModel()
        let firstRound = Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 24),
            durationMinutes: 60,
            address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
            endAddress: "上海市杨浦区五角场", endLatitude: 31.3040, endLongitude: 121.5140
        )
        // 第 2 轮：后端把新时间合进整单，其余槽位从 `current` 逐字继承回来。
        let corrected = Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 25),
            durationMinutes: 60,
            address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
            endAddress: "上海市杨浦区五角场", endLatitude: 31.3040, endLongitude: 121.5140
        )
        stub.parseOrderResponses = [firstRound, corrected]
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场跑到五角场，跑一个小时")
        XCTAssertEqual(wizard.step, .confirm)

        await wizard.submitTranscript("把时间改成明天早上九点")

        XCTAssertEqual(wizard.step, .confirm, "改一项之后回到读回，不是回到整句轮")
        XCTAssertEqual(viewModel.endPlace?.address, "上海市杨浦区五角场", "没提到的终点不许被清掉")
        XCTAssertEqual(viewModel.resolvedDurationMinutes, 60, "没提到的时长不许被清掉")
        XCTAssertEqual(viewModel.selectedStartPlace?.title, "上海市黄浦区人民广场", "没提到的起点不许被清掉")
        XCTAssertTrue(wizard.didCaptureStartTime)
        XCTAssertEqual(
            viewModel.appointmentTime.timeIntervalSince1970,
            Self.date(hoursFromNow: 25).timeIntervalSince1970,
            accuracy: 90,
            "说了要改的那一项必须真的变了"
        )
    }

    /// 跨轮修正的全部前提：确认轮把上一轮的结果作为 `current` **发出去了**。
    /// 只断言路径验不出来 —— 路径对、body 里没有 `current` 的话后端一个新字段都不会给，
    /// 而那正是 2026-08-09 之前的状态（后端做完一整批，iOS 侧全部不可达）。
    func testConfirmRoundSendsThePreviousRoundBackAsCurrent() async {
        let stub = VoiceOrderAPIClientStub()
        let first = Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 24),
            durationMinutes: 60,
            address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
            hasGuideDog: true
        )
        stub.parseOrderResponses = [first, Self.parseResponse(ttsText: "您想改哪一项？", correctionUnclear: true)]
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")
        await wizard.submitTranscript("不对")

        XCTAssertEqual(stub.parseRequests.count, 2)
        XCTAssertNil(stub.parseRequests[0].current, "整句那一轮没有「上一轮」，不该带 current")
        let current = stub.parseRequests[1].current
        XCTAssertEqual(current?.plannedStartTime, first.plannedStartTime)
        XCTAssertEqual(current?.durationMinutes, 60)
        XCTAssertEqual(current?.address, "上海市黄浦区人民广场")
        XCTAssertEqual(current?.latitude, 31.2304)
        XCTAssertEqual(current?.hasGuideDog, true, "可选槽位也要继承，否则第 2 轮会把导盲犬悄悄丢掉")
    }

    /// `current` **只能从响应派生，绝不从 view model 派生**。
    ///
    /// `BlindBookingViewModel.appointmentTime` 的初值是 `Date()`，从它取快照会把一个用户从没说过的
    /// 时刻当成「已确认槽位」发给后端；后端原样继承回来、读回念出来，一张没人说过的单就这么成立了。
    /// 这是 2026-08-06「他也没有经过我的同意」那条红线在跨轮修正上的等价物。
    func testCurrentNeverCarriesAnAppointmentTimeTheUserNeverSpoke() async {
        let stub = VoiceOrderAPIClientStub()
        // 第 1 轮只抽到地点，时间没抽出来 —— 但 `appointmentTime` 这时**已经是一个具体时刻**了。
        stub.parseOrderResponses = [
            Self.parseResponse(
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [.startTime, .duration]
            ),
            Self.parseResponse(ttsText: "您想改哪一项？", correctionUnclear: true)
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("从人民广场出发")
        await wizard.submitTranscript("不对")

        XCTAssertFalse(wizard.didCaptureStartTime)
        XCTAssertNil(
            stub.parseRequests[1].current?.plannedStartTime,
            "用户没说过时间，快照里就一个字都不许有 —— view model 那个 Date() 初值不是用户说的"
        )
    }

    /// 后端判 `CONFIRM`（「这样就行，直接下单吧」这类本地表接不住的说法）走的是同一条提交路径，
    /// 且**仍然受缺槽位门槛拦着** —— 槽位没齐时一句确认不能派单。
    func testBackendConfirmIntentTakesTheSubmitPathAndStillRespectsTheMissingTimeGate() async {
        // ① 缺时间：后端就算判了 CONFIRM 也不许提交。
        let blockedStub = VoiceOrderAPIClientStub()
        blockedStub.parseOrderResponses = [Self.parseResponse(userIntent: .confirm)]
        let blocked = makeWizard(stub: blockedStub, startingAt: .confirm, didCaptureStartTime: false)

        await blocked.submitTranscript("这样就行，直接下单吧")

        XCTAssertNil(blocked.createdOrder, "没说过时间就不能凭一句确认派单")
        XCTAssertTrue(blocked.isRunning)

        // ② 槽位齐了：走提交。
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(userIntent: .confirm)]
        let wizard = makeWizard(stub: stub, startingAt: .confirm, didCaptureStartTime: true)

        await wizard.submitTranscript("这样就行，直接下单吧")

        XCTAssertFalse(wizard.isRunning, "提交后不得继续占着麦克风")
    }

    /// 「算了不下了」结束整个语音流程，**不重问**。用户要退出时再追问一句是把人锁在里面。
    func testBackendCancelIntentEndsTheVoiceFlowWithoutReasking() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(ttsText: "已取消", userIntent: .cancel)]
        let wizard = makeWizard(stub: stub, startingAt: .confirm, didCaptureStartTime: true)

        await wizard.submitTranscript("算了，今天不跑了")

        XCTAssertFalse(wizard.isRunning, "取消就该停下来")
        XCTAssertNil(wizard.createdOrder)
        XCTAssertNotNil(wizard.fallbackMessage, "看不见屏幕的人需要听到语音已经停了，以及接下来去哪")
    }

    /// 后端判 `RESTART` 时**快照也要清干净**。
    /// 留着 `current`，用户「重说」的那一整句会被后端和上一轮的旧槽位合并，
    /// 于是他这次没提的东西又原样回来了，而屏幕上一个字都不会变。
    func testBackendRestartIntentClearsTheSnapshotSoTheNextUtteranceStartsClean() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 24), durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737
            ),
            Self.parseResponse(ttsText: "好的，我们重新来", userIntent: .restart),
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 26), durationMinutes: 30,
                address: "上海市长宁区中山公园", latitude: 31.2230, longitude: 121.4200
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")
        await wizard.submitTranscript("咱们从头再来一次吧，我说错了")

        XCTAssertEqual(wizard.step, .freeform, "后端判重来就要回到整句轮")
        XCTAssertNil(viewModel.selectedStartPlace, "重来必须把上一轮的槽位清干净")

        await wizard.submitTranscript("后天早上十点从中山公园出发跑半小时")

        XCTAssertNil(
            stub.parseRequests[2].current,
            "重来之后的第一句是新的整句轮，不许把上一轮的槽位捎回去"
        )
    }

    /// 「你再念一遍」重播读回，**一个槽位都不动，也不清空**。
    /// 判成重来的代价是把用户刚说完的一整句清掉，方向不对称。
    func testBackendRepeatIntentReadsBackAgainWithoutTouchingAnySlot() async {
        let stub = VoiceOrderAPIClientStub()
        let viewModel = BlindBookingViewModel()
        stub.parseOrderResponses = [
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 24), durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737
            ),
            Self.parseResponse(ttsText: "好的，我再念一遍", userIntent: .repeatBack)
        ]
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")
        await wizard.submitTranscript("你刚才说啥来着，我没跟上")

        XCTAssertEqual(wizard.step, .confirm)
        XCTAssertEqual(viewModel.selectedStartPlace?.title, "上海市黄浦区人民广场", "重听不许动槽位")
        XCTAssertEqual(viewModel.resolvedDurationMinutes, 60)
        XCTAssertTrue(wizard.didCaptureStartTime)
        XCTAssertTrue(
            (wizard.lastSpokenPrompt ?? "").contains("出发地点"),
            "重听要重播整单读回：\(wizard.lastSpokenPrompt ?? "")"
        )
    }

    /// 用户点名要改哪一项但没给值：播后端的定向追问语，**`current` 一个字都不动**。
    ///
    /// 这一轮**不计入重问上限** —— 后端听懂了、用户也在正常推进，把「改三项」记成
    /// 「三次没听清」会在第三项上把人降级到表单。而 `correctionUnclear`（只说了「不对」）
    /// 确实是没听懂，要计数。两者刻意不同。
    func testCorrectionTargetAsksTheTargetedFollowUpAndDoesNotCountAsAReask() async {
        let stub = VoiceOrderAPIClientStub()
        let first = Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 24), durationMinutes: 60,
            address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737
        )
        stub.parseOrderResponses = [
            first,
            Self.parseResponse(
                plannedStartTime: first.plannedStartTime, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                needReask: true,
                ttsText: "好的，请说新的开始时间，比如「明天早上八点」",
                correctionTarget: .startTime
            )
        ]
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")
        await wizard.submitTranscript("我想改一下时间")

        XCTAssertEqual(wizard.step, .confirm, "定向追问不换步骤，屏幕不在用户说话中途变样")
        XCTAssertEqual(wizard.reaskCount, 0, "改一项是正常推进，不是没听清")
        XCTAssertEqual(
            wizard.lastSpokenPrompt, "好的，请说新的开始时间，比如「明天早上八点」",
            "定向追问语只有后端拼得出来（读回措辞规则在后端），这一句必须原样播"
        )
        XCTAssertEqual(
            stub.parseRequests[1].current?.address, "上海市黄浦区人民广场",
            "点名那一轮不许清 current，否则下一句只说值就没有可继承的东西了"
        )
    }

    /// 只说「不对」、没说改哪一项：播消歧问句，并且**计入**重问上限 —— 这一条确实是没听懂。
    func testCorrectionUnclearCountsTowardTheReaskLimit() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            Self.parseResponse(ttsText: "您想改哪一项？出发地、开始时间，还是时长？", correctionUnclear: true)
        ]
        let wizard = makeWizard(stub: stub, startingAt: .confirm, didCaptureStartTime: true)

        await wizard.submitTranscript("不对")

        XCTAssertEqual(wizard.reaskCount, 1)
        XCTAssertEqual(wizard.lastSpokenPrompt, "您想改哪一项？出发地、开始时间，还是时长？")
        XCTAssertEqual(wizard.step, .confirm)
    }

    /// 后端往这两个枚举加值时**不许整条响应解不出来**。语音是盲人唯一的下单通道，
    /// 「点了没反应」在这条链路上就是事故（与 `RunOrderStatus` / `VoiceOrderMissingSlot` 同一条红线）。
    func testUnknownIntentAndCorrectionTargetValuesDecodeInsteadOfThrowing() throws {
        let json = """
        {"missing":[],"needReask":true,"ttsText":"好的",
         "userIntent":"POSTPONE","correctionTarget":"WEATHER","correctionUnclear":false}
        """
        let decoded = try JSONDecoder().decode(ParseVoiceOrderResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.userIntent, .unknown)
        XCTAssertEqual(decoded.correctionTarget, .unknown)
    }

    /// 快照的构造口径：允许「有地址无坐标」（高德查不到时后端就是这么返回的，把它按旧的严格规则
    /// 校会把用户卡死在一个他自己解不开的循环里），但**反过来一律丢弃** —— 只有坐标没有文字地址
    /// 后端返 400，而那是客户端 bug，不是该在运行时发出去试试看的东西。
    func testSnapshotAllowsAnAddressWithoutCoordinatesButNeverTheReverse() {
        let unresolvedEnd = Self.parseResponse(
            address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
            endAddress: "老王家门口"
        ).slotSnapshot
        XCTAssertEqual(unresolvedEnd.endAddress, "老王家门口")
        XCTAssertNil(unresolvedEnd.endLatitude)

        let coordinatesOnly = Self.parseResponse(latitude: 31.2304, longitude: 121.4737).slotSnapshot
        XCTAssertNil(coordinatesOnly.address)
        XCTAssertNil(coordinatesOnly.latitude, "只有坐标没有地名一律整组丢弃")
        XCTAssertNil(coordinatesOnly.longitude)
    }

    /// 读回结尾必须**教用户可以只改一项**。看不见屏幕的人不会自己发现这个能力，
    /// 不教就等于没做 —— 这与「白名单必须和系统教用户说的话一致」是同一条规矩的另一半。
    func testConfirmOutroTeachesThatASingleItemCanBeChanged() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 24), durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737
            )
        ]
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("确认"), "读回教的词必须在本地白名单里：\(spoken)")
        XCTAssertTrue(spoken.contains("重说"), "整句重说仍然是一条出路：\(spoken)")
        XCTAssertTrue(spoken.contains("要改哪一项直接说"), "定点修改必须被念出来：\(spoken)")
    }

    // MARK: - 整句那一轮

    /// 一整句一次抽三个槽位，**只发一个请求**。
    ///
    /// 此前是两路并发 `parse-slot`（地点那路被常量关着），后端 2026-08-04 补了 `/voice/parse`
    /// 先抽地名 span 再查高德，三槽合成一次往返 —— 语音场景里省下的那一个往返是用户听着等的时间。
    func testFreeformUtteranceFillsAllThreeSlotsInASingleRequest() async {
        let stub = VoiceOrderAPIClientStub()
        let plannedStart = DateFormatter.aidRunBackendLocalDateTime.string(
            from: Date().addingTimeInterval(3600 * 24)
        )
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: plannedStart,
                durationMinutes: 60,
                address: "上海市黄浦区人民广场",
                latitude: 31.2304,
                longitude: 121.4737,
                missing: [],
                needReask: false,
                ttsText: "好的，我记下了"
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertEqual(wizard.step, .confirm, "整句解析完必须落到读回确认")
        XCTAssertEqual(viewModel.resolvedDurationMinutes, 60)
        XCTAssertEqual(
            DateFormatter.aidRunBackendLocalDateTime.string(from: viewModel.appointmentTime),
            plannedStart,
            "开始时间必须原样透传，客户端不得二次格式化"
        )
        XCTAssertEqual(stub.paths, [VoiceOrderEndpoint.parseOrder], "整句只该发一个请求：\(stub.paths)")
        XCTAssertTrue(stub.requestedSlotFields.isEmpty, "整句不再走逐槽位端点")
        XCTAssertEqual(wizard.lastUtterance, "明天早上八点从人民广场出发跑一个小时", "读回要先念用户原话")
    }

    /// 三个可选槽位（导盲犬 / 配速 / 备注）必须真的落到订单上，并且**读回要念出来**。
    ///
    /// 回归的是一条静默缺陷：模型层 2026-08-04 就解出了这三项，向导却一个都没消费，
    /// 于是「带导盲犬」被解析出来之后原地丢掉。`hasGuideDogThisRun` 进派单**硬过滤**，
    /// 丢掉它等于按档案默认值缩小候选池，而读回不提这一项，盲人无从察觉。
    func testFreeformAppliesOptionalSlotsAndReadsThemBack() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: DateFormatter.aidRunBackendLocalDateTime.string(
                    from: Date().addingTimeInterval(3600 * 24)
                ),
                durationMinutes: 60,
                address: "上海市黄浦区人民广场",
                latitude: 31.2304,
                longitude: 121.4737,
                missing: [],
                needReask: false,
                ttsText: "好的，我记下了",
                hasGuideDog: true,
                pacePreference: .easy,
                specialNotes: "我有低血糖"
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时，带导盲犬，慢一点，我有低血糖")

        XCTAssertEqual(viewModel.hasGuideDogThisRun, true)
        XCTAssertEqual(viewModel.pacePreference, .easy)
        XCTAssertEqual(viewModel.specialNotes, "我有低血糖")

        let readback = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(readback.contains("本次携带"), "读回必须念出导盲犬：\(readback)")
        XCTAssertTrue(readback.contains("我有低血糖"), "读回必须念出备注：\(readback)")

        let request = viewModel.makeCreateOrderRequest()
        XCTAssertEqual(request?.hasGuideDogThisRun, true)
        XCTAssertEqual(request?.pacePreference, .easy)
        XCTAssertEqual(request?.specialNotes, "我有低血糖")
    }

    /// 「今天不带导盲犬」（`false`）与「压根没提」（`nil`）在下单请求里**必须是两个不同的值**。
    ///
    /// 塌缩成同一个值的后果是静默的：`false` 变 `nil` 时后端回落 `BlindProfile.hasGuideDog`，
    /// 档案里登记了导盲犬的用户明说了「今天不带」仍会按"带"派单，候选池被无声缩小；
    /// 反过来 `nil` 变 `false` 则是替一个什么都没说的用户表了态。两个方向都听不出来。
    func testFreeformKeepsExplicitNoGuideDogDistinctFromUnspoken() async {
        func request(forParsedGuideDog parsed: Bool?) async -> CreateOrderRequest? {
            let stub = VoiceOrderAPIClientStub()
            stub.parseOrderResponses = [
                ParseVoiceOrderResponse(
                    plannedStartTime: DateFormatter.aidRunBackendLocalDateTime.string(
                        from: Date().addingTimeInterval(3600 * 24)
                    ),
                    durationMinutes: 60,
                    address: "上海市黄浦区人民广场",
                    latitude: 31.2304,
                    longitude: 121.4737,
                    missing: [],
                    needReask: false,
                    ttsText: "好的，我记下了",
                    hasGuideDog: parsed
                )
            ]
            let viewModel = BlindBookingViewModel()
            let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)
            await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")
            return viewModel.makeCreateOrderRequest()
        }

        let explicitNo = await request(forParsedGuideDog: false)
        XCTAssertEqual(explicitNo?.hasGuideDogThisRun, false, "「今天不带」必须原样传 false，不能塌成 nil")

        let unspoken = await request(forParsedGuideDog: nil)
        XCTAssertNil(unspoken?.hasGuideDogThisRun, "没提就不传，让后端回落档案默认值")
    }

    /// 整句那一轮**不重问、不失败**：`missing` 等价于「这几项保持默认值」，不是重问信号；
    /// 后端在 `missing` 非空时给的 `ttsText` 是**追问**文案，播它就等于把人拉回重问。
    func testFreeformTreatsMissingSlotsAsDefaultsAndNeverReasks() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil,
                durationMinutes: nil,
                address: nil,
                latitude: nil,
                longitude: nil,
                missing: [.address, .startTime, .duration],
                needReask: true,
                ttsText: "还差三项没听清，可以再说一次"
            )
        ]
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("呃那个我想想")

        XCTAssertEqual(wizard.step, .confirm, "整句抽不出也要往读回走，不能原地重问")
        XCTAssertEqual(wizard.reaskCount, 0)
        XCTAssertTrue(wizard.isRunning)
        XCTAssertNil(wizard.createdOrder)
        XCTAssertEqual(
            wizard.lastSpokenPrompt?.contains("还差三项没听清"), false,
            "后端的追问文案不得出现在读回里：\(wizard.lastSpokenPrompt ?? "nil")"
        )
    }

    /// 整句解析整体失败（网络挂了 / 超时 / 解码不了）同样不打回表单：默认值仍然成单，
    /// 由读回环节把实际内容念清楚。把人在这里踢回表单，等于让一句话白说。
    func testFreeformSwallowsTransportFailuresAndStillReadsBackDefaults() async {
        let stub = VoiceOrderAPIClientStub()
        stub.error = .unknown(statusCode: 500)
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertEqual(wizard.step, .confirm)
        XCTAssertEqual(wizard.reaskCount, 0)
        XCTAssertNil(wizard.fallbackMessage, "整句这一轮不得因为接口失败就交回表单")
        XCTAssertTrue(wizard.isRunning)
    }

    /// 吞掉错误**不等于不说**。整句解析失败时读回念的全是默认值，而用户听不出「语音没在工作」和
    /// 「语音听懂了但你说的正好是默认值」的区别 —— 没仔细听就下了一张时间地点全错的单。
    ///
    /// 这不是假想场景：2026-08-06 查实 `/api/orders/voice/parse` 的 handler 只在后端未部署分支
    /// （`7cb5758`）上，生产跑的 `7bce0b3` 根本没有这个端点，所以 404 是常态而非偶发。
    func testFreeformAnnouncesThatParsingFailedBeforeReadingBackDefaults() async {
        let stub = VoiceOrderAPIClientStub()
        stub.error = .unknown(statusCode: 404)
        // viewModel 必须由用例**持一个强引用**：向导里是 `private weak var`，内联构造
        // （或让 makeWizard 兜底新建）的实例当场就被释放，`askCurrentStep` 于是退到
        // `step.prompt` 兜底文案，连 `confirmPrompt` 都不进 —— 读回和提示一起消失，
        // 断言会因为一个和本用例无关的理由失败。
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertEqual(wizard.step, .confirm)
        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(
            spoken.contains(VoiceOrderWizard.parseFailureNotice),
            "解析失败必须在读回前说出来，否则用户无从察觉语音没在工作：\(spoken)"
        )
        XCTAssertTrue(
            spoken.hasPrefix(VoiceOrderWizard.parseFailureNotice),
            "提示必须在整单之前 —— 说在后面等于让用户先信了一遍默认值：\(spoken)"
        )
        XCTAssertTrue(
            spoken.contains("我听到你说：明天早上八点从人民广场出发跑一个小时。"),
            "识别到的原话仍要念：失败的是解析不是听写，用户得能对出差在哪：\(spoken)"
        )
        // 整句解析失败 = 一个槽位都没抽到 = 时间也没抽到，所以出路念的是「缺时间不能下单」，
        // 而不是「说确认就下单」。教用户说一个说了也不生效的词，比不教更糟。
        XCTAssertTrue(spoken.contains("重说"), "必须给出唯一可行的出路：\(spoken)")
        XCTAssertFalse(
            spoken.contains("说「确认」就下单"),
            "时间都没抽到还教用户说确认，他说了不生效：\(spoken)"
        )
    }

    /// 解析成功时不得出现失败提示 —— 一句每次都念的「提示」等于没有提示。
    func testFreeformDoesNotAnnounceFailureWhenParsingSucceeds() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil,
                durationMinutes: nil,
                address: nil,
                latitude: nil,
                longitude: nil,
                missing: [.address, .startTime, .duration],
                needReask: true,
                ttsText: nil
            )
        ]
        let viewModel = BlindBookingViewModel()  // 强引用，理由同上一条用例
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("呃那个我想想")

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("这次的预约是："), "先确认真的走了读回，否则下一条断言无意义：\(spoken)")
        XCTAssertFalse(
            spoken.contains(VoiceOrderWizard.parseFailureNotice),
            "后端 200 返回「三项都没抽到」是正常业务状态，不是解析失败：\(spoken)"
        )
    }

    /// 时长取整在**整句轮**也必须播报 —— 此前只有定点修改轮播，整句轮是静默取整。
    /// 静默取整对听不见屏幕的人就是篡改，同一条红线不该有两种行为。
    func testFreeformAnnouncesDurationRounding() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil,
                durationMinutes: 40,
                address: nil,
                latitude: nil,
                longitude: nil,
                missing: [.address, .startTime],
                needReask: true,
                ttsText: nil
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("跑四十分钟")

        XCTAssertEqual(viewModel.resolvedDurationMinutes, 40, "40 分钟在契约区间内，必须原样保留")
        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("40 分钟"), "读回要念用户说的时长：\(spoken)")
        XCTAssertFalse(
            spoken.contains("你说的是"),
            "没有改动就不该有那句「你说的是⋯⋯本次按⋯⋯」——每次都念的提示等于没有提示：\(spoken)"
        )
    }

    /// 只有真的超出契约区间才播报改动。**静默改动对听不见屏幕的人就是篡改**，
    /// 这条红线不因为现在很少触发而消失。
    func testDurationBeyondTheContractRangeIsClampedOutLoud() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 400, address: nil,
                latitude: nil, longitude: nil,
                missing: [.address, .startTime], needReask: true, ttsText: nil
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("跑四百分钟")

        XCTAssertEqual(viewModel.resolvedDurationMinutes, 300, "超出契约上限要夹到 300")
        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("400"), "必须说出用户原本说的数字：\(spoken)")
        XCTAssertTrue(spoken.contains("5 小时"), "必须说出实际下单的时长：\(spoken)")
    }

    /// `missing` 收到后端将来新增的值不得把整条响应带崩 —— 崩了表现是「说了一整句什么都没发生」。
    func testUnknownMissingSlotValueDecodesInsteadOfThrowing() throws {
        let json = """
        {"missing":["ADDRESS","ROUTE_PREFERENCE"],"needReask":true,"ttsText":"再说一次"}
        """
        let decoded = try JSONDecoder().decode(ParseVoiceOrderResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.missing, [.address, .unknown])
        XCTAssertNil(decoded.resolvedStartPlace)
    }

    /// 只有地址没有坐标（或反过来）不算抽到起点：前者下不了单，后者读回时没法念。
    func testPartialStartPlaceIsTreatedAsNotResolved() {
        let addressOnly = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil,
            address: "上海市黄浦区人民广场", latitude: nil, longitude: nil,
            missing: nil, needReask: nil, ttsText: nil
        )
        let coordinateOnly = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil,
            address: nil, latitude: 31.2304, longitude: 121.4737,
            missing: nil, needReask: nil, ttsText: nil
        )

        XCTAssertNil(addressOnly.resolvedStartPlace)
        XCTAssertNil(coordinateOnly.resolvedStartPlace)
    }

    // MARK: - 终点（SPEC B1，2026-08-08 后端新增）

    /// 终点的规则**比起点松一档**，两边不是同一套（`api_spec.yaml:3007-3019`）：
    /// 有地名没坐标算数（高德查不到是正常情况，订单照下），只有坐标没地名不算。
    func testEndPlaceKeepsTheAddressEvenWithoutCoordinatesButNeverTheReverse() {
        let full = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil, address: nil, latitude: nil, longitude: nil,
            missing: nil, needReask: nil, ttsText: nil,
            endAddress: "上海市杨浦区五角场", endLatitude: 31.2989, endLongitude: 121.5036
        )
        let addressOnly = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil, address: nil, latitude: nil, longitude: nil,
            missing: nil, needReask: nil, ttsText: nil,
            endAddress: "老王家门口", endLatitude: nil, endLongitude: nil, endAddressUnresolved: true
        )
        let coordinateOnly = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil, address: nil, latitude: nil, longitude: nil,
            missing: nil, needReask: nil, ttsText: nil,
            endAddress: nil, endLatitude: 31.2989, endLongitude: 121.5036
        )
        // 半个坐标：后端会返 400「终点经纬度必须同时提供」，客户端不许构造出这种请求。
        let halfCoordinate = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil, address: nil, latitude: nil, longitude: nil,
            missing: nil, needReask: nil, ttsText: nil,
            endAddress: "五角场", endLatitude: 31.2989, endLongitude: nil
        )

        XCTAssertEqual(full.resolvedEndPlace?.latitude, 31.2989)
        XCTAssertEqual(full.resolvedEndPlace?.isUnresolved, false)

        XCTAssertEqual(addressOnly.resolvedEndPlace?.address, "老王家门口")
        XCTAssertEqual(
            addressOnly.resolvedEndPlace?.isUnresolved, true,
            "说了地名但查不到坐标要保留地名 —— 静默丢掉的话，用户明明说了「跑到老王家门口」、"
                + "读回却不念终点，盲人无从分辨是没听到还是没存下"
        )

        XCTAssertNil(coordinateOnly.resolvedEndPlace, "只有坐标没有地名，读回时无从念起")
        XCTAssertNil(halfCoordinate.resolvedEndPlace?.latitude, "半个坐标必须降级成「只有地名」")
        XCTAssertEqual(halfCoordinate.resolvedEndPlace?.address, "五角场")
    }

    /// 未知枚举/缺字段一律不许把整条响应带崩 —— 老客户端收到带终点的响应时表现成
    /// 「说了一整句什么都没发生」，那对盲人就是事故。
    func testEndLocationFieldsDecodeAndAreOptional() throws {
        let withEnd = """
        {"address":"人民广场","latitude":31.2304,"longitude":121.4737,
         "endAddress":"五角场","endLatitude":31.2989,"endLongitude":121.5036,
         "endAddressUnresolved":false,"missing":[],"needReask":false}
        """
        let withoutEnd = """
        {"address":"人民广场","latitude":31.2304,"longitude":121.4737,"missing":[],"needReask":false}
        """

        let a = try JSONDecoder().decode(ParseVoiceOrderResponse.self, from: Data(withEnd.utf8))
        let b = try JSONDecoder().decode(ParseVoiceOrderResponse.self, from: Data(withoutEnd.utf8))

        XCTAssertEqual(a.resolvedEndPlace?.address, "五角场")
        XCTAssertNil(b.resolvedEndPlace, "后端没给终点字段时不能凭空造一个")
        XCTAssertNil(b.endAddressUnresolved)
    }

    /// 终点三件套要一路落到下单请求里。
    func testResolvedEndPlaceReachesTheCreateOrderRequest() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil,
                endAddress: "上海市杨浦区五角场", endLatitude: 31.2989, endLongitude: 121.5036
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场跑到五角场跑一个小时")

        let request = viewModel.makeCreateOrderRequest()
        XCTAssertEqual(request?.endAddress, "上海市杨浦区五角场")
        XCTAssertEqual(request?.endLatitude, 31.2989)
        XCTAssertEqual(request?.endLongitude, 121.5036)
    }

    /// 查不到坐标时**照样带地名下单**，坐标两个都不许带（只带一个后端返 400）。
    func testUnresolvedEndPlaceStillShipsTheAddressWithoutCoordinates() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil,
                endAddress: "老王家门口", endLatitude: nil, endLongitude: nil,
                endAddressUnresolved: true
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场跑到老王家门口跑一个小时")

        let request = viewModel.makeCreateOrderRequest()
        XCTAssertEqual(request?.endAddress, "老王家门口")
        XCTAssertNil(request?.endLatitude)
        XCTAssertNil(request?.endLongitude)
    }

    /// 读回：终点必须**紧跟起点**念，而且要说清没定位到。
    ///
    /// 位置不是排版偏好 —— 起终点由大模型抽取，抽反了（把出发地听成目的地）只有读回能被用户
    /// 发现，而两句挨着才听得出反没反。中间隔着预约时间就听不出来了。
    func testEndPlaceIsReadBackRightAfterTheStartPlace() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil,
                endAddress: "老王家门口", endLatitude: nil, endLongitude: nil,
                endAddressUnresolved: true
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场跑到老王家门口跑一个小时")

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("结束地点：老王家门口"), "读回必须念出终点：\(spoken)")
        XCTAssertTrue(
            spoken.contains("这个地点没能定位到"),
            "查不到坐标要说出来，否则盲人会以为终点已经定准了：\(spoken)"
        )
        guard let start = spoken.range(of: "出发地点"),
              let end = spoken.range(of: "结束地点"),
              let time = spoken.range(of: "预约时间") else {
            return XCTFail("读回里缺了起点 / 终点 / 时间之一：\(spoken)")
        }
        XCTAssertTrue(start.lowerBound < end.lowerBound, "终点要排在起点后面：\(spoken)")
        XCTAssertTrue(
            end.lowerBound < time.lowerBound,
            "终点必须紧跟起点、排在预约时间之前 —— 隔开就听不出起终点被抽反了：\(spoken)"
        )
    }

    /// 没说终点就**一个字都不提**。`nil` 的语义是「用户未指定」，不是「原路返回起点」，
    /// 多播一句「本次没有结束地点」会让人以为系统漏听了他没说过的话。
    func testNoEndPlaceMeansTheReadBackNeverMentionsIt() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertNil(viewModel.endPlace)
        XCTAssertFalse(
            (wizard.lastSpokenPrompt ?? "").contains("结束地点"),
            "没说终点就不该出现「结束地点」：\(wizard.lastSpokenPrompt ?? "")"
        )
        let request = viewModel.makeCreateOrderRequest()
        XCTAssertNil(request?.endAddress)
        XCTAssertNil(request?.endLatitude)
        XCTAssertNil(request?.endLongitude)
    }

    /// 第二句没提终点就必须把上一句的终点清掉。
    ///
    /// 屏幕上没有任何终点控件，用户重说一遍之后没有**视觉**线索能发现旧终点还挂着 ——
    /// 只有读回会念，而那时他已经准备说「确认」了。
    func testASecondUtteranceWithoutAnEndPlaceClearsThePreviousOne() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 60,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil,
                endAddress: "上海市杨浦区五角场", endLatitude: 31.2989, endLongitude: 121.5036
            ),
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: 30,
                address: "上海市黄浦区人民广场", latitude: 31.2304, longitude: 121.4737,
                missing: [], needReask: false, ttsText: nil
            )
        ]
        let viewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: viewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场跑到五角场跑一个小时")
        XCTAssertEqual(viewModel.endPlace?.address, "上海市杨浦区五角场", "前提：第一句抽到了终点")

        await wizard.submitTranscript("重说")
        XCTAssertNil(viewModel.endPlace, "「重说」要把上一轮的终点一起清掉")

        await wizard.submitTranscript("明天早上八点从人民广场出发跑半小时")
        XCTAssertNil(viewModel.endPlace, "新一句没提终点，旧终点不许留着")
        XCTAssertFalse((wizard.lastSpokenPrompt ?? "").contains("五角场"))
    }

    /// Mock 的终点抽取：只认「跑到」，且不许和起点抢同一段文字。
    ///
    /// 「明天早上8:00到五角场跑四十分钟」只有一个地点，口语里它就是**出发地**（到那儿去跑）。
    /// 裸「到」也认的话，同一段文字会既当起点又当终点 —— 正是后端 2026-08-09 修掉的 N38。
    func testMockEndSpanOnlyMatchesExplicitRunToPhrasing() {
        let cases: [(transcript: String, expected: String?)] = [
            ("明天早上8:00从人民广场跑到五角场，跑四十分钟", "五角场"),
            ("明天早上8:00跑到五角场，从人民广场出发，跑四十分钟", "五角场"),
            ("明天早上8:00从人民广场出发跑到五角场，跑一个小时", "五角场"),
            ("明天下午三点跑到中山公园，跑半小时", "中山公园"),
            ("明天早上8:00到五角场跑四十分钟", nil),
            ("明天早上八点从人民广场出发跑一个小时", nil)
        ]
        for testCase in cases {
            XCTAssertEqual(
                MockAPIClient.mockVoiceEndSpan(in: testCase.transcript),
                testCase.expected,
                "「\(testCase.transcript)」的终点应为 \(testCase.expected ?? "nil")"
            )
        }
    }

    // MARK: - 逐项修改已删除（2026-08-06）
    //
    // 原来这里有四条用例覆盖「改地点 / 改时间 / 改时长」那条逐项流程：needReask 不推进、
    // 连续三次听不清降级、解析结果回填、取整要念出来。逐项修改随 `.restart` 一起删掉之后，
    // 它们测的代码已经不存在。等价保障都在整句轮那几条上：
    //   · 回填 → testFreeformUtteranceFillsAllThreeSlotsInASingleRequest
    //   · 取整播报 → testFreeformAnnouncesDurationRounding
    //   · 连续失败降级 → testRepeatedSilenceEventuallyFallsBackToTheForm
    //   · needReask 不当错误 → testFreeformTreatsMissingSlotsAsDefaultsAndNeverReasks

    /// 语音说多少就是多少，只在超出契约区间（10–300）时夹到边界。
    ///
    /// 原来是「就近 snap 到 6 个枚举档位」，于是「跑三个小时」变成两小时 ——
    /// 枚举存在的理由是选择器需要有限选项，而说话的人不需要选择器。
    func testSpokenDurationIsTakenLiterallyAndOnlyClampedToTheContractRange() {
        XCTAssertEqual(VoiceOrderWizard.acceptedDurationMinutes(180), 180, "三个小时不该被砍成两小时")
        XCTAssertEqual(VoiceOrderWizard.acceptedDurationMinutes(40), 40, "40 分钟不该被抬到 45")
        XCTAssertEqual(VoiceOrderWizard.acceptedDurationMinutes(300), 300)
        XCTAssertEqual(VoiceOrderWizard.acceptedDurationMinutes(400), 300, "超出契约上限夹到 300")
        XCTAssertEqual(VoiceOrderWizard.acceptedDurationMinutes(5), 10, "低于契约下限夹到 10")
    }

    /// 时长文案按精确分钟数生成，不套枚举档位名。
    func testDurationTextReadsTheExactMinutes() {
        XCTAssertEqual(BlindBookingViewModel.durationText(forMinutes: 180), "3 小时")
        XCTAssertEqual(BlindBookingViewModel.durationText(forMinutes: 150), "2 小时 30 分钟")
        XCTAssertEqual(BlindBookingViewModel.durationText(forMinutes: 40), "40 分钟")
    }


    // MARK: - 与后端黄金语料对齐

    // 后端 `demo/docs/voice-golden-corpus.json` 的 iOS 侧镜像，**五族 96 条全覆盖**。
    //
    // 锁的是 **Mock 不许比真实解析器松或紧**：Mock 认得的说法真机上也要认得，Mock 认不得的
    // （语料里 `source: "llm"` 那几条）在开发期就该走到 `needReask` 分支，否则向导的重问路径
    // 永远没被走过，上真机才发现是死的。
    //
    // ⚠️ 下面每个清单上方的 `golden-corpus:` 标记是给 `scripts/validate-golden-corpus.mjs` 认的，
    // 别删。在 2026-08-06 之前那个脚本只比对 DURATION 的 11 条，另外 34 条既无镜像也无告警，
    // 却照样打印「通过」—— 假绿比没有守卫更坏，因为它让人以为查过了。

    /// 语料的时间基准。START_TIME 的期望值全是相对它算出的绝对时间戳，
    /// 不钉住基准就验不出「过去的钟点滚次日」这条规则。
    private static let corpusNow = "2026-07-24T10:00:00"

    private func withCorpusClock(_ body: () -> Void) {
        MockAPIClient.voiceClockForTesting = DateFormatter.aidRunBackendLocalDateTime.date(from: Self.corpusNow)
        defer { MockAPIClient.voiceClockForTesting = nil }
        body()
    }

    func testMockDurationParsingMatchesTheBackendGoldenCorpus() {
        // golden-corpus: DURATION regex
        let regexCases: [(transcript: String, expected: Int)] = [
            ("跑一小时", 60),
            ("跑一个小时", 60),
            ("四十分钟", 40),
            ("半小时", 30),
            ("一个半小时", 90),
            ("一小时二十分钟", 80),
            ("两个小时", 120),
            ("就跑二十分钟吧", 20),
            // 配速词打头。时长这一路不该被「快一点」带偏 —— 两条正则各管各的。
            ("快一点跑四十分钟", 40),
            // 起终点同现的三条：时长要照常抽出来，不受多出来的那个地点影响。
            ("明天早上8:00从人民广场跑到五角场，跑四十分钟", 40),
            ("明天早上8:00跑到五角场，从人民广场出发，跑四十分钟", 40),
            ("明天下午三点跑到中山公园，跑半小时", 30)
        ]

        for testCase in regexCases {
            XCTAssertEqual(
                MockAPIClient.mockVoiceMinutes(in: testCase.transcript),
                testCase.expected,
                "Mock 与黄金语料漂移：「\(testCase.transcript)」应为 \(testCase.expected) 分钟"
            )
        }

        // golden-corpus: DURATION llm
        // `source: "llm"` 的长尾表达：Mock 没有模型兜底，必须落到 needReask，不能瞎猜一个值。
        //
        // 「跑1.5小时」「跑0.5小时」是 2026-08-08 后端 PR #14 补进语料的，锁的是一次**静默篡改**：
        // 没有小数守卫时它们会匹配到小数部分的「5小时」→ 300 分钟，而 300 正好是时长上限，
        // 范围校验拦不住。用户说 1.5 小时、读回念 5 小时，比抽不出更糟。
        for transcript in ["随便说点什么", "陪我跑个把小时吧", "跑到我累了为止", "跑1.5小时", "跑0.5小时"] {
            XCTAssertNil(
                MockAPIClient.mockVoiceMinutes(in: transcript),
                "「\(transcript)」在 Mock 里不该被解析出数值"
            )
        }
    }

    /// START_TIME 13 条。这一族是 2026-08-06 才补上镜像的 —— 补之前 Mock 只认 5 个钟点、
    /// 落点恒定是「明天」，10 条 regex 只对得上 3 条：说「今天八点半」被念成明天，
    /// 说「下午三点」「半小时后」直接走重问，而线上这三种都解得出。
    func testMockStartTimeParsingMatchesTheBackendGoldenCorpus() {
        withCorpusClock {
            // golden-corpus: START_TIME regex
            let regexCases: [(transcript: String, expected: String)] = [
                ("八点半", "2026-07-25T08:30:00"),
                ("今天八点半", "2026-07-24T08:30:00"),
                ("明天早上八点", "2026-07-25T08:00:00"),
                ("后天上午九点", "2026-07-26T09:00:00"),
                ("下午三点", "2026-07-24T15:00:00"),
                ("晚上七点半", "2026-07-24T19:30:00"),
                ("半小时后", "2026-07-24T10:30:00"),
                ("两个小时后", "2026-07-24T12:00:00"),
                ("四十分钟后", "2026-07-24T10:40:00"),
                ("呃，明天早上八点吧", "2026-07-25T08:00:00"),
                // 冒号钟点（后端 PR #14 补进语料）。识别器说中文时常把「八点钟」渲染成 `8:00`，
                // 全角 `8：00` 同样出现过 —— 这类句子里连「点」字都没有。
                ("8:00", "2026-07-25T08:00:00"),
                ("8：00", "2026-07-25T08:00:00"),
                ("18:45", "2026-07-24T18:45:00"),
                ("下午3:00", "2026-07-24T15:00:00"),
                ("8点半", "2026-07-25T08:30:00"),
                ("明天早上8:00从阳光棕榈园跑", "2026-07-25T08:00:00"),
                // 前半句的「跑1:30」必须被跳过、且**继续往后找** —— 真正的钟点在后面。
                // 直接返 nil 会让这句整个抽不出时间。
                ("跑1:30，明天早上8点出发", "2026-07-25T08:00:00"),
                // 同一条「跳过继续找」，被拒的是程度副词而不是时长引导词：
                // 「慢一点」归一化后长得像「慢1点」，真正的钟点在后半句。
                ("跑慢一点，明天早上八点出发", "2026-07-25T08:00:00"),
                ("慢点跑，明天早上八点从人民广场出发", "2026-07-25T08:00:00"),
                // 起终点同现：多出来的那个地点不该影响时间抽取。
                ("明天早上8:00从人民广场跑到五角场，跑四十分钟", "2026-07-25T08:00:00"),
                // 日期词与钟点之间夹一个助词「的」或逗号（语料 `_date_particle_note`，后端 N44）。
                // 后端原来只允许空白，夹了助词就把日期那一组断开 → 日期被当成没说过 →
                // 再套「已过就滚次日」：早上 7 点说「明天的九点」得到**今天** 09:00。
                // 而「明天九点」（不带「的」）一直是对的 —— 两种说法在口语里同样自然，
                // 差别只在一个助词上，没人能预料到它会改变结果。
                ("明天的九点", "2026-07-25T09:00:00"),
                ("明天早上的八点", "2026-07-25T08:00:00"),
                ("明天的早上八点", "2026-07-25T08:00:00"),
                ("后天的八点半", "2026-07-26T08:30:00"),
                ("明天，九点", "2026-07-25T09:00:00"),
                // 「第二天」= 明天（产品 2026-08-09 拍板）。`UNSUPPORTED_DATE` 里有一条
                // 负向前瞻专门把它从「第 N 天」黑名单里放行出来 —— 放行了却不认，
                // 就等于「只取钟点、把日期当没说」，正是那条黑名单要防的静默篡改。
                ("第二天早上八点", "2026-07-25T08:00:00"),
                ("第二天的九点钟", "2026-07-25T09:00:00")
            ]
            for testCase in regexCases {
                let parsed = MockAPIClient.mockVoiceStartTime(in: testCase.transcript)
                XCTAssertEqual(
                    parsed.map(MockAPIClient.mockBackendLocalDateTime),
                    testCase.expected,
                    "Mock 与黄金语料漂移：「\(testCase.transcript)」（now=\(Self.corpusNow)）应为 \(testCase.expected)"
                )
            }

            // golden-corpus: START_TIME llm
            // 「跑1:30」「跑步1:30」是**时长**口语（识别器可能这么渲染「跑一个半小时」），
            // 当成 01:30 出发就会滚到次日、通过提前量校验，然后读回一个用户从没说过的时刻。
            //
            // 后 8 条是**日期表达**（语料 `_unsupported_date_note`）。它们比「解析不出」更危险：
            // Mock 的日期词只认明天/后天/今天，碰上「8月10号」不会失败，而是只取钟点、
            // 把日期当没说，再套「已过就滚次日」—— 于是「8月10号早上8点」被静默解析成次日 08:00。
            // 差 1 天、差 5 天的单都能过提前量校验，读回还念得很顺。
            for transcript in [
                "随便说点什么", "明天差不多这个点吧", "等我吃完早饭吧", "跑1:30", "跑步1:30",
                "8月10号早上8点跑步", "八月十号早上八点跑步", "8月10日早上8点跑步",
                "下周三早上8点跑步", "下下周二早上八点", "这个星期五早上八点",
                "大后天早上八点", "下个月十号早上八点",
                // 「第三天」以上：相对哪一天的第三天没说清（相对今天？相对刚提到的某天？）。
                // 「隔天」在中文里同样常指「每隔一天」（「隔天跑一次」）—— 这是个跑步 App，
                // 这个歧义是真的。两者都宁可追问一次，不猜。
                "第三天早上八点", "隔天八点"
            ] {
                XCTAssertNil(
                    MockAPIClient.mockVoiceStartTime(in: transcript),
                    "「\(transcript)」在 Mock 里不该被解析出时间"
                )
            }

            // golden-corpus: START_TIME none
            // 「没说时间」而不是「说了但正则解不出」—— 后端连大模型兜底都不走。
            // 对 Mock 的要求相同（返回 nil），但拦住它们的是另一道守卫：归一化把「一」转成「1」，
            // 「慢一点」变成「慢1点」正好落进「N点」分支 → 凌晨 1 点。用户根本没提时间，
            // 系统却造出一个能过提前量校验的时刻读给他听，同时「慢一点」还被配速正则认作 EASY
            // —— 同一句话上两条正则打架，时间那条赢了。
            for transcript in ["跑慢一点", "快一点跑四十分钟", "晚一点跑", "早一点出发"] {
                XCTAssertNil(
                    MockAPIClient.mockVoiceStartTime(in: transcript),
                    "「\(transcript)」里没有时间表达，不该被解析出时刻"
                )
            }
        }
    }

    /// 「八点半」滚次日这条规则单独再锁一次 —— 它是这一族里唯一**依赖 now** 的行为，
    /// 上面那张表只要基准写错就会整体失效，而这条会指名道姓地失败。
    func testAClockTimeAlreadyPastTodayRollsToTomorrowUnlessTodayIsSpoken() {
        withCorpusClock {
            let rolled = MockAPIClient.mockVoiceStartTime(in: "八点半")
            XCTAssertEqual(
                rolled.map(MockAPIClient.mockBackendLocalDateTime), "2026-07-25T08:30:00",
                "now=10:00 时「八点半」必须滚到次日：返回今天 08:30 会被提前量校验判成「太近了」，"
                    + "而用户压根没打算约今天"
            )
            XCTAssertEqual(
                MockAPIClient.mockVoiceStartTime(in: "今天八点半").map(MockAPIClient.mockBackendLocalDateTime),
                "2026-07-24T08:30:00",
                "显式说了「今天」就不该滚 —— 那是用户的明确选择，该由提前量校验去拒绝"
            )
        }
    }

    /// ADDRESS 9 条。语料只断言**剥壳抽取**，不断言地理编码结果（语料 `_address_note`）：
    /// 抽出「五角场」而 Mock 的地点表里查不到坐标，正是线上「抽到 span 但正向编码失败」的同形场景。
    func testMockAddressSpanExtractionMatchesTheBackendGoldenCorpus() {
        // golden-corpus: ADDRESS regex
        let regexCases: [(transcript: String, expected: String)] = [
            ("明天早上八点从五角场出发跑一小时", "五角场"),
            ("我想在人民广场跑步", "人民广场"),
            ("到中山公园那边跑四十分钟", "中山公园"),
            ("从我家楼下出发", "我家楼下"),
            ("在天安门集合", "天安门"),
            // 壳是「从…跑」。手列壳对时这一条一对都不中 —— 抽不出起点，人被约到默认位置。
            ("明天早上8:00从阳光棕榈园跑", "阳光棕榈园"),
            // 起终点同现（语料 `_end_address_note`）。`ADDRESS_SPAN` 只产出「起点」这一种角色，
            // 两个地点同现时它必须挑中**出发地**，挑错就是把人约到他要去的终点等着。
            ("明天早上8:00从人民广场跑到五角场，跑四十分钟", "人民广场"),
            // 倒装。SPEC B 刻意不做介词位置一致性校验（中文口语里倒装、省略介词都合法，
            // 位置规则会误杀），所以这条只能靠壳词本身挑对。
            ("明天早上8:00跑到五角场，从人民广场出发，跑四十分钟", "人民广场"),
            ("明天早上8:00从人民广场出发跑到五角场，跑一个小时", "人民广场"),
            // ⚠️ 只有一个地点时「到五角场跑」抽出五角场是**对的**：口语里它就是出发地
            // （到那儿去跑），不是终点。Mock 的终点抽取因此刻意只认「跑到」不认裸「到」。
            ("明天早上8:00到五角场跑四十分钟", "五角场")
        ]
        for testCase in regexCases {
            XCTAssertEqual(
                MockAPIClient.mockVoiceAddressSpan(in: testCase.transcript),
                testCase.expected,
                "Mock 与黄金语料漂移：「\(testCase.transcript)」应抽出「\(testCase.expected)」"
            )
        }

        // golden-corpus: ADDRESS llm
        // 「从明天早上八点开始跑」这类最危险：壳字「从」在，但后面跟的是时间。
        // 抽出来当地点就把人约到了一个不存在的起点，所以必须一条都不许命中。
        // 「从8:00开始跑」的壳内是 `8:00`：不认冒号就判不出它是时间，会当地名送去正向编码。
        // 这是冒号钟点漏洞的**第二个出口**，与 START_TIME 那条是同一个根因。
        //
        // 「明天下午三点跑到中山公园，跑半小时」只说了终点，**起点是真的没说** ——
        // 抽出中山公园当起点会把人约到目的地，所以这里必须是 nil，由 `missing` 含 ADDRESS
        // 走「落回当前位置并读回念出来」那条路。
        for transcript in [
            "从明天早上八点开始跑", "从8:00开始跑", "从8：00开始跑",
            "从半小时后开始跑", "老地方见，跑一小时", "随便说点什么",
            "明天下午三点跑到中山公园，跑半小时"
        ] {
            XCTAssertNil(
                MockAPIClient.mockVoiceAddressSpan(in: transcript),
                "「\(transcript)」不该被抽出地名"
            )
        }
    }

    /// GUIDE_DOG 6 条。`nil`（没提）与 `false`（明确不带）必须分得开 ——
    /// 这个字段进派单硬过滤，混淆会让登记了导盲犬的用户被静默按「不带」派单。
    func testMockGuideDogExtractionMatchesTheBackendGoldenCorpus() {
        // golden-corpus: GUIDE_DOG regex
        let regexCases: [(transcript: String, expected: Bool)] = [
            ("明天八点从五角场出发跑一小时，我带导盲犬", true),
            ("我牵着导盲犬", true),
            ("今天不带导盲犬", false),
            ("这次没带导盲犬", false)
        ]
        for testCase in regexCases {
            XCTAssertEqual(
                MockAPIClient.mockVoiceGuideDog(in: testCase.transcript),
                testCase.expected,
                "Mock 与黄金语料漂移：「\(testCase.transcript)」应为 \(testCase.expected)"
            )
        }

        // 后两条是 🔴 **正反问句**（语料 `_guide_dog_question_note`，后端 N43）：
        // 用户在**点名要改这一项**，不是在答，所以和「压根没提」一样必须是 nil。
        //
        // 它同时长得像肯定和否定（「带不带导盲犬」里既有「不带导盲犬」也有「带…导盲犬」），
        // 所以**只挡一边没用** —— 后端实测给否定加前置守卫之后，肯定那条立刻从第二个「带」字
        // 重新匹配上，值从 false 翻成 true，一样是凭空造的。必须整句先判问句、命中即返回 nil。
        //
        // 这不是边角情况：语音的定点修改会**主动引导用户说出这类句子**
        // （`correctionTarget = GUIDE_DOG` 的定向追问）。
        // golden-corpus: GUIDE_DOG none
        for transcript in [
            "跑步的时候有狗叫", "明天八点从五角场出发跑一小时",
            "带不带导盲犬改一下", "用不用导盲犬那个改一下"
        ] {
            XCTAssertNil(
                MockAPIClient.mockVoiceGuideDog(in: transcript),
                "「\(transcript)」不是在答带不带导盲犬，必须是 nil 而不是 false —— nil 才会回落档案默认值"
            )
        }
    }

    /// PACE 8 条。
    func testMockPaceExtractionMatchesTheBackendGoldenCorpus() {
        // golden-corpus: PACE regex
        let regexCases: [(transcript: String, expected: String)] = [
            // 这两条同时出现在 `START_TIME none` 里：配速要抽出来，时间必须是 nil。
            // 「慢一点」两条正则都想要它，赢的必须是配速这条。
            ("跑慢一点", "EASY"),
            ("快一点跑四十分钟", "FAST"),
            ("慢一点跑", "EASY"),
            ("想轻松跑跑", "EASY"),
            ("能不能快一点", "FAST"),
            ("走跑结合就行", "WALK_RUN"),
            ("中等速度", "MODERATE")
        ]
        for testCase in regexCases {
            XCTAssertEqual(
                MockAPIClient.mockVoicePace(in: testCase.transcript)?.rawValue,
                testCase.expected,
                "Mock 与黄金语料漂移：「\(testCase.transcript)」应为 \(testCase.expected)"
            )
        }

        // golden-corpus: PACE none
        for transcript in ["明天八点从五角场出发跑一小时"] {
            XCTAssertNil(
                MockAPIClient.mockVoicePace(in: transcript),
                "「\(transcript)」没提配速，必须是 nil"
            )
        }
    }

    /// 语料里的每个真实时长都必须**原样保留**。
    ///
    /// 原来这条验的是「取整落点不荒唐（偏差不超过 30 分钟）」—— 那是取整还存在时的将就写法。
    /// 取整删掉之后，正确的断言是零偏差：语料里没有一条超出契约区间，所以一条都不该被改动。
    func testEveryCorpusDurationSurvivesUnchanged() {
        for minutes in [20, 30, 40, 60, 80, 90, 120] {
            XCTAssertEqual(
                VoiceOrderWizard.acceptedDurationMinutes(minutes), minutes,
                "\(minutes) 分钟被改动了 —— 语料里的时长全在 10~300 内，不该有任何夹取"
            )
        }
    }

    // MARK: - 网络失败

    // 「解析端点报错就交回表单」那条用例随逐项修改一起删除（2026-08-06）：它测的是
    // `parseSingleSlot` 的 APIError 分支。整句轮**刻意相反** —— 传输失败被吞掉、仍然读回，
    // 由 `testFreeformSwallowsTransportFailuresAndStillReadsBackDefaults` 与
    // `testFreeformAnnouncesThatParsingFailedBeforeReadingBackDefaults` 覆盖。

    /// 等待期间必须出声。不出声的话，全盲用户在结束音之后听到的是最长 8 秒的绝对静默 ——
    /// 这正是我们用来论证要做 `RecordingCue` 的那条 AppleVis 抱怨（「按下之后全程没有任何反馈」），
    /// 只守住起止两端等于只守了一半。
    ///
    /// 断言点必须在**请求发出的那一刻**：等 `submitTranscript` 返回时，读回已经把它覆盖掉了。
    func testNetworkRoundsSayTheyAreWorkingInsteadOfGoingSilent() async {
        let speechService = SpeechService()
        var heardWhileWaiting: [String] = []

        let freeformStub = VoiceOrderAPIClientStub()
        freeformStub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil, missing: nil, needReask: nil, ttsText: nil
            )
        ]
        freeformStub.onRequest = { heardWhileWaiting.append(speechService.lastSpokenText ?? "") }
        let freeformWizard = makeWizard(
            stub: freeformStub, speechService: speechService, startingAt: .freeform
        )
        await freeformWizard.submitTranscript("明天早上八点跑一个小时")

        let secondStub = VoiceOrderAPIClientStub()
        secondStub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: "2026-08-05T08:00:00", durationMinutes: nil,
                address: nil, latitude: nil, longitude: nil,
                missing: nil, needReask: nil, ttsText: nil
            )
        ]
        secondStub.onRequest = { heardWhileWaiting.append(speechService.lastSpokenText ?? "") }
        let secondWizard = makeWizard(
            stub: secondStub, speechService: speechService, startingAt: .freeform
        )
        await secondWizard.submitTranscript("明天早上八点")

        XCTAssertEqual(heardWhileWaiting.count, 2, "两轮都该发出请求")
        for heard in heardWhileWaiting {
            XCTAssertTrue(heard.contains("正在识别"), "等待期间不得静默，实际听到：「\(heard)」")
        }
    }

    /// 等待提示**不得**顶掉 `lastSpokenPrompt` —— 顶掉之后「重复一遍」念的就是「正在提交订单」，
    /// 而不是用户真正想重听的那一段。
    ///
    /// 断言点选提交轮，是因为**只有这一轮之后没有任何东西会再覆盖 `lastSpokenPrompt`**：
    /// 解析轮无论成功、重问还是降级，随后都会 `speak` 一次把它盖掉，在那里断言等于什么都没测。
    /// `submit()` 失败时播的错误走 `speechService` 而不是向导的 `speak`，所以这里应当保持原样。
    ///
    /// `bookingViewModel` 必须在本地强持有：向导那一侧是 `weak`，不持有的话
    /// `submitConfirmedBooking` 会停在 `guard let` 上，用例根本走不到要测的那一行还照样绿。
    func testParsingNoticeDoesNotBecomeWhatRepeatSpeaks() async {
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(
            stub: VoiceOrderAPIClientStub(),
            bookingViewModel: bookingViewModel,
            startingAt: .confirm,
            didCaptureStartTime: true
        )

        await wizard.submitTranscript("确认")

        XCTAssertNil(
            wizard.lastSpokenPrompt,
            "等待提示不该进「重复一遍」的记忆，实际留下：「\(wizard.lastSpokenPrompt ?? "")」"
        )
    }

    // MARK: - 真人手测说过的原话
    //
    // 语料是造出来的，真人说的话不是。这一组收真机手测里实际说过、且当场出过问题的句子，
    // 用来把「到底是 Mock 认不出，还是别的环节断了」钉死 —— 靠推理分不出来，靠断言可以。

    /// 2026-08-06 手测原话：「明天早上八点钟从阳光棕榈园跑」。时间和地点都没被填上。
    func testRealUtteranceFromDeviceTestParsesTheTimeInMock() {
        let transcript = "明天早上八点钟从阳光棕榈园跑"

        let parsed = MockAPIClient.mockVoiceStartTime(in: transcript)

        let time = try? XCTUnwrap(parsed)
        XCTAssertNotNil(parsed, "Mock 认不出这句话的时间，那手测里「时间没识别到」就是 Mock 的锅")
        if let time {
            let components = Calendar.current.dateComponents([.hour, .minute], from: time)
            XCTAssertEqual(components.hour, 8, "「八点钟」应解析成 8 点")
            XCTAssertEqual(components.minute, 0)
        }
    }

    /// **端到端**：真人原话经真正的 `MockAPIClient` 走完整条链路，时间必须落到向导上。
    ///
    /// 上一条只调了 `mockVoiceStartTime`，那是链路的**第一环**。它绿着而真机仍然「识别不了时间点」，
    /// 说明断点在后面几环里：`handleVoiceParseOrder` 组响应 → `mockBackendLocalDateTime` 格式化
    /// → `backendLocalDate` 解回来 → `didCaptureStartTime` 置位。只测第一环等于没测。
    func testRealUtteranceCapturesTheStartTimeThroughTheRealMockClient() async {
        let client = MockAPIClient()
        client.syncSessionFromAppState(token: "mock_jwt_token_test", role: .blind)
        let bookingViewModel = BlindBookingViewModel()
        let wizard = VoiceOrderWizard()
        wizard.configure(
            bookingViewModel: bookingViewModel,
            speechService: SpeechService(), // guard:allow weak-temporary
            speechInputService: SpeechInputService(), // guard:allow weak-temporary
            apiClient: client
        )
        wizard.startForTesting(at: .freeform)

        await wizard.submitTranscript("明天早上八点钟从阳光棕榈园跑")

        XCTAssertTrue(
            wizard.didCaptureStartTime,
            "整条链路没把时间带过来 —— 真机「识别不了时间点」就是这一条"
        )
        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertFalse(spoken.contains("预约时间还没说"), "读回仍然说没听到时间：\(spoken)")
    }

    /// iOS 的 `SFSpeechRecognizer` 对同一句话有多种输出形式，Mock 必须都认。
    ///
    /// 诊断用：真机说「明天早上八点钟」而时间抽不出，但端到端用例是绿的 —— 说明识别出的字面
    /// 不是我们假设的那个。把现实中可能的形式一次全列出来，绿的排除、红的就是断点。
    func testRealisticRecognizerOutputsForTheSameSpokenTime() {
        let variants = [
            "明天早上八点钟从阳光棕榈园跑",
            "明天早上8点钟从阳光棕榈园跑",
            "明天早上8点从阳光棕榈园跑",
            "明天早上8:00从阳光棕榈园跑",
            "明天早上8：00从阳光棕榈园跑",
            "明天早上八点半从阳光棕榈园跑",
            "明天上午八点从阳光棕榈园跑",
            "明天早上八点，从阳光棕榈园跑"
        ]
        var failures: [String] = []
        for variant in variants where MockAPIClient.mockVoiceStartTime(in: variant) == nil {
            failures.append(variant)
        }
        XCTAssertTrue(failures.isEmpty, "这些识别形式抽不出时间：\(failures)")
    }

    /// 冒号形式解出来的必须是**正确的时分**，不能只是「没返回 nil」。
    func testColonClockTimeResolvesToTheRightHourAndMinute() {
        let cases: [(String, Int, Int)] = [
            ("明天早上8:00出发", 8, 0),
            ("明天早上8：30出发", 8, 30),
            ("明天18:45出发", 18, 45),
            // 时段词对冒号形式同样生效：识别成 `3:00` 时「下午」是唯一的 12/24 制线索
            ("明天下午3:00出发", 15, 0)
        ]
        for (transcript, hour, minute) in cases {
            guard let parsed = MockAPIClient.mockVoiceStartTime(in: transcript) else {
                XCTFail("「\(transcript)」抽不出时间")
                continue
            }
            let components = Calendar.current.dateComponents([.hour, .minute], from: parsed)
            XCTAssertEqual(components.hour, hour, "「\(transcript)」的小时不对")
            XCTAssertEqual(components.minute, minute, "「\(transcript)」的分钟不对")
        }
    }

    /// 「8点半」的半小时不能被静默抹掉。
    ///
    /// 原来只查中文形式「八点半」，识别输出阿拉伯数字时半小时被悄悄归零 ——
    /// 对听不见屏幕的人，静默改掉他说的时间就是一次无声的篡改。
    func testHalfPastIsRecognisedForArabicDigitsToo() {
        for transcript in ["明天早上8点半出发", "明天早上八点半出发"] {
            guard let parsed = MockAPIClient.mockVoiceStartTime(in: transcript) else {
                XCTFail("「\(transcript)」抽不出时间")
                continue
            }
            XCTAssertEqual(
                Calendar.current.component(.minute, from: parsed), 30,
                "「\(transcript)」的半小时被抹掉了"
            )
        }
    }

    /// 剥壳与地理编码是**两件事**，这条把它们分开钉住。
    ///
    /// 2026-08-08 之前这里断言的是「抽不出」，理由写的是「阳光棕榈园不在 Mock 的关键词表里」——
    /// 那句话把两件事混成了一件：抽不出的真实原因是当时的壳只手列了 4 对，`从…跑` 不在里面。
    /// 关键词表管的是**下一步**（span → 坐标），跟能不能剥壳无关。
    ///
    /// 现在壳照抄后端 `ADDRESS_SPAN` 的叉积，span 抽得出；而 `mockVoicePlaces` 里仍然没有这个
    /// 地点，所以坐标依旧查不到 —— 这正是语料 `_address_note` 描述的线上同形场景
    /// 「抽到 span 但正向编码失败」，结果该是 `missing` 含 `ADDRESS`，而不是当用户没说起点。
    func testAddressSpanIsExtractedEvenWhenTheMockCannotGeocodeIt() {
        XCTAssertEqual(
            MockAPIClient.mockVoiceAddressSpan(in: "明天早上八点钟从阳光棕榈园跑"),
            "阳光棕榈园",
            "壳是「从…跑」，剥壳这一步与关键词表无关"
        )
    }

    // MARK: - 不许编时间
    //
    // 2026-08-06 用户原话：「这个默认配置我觉得不应该给它默认配置，除了地点有默认地点之外，
    // 其他的为什么能默认呢」。`appointmentTime` 的初值是 `Date()`，抽不出时间时读回会念出一个
    // 用户从没说过的具体时刻，再补一句「需至少在 30 分钟后」—— 听不见屏幕的人只会记住前半句。

    /// 没抽到开始时间时，读回**不得念出任何具体时刻**。
    func testReadbackSaysTheTimeIsMissingInsteadOfInventingOne() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil,
                missing: [.startTime], needReask: nil, ttsText: nil
            )
        ]
        // bookingViewModel 必须本地强持有：向导那侧是 `weak`，不持有的话 `askCurrentStep`
        // 会走 `else` 分支念 `Step.confirm.prompt` 兜底文案，整单一个字都不念 —— 用例
        // 测的就不是读回内容了。本仓库 `weak-temporary` 守卫说的就是这个坑。
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel, startingAt: .freeform)

        await wizard.submitTranscript("我想去人民广场")

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("预约时间还没说"), "没说就要说没说：\(spoken)")
        XCTAssertFalse(wizard.didCaptureStartTime)
        XCTAssertFalse(
            spoken.contains("预约时间：20"),
            "念出了一个用户从没说过的具体时刻：\(spoken)"
        )
    }

    /// 缺开始时间时「确认」不生效 —— 不能凭一句「确认」就派一张用户没说过时间的单。
    func testConfirmIsRefusedWhenTheStartTimeWasNeverSpoken() async {
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(
            stub: VoiceOrderAPIClientStub(),
            bookingViewModel: bookingViewModel,
            startingAt: .confirm,
            didCaptureStartTime: false
        )

        await wizard.submitTranscript("确认")

        XCTAssertNil(wizard.createdOrder, "用户从没说过时间，不能成单")
        XCTAssertTrue(wizard.isRunning, "拦住之后要留在语音里，而不是静默结束")
        XCTAssertTrue((wizard.lastSpokenPrompt ?? "").contains("重说"), "必须给出唯一可行的出路")
    }

    /// 抽到了时间就正常放行 —— 上面那条拦截不能宽到把正常流程也挡了。
    func testConfirmProceedsOnceTheStartTimeWasCaptured() async {
        let stub = VoiceOrderAPIClientStub()
        let plannedStart = DateFormatter.aidRunBackendLocalDateTime.string(
            from: Date().addingTimeInterval(3600 * 24)
        )
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: plannedStart, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil,
                missing: nil, needReask: nil, ttsText: nil
            )
        ]
        // 同上：不强持有的话下面那条断言会因为兜底文案恰好也含「说「确认」就下单」而**假通过**。
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点从人民广场出发")

        XCTAssertTrue(wizard.didCaptureStartTime)
        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("这次的预约是："), "念的必须是整单读回而不是兜底提问：\(spoken)")
        XCTAssertTrue(spoken.contains("说「确认」就下单"), "抽到时间后就该正常给出确认这条出路：\(spoken)")
        XCTAssertFalse(spoken.contains("预约时间还没说"))
    }

    // MARK: - 不许把人关在没有出口的循环里
    //
    // 「时间抽不出就不许确认」这条规则必须配一个出口，否则解析这一环一坏就成死循环：
    // 说一整句 → 抽不出时间 → 不给确认 → 「请说重说」→ 重说 → 还是抽不出 → 无限。
    // 2026-08-06 手测就是这么卡住的：用户第二遍明确说了时间，仍然抽不到。
    // 对看不见屏幕的人，没有出口的循环比一条错误信息糟得多。

    /// 端点根本不存在（生产上 `/api/orders/voice/parse` 恒 404）时**一次读回都不做**，直接交回表单。
    func testMissingParseEndpointFallsBackImmediatelyInsteadOfOfferingARetry() async {
        let stub = VoiceOrderAPIClientStub()
        stub.error = APIError.serverError(
            ErrorResponse(code: "NOT_FOUND", message: "请求的资源不存在")
        )
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel, startingAt: .freeform)

        await wizard.submitTranscript("明天早上八点钟从阳光棕榈园跑")

        XCTAssertFalse(wizard.isRunning, "端点不存在，重说一万遍也一样，不该留在语音里")
        let fallback = wizard.fallbackMessage ?? ""
        XCTAssertTrue(fallback.contains("表单"), "必须给出真正的出路：\(fallback)")
        XCTAssertFalse(
            fallback.contains("重说"),
            "不得建议重说 —— 那是把死路包装成活路：\(fallback)"
        )
    }

    /// 解析活着但连着两轮都抽不到时间，同样要交回表单，而不是第三次说「请说重说」。
    func testTwoRoundsWithoutAStartTimeFallBackToTheForm() async {
        let stub = VoiceOrderAPIClientStub()
        let noTime = ParseVoiceOrderResponse(
            plannedStartTime: nil, durationMinutes: nil, address: nil,
            latitude: nil, longitude: nil,
            missing: [.startTime], needReask: nil, ttsText: nil
        )
        stub.parseOrderResponses = [noTime, noTime]
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel, startingAt: .freeform)

        await wizard.submitTranscript("我想去人民广场")
        XCTAssertTrue(wizard.isRunning, "第一次抽不到时间应该给一次重说的机会")

        await wizard.submitTranscript("重说")
        await wizard.submitTranscript("还是没说时间")

        XCTAssertFalse(wizard.isRunning, "第二次还抽不到就不能再让人重说了")
        XCTAssertTrue((wizard.fallbackMessage ?? "").contains("表单"))
    }

    /// 出口不能宽到把正常流程也带走：中间成功抽到过时间，计数要清零。
    func testCapturingAStartTimeResetsTheDeadEndCounter() async {
        let stub = VoiceOrderAPIClientStub()
        let plannedStart = DateFormatter.aidRunBackendLocalDateTime.string(
            from: Date().addingTimeInterval(3600 * 24)
        )
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil, missing: [.startTime], needReask: nil, ttsText: nil
            ),
            ParseVoiceOrderResponse(
                plannedStartTime: plannedStart, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil, missing: nil, needReask: nil, ttsText: nil
            )
        ]
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel, startingAt: .freeform)

        await wizard.submitTranscript("我想去人民广场")
        await wizard.submitTranscript("重说")
        await wizard.submitTranscript("明天早上八点从人民广场出发")

        XCTAssertTrue(wizard.isRunning, "这一轮抽到时间了，不该被上一轮的失败计数带走")
        XCTAssertTrue(wizard.didCaptureStartTime)
    }

    // MARK: - 沉默不等于同意默认值
    //
    // 2026-08-06 真机：用户没听到起音提示、不知道麦克风开了，沉默着等；8 秒后系统判定
    // 「他想用默认值」，念了一整单他从没说过的预约。原话是「他也没有经过我的同意」。
    // 沉默的原因绝大多数是没听见 / 没听懂 / 还在想，不是「我接受默认值」。

    /// 整句那一轮**什么都没听到**时必须重问，不能直接跳去读回默认整单。
    func testTotalSilenceInFreeformReasksInsteadOfReadingBackDefaults() async {
        let wizard = makeWizard(stub: VoiceOrderAPIClientStub(), startingAt: .freeform)

        wizard.handleCompletionForTesting(
            SpeechInputCompletion(
                field: .voiceOrderFreeform,
                recognizedText: "",
                reason: .silenceTimeout(hadDetectedSound: false)
            )
        )

        XCTAssertEqual(wizard.step, .freeform, "没听到任何话就跳去读回，等于替用户决定了整张订单")
        XCTAssertEqual(wizard.reaskCount, 1)
        XCTAssertNil(wizard.createdOrder)
    }

    /// 重问那句要**带例句** —— 听不见屏幕的人缺的是「我该说什么」，不是「再说一次」。
    /// 调研 §6.6 引 Google 的错误处理规范：例子比解释有效。
    func testFreeformSilenceReaskGivesAnExample() async {
        let wizard = makeWizard(stub: VoiceOrderAPIClientStub(), startingAt: .freeform)

        wizard.handleCompletionForTesting(
            SpeechInputCompletion(
                field: .voiceOrderFreeform,
                recognizedText: "",
                reason: .silenceTimeout(hadDetectedSound: false)
            )
        )

        let spoken = wizard.lastSpokenPrompt ?? ""
        XCTAssertTrue(spoken.contains("没有听到你说话"), "实际：\(spoken)")
        XCTAssertTrue(spoken.contains("比如"), "重问必须给例句，实际：\(spoken)")
    }

    /// 连续沉默不会无限重问：两次之后交回表单，而不是把人按在麦克风前。
    func testRepeatedSilenceEventuallyFallsBackToTheForm() async {
        let wizard = makeWizard(stub: VoiceOrderAPIClientStub(), startingAt: .freeform)
        let silence = SpeechInputCompletion(
            field: .voiceOrderFreeform,
            recognizedText: "",
            reason: .silenceTimeout(hadDetectedSound: false)
        )

        for _ in 0..<VoiceOrderWizard.maximumReasksPerSlot {
            wizard.handleCompletionForTesting(silence)
        }

        XCTAssertFalse(wizard.isRunning, "连续听不到就该交回表单，不能一直重问")
        XCTAssertNotNil(wizard.fallbackMessage)
        XCTAssertNil(wizard.createdOrder)
    }

    /// **说了话但抽不出槽位**那条路径不受影响 —— 用户确实说了，用默认值补齐并读回是对的，
    /// 他能在读回里听出来。这条钉住上面三条没有把它一起改掉。
    func testSpeakingSomethingUnparseableStillReadsBackInsteadOfReasking() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            ParseVoiceOrderResponse(
                plannedStartTime: nil, durationMinutes: nil, address: nil,
                latitude: nil, longitude: nil,
                missing: [.address, .startTime, .duration], needReask: true, ttsText: nil
            )
        ]
        let wizard = makeWizard(stub: stub, startingAt: .freeform)

        await wizard.submitTranscript("呃那个我想想")

        XCTAssertEqual(wizard.step, .confirm, "说了话就该往读回走 —— 沉默才重问，这两件事不一样")
        XCTAssertEqual(wizard.reaskCount, 0)
    }

    // MARK: - 等 TTS 播完再开麦的上限
    //
    // 2026-08-06 真机手测：读回念到一半被切掉，麦克风当场打开。根因是这个上限写死 8 秒，
    // 而读回整单要 15~25 秒 —— 上限一到就开麦，开麦切换音频分类会把正在播的合成器掐断。
    // 上限必须跟着要念的字数走，这一组把这件事钉住。

    /// 读回整单的实际长度量级（原话 + 三个槽位 + 两条出路，约 120 字）必须等得住。
    /// 这条直接对应报障：120 字在旧的 8 秒上限下必被截断。
    func testSettleTimeoutOutlastsAFullReadback() {
        let readback = String(repeating: "字", count: 120)

        let timeout = VoiceOrderWizard.settleTimeout(forCharacterCount: readback.count)

        XCTAssertGreaterThan(
            timeout,
            20,
            "约 120 字的读回念不完就开麦，音频分类切换会把合成器掐断 —— 盲人听到的是一句被切一半的预约"
        )
    }

    /// 短提示的行为不变：下限仍是 8 秒，不因为这次改动被拖长。
    func testSettleTimeoutKeepsTheOldFloorForShortPrompts() {
        XCTAssertEqual(VoiceOrderWizard.settleTimeout(forCharacterCount: 0), 8)
        XCTAssertEqual(VoiceOrderWizard.settleTimeout(forCharacterCount: 5), 8)
    }

    /// 上限存在的理由是合成器代理丢事件时不能无限等 —— 异常长的文本也必须夹住。
    func testSettleTimeoutIsCappedSoALostDelegateCannotHangTheMicrophone() {
        XCTAssertEqual(VoiceOrderWizard.settleTimeout(forCharacterCount: 100_000), 45)
    }

    // MARK: - start() 的门槛接线
    //
    // 上面 28 条用例全部走 `startForTesting(at:)`，**绕过了 `start()`**，所以门槛那三道分支
    // 一条都没被验过 —— 和「兜底坐标让 `.startPoint` 恒真」是同一类：逻辑写对了，但没人证明
    // 它真的被接上。（openspec tasks 3.4 / 3.5）

    private func makeUnstartedWizard(
        bookingViewModel: BlindBookingViewModel,
        speechInputService: SpeechInputService? = nil
    ) -> VoiceOrderWizard {
        let wizard = VoiceOrderWizard()
        wizard.configure(
            bookingViewModel: bookingViewModel,
            speechService: SpeechService(),
            // 参数是非可选的，但 wizard 那侧是 `weak var`：不传时这个临时对象出了本行就释放，
            // wizard 拿到的实际是 nil。走门槛分支的用例本来就不碰语音服务，故此保持现状；
            // 需要真的语音服务的用例（见 testStartFallsBackImmediately...）必须自己 `let` 住再传进来。
            speechInputService: speechInputService ?? SpeechInputService(), // guard:allow weak-temporary
            apiClient: VoiceOrderAPIClientStub()
        )
        return wizard
    }

    /// 四道「本页填不了」的门槛缺任意一道，`start()` 都不得开麦，并且必须把原因说出来。
    ///
    /// 门槛的唯一真源是后端 `OrderCreationService.createOrder`，客户端这份只是把同样的顺序提前。
    /// 让盲人说完一整句才被服务端 403 拒掉是最坏的顺序。
    func testStartIsBlockedByGatesThatVoiceCannotFill() {
        let appState = AppState(persistence: AppStatePersistenceFactory.makeIsolatedTest())
        // 昵称未填 ⇒ basicProfile 缺失，这一道只能去个人资料页补。
        let viewModel = BlindBookingViewModel()
        viewModel.configureForTesting(speechService: SpeechService(), locationService: nil, appState: appState)
        let wizard = makeUnstartedWizard(bookingViewModel: viewModel)

        XCTAssertFalse(wizard.start(), "门槛没过就不该起步")
        XCTAssertFalse(wizard.isRunning)
        XCTAssertEqual(wizard.fallbackMessage, BlindBookingGate.basicProfile.message, "拦住了就必须说得出原因")
    }

    /// 起点与时间**缺失时反而要照常起步** —— 它们正是用户接下来要说出口的槽位。
    ///
    /// ⚠️ openspec tasks 3.4 原文写的是「默认值不可用时**不**出现首步」，那描述属于已被推翻的
    /// `.confirmDefaults` 形态（先念默认值再逐项追问）。现在首步是整句自由说，把这两道门槛
    /// 当成阻断条件会让「没有 GPS 就彻底用不了语音」—— 而语音正是拿来说出发地点的。
    /// `VoiceOrderWizard.start()` 里那两个 `gate != ...` 判断就是这条规则，本用例锁住它。
    func testStartProceedsWhenOnlyTheVoiceFilledSlotsAreMissing() {
        let appState = AppState(persistence: AppStatePersistenceFactory.makeIsolatedTest())
        appState.updateBlindProfile(BlindProfileResponse(name: "测试用户", verifyStatus: "VERIFIED"))
        appState.updateEmergencyContacts([
            EmergencyContactResponse(id: 1, name: "联系人1", phone: "13900139001", relationship: "家人", isPrimary: true)
        ])
        let viewModel = BlindBookingViewModel()
        // ⚠️ 起点缺失必须用 `locationService: nil` 构造，**不能**用裸 `LocationService()`。
        // 后者在真机上是个竞态：`resolvedStartPlace` 只要 `currentLocation != nil` 就成立
        // （`BlindBookingView.swift:358`），而真机几毫秒内就回调出真实坐标，于是起点反而有了、
        // 门槛跳到 `.appointmentTime`。本用例 2026-08-06 首次上真机就是这么红的 ——
        // 它要验的是「起点缺失时照常起步」，跟坐标是不是演示值无关，没必要引入定位的时序。
        viewModel.configureForTesting(speechService: SpeechService(), locationService: nil, appState: appState)
        XCTAssertEqual(viewModel.firstMissingGate, .startPoint, "前提：只差语音要填的槽位")

        let wizard = makeUnstartedWizard(bookingViewModel: viewModel)

        XCTAssertTrue(wizard.start(), "起点缺失恰恰是要用语音补的，不能反过来把语音关掉")
        XCTAssertTrue(wizard.isRunning)
        XCTAssertEqual(wizard.step, .freeform)
        XCTAssertNil(wizard.fallbackMessage)
    }

    /// 语音链路已经在启动阶段失败过（授权被拒 / recognizer 不可用）就直接交回表单。
    /// 明知打不开麦克风还走一遍重问循环，只会让人听三轮「我再问一次」才等到降级。
    func testStartFallsBackImmediatelyWhenTheSpeechPathIsAlreadyKnownBroken() {
        let appState = AppState(persistence: AppStatePersistenceFactory.makeIsolatedTest())
        appState.updateBlindProfile(BlindProfileResponse(name: "测试用户", verifyStatus: "VERIFIED"))
        appState.updateEmergencyContacts([
            EmergencyContactResponse(id: 1, name: "联系人1", phone: "13900139001", relationship: "家人", isPrimary: true)
        ])
        let viewModel = BlindBookingViewModel()
        // `locationService` 在 view model 里是 weak，这里原本传的临时对象当场就释放了 ——
        // 等价于 nil，写成 nil 才不误导。本用例验的是语音链路失败后的降级，与定位无关。
        viewModel.configureForTesting(
            speechService: SpeechService(), locationService: nil, appState: appState
        )
        let speech = SpeechInputService()
        speech.startPendingAuthorizationForTesting(field: .voiceOrderFreeform)
        speech.denyAuthorizationForTesting()
        XCTAssertTrue(speech.isSpeechPathUnavailable, "前提：语音这条路已知不可用")

        let wizard = makeUnstartedWizard(bookingViewModel: viewModel, speechInputService: speech)

        XCTAssertFalse(wizard.start())
        XCTAssertFalse(wizard.isRunning)
        XCTAssertEqual(
            wizard.fallbackMessage,
            "语音输入当前不可用，已切回表单填写，你可以用屏幕上的输入框继续预约。",
            "降级必须说清接下来去哪 —— 看不见屏幕的人没有别的方式发现语音已经停了"
        )
    }

    // MARK: - 起点候选消歧（N48）

    /// 序数判定全在本地，不发一个字节。这几条就是它的全部契约。
    func testOrdinalIndexRecognisesSpokenOrdinals() {
        XCTAssertEqual(VoiceOrderWizard.ordinalIndex(in: "第一个", count: 3), 0)
        XCTAssertEqual(VoiceOrderWizard.ordinalIndex(in: "第二个", count: 3), 1)
        XCTAssertEqual(
            VoiceOrderWizard.ordinalIndex(in: "第三个吧", count: 3), 2,
            "句尾语气词要被 normalizedCommand 剥掉"
        )
        XCTAssertEqual(
            VoiceOrderWizard.ordinalIndex(in: "第2个", count: 3), 1,
            "识别器在不同 iOS 版本上可能吐阿拉伯数字"
        )
        XCTAssertNil(VoiceOrderWizard.ordinalIndex(in: "确认", count: 3))
        XCTAssertNil(VoiceOrderWizard.ordinalIndex(in: "", count: 3))
    }

    /// `count` 是护栏：只念了 2 个就不许认「第三个」—— 那是让用户挑一个不存在的地点。
    func testOrdinalIndexRejectsOrdinalBeyondCandidateCount() {
        XCTAssertNil(VoiceOrderWizard.ordinalIndex(in: "第三个", count: 2))
        XCTAssertEqual(VoiceOrderWizard.ordinalIndex(in: "第二个", count: 2), 1)
    }

    /// 存进订单的地址要和后端平铺 `address` 同一形态（POI 名 + 街道地址）。
    /// 形态不一致的话，下游按空格切 POI 名的 `spokenAddress` 会切错。
    func testCandidateReadbackAddressMirrorsBackendShape() {
        XCTAssertEqual(Self.candidate("五角场", address: "邯郸路").readbackAddress, "五角场 邯郸路")
        XCTAssertEqual(Self.candidate("五角场").readbackAddress, "五角场")
        XCTAssertEqual(
            Self.candidate("邯郸路1号", address: "邯郸路1号").readbackAddress, "邯郸路1号",
            "名称里已经含街道时不要拼两遍"
        )
    }

    /// 只有一个候选不该把人拉进消歧轮 ——「只有一个结果还问你选哪个」是纯粹的多一轮。
    func testSingleCandidateDoesNotTriggerDisambiguation() {
        let response = Self.parseResponse(candidates: [Self.candidate("阳光棕榈园")])
        XCTAssertNil(response.startCandidatesToDisambiguate)
    }

    /// 端到端：三个候选 → 进消歧轮并念后端文案 → 说「第二个」→ 起点落到第二条 → 回读回轮。
    func testMultipleCandidatesEnterDisambiguationThenSecondIsApplied() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 20),
            durationMinutes: 60,
            address: "阳光棕榈园",
            latitude: 22.5333,
            longitude: 113.9300,
            needReask: true,
            ttsText: "找到3个地点，请说第几个。第一个，阳光棕榈园，南山区，距您400米。",
            candidates: [
                Self.candidate("阳光棕榈园"),
                Self.candidate("阳光棕榈园北门", latitude: 22.5400, longitude: 113.9350),
                Self.candidate("阳光棕榈园东区", latitude: 22.5310, longitude: 113.9280)
            ]
        )]
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel)

        await wizard.submitTranscript("明天早上八点从阳光棕榈园出发跑一个小时")

        guard case .disambiguateStart(let candidates, _) = wizard.step else {
            return XCTFail("三个候选没有进消歧轮，step=\(wizard.step)")
        }
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(
            (wizard.lastSpokenPrompt ?? "").contains("请说第几个"),
            "候选列表只有后端拼得出，必须念它的 ttsText：\(wizard.lastSpokenPrompt ?? "")"
        )

        await wizard.submitTranscript("第二个")

        XCTAssertEqual(wizard.step, .confirm, "挑完就该回读回轮")
        XCTAssertEqual(bookingViewModel.resolvedStartPlace?.title, "阳光棕榈园北门")
        XCTAssertEqual(bookingViewModel.resolvedStartPlace?.latitude, 22.5400)
    }

    /// 🔴 挑完必须换掉快照。
    ///
    /// 不换的话确认轮把旧 `current` 发回后端，起点被继承成**第一条**，读回念的又变回最佳猜测 ——
    /// 用户刚挑的那一下白挑了，而且没有任何提示。
    func testChosenCandidateReplacesSnapshotSentBackAsCurrent() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 20),
                durationMinutes: 60,
                address: "阳光棕榈园",
                latitude: 22.5333,
                longitude: 113.9300,
                candidates: [
                    Self.candidate("阳光棕榈园"),
                    Self.candidate("阳光棕榈园北门", latitude: 22.5400, longitude: 113.9350)
                ]
            ),
            // 确认轮那一次 /parse 的回包，内容不重要，这条用例只看请求里带了什么
            Self.parseResponse(
                plannedStartTime: Self.backendTime(hoursFromNow: 20),
                durationMinutes: 60,
                address: "阳光棕榈园北门",
                latitude: 22.5400,
                longitude: 113.9350
            )
        ]
        let wizard = makeWizard(stub: stub)

        await wizard.submitTranscript("明天早上八点从阳光棕榈园出发跑一个小时")
        await wizard.submitTranscript("第二个")
        // 一句本地表接不住的话，确认轮才会真的发请求
        await wizard.submitTranscript("这样就挺好的麻烦你了")

        XCTAssertEqual(stub.parseRequests.count, 2, "确认轮应该发了第二次 /parse")
        XCTAssertEqual(
            stub.parseRequests.last?.current?.address, "阳光棕榈园北门",
            "回传的 current 还是最佳猜测，用户挑的那一下被丢了"
        )
        XCTAssertEqual(stub.parseRequests.last?.current?.latitude, 22.5400)
    }

    /// 三次挑不出来**不把人丢回表单**（那是其余轮次的降级方式）：手上已经有可用的最佳猜测，
    /// 读回会念出来、用户仍可以说「重说」。但**必须说出「按第一个来」** ——
    /// 静默取第一条正是这轮改动要消灭的那个失败。
    func testThreeFailedPicksFallBackToFirstCandidateOutLoud() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 20),
            durationMinutes: 60,
            address: "阳光棕榈园",
            latitude: 22.5333,
            longitude: 113.9300,
            candidates: [Self.candidate("阳光棕榈园"), Self.candidate("阳光棕榈园北门")]
        )]
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel)

        await wizard.submitTranscript("明天早上八点从阳光棕榈园出发跑一个小时")
        for _ in 0..<VoiceOrderWizard.maximumReasksPerSlot {
            await wizard.submitTranscript("嗯这个那个")
        }

        XCTAssertEqual(wizard.step, .confirm, "不该丢回表单")
        XCTAssertNil(wizard.fallbackMessage)
        XCTAssertEqual(bookingViewModel.resolvedStartPlace?.title, "阳光棕榈园")
        XCTAssertTrue(
            (wizard.lastSpokenPrompt ?? "").contains(VoiceOrderWizard.pickedFirstCandidateNotice),
            "替用户挑了却没说，那就是静默取第一条：\(wizard.lastSpokenPrompt ?? "")"
        )
    }

    /// 消歧轮里「重说」必须能退出去 —— 被一批他听不明白的候选卡住时那是唯一出路。
    func testRestartWordExitsDisambiguation() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 20),
            durationMinutes: 60,
            address: "阳光棕榈园",
            latitude: 22.5333,
            longitude: 113.9300,
            candidates: [Self.candidate("阳光棕榈园"), Self.candidate("阳光棕榈园北门")]
        )]
        let wizard = makeWizard(stub: stub)

        await wizard.submitTranscript("明天早上八点从阳光棕榈园出发跑一个小时")
        await wizard.submitTranscript("重说")

        XCTAssertEqual(wizard.step, .freeform)
    }

    /// 说了地名但没查到时，读回前必须先说出来。
    ///
    /// 不说的话读回念的是「当前位置」，而用户明明说了一个地名 —— 静默落回就是把人约到错误的起点，
    /// 他全程听不出来。后端 2026-08-10 起不再拿全国范围的正向编码兜底，这条会变常见。
    func testUnresolvedStartAddressIsAnnouncedBeforeReadback() async {
        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse(
            plannedStartTime: Self.backendTime(hoursFromNow: 20),
            durationMinutes: 60,
            address: "老王家门口",
            missing: [.address],
            needReask: true,
            addressUnresolved: true
        )]
        // 必须持有一个活着的 view model：wizard 侧是 weak，临时对象等于传 nil，
        // 而 `confirmPrompt(for:)` 拿不到它就退回只念出路那句，读回整段根本不会拼出来
        let bookingViewModel = BlindBookingViewModel()
        let wizard = makeWizard(stub: stub, bookingViewModel: bookingViewModel)

        await wizard.submitTranscript("明天早上八点从老王家门口出发跑一个小时")

        XCTAssertEqual(wizard.step, .confirm)
        XCTAssertTrue(
            (wizard.lastSpokenPrompt ?? "").contains(VoiceOrderWizard.startAddressUnresolvedNotice),
            "听见了地名却没查到，读回却只字未提：\(wizard.lastSpokenPrompt ?? "")"
        )
    }

    // MARK: - 坐标送得上去吗（N48 的根因）

    /// 🔴 **N48 的根因回归。** 站着不动 60 秒之后，语音下单的请求里**还有没有坐标**。
    ///
    /// 用户真机报的是「定位开着，在深圳说的地名却定位到海南」。链路上不是定位坏了 ——
    /// `onAppear` 的 `startUpdating()` 是**持续**定位，而非陪跑模式下 `distanceFilter = 10`，
    /// 站着不动 Core Location 就不推新样本；语音下单恰恰是站着说完一整句，说完常已超过
    /// `latestBackendSample` 默认的 15 秒新鲜度门 ⇒ 闭包返回 nil ⇒ 请求不带坐标 ⇒
    /// 后端只能做全国范围解析。
    ///
    /// 两侧都断言，这条用例才说得清 bug 是什么：默认门会丢掉坐标，放宽后的门不会。
    /// 只断言「放宽后能拿到」的话，有人把 `freshness: 300` 顺手清理回默认值也不会红。
    func testAStaleDeviceSampleStillReachesTheParseRequest() async {
        let locationService = LocationService()
        locationService.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 22.5333, longitude: 113.9300),
            capturedAt: Date().addingTimeInterval(-60)
        )

        // 默认 15 秒门：这就是 N48 里坐标消失的那一步。
        XCTAssertNil(
            locationService.latestBackendSample(),
            "60 秒前的样本本来就该被默认门拒掉 —— 这条用例的前提没了，下面两条断言就不成立"
        )
        XCTAssertNotNil(
            locationService.latestBackendSample(freshness: 300),
            "放宽后的门必须放行，否则语音下单又回到「没有坐标」"
        )

        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse()]
        let wizard = makeWizard(
            stub: stub,
            // 与 `BlindBookingView` 里那一处逐字相同 —— 测的是那个调用点，不是一个理想化的闭包。
            currentCoordinate: { locationService.latestBackendSample(freshness: 300) }
        )

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertEqual(stub.parseRequests.count, 1)
        XCTAssertNotNil(
            stub.parseRequests[0].latitude,
            "站了一分钟就把坐标丢了，后端只能做全国范围解析 —— 这正是把人约到海南的那一步"
        )
        XCTAssertNotNil(stub.parseRequests[0].longitude)
    }

    /// 坐标必须**成对**送，且只送后端坐标系的真实采样。
    ///
    /// 只送一半后端返 400；而演示坐标混进来会把人约到另一座城市 —— 后者由
    /// `LocatedCoordinate.system` 挡着，Demo / UI 测试的定位路径压根产不出设备采样。
    func testNoCoordinateIsSentWhenThereIsNoRealDeviceSample() async {
        let locationService = LocationService()
        // 真机上 Core Location 几毫秒就回调，裸 `LocationService()` 的「无定位」活不过一次 runloop。
        locationService.simulateMissingDeviceLocationForTesting()

        let stub = VoiceOrderAPIClientStub()
        stub.parseOrderResponses = [Self.parseResponse()]
        let wizard = makeWizard(
            stub: stub,
            currentCoordinate: { locationService.latestBackendSample(freshness: 300) }
        )

        await wizard.submitTranscript("明天早上八点从人民广场出发跑一个小时")

        XCTAssertNil(stub.parseRequests[0].latitude, "没有真实采样就一个坐标都不许编")
        XCTAssertNil(stub.parseRequests[0].longitude)
    }

    // MARK: - Mock 的候选消歧

    /// 候选**只在同一个关键词命中 ≥2 条时**产生，而且必须带坐标才有。
    ///
    /// 后者与后端一致：没有坐标就算不出 `distanceMeters`，而缺了距离的同名列表更难选。
    func testMockReturnsCandidatesOnlyForSameNamePlacesWithCoordinates() async throws {
        let client = MockAPIClient()
        client.syncSessionFromAppState(token: "mock_jwt_token_test", role: .blind)

        let withCoordinates: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(
                transcript: "明天早上八点从万象城出发跑一个小时",
                latitude: 22.5300, longitude: 113.9400
            )
        )
        XCTAssertGreaterThanOrEqual(
            withCoordinates.candidates?.count ?? 0, 2,
            "「万象城」在表里有三条同名，带了坐标就该给候选"
        )
        XCTAssertEqual(withCoordinates.startCandidatesToDisambiguate?.count, 3)

        let withoutCoordinates: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(transcript: "明天早上八点从万象城出发跑一个小时")
        )
        XCTAssertEqual(
            withoutCoordinates.candidates, [],
            "没有坐标就没有候选 —— 空数组不是 null，客户端按 count >= 2 判这一轮是不是消歧轮"
        )

        let unique: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(
                transcript: "明天早上八点从人民广场出发跑一个小时",
                latitude: 31.2304, longitude: 121.4737
            )
        )
        XCTAssertEqual(unique.candidates, [], "只有一个同名地点时不该问用户选哪个，那是纯粹多一轮")
    }

    /// 🔴 表里那条 catch-all `("公园", "本市公园")` **不许被当成同名兄弟**。
    ///
    /// 「中山公园」会同时命中 `中山公园` 和 `公园`，若按「所有命中的条目」收候选，
    /// 每个带「公园」二字的地名都会凭空多出一轮消歧 —— 而线上根本没有这回事
    /// （后端是同一个 query 搜出多个同名 POI，不是模糊包含）。
    func testMockCatchAllParkEntryNeverFabricatesCandidates() async throws {
        let client = MockAPIClient()
        client.syncSessionFromAppState(token: "mock_jwt_token_test", role: .blind)

        let response: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(
                transcript: "明天早上八点从中山公园出发跑一个小时",
                latitude: 31.2230, longitude: 121.4200
            )
        )

        XCTAssertEqual(response.candidates, [], "「中山公园」只有一个真实地点，不该被 catch-all 凑成两个")
        XCTAssertNil(response.startCandidatesToDisambiguate)
    }

    /// 候选播报文案的形状要和后端一致 —— **这段话是教用户说什么的**。
    /// Mock 里念得跟线上不一样，开发期练熟的说法上真机就不生效。
    func testMockCandidateTtsMatchesTheBackendShape() async throws {
        let client = MockAPIClient()
        client.syncSessionFromAppState(token: "mock_jwt_token_test", role: .blind)

        let response: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(
                transcript: "明天早上八点从万象城出发跑一个小时",
                latitude: 22.5300, longitude: 113.9400
            )
        )
        let tts = try XCTUnwrap(response.ttsText)

        XCTAssertTrue(tts.hasPrefix("找到3个地点，请说第几个。"), "开头照抄后端 buildCandidateTts：\(tts)")
        for ordinal in VoiceOrderWizard.ordinalWords {
            XCTAssertTrue(tts.contains(ordinal), "序数要逐个念出来，否则用户不知道能说什么：\(tts)")
        }
        XCTAssertTrue(tts.contains("距您"), "距离是同名地点唯一能靠听分辨的信息：\(tts)")
        // 最近的那条排第一 —— 深圳那家离请求坐标最近。
        XCTAssertEqual(response.candidates?.first?.adname, "南山区")
        XCTAssertEqual(response.address, response.candidates?.first?.readbackAddress,
                       "平铺 address 就是候选第一项，老客户端只读它也要能下单")
    }

    /// 「说了地名、但我们没查到」要报出来，而不是静默落回当前位置。
    ///
    /// 后端同批已经不再回落全国范围的正向编码（那条路曾把深圳说的地名解析到海南），
    /// 所以这个 `true` 会**变常见**；Mock 不跟上的话，开发期永远走不到那条播报分支。
    func testMockReportsAddressUnresolvedWhenTheSpanCannotBeGeocoded() async throws {
        let client = MockAPIClient()
        client.syncSessionFromAppState(token: "mock_jwt_token_test", role: .blind)

        let response: ParseVoiceOrderResponse = try await client.post(
            VoiceOrderEndpoint.parseOrder,
            body: ParseVoiceOrderRequest(
                transcript: "明天早上八点钟从阳光棕榈园跑",
                latitude: 22.5333, longitude: 113.9300
            )
        )

        XCTAssertEqual(response.addressUnresolved, true, "抽到了地名却查不到坐标，必须说得出「说了但没查到」")
        XCTAssertTrue(response.missing?.contains(.address) == true)
        XCTAssertEqual(response.candidates, [])
    }

    // MARK: - Helpers

    /// 构造一条 `/voice/parse` 响应。默认值 = 「什么都没抽到、不用重问、没有表态」，
    /// 每个用例只写它真正关心的那几项，读起来才看得出这条用例在测什么。
    private static func parseResponse(
        plannedStartTime: String? = nil,
        durationMinutes: Int? = nil,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        missing: [VoiceOrderMissingSlot] = [],
        needReask: Bool = false,
        ttsText: String = "好的，我记下了",
        endAddress: String? = nil,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil,
        hasGuideDog: Bool? = nil,
        userIntent: VoiceUserIntent? = nil,
        correctionTarget: VoiceCorrectionTarget? = nil,
        correctionUnclear: Bool = false,
        candidates: [AddressCandidate] = [],
        addressUnresolved: Bool = false
    ) -> ParseVoiceOrderResponse {
        ParseVoiceOrderResponse(
            plannedStartTime: plannedStartTime,
            durationMinutes: durationMinutes,
            address: address,
            latitude: latitude,
            longitude: longitude,
            missing: missing,
            needReask: needReask,
            ttsText: ttsText,
            endAddress: endAddress,
            endLatitude: endLatitude,
            endLongitude: endLongitude,
            endAddressUnresolved: endAddress == nil ? nil : (endLatitude == nil),
            hasGuideDog: hasGuideDog,
            userIntent: userIntent,
            correctionTarget: correctionTarget,
            correctionUnclear: correctionUnclear,
            candidates: candidates,
            addressUnresolved: addressUnresolved
        )
    }

    /// 一条候选。默认坐标落在深圳南山区 —— 就是用户报这个 bug 的那片地方。
    private static func candidate(
        _ name: String,
        address: String? = nil,
        latitude: Double = 22.5333,
        longitude: Double = 113.9300
    ) -> AddressCandidate {
        AddressCandidate(
            name: name, address: address, adname: "南山区", business: nil,
            distanceMeters: 400, latitude: latitude, longitude: longitude
        )
    }

    private static func date(hoursFromNow hours: Double) -> Date {
        Date().addingTimeInterval(3600 * hours)
    }

    private static func backendTime(hoursFromNow hours: Double) -> String {
        DateFormatter.aidRunBackendLocalDateTime.string(from: date(hoursFromNow: hours))
    }

    private func makeWizard(
        stub: VoiceOrderAPIClientStub,
        bookingViewModel: BlindBookingViewModel? = nil,
        speechService: SpeechService = SpeechService(),
        startingAt step: VoiceOrderWizard.Step = .freeform,
        didCaptureStartTime: Bool = false,
        currentCoordinate: (() -> LocatedCoordinate?)? = nil
    ) -> VoiceOrderWizard {
        let bookingViewModel = bookingViewModel ?? BlindBookingViewModel()
        let wizard = VoiceOrderWizard()
        wizard.configure(
            bookingViewModel: bookingViewModel,
            speechService: speechService,
            // 同上：wizard 侧是 weak，这个临时对象等于传 nil。这批用例全走 `startForTesting(at:)`，
            // 不经过真正的开麦路径，所以不需要一个活着的语音服务。
            speechInputService: SpeechInputService(), // guard:allow weak-temporary
            apiClient: stub,
            currentCoordinate: currentCoordinate
        )
        wizard.startForTesting(at: step, didCaptureStartTime: didCaptureStartTime)
        return wizard
    }
}

// MARK: - Stub

private final class VoiceOrderAPIClientStub: APIClientProtocol, @unchecked Sendable {
    enum StubError: Error { case exhausted, unexpectedType }

    var resolveAddressResponses: [ResolveAddressResponse] = []
    var parseOrderResponses: [ParseVoiceOrderResponse] = []
    var parseSlotResponses: [ParseSlotResponse] = []
    var error: APIError?
    /// 在请求发出的那一刻回调。用来观察「等待期间用户听到了什么」—— 这件事只在往返途中成立，
    /// 等 `submitTranscript` 返回时早被读回覆盖了。
    var onRequest: (() -> Void)?
    private(set) var paths: [String] = []
    private(set) var requestedSlotFields: [VoiceSlotField] = []
    /// 发往 `/voice/parse` 的请求体。**跨轮修正的全部前提是 `current` 真的被发出去了**，
    /// 只看 `paths` 验不出来 —— 路径对、body 里没有 `current` 的话后端一个新字段都不会给。
    private(set) var parseRequests: [ParseVoiceOrderRequest] = []

    func request<T: Decodable>(
        method: HTTPMethod,
        path: String,
        query: [String: String]?,
        body: (any Encodable & Sendable)?,
        requiresAuth: Bool
    ) async throws -> T {
        paths.append(path)
        onRequest?()
        if let error { throw error }
        switch path {
        case VoiceOrderEndpoint.parseOrder:
            if let parsed = Self.decode(ParseVoiceOrderRequest.self, from: body) {
                parseRequests.append(parsed)
            }
            guard !parseOrderResponses.isEmpty else { throw StubError.exhausted }
            guard let typed = parseOrderResponses.removeFirst() as? T else {
                throw StubError.unexpectedType
            }
            return typed
        case VoiceOrderEndpoint.resolveAddress:
            guard !resolveAddressResponses.isEmpty else { throw StubError.exhausted }
            guard let typed = resolveAddressResponses.removeFirst() as? T else {
                throw StubError.unexpectedType
            }
            return typed
        case VoiceOrderEndpoint.parseSlot:
            // 整句轮 2026-08-04 起走 `/voice/parse` 单请求，`parse-slot` 只剩定点修改轮在用 ——
            // 那是串行的一轮一个，按队列取就够，不会串台（此前的 by-field 字典已随之删除）。
            if let field = Self.slotField(from: body) { requestedSlotFields.append(field) }
            guard !parseSlotResponses.isEmpty else { throw StubError.exhausted }
            guard let typed = parseSlotResponses.removeFirst() as? T else {
                throw StubError.unexpectedType
            }
            return typed
        default:
            throw StubError.unexpectedType
        }
    }

    func upload<T: Decodable>(
        path: String,
        query: [String: String]?,
        fields: [String: String]?,
        files: [MultipartFile],
        requiresAuth: Bool
    ) async throws -> T {
        throw StubError.unexpectedType
    }

    private static func slotField(from body: (any Encodable & Sendable)?) -> VoiceSlotField? {
        decode(ParseSlotRequest.self, from: body)?.field
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from body: (any Encodable & Sendable)?
    ) -> T? {
        guard let body,
              let data = try? JSONEncoder().encode(ParseSlotRequestBox(body: body)) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private struct ParseSlotRequestBox: Encodable {
        let body: any Encodable & Sendable
        func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
    }
}
