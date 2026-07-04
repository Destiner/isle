//
//  PillView.swift
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
    /// True while the shown response is an error notice, so the status header
    /// reads "Error" (red) instead of "Ready" (green). Otherwise an error turn
    /// behaves like any response (stays on screen; voice re-arms for a retry).
    @Published private(set) var isError = false
    /// Tool/MCP calls surfaced while Codex works (icon + label). Populated during
    /// `.thinking` and cleared at every turn boundary (folded into
    /// `clearTranscript`). The data path from `CodexClient`'s `--json` event log
    /// isn't wired yet — today this is driven directly (see the gallery).
    /// The tool/MCP call currently running — a single slot, so a new call
    /// replaces (and rolls over) the prior one rather than stacking. Nil when
    /// nothing's running, so the pill falls back to the plain "Thinking" row.
    /// Cleared at every turn boundary (folded into `clearTranscript`).
    @Published private(set) var currentTool: ToolActivity?
    /// The message the user just submitted, shown while the model is thinking so
    /// it's clear what's being answered. Voice has the live transcript for this;
    /// text throws the draft away on submit, so we keep it here. Cleared at every
    /// turn boundary (folded into `clearTranscript`).
    @Published private(set) var userMessage: String = ""

    /// Wrap width (pill width minus padding); set by the view once laid out.
    var availableTextWidth: CGFloat = 344

    // Staged reveal: queued words plus the width used by the current bottom line.
    private var pending: [TranscriptWord] = []
    private var currentLineWidth: CGFloat = 0
    private var staging = false
    private var turnCounter = 0
    private var toolCounter = 0

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

    /// Full clear (fresh start / conversation idled out): drops the transcript
    /// and all answers.
    func reset() {
        clearTranscript()
        assistantTurns = []
        draft = ""
        phase = .listening
        isError = false
    }

    /// Closing the pill: drop the in-progress compose but keep the answers (and
    /// the error flag) so reopening within the idle window can restore the last
    /// one. The full clear happens later, when the idle timer fires.
    func prepareForClose() {
        clearTranscript()
        draft = ""
    }

    /// Reopening within the conversation window: bring the last answer back as
    /// the active turn — the same on-screen state as just after it landed.
    func restore() {
        clearTranscript()
        draft = ""
        phase = .responding
    }

    /// Begins a new user turn while keeping the conversation: the previous
    /// answer stays on screen and, once `phase` leaves `.responding`, collapses
    /// to a greyed context line as we start listening for the next request.
    func startTurn() {
        clearTranscript()
        draft = ""
        phase = .listening
        isError = false
    }

    /// Speech capture is done; we're now waiting on Codex.
    func beginThinking() {
        phase = .thinking
        isError = false
    }

    /// Codex answered: append it as the active turn (white, full).
    func showResponse(_ text: String) {
        turnCounter += 1
        assistantTurns.append(AssistantTurn(id: turnCounter, text: text))
        clearTranscript()
        phase = .responding
        isError = false
    }

    /// Codex failed: show the error notice as the active turn, flagged so the
    /// status header reads "Error" (red). Otherwise identical to `showResponse`
    /// — the notice stays on screen and, in voice mode, the mic re-arms so the
    /// user can simply speak the request again.
    func showError(_ text: String) {
        turnCounter += 1
        assistantTurns.append(AssistantTurn(id: turnCounter, text: text))
        clearTranscript()
        phase = .responding
        isError = true
    }

    /// An empty/failed capture: fall back to the previous answer if there is one
    /// (so a stray tap doesn't lose context). Returns false when there's nothing
    /// to fall back to, so the caller can hide the pill instead.
    @discardableResult
    func cancelTurn() -> Bool {
        clearTranscript()
        guard hasHistory else { return false }
        phase = .responding
        isError = false
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
        // Every clearTranscript site is a turn boundary (new turn / answer / close),
        // so the running tool and the pending user message — both transient to the
        // turn that spawned them — reset here too.
        currentTool = nil
        userMessage = ""
    }

    /// Record the message the user just sent so it stays on screen while the
    /// model thinks. Set after the draft is cleared, before `beginThinking`.
    func setUserMessage(_ text: String) {
        userMessage = text
    }

    /// Surface a running tool step. `named:` resolves the icon + label via
    /// `ToolPresentation`; the raw overload is for one-off/custom steps.
    func beginTool(named name: String) {
        let p = ToolPresentation.activity(forTool: name)
        beginTool(icon: p.icon, label: p.label)
    }

    func beginTool(icon: String, label: String) {
        toolCounter += 1
        currentTool = ToolActivity(id: toolCounter, icon: icon, label: label)
    }

    /// The tool finished with nothing else running → back to the plain "Thinking".
    func endTool() {
        currentTool = nil
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
struct PillView: View {
    @ObservedObject var state: IslandState
    var pillSize: CGSize
    var topRoom: CGFloat
    /// Width the transcript wraps at once text starts arriving.
    var expandedWidth: CGFloat
    /// Called when the user presses Enter in the text field.
    var onSubmitText: () -> Void
    var onQuit: () -> Void

    @FocusState private var inputFocused: Bool
    /// Ties the text composer and the greyed submitted-message together so the
    /// draft appears to grey out and slide into place rather than pop.
    @Namespace private var composeNS

    private let textPadding: CGFloat = 18

    /// The user's live/just-finished message shows while listening or thinking;
    /// once Codex answers it's dropped in favor of the response.
    private var showsUserMessage: Bool {
        state.hasTranscript && state.phase != .responding
    }

    /// Text mode has no live transcript, so the just-sent message is shown from
    /// `state.userMessage` while the model is thinking.
    private var showsUserText: Bool {
        !state.userMessage.isEmpty && !state.hasTranscript && state.phase != .responding
    }

    /// Voice surfaces a "Listening" status row whenever the mic is live or armed:
    /// while capturing (`.listening`) and while an answer is shown (`.responding`,
    /// where the follow-up mic is armed so you can just speak again).
    private var showsListening: Bool {
        state.mode == .voice && (state.phase == .listening || state.phase == .responding)
    }

    /// The listening row is centered only when it's the sole content (the idle,
    /// pre-speech voice pill). Otherwise it sits bottom-left under whatever's there.
    private var listeningCentered: Bool {
        state.phase == .listening && !state.hasTranscript && visibleTurns.isEmpty
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
    /// transcript, any answer, or running tool steps.
    private var expanded: Bool {
        showsUserMessage || showsUserText || !visibleTurns.isEmpty || showsInput
            || state.currentTool != nil || state.phase == .thinking
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
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.currentTool?.id)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.mode)
            // Grow/shrink the multiline field smoothly as lines are added/removed.
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: state.draft)
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
            // What the user said: the live transcript (voice) or the typed message
            // (text), shown while capturing / thinking.
            if showsUserMessage {
                TranscriptText(
                    words: state.words,
                    availableWidth: expandedWidth - 2 * textPadding
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if showsUserText {
                Text(state.userMessage)
                    .font(.system(size: TranscriptMetrics.fontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .matchedGeometryEffect(id: "compose", in: composeNS, properties: .position, anchor: .topLeading)
                    .transition(.opacity)
            }

            // The answer (active, or collapsed context once a new turn begins).
            ForEach(visibleTurns) { turn in
                ResponseBubble(text: turn.text, active: turn.id == state.activeTurnID, isError: state.isError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Fade + collapse upward when the new user message displaces it.
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }

            // Text composer — extra breathing room when it trails an answer.
            if showsInput {
                inputField
                    .padding(.top, visibleTurns.isEmpty ? 0 : 10)
            }

            // Bottom-left status affordance: tool steps while thinking, else the
            // phase row (Thinking / Listening).
            if let tool = state.currentTool {
                // Single slot: switching tools rolls the old out / new in.
                ToolActivityRow(activity: tool)
                    .id(tool.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.push(from: .bottom))
            } else if state.phase == .thinking {
                StatusRow(icon: "ellipsis", label: "Thinking", animating: state.isOpen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if showsListening {
                // Animate only while actively capturing (`.listening`). While the
                // mic is merely armed (`.responding`) or the pill is closed, keep it
                // static — the continuous symbol animation otherwise pegs the main
                // thread and starves the (main-actor) speech-onset loop.
                let live = state.isOpen && state.phase == .listening
                if listeningCentered {
                    // Idle (pre-speech): centered on its own in the compact pill.
                    StatusRow(icon: "waveform", label: "Listening", animating: live)
                        .transition(.opacity)
                } else {
                    StatusRow(icon: "waveform", label: "Listening", animating: live)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
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
        // Grows with the text, capped at 5 lines (then scrolls internally).
        TextField("Ask anything…", text: $state.draft, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .font(.system(size: TranscriptMetrics.fontSize, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($inputFocused)
            // A vertical-axis field turns Return into a newline instead of
            // firing `onSubmit`, so intercept the keypress directly and submit
            // (swallowed so no newline is inserted). Pasted text keeps its
            // newlines untouched — only a real Return keypress submits, so
            // pasting multiline text no longer triggers a send.
            .onKeyPress(keys: [.return], phases: .down) { _ in
                onSubmitText()
                return .handled
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .matchedGeometryEffect(id: "compose", in: composeNS, properties: .position, anchor: .topLeading)
            .transition(.opacity)
    }
}

/// One Codex answer. As the active turn it's full and white (scrolling past a
/// height cap); once a newer turn takes over it collapses to two greyed lines of
/// context. Both states share this view so the change animates as a collapse.
private struct ResponseBubble: View {
    var text: String
    var active: Bool
    /// The turn is a failure notice: rendered as plain red-ish text (errors are
    /// short and aren't markdown), no header needed to flag it.
    var isError: Bool = false

    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 340
    private static let errorColor = Color(red: 0.98, green: 0.44, blue: 0.44)

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
                if isError {
                    // Failure notice: a warning triangle + plain red-ish text
                    // (errors are short and aren't markdown), no header needed.
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Self.errorColor)
                            .padding(.top, 1)
                        Text(text)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(Self.errorColor)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if active {
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
    return PillView(
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
