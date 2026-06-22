import SwiftUI

/// Custom settings chrome (issue 13 §3) — the prototype's hand-rolled toggle/segment/chip
/// pixels (`sw`/`seg` helpers, prototype lines 672–673), which the native `Picker`/`Toggle`
/// can't match. Theme-dependent off-state colors come from `@Environment(\.colorScheme)`,
/// which is the scheme `ThemedRoot` has already forced — so `light`/`dark`/`system` all
/// resolve correctly here.

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
    @Environment(\.colorScheme) private var scheme

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
        .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() } }
        .accessibilityElement()
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Segmented control (single-select pills on a track)

struct WattlySegment<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var fontSize: CGFloat = 12.5
    var pillVPadding: CGFloat = 7
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tokens) private var t

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
        return Text(label)
            .font(WattlyFont.at(fontSize, weight: .semibold))
            .foregroundStyle(active ? t.text : scheme.segInactiveText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, pillVPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? scheme.segActiveBg : .clear)
                    .shadow(color: active ? scheme.segActiveShadow : .clear, radius: 1, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Multi-select chip (menu metrics)

struct WattlyChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tokens) private var t

    var body: some View {
        Text(label)
            .font(WattlyFont.at(12, weight: .semibold))
            .foregroundStyle(isOn ? t.text : scheme.segInactiveText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? scheme.segActiveBg : .clear)
                    .shadow(color: isOn ? scheme.segActiveShadow : .clear, radius: 1, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Layout wrappers

/// A titled section: the 11px/700/tracking caption + its content (prototype gap 9).
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.tokens) private var t

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

/// The bordered rounded container that groups rows (prototype `rowBg`/`rowBorder`, radius 10).
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.rowBg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.rowBorder, lineWidth: 1))
    }
}

/// One toggle row: title (+ optional accessory/subtitle) on the left, `WattlyToggle` right.
/// `divider` draws the 1px bottom separator used between grouped rows.
struct SettingsToggleRow<Label: View>: View {
    @Binding var isOn: Bool
    let divider: Bool
    @ViewBuilder var label: () -> Label
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                label()
                Spacer(minLength: 8)
                WattlyToggle(isOn: $isOn)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            if divider {
                Rectangle().fill(t.line).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
