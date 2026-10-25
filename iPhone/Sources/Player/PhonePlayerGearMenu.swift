import SwiftUI
import UIKit

/// The HUD's gear: a UIKit button whose press opens the system's glass menu right over the player,
/// anchored to the button (Volume Boost, Playback Speed, the audio track, the subtitle, Advanced
/// Options). Each row with a list opens in place as a scrolling list with the current choice ticked,
/// under its own header. The rows are rebuilt on every open (`items`), so they read the player as it is.
struct PhonePlayerGearButton: UIViewRepresentable {
    /// The menu's rows, read when it opens.
    var items: () -> [UIMenuElement]
    /// The menu opened (true) or went (false).
    var onOpen: (Bool) -> Void
    var label: String
    /// Read out with the label: the audio track and the subtitle on.
    var value: String = ""

    func makeUIView(context: Context) -> GearButton {
        let b = GearButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "gearshape.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        b.configuration = config
        b.showsMenuAsPrimaryAction = true
        b.preferredMenuElementOrder = .fixed
        b.accessibilityIdentifier = "player-gear"
        b.setContentHuggingPriority(.required, for: .horizontal)
        update(b)
        return b
    }

    func updateUIView(_ b: GearButton, context: Context) { update(b) }

    private func update(_ b: GearButton) {
        b.onOpen = onOpen
        b.accessibilityLabel = label
        b.accessibilityValue = value
        let items = self.items
        b.menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in done(items()) }])
    }

    final class GearButton: UIButton {
        var onOpen: (Bool) -> Void = { _ in }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            onOpen(true)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            onOpen(false)
        }
    }
}

// MARK: the rows

extension PhonePlayerView {
    /// The gear menu, as Infuse lays it out: Volume Boost, Playback Speed, the audio track playing, the
    /// subtitle on (or None), then Advanced Options with the rest of Harbor's player: the sleep timer, the
    /// audio and subtitle sheets (sync, search, style), sources, quality, stats and X-Ray.
    func gearItems() -> [UIMenuElement] {
        let tracks: [MPVPlayerController.Track] = session.controller?.tracks() ?? []
        var rows: [UIMenuElement] = []
        if session.engine == .mpv || session.controller?.engineKind == .mpv || PlayerFixtures.standInEngine(for: session.playURL) {
            rows.append(boostMenu())
        }
        if !session.isLive { rows.append(speedMenu()) }
        rows.append(audioMenu(tracks))
        rows.append(subtitleMenu(tracks))
        rows.append(advancedMenu())
        return rows
    }

    private func boostMenu() -> UIMenu {
        let steps: [UIMenuElement] = PhonePlayerMenuModel.boostSteps.map { p in
            UIAction(title: PhonePlayerMenuModel.boostLabel(p), state: p == boost ? .on : .off) { _ in
                setBoost(p)
            }
        }
        return UIMenu(title: T("Volume Boost"), image: UIImage(systemName: "speaker.wave.3"), children: steps)
    }

    private func speedMenu() -> UIMenu {
        let rate: Double = session.rate
        var items: [UIMenuElement] = PhonePlayerMenuModel.speeds(custom: settings.slice.customPlaybackSpeeds).map { v in
            UIAction(title: PhonePlayerMenuModel.speedLabel(v), state: PhoneSpeedSleep.isRate(v, rate) ? .on : .off) { _ in
                session.setRate(v)
                PhoneFeedback.shared.selection()
            }
        }
        let isDefault: Bool = PhoneSpeedSleep.isRate(settings.slice.defaultPlaybackSpeed ?? 1, rate)
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: T("Set as Default Speed"), image: UIImage(systemName: "star"), state: isDefault ? .on : .off) { _ in
                Task { try? await SettingsBridge.shared.patch(["defaultPlaybackSpeed": .number(rate)]) }
            },
        ]))
        return UIMenu(title: T("Playback Speed"), image: UIImage(systemName: "gauge.with.dots.needle.33percent"), children: items)
    }

    private func audioMenu(_ tracks: [MPVPlayerController.Track]) -> UIMenu {
        let audio = tracks.filter { $0.type == "audio" }
        var items: [UIMenuElement] = audio.map { t in
            UIAction(title: PhonePlayerMenuModel.audioRow(t), state: t.selected ? .on : .off) { _ in
                session.controller?.select(track: t, type: "audio")
                session.controller?.rememberAudio(t)
                PhoneFeedback.shared.selection()
                refreshPicks()
            }
        }
        if audio.isEmpty {
            items.append(UIAction(title: T("No audio tracks"), attributes: .disabled) { _ in })
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: T("Audio Sync…"), image: UIImage(systemName: "waveform")) { _ in openPanel(.audio) },
        ]))
        return UIMenu(title: PhonePlayerMenuModel.audioTitle(tracks), image: UIImage(systemName: "music.note"), children: items)
    }

    private func subtitleMenu(_ tracks: [MPVPlayerController.Track]) -> UIMenu {
        let subs = tracks.filter { $0.type == "sub" }
        let anyOn: Bool = subs.contains { $0.selected }
        var items: [UIMenuElement] = [
            UIAction(title: T("None"), state: anyOn ? .off : .on) { _ in
                session.controller?.select(track: nil, type: "sub")
                session.controller?.rememberSubtitle(nil)
                PhoneFeedback.shared.selection()
                refreshPicks()
            },
        ]
        items += subs.map { t in
            UIAction(title: PhonePlayerMenuModel.subtitleRow(t), state: t.selected ? .on : .off) { _ in
                session.controller?.select(track: t, type: "sub")
                session.controller?.rememberSubtitle(t)
                PhoneFeedback.shared.selection()
                refreshPicks()
            }
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: T("Search, Sync & Style…"), image: UIImage(systemName: "magnifyingglass")) { _ in openPanel(.subtitles) },
        ]))
        return UIMenu(title: PhonePlayerMenuModel.subtitleTitle(tracks), image: UIImage(systemName: "text.bubble"), children: items)
    }

    private func advancedMenu() -> UIMenu {
        var items: [UIMenuElement] = [sleepMenu()]
        for p in PhonePlayerPanel.shown(panelFacts) where p != .subtitles && p != .audio && p != .speed {
            items.append(UIAction(title: p.title, image: UIImage(systemName: p.icon)) { _ in openPanel(p) })
        }
        items.append(UIAction(title: T("Speed & Sleep…"), image: UIImage(systemName: PhonePlayerPanel.speed.icon)) { _ in openPanel(.speed) })
        return UIMenu(title: T("Advanced Options"), image: UIImage(systemName: "gearshape.fill"), children: items)
    }

    private func sleepMenu() -> UIMenu {
        let sleep = SleepTimer.shared
        let rows = PhoneSpeedSleep.sleepRows(minutes: PhoneSpeedSleep.sleepMinutes(custom: settings.slice.customSleepMinutes))
        var items: [UIMenuElement] = rows.map { row in
            UIAction(title: row.label, image: UIImage(systemName: row.icon), state: PhoneSpeedSleep.isSelected(sleep.mode, row.mode) ? .on : .off) { _ in
                sleep.set(row.mode)
                PhoneFeedback.shared.selection()
            }
        }
        if sleep.isActive {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: T("Cancel Timer"), image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { _ in sleep.clear() },
            ]))
        }
        let menu = UIMenu(title: T("Sleep Timer"), image: UIImage(systemName: "moon"), children: items)
        if let left = sleep.faceLabel { menu.subtitle = left }
        return menu
    }
}
