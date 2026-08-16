import SwiftUI
import AppKit

/// Custom settings chrome (issue 13 §3) — the prototype's hand-rolled toggle/segment/chip
/// pixels (`sw`/`seg` helpers, prototype lines 672–673), which the native `Picker`/`Toggle`
/// can't match. Theme-dependent off-state colors come from `@Environment(\.colorScheme)`,
/// which is the scheme `ThemedRoot` has already forced — so `light`/`dark`/`system` all
/// resolve correctly here.

// MARK: - Focus ring (DS README §148, issue 15 §5)

extension View {
    /// The DS keyboard-focus ring: a 2px accent stroke offset 2px from the surface, shown
    /// while this control holds focus. `.focusEffectDisabled()` suppresses the default system
    /// ring so only ours draws. NOTE: macOS gates Tab focus to non-text controls behind
    /// System Settings › Keyboard › "Keyboard Navigation", so the ring is visible only while
    /// that setting is on (issue 15 수용 기준). VoiceOver reachability is independent of it.
    func wattlyFocusRing(_ focused: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .strokeBorder(Tokens.accent, lineWidth: 2)
                .padding(-2)
                .opacity(focused ? 1 : 0)
        )
        .focusEffectDisabled()
    }
}

// MARK: - Theme-dependent chrome colors (prototype `sw`/`seg`)

private extension ColorScheme {
    /// Switch OFF-track fill (prototype `sw`: dark 0.24 / light 0.28 neutral).
    var switchOffBg: Color {
        self == .dark ? .rgba(174, 176, 182, 0.24) : .rgba(112, 115, 124, 0.28)
    }
    /// Active segment/chip fill (prototype `seg`: dark #3a3b3e / light #fff).
    var segActiveBg: Color {
        self == .dark ? Color(hex: "#3a3b3e") : Color(hex: "#ffffff")
    }
    /// Inactive segment/chip text (prototype `seg`: 0.55 of the body color).
    var segInactiveText: Color {
        self == .dark ? .rgba(247, 247, 248, 0.55) : .rgba(46, 47, 51, 0.55)
    }
    /// Active segment shadow — light only (prototype `seg`).
    var segActiveShadow: Color {
        self == .dark ? .clear : .rgba(23, 23, 23, 0.10)
    }
}

// MARK: - Toggle (38×22, knob 18, left 2↔18)

struct WattlyToggle: View {
    @Binding var isOn: Bool
    let isEnabled: Bool
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 11)
                .fill(isOn ? Tokens.accent : scheme.switchOffBg)
                .frame(width: 38, height: 22)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                .padding(.horizontal, 2)
        }
        .frame(width: 38, height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            toggle()
            focused = false
        }
        .focusable(isEnabled)
        .focused($focused)
        .onKeyPress(.space) { guard isEnabled else { return .ignored }; toggle(); return .handled }
        .onKeyPress(.return) { guard isEnabled else { return .ignored }; toggle(); return .handled }
        .opacity(isEnabled ? 1 : 0.5)
        .wattlyFocusRing(focused, cornerRadius: 11)
        // The combined `SettingsToggleRow` owns the VoiceOver element (label + 켜짐/꺼짐 +
        // actuation, issue 15 §11) — the bare switch is hidden so it isn't a duplicate stop.
        .accessibilityHidden(true)
    }

    private func toggle() { withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() } }
}

// MARK: - Segmented control (single-select pills on a track)

struct WattlySegment<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var fontSize: CGFloat = 12.5
    var pillVPadding: CGFloat = 7
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tokens) private var t
    @FocusState private var focusedValue: T?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                pill(option.value, option.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
    }

    private func pill(_ value: T, _ label: String) -> some View {
        let active = selection == value
        return Text(LocalizedStringKey(label))
            .font(WattlyFont.at(fontSize, weight: .semibold))
            .foregroundStyle(active ? t.text : scheme.segInactiveText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .padding(.vertical, pillVPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? scheme.segActiveBg : .clear)
                    .shadow(color: active ? scheme.segActiveShadow : .clear, radius: 1, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selection = value
                focusedValue = nil
            }
            .focusable()
            .focused($focusedValue, equals: value)
            .onKeyPress(.space) { selection = value; return .handled }
            .onKeyPress(.return) { selection = value; return .handled }
            .wattlyFocusRing(focusedValue == value, cornerRadius: 6)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Multi-select chip (menu metrics)

struct WattlyChip: View {
    let label: String
    let isOn: Bool
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tokens) private var t
    @FocusState private var focused: Bool

    init(label: String, isOn: Bool, isEnabled: Bool = true, disabledReason: String? = nil,
         action: @escaping () -> Void) {
        self.label = label
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.action = action
    }

    var body: some View {
        Text(LocalizedStringKey(label))
            .font(WattlyFont.at(12, weight: .semibold))
            .foregroundStyle(isOn ? t.text : scheme.segInactiveText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? scheme.segActiveBg : .clear)
                    .shadow(color: isOn ? scheme.segActiveShadow : .clear, radius: 1, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                action()
                focused = false
            }
            .focusable(isEnabled)
            .focused($focused)
            .onKeyPress(.space) { guard isEnabled else { return .ignored }; action(); return .handled }
            .onKeyPress(.return) { guard isEnabled else { return .ignored }; action(); return .handled }
            .opacity(isEnabled ? 1 : 0.45)
            .wattlyFocusRing(focused, cornerRadius: 6)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
            .accessibilityAction { guard isEnabled else { return }; action() }
    }
}

// MARK: - Layout wrappers

/// A top-level group label (표시/동작 in `SettingsView`) — larger and bolder than
/// `SettingsSection`'s per-section caption, with no divider line (settings-card-unification).
/// Used ONLY above groups with 2+ sections; a lone-section group (시스템) reuses its single
/// section's own `SettingsSection` caption instead, so two redundant captions never stack
/// directly on top of each other.
struct SettingsGroupHeader: View {
    let title: LocalizedStringKey
    @Environment(\.tokens) private var t

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    init(title: LocalizedStringKey) {
        self.title = title
    }

    init(_ title: String) {
        self.title = LocalizedStringKey(title)
    }

    init(title: String) {
        self.title = LocalizedStringKey(title)
    }

    var body: some View {
        Text(title)
            .font(WattlyFont.at(12, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(t.faint)
    }
}

/// A titled section: the 11px/700/tracking caption + its content (prototype gap 9).
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @Environment(\.tokens) private var t

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = LocalizedStringKey(title)
        self.content = content
    }

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = LocalizedStringKey(title)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(WattlyFont.at(11, weight: .bold))
                .tracking(0.33)
                .foregroundStyle(t.faint)
            content()
        }
    }
}

/// The bordered rounded container that groups rows (prototype `rowBg`/`rowBorder`). Radius
/// matches the popover's Mode A/B cards via `Tokens.cardRadius` (settings-card-unification) —
/// previously a separately-chosen literal `10`.
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(t.rowBg))
            .overlay(RoundedRectangle(cornerRadius: Tokens.cardRadius).strokeBorder(t.rowBorder, lineWidth: 1))
    }
}

/// One toggle row: title (+ optional accessory/subtitle) on the left, `WattlyToggle` right.
/// `divider` draws the 1px bottom separator used between grouped rows.
struct SettingsToggleRow<Label: View>: View {
    @Binding var isOn: Bool
    let divider: Bool
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    @ViewBuilder var label: () -> Label
    @Environment(\.tokens) private var t

    init(isOn: Binding<Bool>, divider: Bool, isEnabled: Bool = true, disabledReason: String? = nil,
         @ViewBuilder label: @escaping () -> Label) {
        _isOn = isOn
        self.divider = divider
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.label = label
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                label()
                Spacer(minLength: 8)
                WattlyToggle(isOn: $isOn, isEnabled: isEnabled)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            if divider {
                Rectangle().fill(t.line).frame(height: 1)
            }
        }
        // One combined VoiceOver element: the row's title (from `.combine`) + the on/off
        // state as a spoken value + a toggle action (issue 15 §11). The state copy lives
        // HERE, not on `WattlyToggle` — the `.isSelected` trait alone is announced as
        // "선택됨", not "켜짐/꺼짐".
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "켜짐" : "꺼짐")
        .accessibilityAddTraits(isEnabled ? .isButton : .isStaticText)
        .accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
        .accessibilityAction { guard isEnabled else { return }; isOn.toggle() }
    }
}

/// Standard title for a settings row (13.5px semibold) with optional regular faint suffix.
struct SettingsRowTitle: View {
    let title: LocalizedStringKey
    var suffix: LocalizedStringKey? = nil
    @Environment(\.tokens) private var t

    init(_ title: LocalizedStringKey, suffix: LocalizedStringKey? = nil) {
        self.title = title
        self.suffix = suffix
    }

    init(_ title: String, suffix: String? = nil) {
        self.title = LocalizedStringKey(title)
        self.suffix = suffix.map { LocalizedStringKey($0) }
    }

    var body: some View {
        if let suffix {
            (Text(title).font(WattlyFont.at(13.5, weight: .semibold)).foregroundColor(t.text)
                + Text(verbatim: " ")
                + Text(suffix).font(WattlyFont.at(11.5, weight: .regular)).foregroundColor(t.faint))
        } else {
            Text(title).font(WattlyFont.at(13.5, weight: .semibold)).foregroundStyle(t.text)
        }
    }
}

// MARK: - Window Appearance Sync

/// Reactively syncs the Settings window's own `NSAppearance` to the theme setting.
/// `.preferredColorScheme` (applied by `ThemedRoot.body`) only sets the color-scheme
/// trait SwiftUI content renders with — it does NOT re-resolve an already-visible `NSWindow`'s
/// AppKit-drawn chrome (the native titlebar) after the theme changes; that chrome only picks up
/// the new value the next time the window is created. Assigning `.appearance` on the hosting
/// window directly, on every reactive update, fixes it.
final class WindowAppearanceSyncView: NSView {
    var mode: ThemeMode = .system {
        didSet { applyAppearance() }
    }

    private var systemAppearanceObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    private func applyAppearance() {
        let resolved: NSAppearance? = mode == .system
            ? NSAppearance(named: SystemAppearance.isDark() ? .darkAqua : .aqua)
            : ThemeResolver.nsAppearance(mode)
        window?.appearance = resolved
    }
}

struct WindowAppearanceSync: NSViewRepresentable {
    let mode: ThemeMode

    func makeNSView(context: Context) -> WindowAppearanceSyncView {
        WindowAppearanceSyncView()
    }

    func updateNSView(_ nsView: WindowAppearanceSyncView, context: Context) {
        nsView.mode = mode
    }
}


