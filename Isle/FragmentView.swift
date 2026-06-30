//
//  FragmentView.swift
//  Isle
//

import SwiftUI
import Combine
import AppKit

/// A single recognized word plus when the model last wrote or rewrote it,
/// so freshly-changed words can be highlighted and fade to gray over time.
struct TranscriptWord: Identifiable {
    let id: Int          // position in the transcript
    var text: String
    var changedAt: Date
}

/// Shared text metrics so the on-screen line wrapping (`TranscriptText`) and the
/// line-break pacing (`IslandState`) agree on exactly where lines break.
enum TranscriptMetrics {
    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 2

    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: fontSize) ?? base
        }
        return base
    }()

    static var lineHeight: CGFloat { ceil(font.ascender - font.descender) }
    static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    static let spaceWidth: CGFloat = width(" ")
}

/// The stage of a single interaction: capturing speech, waiting on
/// Codex, or showing its answer.
enum IslandPhase {
    case listening
    case thinking
    case responding
}

/// One answer from Codex, kept as an identified turn so SwiftUI preserves the
/// view across phases — the same bubble morphs from the active (white, full)
/// answer into a collapsed, greyed context line when the next turn begins.
struct AssistantTurn: Identifiable {
    let id: Int
    let text: String
}

/// Drives the open/close animation and holds the live transcript + answers.
/// Toggled by the fn key in AppDelegate.
final class IslandState: ObservableObject {
    @Published var isOpen = false
    /// Recognized speech as positioned words, each stamped with its last change.
    @Published private(set) var words: [TranscriptWord] = []
    /// Where we are in the listen → think → answer cycle.
    @Published private(set) var phase: IslandPhase = .listening
    /// Every answer this conversation; the last is the active one while
    /// `phase == .responding`, earlier ones render as collapsed grey context.
    @Published private(set) var assistantTurns: [AssistantTurn] = []
    /// The message being typed in text mode (bound to the input field).
    @Published var draft: String = ""
    /// Active input mode; flipped live by Tab (see AppDelegate.switchMode).
    @Published var mode: InputMode = .text

    /// Wrap width (pill width minus padding); set by the view once laid out.
    var availableTextWidth: CGFloat = 344

    // Staged reveal: queued words plus the width used by the current bottom line.
    private var pending: [TranscriptWord] = []
    private var currentLineWidth: CGFloat = 0
    private var staging = false
    private var turnCounter = 0

    var hasTranscript: Bool { !words.isEmpty }
    var hasHistory: Bool { !assistantTurns.isEmpty }
    /// The answer currently presented as active (white, full); nil unless
    /// responding. Once the user starts composing the next message (a non-empty
    /// `draft`), it goes grey too — collapsing to the context line so the focus
    /// shifts to what's being typed.
    var activeTurnID: Int? {
        guard phase == .responding, draft.isEmpty else { return nil }
        return assistantTurns.last?.id
    }

    /// Full clear (Esc / fresh start): drops the transcript and all answers.
    func reset() {
        clearTranscript()
        assistantTurns = []
        draft = ""
        phase = .listening
    }

    /// Begins a new user turn while keeping the conversation: the previous
    /// answer stays on screen and, once `phase` leaves `.responding`, collapses
    /// to a greyed context line as we start listening for the next request.
    func startTurn() {
        clearTranscript()
        draft = ""
        phase = .listening
    }

    /// Speech capture is done; we're now waiting on Codex.
    func beginThinking() {
        phase = .thinking
    }

    /// Codex answered: append it as the active turn (white, full).
    func showResponse(_ text: String) {
        turnCounter += 1
        assistantTurns.append(AssistantTurn(id: turnCounter, text: text))
        clearTranscript()
        phase = .responding
    }

    /// An empty/failed capture: fall back to the previous answer if there is one
    /// (so a stray tap doesn't lose context). Returns false when there's nothing
    /// to fall back to, so the caller can hide the pill instead.
    @discardableResult
    func cancelTurn() -> Bool {
        clearTranscript()
        guard hasHistory else { return false }
        phase = .responding
        return true
    }

    /// Recording stopped: append any not-yet-revealed words and show the whole
    /// message at once — no point pacing the reveal once capture is over.
    func setFinalTranscript(_ text: String) {
        update(transcript: text)
        let now = Date()
        while !pending.isEmpty {
            var word = pending.removeFirst()
            word.changedAt = now
            words.append(word)
        }
        currentLineWidth = 0
        staging = false
    }

    func clearTranscript() {
        words = []
        pending = []
        currentLineWidth = 0
        staging = false
    }

    /// Append-only reconciliation: the live preview only grows with genuinely
    /// new words and never rewrites what's already shown. The model revises
    /// earlier words as it hears more, but folding those corrections in here
    /// would re-wrap the lines and re-brighten settled text — distracting, and
    /// the corrections still reach the final paste. So we freeze the shown
    /// prefix and only stamp the newly appended words, then reveal them in
    /// staged steps so a line-fill and a new-line spill never share a frame.
    func update(transcript: String) {
        let tokens = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let known = words.count + pending.count
        guard tokens.count > known else { return }

        let appended = tokens[known...].enumerated().map { offset, token in
            TranscriptWord(id: known + offset, text: String(token), changedAt: Date())
        }
        pending.append(contentsOf: appended)
        startStaged()
    }

    private func startStaged() {
        guard !staging else { return }
        staging = true
        stepStaged()
    }

    /// One frame of staged reveal. If the next word fits the current line, reveal
    /// every word that fits at once (the bottom line just grows — no scroll, so
    /// batching is smooth). Otherwise reveal only the single word that starts a
    /// new line, isolating the scroll so the line above it is already settled.
    private func stepStaged() {
        guard let next = pending.first else { staging = false; return }

        if fitsOnCurrentLine(next.text) {
            revealFittingWords()
            scheduleNextStep(after: 0.06)   // brief gap before the line break
        } else {
            revealOne()                     // starts a new line → triggers scroll
            scheduleNextStep(after: 0.3)    // let the scroll settle first
        }
    }

    private func fitsOnCurrentLine(_ text: String) -> Bool {
        currentLineWidth == 0
            || currentLineWidth + TranscriptMetrics.spaceWidth + TranscriptMetrics.width(text) <= availableTextWidth
    }

    private func revealFittingWords() {
        let now = Date()
        while let next = pending.first, fitsOnCurrentLine(next.text) {
            var word = pending.removeFirst()
            word.changedAt = now
            words.append(word)
            let w = TranscriptMetrics.width(word.text)
            currentLineWidth = currentLineWidth == 0 ? w : currentLineWidth + TranscriptMetrics.spaceWidth + w
        }
    }

    private func revealOne() {
        guard !pending.isEmpty else { return }
        var word = pending.removeFirst()
        word.changedAt = Date()
        words.append(word)
        currentLineWidth = TranscriptMetrics.width(word.text)
    }

    private func scheduleNextStep(after delay: TimeInterval) {
        guard !pending.isEmpty else { staging = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.stepStaged()
        }
    }
}

/// A standalone Dynamic Island-style pill that springs out from under the
/// notch, showing a live "listening" indicator while recording.
///
/// The hosting panel is taller than the pill (`topRoom` of empty space above)
/// so the emerge animation can travel upward without being clipped.
struct FragmentView: View {
    @ObservedObject var state: IslandState
    var pillSize: CGSize
    var topRoom: CGFloat
    /// Width the transcript wraps at once text starts arriving.
    var expandedWidth: CGFloat
    /// Called when the user presses Enter in the text field.
    var onSubmitText: () -> Void
    var onQuit: () -> Void

    @FocusState private var inputFocused: Bool

    private let textPadding: CGFloat = 18

    /// The user's live/just-finished message shows while listening or thinking;
    /// once Codex answers it's dropped in favor of the response.
    private var showsUserMessage: Bool {
        state.hasTranscript && state.phase != .responding
    }

    /// In text mode the input field is present whenever the pill is open and
    /// Codex isn't mid-thought — so the next question can be typed right after an
    /// answer without any extra gesture.
    private var showsInput: Bool {
        state.mode == .text && state.phase != .thinking
    }

    /// While responding, show the active answer. Otherwise show the previous
    /// answer as collapsed grey context — but only until the new message starts
    /// arriving, at which point it animates away.
    private var visibleTurns: [AssistantTurn] {
        if state.phase != .responding && state.hasTranscript { return [] }
        return Array(state.assistantTurns.suffix(1))
    }

    /// The pill grows into a card whenever there's content to show — a live
    /// transcript or any answer.
    private var expanded: Bool {
        showsUserMessage || !visibleTurns.isEmpty || showsInput
    }

    var body: some View {
        pill
            // Grow downward from the top edge so it reads as emerging from the notch.
            .scaleEffect(state.isOpen ? 1 : 0.3, anchor: .top)
            .offset(y: state.isOpen ? 0 : -20)
            .opacity(state.isOpen ? 1 : 0)
            .padding(.top, topRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.7), value: state.isOpen)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.words.count)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.phase)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.assistantTurns.count)
            .onAppear { state.availableTextWidth = expandedWidth - 2 * textPadding }
            // Grab the caret whenever the input field is on screen so the user can
            // just start typing the moment the pill opens (or after an answer).
            .onChange(of: state.isOpen) { _, _ in syncFocus() }
            .onChange(of: state.phase) { _, _ in syncFocus() }
            // A Tab switch can land on text mode without changing phase, so react
            // to the mode flip too — grab the caret for text, drop it for voice.
            .onChange(of: state.mode) { _, _ in syncFocus() }
            .contextMenu { Button("Quit Isle", action: onQuit) }
    }

    private func syncFocus() {
        inputFocused = state.mode == .text && state.isOpen && showsInput
    }

    /// The capsule itself: a compact status pill that grows into a rounded card
    /// as recognized text streams in and as Codex's answers arrive.
    private var pill: some View {
        // Center-aligned so the status indicator stays centered as the pill
        // widens; the transcript/answers keep their own full-width leading frame.
        VStack(alignment: .center, spacing: 10) {
            StatusIndicator(phase: state.phase, mode: state.mode, active: state.isOpen)

            ForEach(visibleTurns) { turn in
                ResponseBubble(text: turn.text, active: turn.id == state.activeTurnID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Fade + collapse upward when the new user message displaces it.
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }

            if showsUserMessage {
                TranscriptText(
                    words: state.words,
                    availableWidth: expandedWidth - 2 * textPadding
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if showsInput {
                inputField
            }
        }
        .padding(.horizontal, textPadding)
        .padding(.vertical, expanded ? 16 : 0)
        .frame(minWidth: pillSize.width, minHeight: pillSize.height)
        .frame(maxWidth: expanded ? expandedWidth : nil, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The text-mode composer: a borderless field styled to match the transcript
    /// so it blends into the pill. Enter sends; the caret is grabbed on open via
    /// `syncFocus()`.
    private var inputField: some View {
        TextField("Ask anything…", text: $state.draft)
            .textFieldStyle(.plain)
            .font(.system(size: TranscriptMetrics.fontSize, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($inputFocused)
            .onSubmit(onSubmitText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }
}

/// One Codex answer. As the active turn it's full and white (scrolling past a
/// height cap); once a newer turn takes over it collapses to two greyed lines of
/// context. Both states share this view so the change animates as a collapse.
private struct ResponseBubble: View {
    var text: String
    var active: Bool

    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 340

    /// Flatten markdown to readable plain text for the collapsed two-line context
    /// line — drops fenced code blocks and strips the common inline/block markers
    /// so leftover `**`/`#`/`` ` `` don't clutter the preview.
    private static func plainPreview(_ markdown: String) -> String {
        var keep: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            var stripped = trimmed
            while let first = stripped.first, first == "#" || first == ">" {
                stripped.removeFirst()
            }
            for marker in ["- ", "* ", "+ "] where stripped.hasPrefix(marker) {
                stripped.removeFirst(marker.count)
            }
            stripped = stripped
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { keep.append(stripped) }
        }
        return keep.joined(separator: " ")
    }

    private struct HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        ScrollView {
            Group {
                if active {
                    // Full answer: render Codex's markdown (bold, code, lists, …).
                    MarkdownText(markdown: text)
                } else {
                    // Collapsed context: a flattened two-line preview, greyed out.
                    // Markdown structure isn't useful at two lines, so we strip the
                    // syntax to plain text rather than render it.
                    Text(Self.plainPreview(text))
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear.preference(key: HeightKey.self, value: geo.size.height)
            })
        }
        .scrollDisabled(!active)
        .frame(height: min(contentHeight, maxHeight))
        // Animate the measured height too: when `active` flips, the text reflows
        // to a new height a render later, so without this the height would jump
        // while only the color tweened.
        .onPreferenceChange(HeightKey.self) { newHeight in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                contentHeight = newHeight
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: active)
    }
}

/// One laid-out line of the transcript. The id is the line's position, so as
/// new lines are appended the earlier lines keep a stable identity and SwiftUI
/// reuses (rather than rebuilds) them — giving the teleprompter scroll.
private struct TranscriptLine: Identifiable {
    let id: Int
    let words: [TranscriptWord]
}

/// Renders the transcript like a reverse teleprompter: words are packed into
/// fixed lines (our own greedy wrapping), only the most recent two lines show,
/// and as a new line forms the stack translates up by exactly one line so the
/// older line scrolls off the top instead of the whole block re-wrapping.
///
/// Each word also carries a recency highlight: bright when the model just wrote
/// or rewrote it, holding briefly, then easing to gray. The fade is driven by a
/// `TimelineView` so it's purely time-based.
private struct TranscriptText: View {
    var words: [TranscriptWord]
    /// Text width to wrap at (pill width minus its horizontal padding).
    var availableWidth: CGFloat

    // Hold bright briefly, then snap to gray over a short window.
    private let hold: TimeInterval = 1.0
    private let fade: TimeInterval = 0.5
    private let freshOpacity = 1.0
    private let agedOpacity = 0.4

    private let visibleLines = 2

    private var fontSize: CGFloat { TranscriptMetrics.fontSize }
    private var lineSpacing: CGFloat { TranscriptMetrics.lineSpacing }
    private var lineHeight: CGFloat { TranscriptMetrics.lineHeight }
    /// Vertical distance to scroll when one line is added.
    private var rowStride: CGFloat { lineHeight + lineSpacing }

    var body: some View {
        let lines = layoutLines()
        let scrolling = lines.count > visibleLines

        // Two crisp lines, plus one extra "ghost" line above while scrolling that
        // the top gradient dissolves — so the outgoing line fades out instead of
        // being hard-clipped at the pill edge (which read as a jarring jump).
        let crispCount = min(lines.count, visibleLines)
        let crispHeight = CGFloat(crispCount) * lineHeight
            + CGFloat(max(0, crispCount - 1)) * lineSpacing
        let fadeZone = scrolling ? rowStride : 0
        let viewportHeight = crispHeight + fadeZone

        let shown = visibleLines + (scrolling ? 1 : 0)
        let linesAbove = max(0, lines.count - shown)

        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            VStack(alignment: .leading, spacing: lineSpacing) {
                ForEach(lines) { line in
                    lineView(line, at: context.date)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: -CGFloat(linesAbove) * rowStride)
        }
        .frame(height: viewportHeight, alignment: .top)
        .mask(topFadeMask(fadeZone: fadeZone))
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: lines.count)
    }

    /// Opaque over the crisp lines; a clear→opaque ramp over the top fade zone so
    /// content dissolves as it scrolls up and out.
    private func topFadeMask(fadeZone: CGFloat) -> some View {
        VStack(spacing: 0) {
            if fadeZone > 0 {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeZone)
            }
            Color.black
        }
    }

    /// Greedy line breaking over the measured word widths. Deterministic, so an
    /// unchanged prefix of words always yields the same earlier lines.
    private func layoutLines() -> [TranscriptLine] {
        guard availableWidth > 0 else { return [TranscriptLine(id: 0, words: words)] }
        let spaceWidth = TranscriptMetrics.spaceWidth

        var lines: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        var width: CGFloat = 0

        for word in words {
            let wordWidth = TranscriptMetrics.width(word.text)
            let projected = current.isEmpty ? wordWidth : width + spaceWidth + wordWidth
            if !current.isEmpty && projected > availableWidth {
                lines.append(current)
                current = [word]
                width = wordWidth
            } else {
                current.append(word)
                width = projected
            }
        }
        if !current.isEmpty { lines.append(current) }

        return lines.enumerated().map { TranscriptLine(id: $0.offset, words: $0.element) }
    }

    private func lineView(_ line: TranscriptLine, at now: Date) -> some View {
        var attributed = AttributedString()
        for (index, word) in line.words.enumerated() {
            let separator = index == line.words.count - 1 ? "" : " "
            var run = AttributedString(word.text + separator)
            run.foregroundColor = .white.opacity(opacity(for: word, at: now))
            attributed += run
        }
        return Text(attributed)
            .font(.system(size: fontSize, weight: .regular, design: .rounded))
            .lineLimit(1)
            .fixedSize()
    }

    private func opacity(for word: TranscriptWord, at now: Date) -> Double {
        let age = now.timeIntervalSince(word.changedAt)
        let t = min(max((age - hold) / fade, 0), 1)
        let eased = t * t * (3 - 2 * t)  // smoothstep
        return freshOpacity + (agedOpacity - freshOpacity) * eased
    }
}

/// A pulsing dot + label conveying the current phase: teal "Listening" while
/// capturing speech, amber "Thinking" while waiting on Codex. The dot gently
/// breathes while a soft ring pings outward — subtle, not blinky.
private struct StatusIndicator: View {
    var phase: IslandPhase
    var mode: InputMode
    /// Only animates while the island is open.
    var active: Bool

    /// One ping cycle, in seconds.
    private let pingPeriod: TimeInterval = 1.5

    private var tint: Color {
        switch phase {
        case .listening: Color(red: 0.20, green: 0.80, blue: 0.80)  // teal
        case .thinking: Color(red: 0.95, green: 0.72, blue: 0.30)   // amber
        case .responding: Color(red: 0.30, green: 0.82, blue: 0.46) // green
        }
    }

    private var label: String {
        switch phase {
        case .listening: mode == .text ? "Ask" : "Listening"
        case .thinking: "Thinking"
        case .responding: "Ready"
        }
    }

    /// In voice mode the dot pulses while listening or thinking. In text mode
    /// there's no live capture, so the input phase ("Ask") stays steady and only
    /// thinking pulses.
    private var shouldPulse: Bool {
        switch mode {
        case .voice: active && phase != .responding
        case .text: active && phase == .thinking
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                // A ring that expands outward from the core and fades. Driven by
                // wall-clock time via TimelineView rather than a repeatForever
                // animation, which SwiftUI restarts on unrelated re-renders and
                // makes the dot blink. The schedule pauses when there's nothing
                // to pulse so it costs nothing at rest.
                TimelineView(.animation(paused: !shouldPulse)) { context in
                    let t = pingProgress(at: context.date)
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .scaleEffect(1 + 1.3 * t)
                        .opacity(shouldPulse ? 0.5 * (1 - t) : 0)
                }
                // Core dot — constant.
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 9, height: 9)
            .shadow(color: tint.opacity(0.7), radius: 5)

            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    /// Eased 0→1 sawtooth over `pingPeriod`, keyed off absolute time so the
    /// cycle is continuous and never restarts when the view re-renders.
    private func pingProgress(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pingPeriod) / pingPeriod
        let t = CGFloat(phase)
        return t * (2 - t)  // ease-out
    }
}

#Preview {
    let state = IslandState()
    state.isOpen = true
    state.showResponse("""
        Here's a quick **summary** with a few `inline` bits:

        - First point worth noting
        - Second one, a bit longer so it wraps across the pill width

        ```swift
        func greet(_ name: String) {
            print("Hello, \\(name)")
        }
        ```

        That's the gist — see the [docs](https://example.com) for more.
        """)
    return FragmentView(
        state: state,
        pillSize: CGSize(width: 150, height: 40),
        topRoom: 30,
        expandedWidth: 360,
        onSubmitText: {},
        onQuit: {}
    )
    .frame(width: 420, height: 300)
    .background(.gray)
}
