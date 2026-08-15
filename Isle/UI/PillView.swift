//
//  PillView.swift
//  Isle
//

import SwiftUI
import Combine
import AppKit

/// The body text size shared by the composer, the submitted-message echo, and
/// the chat switcher rows, so they all read as one block.
enum PillText {
    static let fontSize: CGFloat = 14
}

/// The stage of a single interaction: composing the request, waiting on Codex,
/// or showing its answer.
enum IslandPhase {
    case composing
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

/// Drives the open/close animation and holds the draft + answers.
/// Toggled by the fn key in AppDelegate.
final class IslandState: ObservableObject {
    @Published var isOpen = false
    /// Where we are in the compose → think → answer cycle.
    @Published private(set) var phase: IslandPhase = .composing
    /// Every answer this conversation; the last is the active one while
    /// `phase == .responding`, earlier ones render as collapsed grey context.
    @Published private(set) var assistantTurns: [AssistantTurn] = []
    /// The message being typed (bound to the input field).
    @Published var draft: String = ""
    /// True while the shown response is an error notice, so the status header
    /// reads "Error" (red) instead of "Ready" (green). Otherwise an error turn
    /// behaves like any response — it stays on screen, ready for a retry.
    @Published private(set) var isError = false
    /// The tool/MCP call currently shown while Codex works (icon + label), fed by
    /// the agent's turn events via `beginTool`/`endTool`. A single
    /// slot, so a new call replaces (and rolls over) the prior one rather than
    /// stacking; nil when nothing's running, so the pill falls back to the plain
    /// "Thinking" row. Changes are debounced through `setTool` (min-display gate)
    /// so instant calls don't flicker past. Cleared at every turn boundary
    /// (folded into `clearTurnState`).
    @Published private(set) var currentTool: ToolActivity?
    /// The message the user just submitted, shown while the model is thinking so
    /// it's clear what's being answered — the draft is thrown away on submit, so
    /// we keep it here. Cleared at every turn boundary (folded into
    /// `clearTurnState`).
    @Published private(set) var userMessage: String = ""

    /// Recent-chats switcher (press ↑ in the empty new-chat state). `chatOptions`
    /// are chronological (oldest first), so `selection` starts on the last row —
    /// the latest chat — and a single ↓ drops back out to the empty state.
    /// Populated by `AppDelegate` from `ChatStore`.
    @Published private(set) var isSwitching = false
    @Published private(set) var chatOptions: [ChatSummary] = []
    @Published private(set) var switcherSelection = 0

    private var turnCounter = 0
    private var toolCounter = 0

    // Tool-row debounce: keep each shown tool visible for at least this long so
    // near-instant back-to-back calls don't flicker past unread. See `setTool`.
    private let minToolDisplay: TimeInterval = 1.0
    /// When the visible tool last changed to a non-nil value; nil while none shown.
    private var toolShownAt: Date?
    /// Latest desired tool state, applied once the visible tool has had its time.
    /// `hasPendingTool` distinguishes "nothing queued" from "queued a clear (nil)".
    private var pendingTool: ToolActivity?
    private var hasPendingTool = false
    private var toolFlipWork: DispatchWorkItem?

    var hasHistory: Bool { !assistantTurns.isEmpty }
    /// The answer currently presented as active (white, full); nil unless
    /// responding. Once the user starts composing the next message (a non-empty
    /// `draft`), it goes grey too — collapsing to the context line so the focus
    /// shifts to what's being typed.
    var activeTurnID: Int? {
        guard phase == .responding, draft.isEmpty else { return nil }
        return assistantTurns.last?.id
    }

    /// The empty new-chat state where ↑ opens the switcher: pill open, nothing
    /// submitted or answered yet.
    var isEmptyNewChat: Bool {
        isOpen && phase == .composing && assistantTurns.isEmpty && userMessage.isEmpty
    }

    /// The selection is on the last (latest) row, so ↓ exits the switcher.
    var switcherAtLast: Bool { switcherSelection >= chatOptions.count - 1 }

    /// The chat the switcher is currently pointing at, if any.
    var selectedChatID: UUID? {
        guard chatOptions.indices.contains(switcherSelection) else { return nil }
        return chatOptions[switcherSelection].id
    }

    /// Show the recent-chats list. `options` are chronological (oldest first),
    /// so the selection opens on the last row (the latest chat).
    func openSwitcher(_ options: [ChatSummary]) {
        guard !options.isEmpty else { return }
        chatOptions = options
        switcherSelection = options.count - 1
        isSwitching = true
    }

    /// Move the selection, clamped to the list (the caller handles ↓-past-last).
    func moveSwitcher(by delta: Int) {
        let next = switcherSelection + delta
        guard chatOptions.indices.contains(next) else { return }
        switcherSelection = next
    }

    /// Point the selection at a specific row (hover).
    func setSwitcherSelection(_ index: Int) {
        guard chatOptions.indices.contains(index) else { return }
        switcherSelection = index
    }

    /// Leave the switcher, back to the empty new-chat state.
    func closeSwitcher() {
        isSwitching = false
        chatOptions = []
        switcherSelection = 0
    }

    /// Full clear (fresh start / conversation idled out): drops the compose state
    /// and all answers.
    func reset() {
        clearTurnState()
        assistantTurns = []
        draft = ""
        phase = .composing
        isError = false
        closeSwitcher()
    }

    /// Closing the pill: drop the in-progress compose but keep the answers (and
    /// the error flag) so reopening within the idle window can restore the last
    /// one. The full clear happens later, when the idle timer fires.
    func prepareForClose() {
        clearTurnState()
        draft = ""
    }

    /// Reopening within the conversation window: bring the last answer back as
    /// the active turn — the same on-screen state as just after it landed.
    func restore() {
        clearTurnState()
        draft = ""
        phase = .responding
    }

    /// Begins a new user turn while keeping the conversation: the previous
    /// answer stays on screen and, once `phase` leaves `.responding`, collapses
    /// to a greyed context line as the next request is composed.
    func startTurn() {
        clearTurnState()
        draft = ""
        phase = .composing
        isError = false
        closeSwitcher()
    }

    /// Reinstate a saved chat's answers on screen: rebuild the turns and present
    /// the last one as the active response, ready for a follow-up — the same
    /// on-screen shape as `restore()`. The model-facing history is restored
    /// separately in `Conversation` (see `AppDelegate.reinstate`).
    func reinstate(assistantTexts: [String]) {
        clearTurnState()
        draft = ""
        var rebuilt: [AssistantTurn] = []
        for text in assistantTexts {
            turnCounter += 1
            rebuilt.append(AssistantTurn(id: turnCounter, text: text))
        }
        assistantTurns = rebuilt
        phase = .responding
        isError = false
        closeSwitcher()
    }

    /// The message is sent; we're now waiting on Codex.
    func beginThinking() {
        phase = .thinking
        isError = false
    }

    /// Codex answered: append it as the active turn (white, full).
    func showResponse(_ text: String) {
        turnCounter += 1
        assistantTurns.append(AssistantTurn(id: turnCounter, text: text))
        clearTurnState()
        phase = .responding
        isError = false
    }

    /// Codex failed: show the error notice as the active turn, flagged so the
    /// status header reads "Error" (red). Otherwise identical to `showResponse`
    /// — the notice stays on screen and the field is focused again so the user
    /// can simply ask again.
    func showError(_ text: String) {
        turnCounter += 1
        assistantTurns.append(AssistantTurn(id: turnCounter, text: text))
        clearTurnState()
        phase = .responding
        isError = true
    }

    /// An empty/failed submit: fall back to the previous answer if there is one
    /// (so a stray tap doesn't lose context). Returns false when there's nothing
    /// to fall back to, so the caller can hide the pill instead.
    @discardableResult
    func cancelTurn() -> Bool {
        clearTurnState()
        guard hasHistory else { return false }
        phase = .responding
        isError = false
        return true
    }

    /// Every call site is a turn boundary (new turn / answer / close), so the
    /// running tool and the pending user message — both transient to the turn
    /// that spawned them — reset here. `applyTool(nil)` also cancels any deferred
    /// flip so a stale step can't surface over the next turn's answer.
    func clearTurnState() {
        applyTool(nil)
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
        setTool(ToolActivity(id: toolCounter, icon: icon, label: label))
    }

    /// The tool finished with nothing else running → back to the plain "Thinking".
    func endTool() {
        setTool(nil)
    }

    /// Every tool change funnels through this min-display gate. If nothing's
    /// shown yet, or the visible tool has already had its `minToolDisplay`, the
    /// change applies at once; otherwise it's recorded as the latest desired
    /// state and applied when the window ends. Bursts coalesce to the latest —
    /// every *shown* step gets its second, sub-second blips in between are
    /// skipped (this is a live status, not a log). A long-running tool clears
    /// as soon as it ends, since its window is long past.
    private func setTool(_ next: ToolActivity?) {
        guard let shownAt = toolShownAt else {
            applyTool(next)   // nothing visible → show immediately
            return
        }
        let remaining = minToolDisplay - Date().timeIntervalSince(shownAt)
        if remaining <= 0 {
            applyTool(next)
        } else {
            pendingTool = next
            hasPendingTool = true
            scheduleToolFlip(after: remaining)
        }
    }

    private func applyTool(_ tool: ToolActivity?) {
        toolFlipWork?.cancel()
        toolFlipWork = nil
        pendingTool = nil
        hasPendingTool = false
        currentTool = tool
        toolShownAt = tool == nil ? nil : Date()
    }

    private func scheduleToolFlip(after delay: TimeInterval) {
        toolFlipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasPendingTool else { return }
            self.applyTool(self.pendingTool)
        }
        toolFlipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// A standalone Dynamic Island-style pill that springs out from under the
/// notch, holding the composer and the conversation's answers.
///
/// The hosting panel is taller than the pill (`topRoom` of empty space above)
/// so the emerge animation can travel upward without being clipped.
struct PillView: View {
    @ObservedObject var state: IslandState
    var pillSize: CGSize
    var topRoom: CGFloat
    /// Width the pill grows to once there's content to show.
    var expandedWidth: CGFloat
    /// Called when the user presses Enter in the text field.
    var onSubmitText: () -> Void
    /// Called when ↑ is pressed on an empty field in the new-chat state — asks
    /// AppDelegate to load recent chats and open the switcher.
    var onOpenSwitcher: () -> Void
    /// Called when a chat is chosen from the switcher (Enter or click).
    var onReinstate: (UUID) -> Void
    var onQuit: () -> Void

    @FocusState private var inputFocused: Bool
    @FocusState private var switcherFocused: Bool
    /// Ties the text composer and the greyed submitted-message together so the
    /// draft appears to grey out and slide into place rather than pop.
    @Namespace private var composeNS

    private let textPadding: CGFloat = 18

    /// The just-sent message, echoed from `state.userMessage` while the model is
    /// thinking; once Codex answers it's dropped in favor of the response.
    private var showsUserText: Bool {
        !state.userMessage.isEmpty && state.phase != .responding
    }

    /// The input field is present whenever the pill is open and Codex isn't
    /// mid-thought — so the next question can be typed right after an answer
    /// without any extra gesture.
    private var showsInput: Bool {
        state.phase != .thinking && !state.isSwitching
    }

    /// While responding, show the active answer. Otherwise show the previous
    /// answer as collapsed grey context — but only until the new message is sent,
    /// at which point it animates away.
    private var visibleTurns: [AssistantTurn] {
        // Hide the prior answer the moment the new user message is echoed on
        // screen — otherwise the prior response lingers behind it while thinking.
        if showsUserText { return [] }
        return Array(state.assistantTurns.suffix(1))
    }

    /// The pill grows into a card whenever there's content to show — the
    /// composer, any answer, or running tool steps.
    private var expanded: Bool {
        showsUserText || !visibleTurns.isEmpty || showsInput
            || state.currentTool != nil || state.phase == .thinking || state.isSwitching
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
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.phase)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.assistantTurns.count)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.currentTool?.id)
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: state.isSwitching)
            // Grow/shrink the multiline field smoothly as lines are added/removed.
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: state.draft)
            // Grab the caret whenever the input field is on screen so the user can
            // just start typing the moment the pill opens (or after an answer).
            .onChange(of: state.isOpen) { _, _ in syncFocus() }
            .onChange(of: state.phase) { _, _ in syncFocus() }
            // Hand focus to the switcher list while it's open (so arrows/Enter
            // reach it), and back to the field when it closes.
            .onChange(of: state.isSwitching) { _, on in
                if on { switcherFocused = true } else { syncFocus() }
            }
            .contextMenu { Button("Quit Isle", action: onQuit) }
    }

    private func syncFocus() {
        inputFocused = state.isOpen && showsInput
    }

    /// The capsule itself: a compact status pill that grows into a rounded card
    /// as the request is typed and as Codex's answers arrive.
    private var pill: some View {
        // Center-aligned so the status indicator stays centered as the pill
        // widens; the message/answers keep their own full-width leading frame.
        VStack(alignment: .center, spacing: 10) {
            // The message the user just sent, echoed while the model thinks.
            if showsUserText {
                Text(verbatim: state.userMessage)
                    .font(.system(size: PillText.fontSize, weight: .regular, design: .rounded))
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

            // Recent-chats switcher (↑ from the empty new-chat state).
            if state.isSwitching {
                ChatSwitcherList(
                    options: state.chatOptions,
                    selection: state.switcherSelection,
                    onSelect: { onReinstate($0) },
                    onHover: { state.setSwitcherSelection($0) }
                )
                .focusable()
                .focused($switcherFocused)
                .focusEffectDisabled()
                .transition(.opacity)
                .onKeyPress(.upArrow) { state.moveSwitcher(by: -1); return .handled }
                .onKeyPress(.downArrow) {
                    // ↓ past the last (latest) row drops back to the empty state.
                    if state.switcherAtLast { state.closeSwitcher() }
                    else { state.moveSwitcher(by: 1) }
                    return .handled
                }
                .onKeyPress(.return) {
                    if let id = state.selectedChatID { onReinstate(id) }
                    return .handled
                }
                .onKeyPress(.escape) { state.closeSwitcher(); return .handled }
            }

            // Bottom-left status affordance: tool steps while thinking, else the
            // plain "Thinking" row.
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
            }
        }
        .padding(.horizontal, textPadding)
        .padding(.vertical, expanded ? 16 : 0)
        .frame(minWidth: pillSize.width, minHeight: pillSize.height)
        .frame(maxWidth: expanded ? expandedWidth : nil, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The composer: a borderless field styled to match the answers so it blends
    /// into the pill. Enter sends; the caret is grabbed on open via `syncFocus()`.
    private var inputField: some View {
        // Grows with the text, capped at 5 lines (then scrolls internally).
        TextField("Ask anything…", text: $state.draft, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .font(.system(size: PillText.fontSize, weight: .regular, design: .rounded))
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
            // ↑ on an empty field in the new-chat state opens the recent-chats
            // switcher; with any text typed it stays a normal caret move.
            .onKeyPress(.upArrow) {
                guard state.draft.isEmpty, state.isEmptyNewChat else { return .ignored }
                onOpenSwitcher()
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

/// The recent-chats list shown when ↑ is pressed in the empty new-chat state.
/// Rows are chronological (oldest first); the selected row is highlighted, and
/// the whole list carries focus so arrows/Enter drive it (see PillView).
private struct ChatSwitcherList: View {
    let options: [ChatSummary]
    let selection: Int
    var onSelect: (UUID) -> Void
    var onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, chat in
                    ChatSwitcherRow(chat: chat, selected: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(chat.id) }
                        .onHover { if $0 { onHover(index) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row: the chat's first user message (truncated) plus its age, anchored to
/// the first message. The selected row brightens and gets a subtle fill.
private struct ChatSwitcherRow: View {
    let chat: ChatSummary
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(chat.firstUserMessage)
                .font(.system(size: PillText.fontSize, weight: .regular, design: .rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Self.relativeAge(chat.startedAt))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(selected ? 0.55 : 0.3))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(selected ? 0.12 : 0))
        )
    }

    /// Compact relative age like "3m", "6d", "7mo" (m = minutes, mo = months).
    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60:          return "now"
        case ..<3600:        return "\(Int(s / 60))m"
        case ..<86_400:      return "\(Int(s / 3600))h"
        case ..<2_592_000:   return "\(Int(s / 86_400))d"
        case ..<31_536_000:  return "\(Int(s / 2_592_000))mo"
        default:             return "\(Int(s / 31_536_000))y"
        }
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
        onOpenSwitcher: {},
        onReinstate: { _ in },
        onQuit: {}
    )
    .frame(width: 420, height: 300)
    .background(.gray)
}
