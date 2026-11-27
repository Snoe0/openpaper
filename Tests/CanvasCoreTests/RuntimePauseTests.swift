import XCTest

@MainActor
final class RuntimePauseTests: XCTestCase {
    private let spinner = """
    <style>@keyframes spin { to { transform: rotate(360deg) } } #a { animation: spin 10s linear infinite }</style>
    <div id="a">a</div><x-spinner id="s"></x-spinner>
    """
    private let spinnerComponent = [
        "spinner": "<style>@keyframes s { to { opacity: 0 } } i { animation: s 10s linear infinite }</style><i>s</i>",
    ]
    private let documentAnimationTime = "return document.getElementById('a').getAnimations()[0].currentTime"
    private let shadowAnimationTime =
        "return document.getElementById('s').shadowRoot.querySelector('i').getAnimations()[0].currentTime"
    /// A Web Animation (not CSS) inside a shadow root: only `Animation.pause()` can freeze it.
    private let startShadowScriptAnimation = """
        const target = document.getElementById('s').shadowRoot.querySelector('i')
        window.scripted = target.animate([{ color: 'red' }, { color: 'blue' }], { duration: 10000, iterations: Infinity })
        """
    private let shadowScriptAnimationTime = "return window.scripted.currentTime"

    func testPauseFreezesAnimationsIncludingShadowRootsUntilResume() async throws {
        let page = try await RuntimePage.open(body: spinner, components: spinnerComponent)
        try await page.js(startShadowScriptAnimation)
        try await page.sleep(for: .milliseconds(100))

        try await page.js("Canvas.pause()")
        try await page.sleep(for: .milliseconds(50))
        let frozen = try await page.double(documentAnimationTime)
        let frozenShadow = try await page.double(shadowAnimationTime)
        let frozenScripted = try await page.double(shadowScriptAnimationTime)
        let paused = try await page.bool("return Canvas.isPaused && document.documentElement.classList.contains('canvas-paused')")
        try await page.sleep(for: .milliseconds(250))
        let stillFrozen = try await page.double(documentAnimationTime)
        let stillFrozenShadow = try await page.double(shadowAnimationTime)
        let stillFrozenScripted = try await page.double(shadowScriptAnimationTime)
        XCTAssertTrue(paused)
        XCTAssertEqual(stillFrozenScripted, frozenScripted, accuracy: 1)
        XCTAssertEqual(stillFrozen, frozen, accuracy: 1)
        XCTAssertEqual(stillFrozenShadow, frozenShadow, accuracy: 1)

        try await page.js("Canvas.resume()")
        try await page.sleep(for: .milliseconds(250))
        let resumed = try await page.bool("return !Canvas.isPaused && !document.documentElement.classList.contains('canvas-paused')")
        let advanced = try await page.double(documentAnimationTime)
        let advancedShadow = try await page.double(shadowAnimationTime)
        let advancedScripted = try await page.double(shadowScriptAnimationTime)
        XCTAssertTrue(resumed)
        XCTAssertGreaterThan(advancedScripted, frozenScripted + 100)
        XCTAssertGreaterThan(advanced, frozen + 100)
        XCTAssertGreaterThan(advancedShadow, frozenShadow + 100)
    }

    func testAnimationStartedWhilePausedInPageCreatedShadowRootStaysFrozenUntilResume() async throws {
        let page = try await RuntimePage.open(body: """
            <div id="host"></div>
            <script>
              document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML =
                '<style>@keyframes fade { to { opacity: 0 } } .fading { animation: fade 10s linear infinite }</style><i>i</i>'
            </script>
            """)
        let target = "document.getElementById('host').shadowRoot.querySelector('i')"

        try await assertAnimationStartedWhilePausedStaysFrozenUntilResume(on: target, in: page)
    }

    func testAnimationStartedWhilePausedInTheDocumentStaysFrozenUntilResume() async throws {
        let page = try await RuntimePage.open(body: """
            <style>@keyframes fade { to { opacity: 0 } } .fading { animation: fade 10s linear infinite }</style>
            <p id="plain">p</p>
            """)

        try await assertAnimationStartedWhilePausedStaysFrozenUntilResume(on: "document.getElementById('plain')", in: page)
    }

    private func assertAnimationStartedWhilePausedStaysFrozenUntilResume(
        on target: String,
        in page: RuntimePage,
        line: UInt = #line
    ) async throws {
        let time = "return \(target).getAnimations()[0].currentTime"
        try await page.js("Canvas.pause(); \(target).classList.add('fading')")
        try await page.sleep(for: .milliseconds(300))
        let whilePaused = try await page.double(time)

        try await page.js("Canvas.resume()")
        try await page.sleep(for: .milliseconds(250))
        let afterResume = try await page.double(time)

        XCTAssertEqual(whilePaused, 0, accuracy: 1, line: line)
        XCTAssertGreaterThan(afterResume, 100, line: line)
    }

    func testRestartWhilePausedKeepsFinishedAnimationsPausedUntilResume() async throws {
        let page = try await RuntimePage.open(body: #"<p id="p">p</p>"#)
        try await page.js("window.short = document.getElementById('p').animate([{ color: 'red' }, { color: 'blue' }], { duration: 200, fill: 'forwards' })")
        let finished = try await page.waitUntil("short.playState === 'finished'")
        XCTAssertTrue(finished)

        try await page.js("Canvas.pause(); Canvas.restart()")
        try await page.sleep(for: .milliseconds(150))
        let whilePaused = try await page.double("return short.currentTime")
        let playState = try await page.string("return short.playState")
        XCTAssertEqual(whilePaused, 0, accuracy: 1)
        XCTAssertEqual(playState, "paused")

        try await page.js("Canvas.resume()")
        try await page.sleep(for: .milliseconds(100))
        let afterResume = try await page.double("return short.currentTime")
        XCTAssertGreaterThan(afterResume, 30)
    }

    func testTimerCallbacksRunWithWindowAsThisIncludingDeferredOnes() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("""
            window.receivers = []
            const record = function () { 'use strict'; receivers.push(this === window) }
            setTimeout(record, 0)
            await new Promise(resolve => setTimeout(resolve, 20))
            setTimeout(record, 10)
            Canvas.pause()
        """)
        try await page.sleep(for: .milliseconds(100))
        try await page.js("Canvas.resume()")
        let ranBoth = try await page.waitUntil("receivers.length === 2")

        let receivers = try await page.string("return receivers.join()")
        XCTAssertTrue(ranBoth)
        XCTAssertEqual(receivers, "true,true")
    }

    func testClearIntervalDropsAnAlreadyDeferredTick() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("window.ticks = 0; window.timer = setInterval(() => window.ticks++, 20); Canvas.pause()")
        try await page.sleep(for: .milliseconds(150))
        try await page.js("clearInterval(timer); Canvas.resume()")
        try await page.sleep(for: .milliseconds(150))

        let ticks = try await page.double("return window.ticks")
        XCTAssertEqual(ticks, 0)
    }

    func testRestartRewindsMedia() async throws {
        let page = try await RuntimePage.open(body: #"<audio id="a" loop src="\#(silentWAVDataURL())"></audio>"#)
        try await page.js("await document.getElementById('a').play()")
        let advanced = try await page.waitUntil("document.getElementById('a').currentTime > 0.3")
        XCTAssertTrue(advanced)

        let rewound = try await page.double("Canvas.restart(); return document.getElementById('a').currentTime")
        XCTAssertLessThan(rewound, 0.1)
    }

    func testResumeLeavesDisconnectedMediaAndAnimationsAlone() async throws {
        let page = try await RuntimePage.open(body: #"<audio id="a" loop src="\#(silentWAVDataURL())"></audio><p id="p">p</p>"#)
        try await page.js("""
            await document.getElementById('a').play()
            window.detachedAnimation = document.getElementById('p').animate([{ color: 'red' }, { color: 'blue' }], { duration: 10000 })
        """)

        try await page.js("""
            Canvas.pause()
            window.detachedAudio = document.getElementById('a')
            detachedAudio.remove()
            document.getElementById('p').remove()
            Canvas.resume()
        """)
        try await page.sleep(for: .milliseconds(150))

        let audioPaused = try await page.bool("return detachedAudio.paused")
        let animationState = try await page.string("return detachedAnimation.playState")
        XCTAssertTrue(audioPaused)
        XCTAssertEqual(animationState, "paused")
    }

    func testRestartLeavesDeliberatelyPausedAnimationsPaused() async throws {
        let page = try await RuntimePage.open(body: #"<p id="p">p</p>"#)
        try await page.js("""
            window.held = document.getElementById('p').animate([{ color: 'red' }, { color: 'blue' }], { duration: 10000 })
            await new Promise(resolve => setTimeout(resolve, 100))
            held.pause()
        """)

        try await page.js("Canvas.restart()")
        try await page.sleep(for: .milliseconds(150))

        let playState = try await page.string("return held.playState")
        let time = try await page.double("return held.currentTime")
        XCTAssertEqual(playState, "paused")
        XCTAssertEqual(time, 0, accuracy: 1)
    }

    func testRestartReplaysEndedMediaFromTheStart() async throws {
        let page = try await RuntimePage.open(body: #"<audio id="a" src="\#(silentWAVDataURL(seconds: 0.3))"></audio>"#)
        try await page.js("await document.getElementById('a').play()")
        let ended = try await page.waitUntil("document.getElementById('a').ended")
        XCTAssertTrue(ended)

        try await page.js("Canvas.restart()")

        let replaying = try await page.waitUntil("!document.getElementById('a').paused && !document.getElementById('a').ended")
        XCTAssertTrue(replaying)
    }

    func testMediaInsideAShadowRootPausesAndResumes() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-player id="p"></x-player>"#,
            components: ["player": #"<audio loop src="\#(silentWAVDataURL())"></audio>"#]
        )
        let audio = "document.getElementById('p').shadowRoot.querySelector('audio')"
        try await page.js("await \(audio).play()")

        try await page.js("Canvas.pause()")
        let paused = try await page.bool("return \(audio).paused")
        try await page.js("Canvas.resume()")
        let resumed = try await page.waitUntil("!\(audio).paused")

        XCTAssertTrue(paused)
        XCTAssertTrue(resumed)
    }

    func testThrowingDeferredCallbackIsReportedAndTheRestStillRun() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("""
            window.ran = []
            Canvas.pause()
            setTimeout(() => { throw new Error('deferred boom') }, 10)
            setTimeout(() => ran.push('timer'), 10)
            requestAnimationFrame(() => { throw new Error('frame boom') })
            requestAnimationFrame(() => ran.push('frame'))
        """)
        try await page.sleep(for: .milliseconds(150))
        try await page.js("Canvas.resume()")

        let bothRan = try await page.waitUntil("ran.length === 2")
        let reported = try await page.waitUntil("""
            ['deferred boom', 'frame boom'].every(text => Canvas.logs.some(entry => entry.level === 'error' && entry.message.includes(text)))
            """)
        XCTAssertTrue(bothRan)
        XCTAssertTrue(reported)
    }

    func testSetTimeoutAcceptsAStringHandler() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("setTimeout('window.fromString = 42', 0)")

        let ran = try await page.waitUntil("window.fromString === 42")
        XCTAssertTrue(ran)
    }

    func testAnimationFrameRequestedWhilePausedRunsOnlyAfterResume() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("Canvas.pause(); window.frameCount = 0; requestAnimationFrame(() => window.frameCount++)")
        try await page.sleep(for: .milliseconds(250))
        let whilePaused = try await page.double("return window.frameCount")
        XCTAssertEqual(whilePaused, 0)

        try await page.js("Canvas.resume()")
        let ran = try await page.waitUntil("window.frameCount === 1")
        XCTAssertTrue(ran)
    }

    func testTimeoutFiringDuringPauseIsDeferredUntilResume() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("window.fired = 0; setTimeout(() => window.fired++, 20); Canvas.pause()")
        try await page.sleep(for: .milliseconds(250))
        let whilePaused = try await page.double("return window.fired")
        XCTAssertEqual(whilePaused, 0)

        try await page.js("Canvas.resume()")
        let fired = try await page.waitUntil("window.fired === 1")
        XCTAssertTrue(fired)
    }

    func testIntervalDoesNotTickWhilePausedAndKeepsItsRemainingTimeOnResume() async throws {
        let page = try await RuntimePage.open(body: "")

        // Ticks at 1000 and 2000 ms would fall inside the pause; none may come due at resume.
        try await page.js("window.ticks = 0; window.timer = setInterval(() => window.ticks++, 1000); Canvas.pause()")
        try await page.sleep(for: .milliseconds(2500))
        let whilePaused = try await page.double("return window.ticks")
        XCTAssertEqual(whilePaused, 0)

        let rightAfterResume = try await page.double("""
            Canvas.resume()
            await new Promise(resolve => setTimeout(resolve, 0))
            return window.ticks
        """)
        XCTAssertEqual(rightAfterResume, 0)
        let ticksAgain = try await page.waitUntil("window.ticks >= 2")
        XCTAssertTrue(ticksAgain)
    }

    func testTimeoutKeepsItsRemainingTimeAcrossAPause() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("window.startedAt = performance.now(); setTimeout(() => window.firedAt = performance.now(), 3000)")
        try await page.sleep(for: .milliseconds(1000))
        try await page.js("window.pausedAt = performance.now(); Canvas.pause()")
        try await page.sleep(for: .milliseconds(1500))
        let firedWhilePaused = try await page.bool("return 'firedAt' in window")
        try await page.js("window.resumedAt = performance.now(); Canvas.resume()")
        let fired = try await page.waitUntil("'firedAt' in window")

        let afterResume = try await page.double("return firedAt - resumedAt")
        let activeTime = try await page.double("return (pausedAt - startedAt) + (firedAt - resumedAt)")
        XCTAssertFalse(firedWhilePaused)
        XCTAssertTrue(fired)
        XCTAssertGreaterThanOrEqual(afterResume, 1500, "the ~2 s left at pause must still be waited out after resume")
        XCTAssertGreaterThanOrEqual(activeTime, 2950, "time spent paused must not count towards the delay")
    }

    func testClearTimeoutDuringPauseCancelsATimeoutStartedBeforeThePause() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("window.fired = 0; window.timer = setTimeout(() => window.fired++, 200); Canvas.pause()")
        try await page.sleep(for: .milliseconds(300))
        try await page.js("clearTimeout(timer); Canvas.resume()")
        try await page.sleep(for: .milliseconds(400))

        let fired = try await page.double("return window.fired")
        XCTAssertEqual(fired, 0)
    }

    func testAnimationFrameParkedDuringPauseGetsTheResumeFrameTimestamp() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("Canvas.pause(); requestAnimationFrame(time => window.stamp = time)")
        try await page.sleep(for: .milliseconds(300))
        try await page.js("window.resumedAt = performance.now(); Canvas.resume()")
        let ran = try await page.waitUntil("'stamp' in window")

        let lag = try await page.double("return resumedAt - stamp")
        XCTAssertTrue(ran)
        XCTAssertLessThan(lag, 50, "the timestamp must come from a frame after resume, not one during the pause")
    }

    func testRestartReplaysFinishedCSSAnimationsWithoutFillIncludingShadowRoots() async throws {
        let page = try await RuntimePage.open(
            body: """
            <style>@keyframes fade { from { opacity: 0 } } #b { animation: fade .2s }</style>
            <div id="b">b</div><x-flash id="f"></x-flash>
            """,
            components: ["flash": "<style>@keyframes f { from { opacity: 0 } } i { animation: f .2s }</style><i>f</i>"]
        )
        let document = "document.getElementById('b')"
        let shadow = "document.getElementById('f').shadowRoot.querySelector('i')"
        let finished = try await page.waitUntil("\(document).getAnimations().length === 0 && \(shadow).getAnimations().length === 0")
        XCTAssertTrue(finished)

        let replaying = try await page.string("""
            Canvas.restart()
            return [\(document), \(shadow)].map(el => el.getAnimations().map(a => a.playState + ':' + (a.currentTime < 100)).join()).join('|')
        """)
        XCTAssertEqual(replaying, "running:true|running:true")
    }

    func testRestartReplaysFinishedScriptedAnimationsWithoutFill() async throws {
        let page = try await RuntimePage.open(body: #"<p id="p">p</p>"#)
        try await page.js("window.flash = document.getElementById('p').animate([{ opacity: 0 }, { opacity: 1 }], 200)")
        let finished = try await page.waitUntil("flash.playState === 'finished'")
        XCTAssertTrue(finished)

        let replaying = try await page.string("Canvas.restart(); return flash.playState + ':' + (flash.currentTime < 100)")
        XCTAssertEqual(replaying, "running:true")
    }

    func testRestartReplaysOnlyTheLatestRunOfARepeatedOneShot() async throws {
        let page = try await RuntimePage.open(body: #"<p id="p">p</p>"#)
        try await page.js("""
            const p = document.getElementById('p')
            window.runs = []
            for (let i = 0; i < 100; i++) {
              const run = p.animate([{ opacity: 0 }, { opacity: 1 }], 20)
              runs.push(run)
              await run.finished
            }
        """)
        try await page.sleep(for: .milliseconds(200))

        let replayed = try await page.double("Canvas.restart(); return runs.filter(run => run.playState === 'running').length")
        let latestReplayed = try await page.bool("return runs[runs.length - 1].playState === 'running'")
        XCTAssertGreaterThanOrEqual(replayed, 1)
        XCTAssertLessThanOrEqual(replayed, 2, "earlier finished runs of the same one-shot must not all replay at once")
        XCTAssertTrue(latestReplayed)
    }

    func testRestartReplaysAtMostABoundedNumberOfFinishedScriptedAnimations() async throws {
        let page = try await RuntimePage.open(body: #"<div id="box"></div>"#)
        try await page.js("""
            const box = document.getElementById('box')
            window.runs = Array.from({ length: 300 }, () => box.appendChild(document.createElement('i')).animate([{ opacity: 0 }, { opacity: 1 }], 20))
            await Promise.all(runs.map(run => run.finished))
        """)

        let replayed = try await page.double("Canvas.restart(); return runs.filter(run => run.playState === 'running').length")
        let newestReplayed = try await page.bool("return runs[runs.length - 1].playState === 'running'")
        XCTAssertGreaterThan(replayed, 0)
        XCTAssertLessThanOrEqual(replayed, 200)
        XCTAssertTrue(newestReplayed)
    }

    func testRestartWhilePausedHoldsReplayedAnimationsAtTheStartUntilResume() async throws {
        let page = try await RuntimePage.open(body: """
            <style>@keyframes fade { from { opacity: 0 } } #b { animation: fade .4s }</style>
            <div id="b">b</div><p id="p">p</p>
            """)
        let css = "document.getElementById('b')"
        try await page.js("window.flash = document.getElementById('p').animate([{ opacity: 0 }, { opacity: 1 }], 400)")
        let finished = try await page.waitUntil("flash.playState === 'finished' && \(css).getAnimations().length === 0")
        XCTAssertTrue(finished)

        try await page.js("Canvas.pause(); Canvas.restart()")
        try await page.sleep(for: .milliseconds(300))
        let held = try await page.string("""
            const [cssAnimation] = \(css).getAnimations()
            return [cssAnimation, flash].map(a => a && a.playState + ':' + Math.round(a.currentTime)).join()
        """)
        XCTAssertEqual(held, "paused:0,paused:0")

        try await page.js("Canvas.resume()")
        let ranToTheEnd = try await page.waitUntil("flash.playState === 'finished' && \(css).getAnimations().length === 0")
        XCTAssertTrue(ranToTheEnd)
    }

    func testScriptedAnimationStartedWhilePausedStaysFrozenUntilResume() async throws {
        let page = try await RuntimePage.open(body: #"<p id="p">p</p>"#)

        try await page.js("Canvas.pause(); window.late = document.getElementById('p').animate([{ opacity: 0 }, { opacity: 1 }], 10000)")
        try await page.sleep(for: .milliseconds(250))
        let held = try await page.string("return late.playState + ':' + Math.round(late.currentTime)")
        XCTAssertEqual(held, "paused:0")

        try await page.js("Canvas.resume()")
        try await page.sleep(for: .milliseconds(250))
        let advanced = try await page.double("return late.currentTime")
        XCTAssertGreaterThan(advanced, 100)
    }

    func testMediaStartedWhilePausedStaysPausedUntilResumeIncludingShadowRoots() async throws {
        let page = try await RuntimePage.open(
            body: #"<audio id="a" loop src="\#(silentWAVDataURL())"></audio><x-player id="p"></x-player>"#,
            components: ["player": #"<audio loop src="\#(silentWAVDataURL())"></audio>"#]
        )
        let both = "[document.getElementById('a'), document.getElementById('p').shadowRoot.querySelector('audio')]"

        try await page.js("Canvas.pause(); \(both).forEach(media => media.play().catch(() => {}))")
        try await page.sleep(for: .milliseconds(400))
        let held = try await page.bool("return \(both).every(media => media.paused && media.currentTime < 0.5)")
        XCTAssertTrue(held)

        try await page.js("Canvas.resume()")
        let playing = try await page.waitUntil("\(both).every(media => !media.paused && media.currentTime > 0)")
        XCTAssertTrue(playing)
    }

    func testShadowRootAttachedWhilePausedHasItsCSSAnimationsPausedUntilResume() async throws {
        let page = try await RuntimePage.open(body: #"<div id="host"></div>"#)
        let time = "return closedRoot.querySelector('i').getAnimations()[0].currentTime"

        try await page.js("""
            Canvas.pause()
            window.closedRoot = document.getElementById('host').attachShadow({ mode: 'closed' })
            closedRoot.innerHTML = '<style>@keyframes fade { to { opacity: 0 } } i { animation: fade 10s linear infinite }</style><i>i</i>'
        """)
        try await page.sleep(for: .milliseconds(300))
        let whilePaused = try await page.double(time)

        try await page.js("Canvas.resume()")
        try await page.sleep(for: .milliseconds(250))
        let afterResume = try await page.double(time)

        XCTAssertEqual(whilePaused, 0, accuracy: 1)
        XCTAssertGreaterThan(afterResume, 100)
    }

    func testCancelAndClearKeepWorkingIncludingForDeferredCallbacks() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("""
            window.ran = []
            const frame = requestAnimationFrame(() => ran.push('frame'))
            const timeout = setTimeout(() => ran.push('timeout'), 10)
            const interval = setInterval(() => ran.push('interval'), 10)
            cancelAnimationFrame(frame); clearTimeout(timeout); clearInterval(interval)
            window.idTypes = [frame, timeout, interval].map(id => typeof id).join()

            Canvas.pause()
            window.deferredFrame = requestAnimationFrame(() => ran.push('deferredFrame'))
            window.deferredTimeout = setTimeout(() => ran.push('deferredTimeout'), 10)
        """)
        try await page.sleep(for: .milliseconds(150))
        try await page.js("cancelAnimationFrame(deferredFrame); clearTimeout(deferredTimeout); Canvas.resume()")
        try await page.sleep(for: .milliseconds(150))

        let ran = try await page.string("return ran.join()")
        let idTypes = try await page.string("return idTypes")
        XCTAssertEqual(ran, "")
        XCTAssertEqual(idTypes, "number,number,number")
    }

    func testTimerCallbacksReceiveExtraArguments() async throws {
        let page = try await RuntimePage.open(body: "")

        let result = try await page.string("""
            return await new Promise(resolve => setTimeout((a, b) => resolve(a + b), 0, 'x', 'y'))
        """)
        XCTAssertEqual(result, "xy")
    }

    func testRestartRewindsAnimationsAndStaysPausedWhenPaused() async throws {
        let page = try await RuntimePage.open(body: spinner, components: spinnerComponent)
        try await page.sleep(for: .milliseconds(300))

        // Read in the same call as the restart: a separate round trip lets the animations run on under load.
        let rewound = try await page.double("Canvas.restart(); \(documentAnimationTime)")
        let rewoundShadow = try await page.double("Canvas.restart(); \(shadowAnimationTime)")
        XCTAssertLessThan(rewound, 100)
        XCTAssertLessThan(rewoundShadow, 100)

        try await page.sleep(for: .milliseconds(200))
        try await page.js("Canvas.pause(); Canvas.restart()")
        try await page.sleep(for: .milliseconds(150))
        let pausedAtStart = try await page.double(documentAnimationTime)
        let playState = try await page.string("return document.getAnimations()[0].playState")
        XCTAssertEqual(pausedAtStart, 0, accuracy: 1)
        XCTAssertEqual(playState, "paused")
    }

    func testPauseStopsPlayingMediaAndResumeRestartsOnlyThatMedia() async throws {
        let page = try await RuntimePage.open(body: """
            <audio id="playing" loop src="\(silentWAVDataURL())"></audio>
            <audio id="idle" loop src="\(silentWAVDataURL())"></audio>
            """)
        try await page.js("await document.getElementById('playing').play()")

        try await page.js("Canvas.pause()")
        let pausedByCanvas = try await page.bool("return document.getElementById('playing').paused")
        XCTAssertTrue(pausedByCanvas)

        try await page.js("Canvas.resume()")
        let resumed = try await page.waitUntil("!document.getElementById('playing').paused")
        let idleStillPaused = try await page.bool("return document.getElementById('idle').paused")
        XCTAssertTrue(resumed)
        XCTAssertTrue(idleStillPaused)
    }
}
