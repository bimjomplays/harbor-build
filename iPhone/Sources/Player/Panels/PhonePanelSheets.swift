import SwiftUI

/// The phone player's panel sheets: audio, speed & sleep, quality and stats. Subtitles,
/// X-Ray and Sources are in their own files. Each draws over the shared models the TV's panels use;
/// what a press does to the session is the TV's too (speed closes the panel, a pick of audio stays).

// MARK: Audio

/// PlayerAudioPanel for a finger: the tracks (a press plays it and keeps the language for the show) and
/// the sync offset. The position is the engine's own and is not touched.
struct PhoneAudioSheet: View {
    @ObservedObject var session: PlayerSession
    let onClose: () -> Void
    @StateObject private var model: PhoneAudioModel

    init(session: PlayerSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _model = StateObject(wrappedValue: PhoneAudioModel(controller: session.controller, delay: session.audioDelay,
                                                           onDelay: { [weak session] in session?.audioDelay = $0 }))
    }

    var body: some View {
        PhoneSheetFrame(panel: .audio, line: model.headerLine(title: session.shownTitle), onClose: onClose) {
            if model.tracks.isEmpty {
                PhoneNote(text: T("This file has one audio track."))
                    .accessibilityIdentifier("panel-audio-empty")
            }
            ForEach(model.tracks, id: \.id) { t in
                let l = PhoneTrackText.lines(t)
                PhonePanelRow(id: "panel-audio-\(t.id)", icon: "waveform", title: l.head, detail: l.detail, selected: t.selected) {
                    model.select(t)
                }
            }
            PhoneSectionLabel(text: T("Sync Offset"))
            // BpAudioLane: AVPlayer can't offset audio, so the cells are disabled there.
            Group {
                HStack {
                    Text(verbatim: model.delayLabel)
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .body)).monospacedDigit().foregroundStyle(BP.ink)
                        .accessibilityIdentifier("panel-audio-delay-value")
                    Spacer()
                }
                PhoneFlowRow(spacing: 8, lineSpacing: 8) {
                    ForEach(PhoneAudioModel.delaySteps, id: \.self) { step in
                        PhoneOptionChip(id: "panel-audio-delay-" + String(format: "%+.1f", step),
                                        title: String(format: "%+.1fs", step)) { model.nudge(by: step) }
                    }
                    PhoneOptionChip(id: "panel-audio-delay-reset", title: T("Reset")) { model.setDelay(0) }
                }
            }
            .disabled(model.delayLocked)
            .opacity(model.delayLocked ? 0.45 : 1)
        }
        .task(id: model.engineKey) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                model.use(session.controller)
            }
        }
    }
}

// MARK: Speed & sleep

/// speed-menu.tsx on a phone: the playback speeds (a press sets it and closes the sheet), "Set as default
/// speed", and the sleep timer (a press arms it and the countdown runs in the row).
struct PhoneSpeedSheet: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject private var sleep = SleepTimer.shared
    @ObservedObject private var settings = SettingsBridge.shared
    let onClose: () -> Void

    private var speeds: [Double] { PhoneSpeedSleep.speeds(custom: settings.slice.customPlaybackSpeeds) }
    private var sleepRows: [PhoneSpeedSleep.SleepRow] {
        PhoneSpeedSleep.sleepRows(minutes: PhoneSpeedSleep.sleepMinutes(custom: settings.slice.customSleepMinutes))
    }

    var body: some View {
        PhoneSheetFrame(panel: .speed, line: PhoneSpeedSleep.face(rate: session.rate, isLive: session.isLive, sleepFace: sleep.faceLabel), onClose: onClose) {
            if !session.isLive {
                PhoneSectionLabel(text: T("Speed"))
                PhoneFlowRow(spacing: 8, lineSpacing: 8) {
                    ForEach(speeds, id: \.self) { v in
                        PhoneOptionChip(id: "panel-speed-" + String(format: "%g", v), title: String(format: "%g×", v),
                                        selected: PhoneSpeedSleep.isRate(v, session.rate), label: PhoneSpeedSleep.rateLabel(v)) {
                            session.setRate(v)
                            onClose()
                        }
                    }
                }
                let isDefault: Bool = PhoneSpeedSleep.isRate(settings.slice.defaultPlaybackSpeed ?? 1, session.rate)
                PhonePanelRow(id: "panel-speed-default", icon: "star", title: T("Set as default speed"),
                              detail: PhoneSpeedSleep.rateLabel(session.rate), selected: isDefault) {
                    let now: Double = session.rate
                    Task { try? await SettingsBridge.shared.patch(["defaultPlaybackSpeed": .number(now)]) }
                }
            }
            PhoneSectionLabel(text: T("Sleep timer"))
            ForEach(Array(sleepRows.enumerated()), id: \.offset) { i, row in
                let on: Bool = PhoneSpeedSleep.isSelected(sleep.mode, row.mode)
                PhonePanelRow(id: "panel-sleep-\(i)", icon: row.icon, title: row.label,
                              detail: on && row.isMinutes ? sleep.remainingSec.map { T("%@ left", SleepTimer.formatRemaining($0)) } : nil,
                              selected: on) {
                    sleep.set(row.mode)
                }
            }
            if sleep.isActive {
                PhonePanelRow(id: "panel-sleep-cancel", icon: "xmark.circle", title: T("Cancel timer")) { sleep.clear() }
            }
        }
    }
}

// MARK: Quality

/// HomeServerQualityPanel for a finger: the qualities the home server offers for this title. A press
/// swaps the stream in place (the server gets the spot and play state); the one playing just closes.
struct PhoneQualitySheet: View {
    @ObservedObject var session: PlayerSession
    let home: HomeServerSession
    let onClose: () -> Void
    @StateObject private var model = PhoneQualityModel()

    var body: some View {
        PhoneSheetFrame(panel: .quality, line: T("Switch quality without losing your place."), onClose: onClose) {
            if !model.loaded {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier("panel-quality-loading")
            }
            ForEach(model.options) { o in
                PhonePanelRow(id: "panel-quality-\(o.id)", icon: "dial.medium", title: o.label,
                              selected: o.id == model.current, busy: model.switching == o.id) { choose(o.id) }
            }
            if let e = model.error { PhoneNote(text: e, tone: BP.danger).accessibilityIdentifier("panel-quality-error") }
        }
        .task { await model.load(home) }
    }

    private func choose(_ id: String) {
        switch model.press(id) {
        case .close: onClose()
        case .busy: break
        case .switchTo(let next):
            let at: Double = session.clock.snap.position
            let playing: Bool = !session.isPaused
            Task {
                guard let r = await model.switchTo(next, home, positionSec: at, playing: playing) else { return }
                // PlayerScreen: the new stream opens paused when this one was.
                session.pausedAfterSwitch = session.clock.snap.paused
                session.switchStream(to: r.url, headers: r.headers, subtitles: r.subtitles, replacesSrc: true)
            }
        }
    }
}

// MARK: Stats

/// The player's numbers: the engine, the source host, the state and the picture and output the engine reports.
struct PhoneStatsSheet: View {
    @ObservedObject var session: PlayerSession
    let onClose: () -> Void

    var body: some View {
        PhoneSheetFrame(panel: .stats, line: session.shownTitle, onClose: onClose) {
            PlayerClockReader(session.clock) { c in
                let rows = PhoneStats.rows(engine: session.engine, url: session.playURL, status: session.status,
                                           position: c.snap.position, duration: c.snap.duration, buffered: c.buffered, rate: session.rate)
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: r.label).font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkMuted)
                            Spacer(minLength: 12)
                            Text(verbatim: r.value).font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline)).monospacedDigit()
                                .foregroundStyle(BP.ink).multilineTextAlignment(.trailing)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("panel-stats-row-\(i)")
                    }
                }
            }
            let log: [String] = PhoneStats.log(session.status)
            if !log.isEmpty {
                PhoneSectionLabel(text: T("Engine log"))
                Text(verbatim: log.joined(separator: "\n"))
                    .font(.caption2.monospaced()).foregroundStyle(BP.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("panel-stats-log")
            }
        }
    }
}
