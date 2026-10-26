import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Shared SwiftUI primitives — the mark, headers, list rows, callouts.
//
// Each one mirrors a component from the prototype's parts.jsx (see file
// for vocabulary). Microcopy and visual patterns are deliberately faithful
// — see HANDOFF.md "Keep these copies verbatim" and "Visual language".

// MARK: - Layout

/// Cross-screen layout helpers driven by runtime system metrics so we
/// don't sprinkle hardcoded paddings tuned for a single device.
public enum CairnLayout {
    /// Gap we want between the top system chrome and the wordmark.
    private static let brandHeaderGap: CGFloat = 30

    /// Total clearance to fall back to when the system reports no top
    /// safe-area inset at all — an iPhone-only app in iPad compat mode,
    /// whose chrome is drawn outside the iPhone window's reported safe
    /// area. Enough to clear it unaided.
    private static let brandHeaderCompatClearance: CGFloat = 96

    /// Top padding for the hand-rolled brand header (Status + Setup
    /// wordmarks) — sits the cairn mark a comfortable distance below
    /// whatever system chrome is at the top of the screen.
    ///
    /// Both headers live inside a `ScrollView` that SwiftUI has already
    /// inset for the top safe area, so the status bar is *already*
    /// accounted for before this padding applies. The previous
    /// implementation added the measured status-bar height on top of
    /// that, double-counting it: the comment claimed "status bar + ~30pt
    /// gap" but the result was the safe-area inset plus a further 96pt,
    /// putting the wordmark ~155pt down a 15 Pro instead of ~89pt.
    ///
    /// So: measure the inset that's already applied and pad only by
    /// what's missing. On any real iPhone the inset covers the chrome
    /// and this is just `brandHeaderGap`; where the system reports no
    /// inset, it widens to clear the chrome itself.
    ///
    /// Computed property (not a constant) so device rotation / scene
    /// changes pick up the new value on next render.
    public static var brandHeaderTopPadding: CGFloat {
        #if canImport(UIKit)
        let inset = activeTopSafeAreaInset()
        return max(brandHeaderCompatClearance - inset, brandHeaderGap)
        #else
        return 60
        #endif
    }

    #if canImport(UIKit)
    /// Top safe-area inset of the foreground window — the amount
    /// SwiftUI has already pushed our content down by. Returns 0 if no
    /// scene is active (during launch) or when the platform reports
    /// none, which is the case the compat clearance exists for.
    private static func activeTopSafeAreaInset() -> CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first
        else { return 0 }
        let window = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        return window?.safeAreaInsets.top ?? 0
    }
    #endif
}

// MARK: - Inline wordmark

extension Text {
    /// The inline-prose form of the cairn wordmark. Monospace so the name
    /// reads visually differently from surrounding prose — mirrors the
    /// "with text" logo variant which is set in Fira Code. Preserves the
    /// inherited font size via `.monospaced()` (iOS 16+), so the glyphs
    /// are the same height as the sentence they sit in.
    ///
    /// **Use when:** "cairn" appears inside a prose sentence
    /// (`Text("… so ") + .cairnWord + Text(" can detect …")`).
    ///
    /// **Do NOT use when:** "cairn" is the standalone hero wordmark /
    /// page title — those instances have their own display-size treatment
    /// (`Text("cairn").font(.cairnScaled(size: 28, weight: .semibold))` + the
    /// `CairnMark` image alongside) and should remain distinct from the
    /// inline treatment to read as a brand element.
    public static var cairnWord: Text {
        Text("cairn").monospaced()
    }
}

// MARK: - Press feedback

/// Shared press-in animation for every tappable surface that isn't a full-
/// width CTA. Gives the subtle scale + dim the iOS system uses on
/// controls — without it, our custom-styled Buttons feel dead, like
/// they've been disabled. Duration is short enough to feel immediate
/// (snappy) and still read as "I was pressed."
///
/// Apply on any `Button` where the visuals are already styled manually
/// (chips, icon buttons, segmented toggles) — replaces `.buttonStyle(.plain)`.
public struct CairnPressStyle: ButtonStyle {
    public init() {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? .none : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Chip

/// Standard small action chip — bordered rect, 11pt semibold tracked text,
/// compact padding. The one place in the UI to reach for when you want
/// a tappable label that reads as "button, but unobtrusive." Mirrors the
/// prototype's `.btn-ghost` pattern.
///
/// Use for per-row actions ("Trash now", "Exclude", "Remove") and
/// secondary callout affordances ("Bulk exclude N"). For full-width CTAs
/// use the button patterns in the host view directly — those need
/// different sizing and tone logic.
public struct CairnChip: View {
    public enum Tone: Sendable {
        case neutral
        case danger
    }

    let label: String
    let tone: Tone
    let accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    public init(
        _ label: String,
        tone: Tone = .neutral,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.tone = tone
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel(accessibilityLabel ?? label)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return t.textBody
        case .danger:  return t.dangerInk
        }
    }
}

// MARK: - Brand mark

/// The 3-stone cairn brand mark at small/medium sizes — tab bar, row
/// icons, step headers. Two monochromatic SVGs composed via `ZStack`,
/// each template-rendered so tints flow from `cairnTokens`:
///
///   - `CairnMarkStones` — the stack itself, tinted `t.textMuted` so it
///     softens to mid-gray on both schemes (`slate` in light mode,
///     `pebble` in dark) rather than punching out at full black /
///     full white. The mark is a brand element, not body text — it
///     should feel calm.
///   - `CairnMarkCap` — the accent on top, tinted `t.primary` (brand
///     red, fixed across themes).
///
/// Both SVGs share an identical viewBox so the overlay registers
/// pixel-accurately. Each imageset carries
/// `template-rendering-intent: "template"` in its Contents.json — the
/// flag that lets `.foregroundStyle` override the authored fill color.
///
/// For a large, detailed "impression" rendering (onboarding hero,
/// splash), use `CairnHeroMark` instead — that one keeps the original
/// multi-color SVG with shading and is deliberately NOT theme-responsive
/// (the design leans on the specific color values).
///
/// `crowned` is accepted for source compatibility with call sites
/// written before the SVG swap; the cap always renders now regardless.
public struct CairnMark: View {
    public var size: CGFloat
    public var crowned: Bool

    @Environment(\.cairnTokens) private var t

    public init(size: CGFloat = 22, crowned: Bool = false) {
        self.size = size
        self.crowned = crowned
    }

    public var body: some View {
        ZStack {
            Image("CairnMarkStones", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(t.textMuted)
            Image("CairnMarkCap", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(t.primary)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("cairn")
    }
}

/// Large, detailed cairn mark for hero placements — onboarding splash,
/// the initial-scan takeover screen, anywhere the user's gaze dwells.
/// Renders the original multi-color SVG (shaded stones, accented cap,
/// subtle highlights) verbatim — **not** theme-responsive. Use
/// `CairnMark` (the small, adaptive sibling) for any surface that has
/// to flip with the system appearance.
public struct CairnHeroMark: View {
    public var size: CGFloat

    public init(size: CGFloat = 72) {
        self.size = size
    }

    public var body: some View {
        Image("CairnMarkRich", bundle: .module)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("cairn")
    }
}

// MARK: - Composed wordmark

/// The brand wordmark with the cairn mark standing in for the letter
/// "i": rendered as `ca` + ⟨mark⟩ + `rn`. No SVG text needed — we
/// compose three live views so the "ca"/"rn" segments inherit the
/// current theme and variable-font weight, and the mark swaps between
/// the adaptive-tinted `CairnMark` and the rich multi-color
/// `CairnHeroMark` via the `variant` parameter.
///
/// **Alignment.** Segments and the mark share `firstTextBaseline`.
/// An `alignmentGuide` anchors the mark's bottom to the text baseline
/// so it sits on the baseline the same way a lowercase "i" would,
/// rather than floating in the middle of the x-height.
///
/// **Sizing.** The mark's side length is proportional to `size` and
/// tuned by feel — at `size * 0.9` the three-stone stack reads as a
/// letter-sized glyph in Fira Code / SF Mono without dominating the
/// surrounding text. Override via `markScale` when a particular
/// surface wants a heavier or lighter mark.
///
/// **Baseline sits just below visual baseline.** Text in a
/// monospaced font has a small descender gap under the visible
/// glyphs; pulling the mark up by `size * 0.06` puts its bottom at
/// the *visible* baseline (where "c" and "n" touch the baseline
/// line) rather than at the descender line.
public struct CairnWordmark: View {
    public enum Variant: Sendable {
        /// Adaptive 2-image composition (stones tinted `textMuted`,
        /// cap tinted `primary`). Use on surfaces that already flow
        /// theme tokens.
        case adaptive
        /// Rich multi-color SVG. Use on hero / splash surfaces where
        /// the detailed art is the point.
        case hero
    }

    public enum Style: Sendable {
        /// Mark on the left, full "cairn" text on the right — the
        /// default production treatment. Looks like a classic
        /// brand lockup.
        case iconPrefix
        /// Mark stands in for the letter "i" in "cairn", rendered
        /// as `ca` + ⟨mark⟩ + `rn`. An experimental alternative;
        /// not currently used in production surfaces.
        case splitI
    }

    public let size: CGFloat
    public let weight: Font.Weight
    public let variant: Variant
    public let style: Style
    /// Mark side length as a fraction of `size`. `nil` defers to
    /// the per-style default from `Self.defaultMarkScale(style:)`,
    /// which is tuned per arrangement (icon-prefix needs a heavier
    /// mark to balance the full word, split-I a lighter one to sit
    /// between glyphs).
    public let markScale: CGFloat?
    /// Gap between mark and text as a fraction of `size`. `nil`
    /// defers to `Self.defaultSpacingRatio(style:variant:)`.
    public let spacingRatio: CGFloat?
    /// Text tracking as a fraction of `size`. `nil` defers to the
    /// style default. Observed production values (-0.6 at 28pt,
    /// -0.8 at 40pt) ≈ size × -0.021.
    public let trackingRatio: CGFloat?

    @Environment(\.cairnTokens) private var t

    public init(
        size: CGFloat,
        weight: Font.Weight = .semibold,
        variant: Variant = .adaptive,
        style: Style = .iconPrefix,
        markScale: CGFloat? = nil,
        spacingRatio: CGFloat? = nil,
        trackingRatio: CGFloat? = nil
    ) {
        self.size = size
        self.weight = weight
        self.variant = variant
        self.style = style
        self.markScale = markScale
        self.spacingRatio = spacingRatio
        self.trackingRatio = trackingRatio
    }

    // MARK: Style defaults

    /// Per-style mark-to-font ratios. Tweaks here propagate to
    /// every call site that doesn't override locally — one-place
    /// tuning for the whole app's brand surfaces.
    public static func defaultMarkScale(style: Style, variant: Variant) -> CGFloat {
        switch (style, variant) {
        case (.iconPrefix, .adaptive): return 1.11   // nav-chrome lockup (31pt at 28pt text)
        case (.iconPrefix, .hero):     return 1.75   // Setup hero lockup (70pt at 40pt text)
        case (.splitI, _):             return 1.00
        }
    }

    public static func defaultSpacingRatio(style: Style, variant: Variant) -> CGFloat {
        switch (style, variant) {
        // Tightened from 0.25 to 0.125 after reading the lockup at
        // size — the wider gap read as "mark floating beside word"
        // rather than "mark anchoring the word." The current ratio
        // yields 3.5pt at 28pt text (nav chrome) and 5pt at 40pt
        // text (Setup hero).
        case (.iconPrefix, .adaptive): return 0.125
        case (.iconPrefix, .hero):     return 0.125
        case (.splitI, _):             return 0.03   // very tight — mark is an inline glyph
        }
    }

    public static func defaultTrackingRatio(style: Style) -> CGFloat {
        -0.021   // -0.6@28pt, -0.8@40pt observed; same for both styles
    }

    // MARK: Body

    private var effectiveMarkScale: CGFloat {
        markScale ?? Self.defaultMarkScale(style: style, variant: variant)
    }
    private var effectiveSpacing: CGFloat {
        size * (spacingRatio ?? Self.defaultSpacingRatio(style: style, variant: variant))
    }
    private var effectiveTracking: CGFloat {
        size * (trackingRatio ?? Self.defaultTrackingRatio(style: style))
    }

    public var body: some View {
        Group {
            switch style {
            case .iconPrefix: iconPrefixBody
            case .splitI:     splitIBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("cairn")
    }

    private var iconPrefixBody: some View {
        HStack(spacing: effectiveSpacing) {
            mark
                .frame(width: size * effectiveMarkScale, height: size * effectiveMarkScale)
            Text("cairn")
                .font(.cairnMono(size: size, weight: weight))
                .tracking(effectiveTracking)
                .foregroundStyle(t.text)
        }
    }

    private var splitIBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("ca")
                .font(.cairnMono(size: size, weight: weight))
                .foregroundStyle(t.text)
            mark
                .frame(width: size * effectiveMarkScale, height: size * effectiveMarkScale)
                // Anchor the mark to the visual baseline of the
                // adjacent text. See `defaultSpacingRatio` comment;
                // the epsilon below is tuned for Fira Code at
                // semibold and is specific to split-I.
                .alignmentGuide(.firstTextBaseline) { d in
                    d.height - size * 0.06
                }
                .padding(.horizontal, effectiveSpacing)
            Text("rn")
                .font(.cairnMono(size: size, weight: weight))
                .foregroundStyle(t.text)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch variant {
        case .adaptive: CairnMark(size: size * effectiveMarkScale, crowned: true)
        case .hero:     CairnHeroMark(size: size * effectiveMarkScale)
        }
    }
}

// MARK: - App header

/// The screen header used at the top of every primary screen. Matches
/// prototype `parts.jsx::AppHeader` — title + optional subtitle, optional
/// leading and trailing slots.
public struct AppHeader<Leading: View, Trailing: View>: View {
    public let title: String
    public let subtitle: String?
    public let leading: Leading
    public let trailing: Trailing

    @Environment(\.cairnTokens) private var t

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !(leading is EmptyView) {
                    leading
                }
                Text(title)
                    .font(.cairnScaled(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.6)
                    .foregroundStyle(t.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                }
            }
            Spacer(minLength: 0)
            if !(trailing is EmptyView) {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

// MARK: - Section keyline

/// The all-caps section header used between cards. Matches prototype's
/// `<div class="keyline">` block.
///
/// Optional `icon` + `iconTint` add a small leading SF Symbol in a
/// semantic color — used in dense lists (Settings) where a string of
/// neutral-gray section titles makes it hard to scan. The icon carries
/// the color; the title stays in `textMuted` so the type hierarchy is
/// preserved. `nil` icon (the default) renders identically to the
/// pre-icon design — backwards-compatible across all existing
/// callsites.
public struct KeylineSection: View {
    public let title: String
    public let icon: String?
    public let iconTint: Color?
    public let trailing: AnyView?

    @Environment(\.cairnTokens) private var t

    public init(_ title: String, icon: String? = nil, iconTint: Color? = nil) {
        self.title = title
        self.icon = icon
        self.iconTint = iconTint
        self.trailing = nil
    }

    public init<V: View>(
        _ title: String,
        icon: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder trailing: () -> V
    ) {
        self.title = title
        self.icon = icon
        self.iconTint = iconTint
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(spacing: 7) {
            if let icon, let iconTint {
                Image(systemName: icon)
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            Text(CairnL10n.isChinese ? title.loc : title.loc.uppercased())
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

// MARK: - Card

/// The standard card container. Most settings rows and stat blocks live
/// inside one. Bone background on light, graphite on dark.
public struct CairnCard<Content: View>: View {
    public let content: Content

    @Environment(\.cairnTokens) private var t

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(t.divider, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Rows

/// Label-on-left, value-on-right list row with optional chevron + tap.
/// Matches prototype `KeyValRow`.
public struct KeyValRow: View {
    public let label: String
    public let value: AnyView
    public let mono: Bool
    public let chevron: Bool
    public let onTap: (() -> Void)?

    @Environment(\.cairnTokens) private var t

    public init<V: View>(
        _ label: String,
        @ViewBuilder value: () -> V,
        mono: Bool = false,
        chevron: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = AnyView(value())
        self.mono = mono
        self.chevron = chevron
        self.onTap = onTap
    }

    public init(
        _ label: String,
        value: String,
        mono: Bool = false,
        chevron: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.init(label, value: { Text(value) }, mono: mono, chevron: chevron, onTap: onTap)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label.loc)
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
            Spacer(minLength: 12)
            value
                .font(.cairnScaled(size: mono ? 13 : 15, design: mono ? .monospaced : .default))
                .foregroundStyle(t.textBody)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.cairnScaled(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .accessibilityAddTraits(onTap != nil ? [.isButton] : [])
    }
}

/// Toggle row: label on the left (with optional sublabel), switch on the
/// right. Mirrors prototype `ToggleRow`.
public struct ToggleRow: View {
    public let label: String
    public let sub: String?
    @Binding public var value: Bool

    @Environment(\.cairnTokens) private var t

    public init(_ label: String, sub: String? = nil, value: Binding<Bool>) {
        self.label = label
        self.sub = sub
        self._value = value
    }

    public var body: some View {
        HStack(alignment: sub == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.loc)
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                if let sub {
                    Text(sub.loc)
                        .font(.cairnScaled(size: 12))
                        .foregroundStyle(t.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Hide the visual VStack from VoiceOver — its content is
            // accessed via the merged row label instead so the toggle
            // announces with both label and sub-description.
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle("", isOn: $value)
                .labelsHidden()
                // Palette-sourced green for the on-state. Without
                // `.tint(...)` SwiftUI falls back to iOS's default
                // systemGreen, which is fine visually but mixes the
                // palette with the platform default. Standardising on
                // `t.verified` (cairn's seaweed-green) keeps every
                // toggle in the app sourcing its on-state from the
                // same token, in both color schemes.
                .tint(t.verified)
                .accessibilityLabel(label)
                .accessibilityHint(sub ?? "")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        // Merge row + toggle into one accessibility element so VoiceOver
        // users tap anywhere on the row to flip the switch. Without this
        // the visible row text and the switch live in separate elements
        // and the row label feels orphaned from its control.
        .accessibilityElement(children: .combine)
    }
}

/// Hairline divider used between rows inside a card.
public struct RowDivider: View {
    @Environment(\.cairnTokens) private var t
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(t.divider)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

// MARK: - Stats

/// A single labeled stat in a row of stats. Tabular-numeral large display
/// number above a small sub-caption. Mirrors prototype `Stat`.
public struct Stat: View {
    public let label: String
    public let value: String
    public let sub: String?
    public let color: Color?

    @Environment(\.cairnTokens) private var t

    public init(label: String, value: String, sub: String? = nil, color: Color? = nil) {
        self.label = label
        self.value = value
        self.sub = sub
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CairnL10n.isChinese ? label.loc : label.loc.uppercased())
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Text(value)
                .font(.cairnScaled(size: 24, weight: .semibold).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(color ?? t.text)
            if let sub {
                Text(sub.loc)
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Callouts

/// Inline-message block with a soft fill and a left-border accent.
/// Mirrors prototype `.callout-*` styles. Tone drives both the fill and
/// the accent ink.
public enum CalloutTone: Sendable {
    case info       // accent-info / blue
    case verified   // moss
    case pending    // amber
    case danger     // rust
}

public struct Callout<Content: View>: View {
    public let tone: CalloutTone
    public let icon: String?  // SF Symbol name
    public let content: Content

    @Environment(\.cairnTokens) private var t

    public init(_ tone: CalloutTone, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.cairnScaled(size: 14, weight: .semibold))
                    .foregroundStyle(inkColor)
            }
            content
                .font(.cairnScaled(size: 13))
                .foregroundStyle(inkColor)
        }
        // Fill the available horizontal width so callouts span the
        // same width as siblings like CairnCard. Without this, an
        // HStack containing only intrinsic-sized children (icon +
        // short Text) sizes to that intrinsic content and the
        // banner reads as visibly narrower than adjacent cards.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(softColor)
        .overlay(
            Rectangle()
                .fill(inkColor.opacity(0.55))
                .frame(width: 3)
                .padding(.vertical, -0.5),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var softColor: Color {
        switch tone {
        case .info: t.infoSoft
        case .verified: t.verifiedSoft
        case .pending: t.pendingSoft
        case .danger: t.dangerSoft
        }
    }

    private var inkColor: Color {
        switch tone {
        case .info: t.infoInk
        case .verified: t.verifiedInk
        case .pending: t.pendingInk
        case .danger: t.dangerInk
        }
    }
}

// MARK: - Help popover

/// Small question-mark glyph that presents an explanatory popover on
/// tap. Attach to any settings row whose meaning isn't self-evident —
/// the popover is where the detailed "why this exists" explanation
/// goes, rather than inline sub-text (which stays short and factual
/// for scannability).
///
/// **Styling.** The glyph is deliberately subtle — `textHint`-toned so
/// it reads as optional affordance, not as a required tap target.
/// Popover body uses `textBody` and scales from the root font size.
///
/// **Usage.**
/// ```swift
/// HStack {
///     Text("Deletion strictness")
///     HelpPopover {
///         Text("Strict: …")
///         Text("Trusting: …")
///     }
/// }
/// ```
///
/// On iPhone, SwiftUI defaults `.popover` to a sheet; we force popover
/// style via `.presentationCompactAdaptation(.popover)` so the hint
/// pops *near* the glyph rather than taking over the screen.
public struct HelpPopover<Content: View>: View {
    public let content: Content
    @State private var showing: Bool = false

    @Environment(\.cairnTokens) private var t

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.cairnScaled(size: 13, weight: .regular))
                .foregroundStyle(t.textHint)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        #if canImport(UIKit)
        // Presents via a UIKit bridge (see CairnHelpPopoverBridge) so
        // we can install a custom `UIPopoverBackgroundView` and stroke
        // the entire popover chrome — body and arrow — as one
        // continuous outline. SwiftUI's `.popover` doesn't expose the
        // background class, so a pure-SwiftUI `.overlay(stroke)` can
        // only outline the inner content rectangle, leaving a visible
        // break where the arrow joins the body.
        .background(
            CairnHelpPopoverPresenter(
                isPresented: $showing,
                fillColor: t.surface,
                strokeColor: t.textMuted
            ) {
                helpPopoverContent
                    .environment(\.cairnTokens, t)
            }
        )
        #else
        // Non-UIKit platforms (Catalyst-only builds, future macOS
        // host) fall back to the SwiftUI popover with the
        // content-rect-only outline. The bridge requires
        // UIPopoverBackgroundView which is iOS-only.
        .popover(isPresented: $showing, arrowEdge: .top) {
            helpPopoverContent
                .frame(idealWidth: 300, maxWidth: 340, minHeight: 80, idealHeight: 200, maxHeight: 420)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(t.textMuted, lineWidth: 1)
                )
                .presentationCompactAdaptation(.popover)
                .presentationBackground(t.surface)
        }
        #endif
    }

    /// Shared SwiftUI body for the popover content — pulled out so
    /// both the UIKit-bridged path (iOS) and the SwiftUI fallback
    /// render the same thing. Inner padding of 20 keeps text from
    /// running flush to the chrome edges as it scrolls.
    @ViewBuilder
    private var helpPopoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .font(.cairnScaled(size: 14))
            .foregroundStyle(t.textBody)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(t.surface)
    }
}

// MARK: - Banner transitions

/// Shared entrance/exit transition for inline banners (Callouts)
/// across the app. Asymmetric by design:
///
///   - **Insertion**: slide-in from the top + fade, so the banner
///     visibly arrives from above. Paired with a lightly-damped
///     spring (see `cairnBannerAnimation`) it overshoots slightly
///     before settling — enough bounce to feel alive without
///     looking toy-ish.
///   - **Removal**: collapse-to-zero vertically from the top edge
///     + fade, rather than sliding back up. The effect reads as
///     the banner "retracting" into the element above it — more
///     playful than a symmetric slide-out, and visually distinct
///     so the user registers "gone" rather than "temporarily
///     shifted."
public extension AnyTransition {
    static var cairnBanner: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .top))
        )
    }

    /// Bottom-anchored sibling of `cairnBanner` for elements that
    /// arrive from below the fold — selection action bars, footer
    /// swaps, contextual bottom toolbars. Same shape, mirrored
    /// anchors, so the motion vocabulary stays consistent.
    static var cairnBannerBottom: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .bottom))
        )
    }

    /// Centered scale+fade for inline elements without a clear edge
    /// affinity — inline flashes, chips that flicker in, small
    /// floating callouts. Enters slightly undersized and springs
    /// out to full size; leaves by collapsing toward its center
    /// rather than sliding off-axis.
    static var cairnPop: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .center)),
            removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .center))
        )
    }
}

public extension Animation {
    /// The canonical "cairn springy" timing for **banner enter/exit**
    /// and other appearance-class motion — lightly-overshooting spring
    /// that reads as alive without feeling toy-ish.
    /// Response 0.5s / damping 0.58. Paired with `.cairnBanner`
    /// transitions at sites like StatusScreen, PendingReview, DryRun.
    static func cairnSpring(response: Double = 0.5, damping: Double = 0.58) -> Animation {
        .spring(response: response, dampingFraction: damping)
    }

    static var cairnSpring: Animation { cairnSpring() }
    static var cairnSpringSnappy: Animation { cairnSpring(response: 0.28, damping: 0.62) }
    static var cairnSpringTab: Animation { cairnSpring(response: 0.22, damping: 0.68) }
}

public extension View {
    /// Apply the canonical cairn spring animation keyed on a value
    /// whose change drives the transition. Any Equatable works —
    /// `Bool` for single-banner visibility, `[Bool]` for a bundle
    /// (see `StatusScreen.bannerVisibilityKey`).
    ///
    /// Keep `.transition(.cairnBanner)` and this modifier paired at
    /// the parent: the transition describes shape, the animation
    /// describes timing.
    func cairnBannerAnimation<V: Equatable>(value: V) -> some View {
        modifier(CairnBannerAnimationModifier(value: value))
    }
}

private struct CairnBannerAnimationModifier<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .none : .cairnSpring, value: value)
    }
}

// MARK: - Swipe-to-dismiss modifier

public extension View {
    /// Makes a non-critical banner swipeable off-screen. A
    /// horizontal drag past ~60pt in either direction fires
    /// `onDismiss`; partial drags rubber-band back in place.
    /// Pairs well with a dismissal-tracking `@State` that
    /// re-shows the banner when underlying state changes
    /// (e.g. the queue grew by one item). Keep off the
    /// critical degraded / initial-scan banners — those are
    /// actionable and shouldn't be swipable away.
    func cairnSwipeToDismiss(onDismiss: @escaping () -> Void) -> some View {
        modifier(CairnSwipeDismissModifier(onDismiss: onDismiss))
    }
}

private struct CairnSwipeDismissModifier: ViewModifier {
    let onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance threshold past which the drag commits to a
    /// dismiss. Shorter feels flaky; longer requires an
    /// awkward full-finger swipe.
    private let dismissThreshold: CGFloat = 60

    func body(content: Content) -> some View {
        content
            .offset(x: dragOffset)
            .opacity(1.0 - min(1.0, abs(dragOffset) / 200.0))
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .onChanged { value in
                        // Only horizontal. Clamp vertical
                        // slop so diagonal drags feel grounded.
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.width) > dismissThreshold {
                            withAnimation(reduceMotion ? .none : .snappy(duration: 0.22)) {
                                dragOffset = value.translation.width > 0 ? 400 : -400
                            }
                            // Commit dismiss on the next runloop so
                            // the exit animation plays before the
                            // view leaves the tree.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onDismiss()
                            }
                        } else {
                            withAnimation(reduceMotion ? .none : .snappy(duration: 0.18)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }
}

// MARK: - Keyboard dismissal helpers

#if canImport(UIKit)
import UIKit

extension UIApplication {
    /// Resigns whatever view is currently first responder. Used by
    /// the tap-to-dismiss modifier below — sending
    /// `resignFirstResponder` up a nil target walks the responder
    /// chain, which includes the focused TextField.
    fileprivate func cairn_endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

public extension View {
    /// Attaches a tap gesture on a transparent background layer
    /// that dismisses the keyboard. Safe to compose on top of
    /// ScrollViews — the background sits behind interactive
    /// content, so taps on fields / buttons still hit their
    /// handlers; only taps on otherwise-empty chrome bubble up
    /// to this gesture.
    ///
    /// Pair with the built-in `.scrollDismissesKeyboard(.interactively)`
    /// on the parent ScrollView for drag-to-dismiss coverage.
    /// Together they replace the keyboard-toolbar "Done" pattern,
    /// which renders awkwardly on iOS 26 / Liquid Glass.
    func cairnDismissKeyboardOnBackgroundTap() -> some View {
        #if canImport(UIKit)
        background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.cairn_endEditing()
                }
        )
        #else
        self
        #endif
    }
}

// MARK: - Numeric parse helpers

/// Shared parse closures for the `EditableNumericField.parse`
/// argument. Every slider + numeric-input row in the app was
/// inlining the same filter-then-init lambda (`Double($0.filter {
/// "0123456789".contains($0) })` / with a decimal variant); this
/// is the canonical version.
public enum NumericInputParse {
    /// Integer parse — accepts any input, keeps only digits, then
    /// converts to Double. Use for "whole number" sliders like
    /// Quarantine window, Count floor, iCloud limit MB, backlog
    /// threshold.
    public static func integer(_ raw: String) -> Double? {
        Double(raw.filter { "0123456789".contains($0) })
    }

    /// Decimal parse — keeps digits plus a single `.`. Use for
    /// percent-style sliders (e.g., percent threshold = 1.5%).
    /// Multiple dots in the raw input will parse as invalid
    /// (Double init returns nil), matching user expectation.
    public static func decimal(_ raw: String) -> Double? {
        Double(raw.filter { "0123456789.".contains($0) })
    }
}

// MARK: - Slider input row

/// Slider paired with an editable numeric field. Standard "settings
/// control" pattern across the app — drag the slider for a rough
/// value, tap the field to type the exact one. Two-way binding:
/// slider moves update the field; a commit on the field (blur or
/// Done-tap) parses, clamps into `range`, snaps to `step`, writes
/// back to `value`.
///
/// **Style axis.** Two preset visual densities:
///   - `.standard` — label + field on top, optional sub-text,
///     slider last. Larger label, generous padding. Used in the
///     main Settings screen.
///   - `.compact` — tighter padding, smaller label, sub-text
///     *below* the slider (matches the InitialScan scan-options
///     treatment where rows live in a dense expanded card).
///
/// `format` turns a model value into the display string (without
/// unit). `unitSuffix` is appended when the field is idle and
/// stripped when focused so typing isn't tangled with the glyph.
/// `parse` extracts a value from arbitrary user input — see
/// `NumericInputParse.integer` / `.decimal` for the canonical
/// shapes.
public struct SliderInputRow: View {
    public enum Style: Sendable {
        case standard
        case compact
    }

    public let label: String
    public let sub: String?
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let unitSuffix: String
    public let format: (Double) -> String
    public let parse: (String) -> Double?
    public let style: Style

    @Environment(\.cairnTokens) private var t

    public init(
        label: String,
        sub: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unitSuffix: String,
        format: @escaping (Double) -> String,
        parse: @escaping (String) -> Double?,
        style: Style = .standard
    ) {
        self.label = label
        self.sub = sub
        self._value = value
        self.range = range
        self.step = step
        self.unitSuffix = unitSuffix
        self.format = format
        self.parse = parse
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 8 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label.loc)
                    .font(.cairnScaled(size: style == .compact ? 14 : 15))
                    .foregroundStyle(t.textBody)
                Spacer(minLength: 8)
                EditableNumericField(
                    value: $value,
                    range: range,
                    step: step,
                    unitSuffix: unitSuffix,
                    format: format,
                    parse: parse
                )
            }
            if style == .standard, let sub {
                Text(sub.loc)
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            Slider(value: $value, in: range, step: step)
                // `t.verified` (the active-green) matches every other
                // slider in Settings — the inline iCloud-ceiling /
                // propagation sliders and the InitialScan sliders all
                // tint their filled track green. `t.text` here left this
                // shared row (Quarantine window, iCloud download limit,
                // etc.) rendering a white filled track, out of step with
                // the rest of the screen.
                .tint(t.verified)
            // Compact style puts the sub-text below the slider so
            // the slider + field stay visually paired at the top
            // of the row — matches the InitialScan scan-options
            // card where vertical space is scarce.
            if style == .compact, let sub {
                Text(sub)
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, style == .compact ? 12 : 14)
    }
}

// MARK: - Editable numeric field

/// Small monospace text field bound to a numeric `Double` value,
/// with display-time unit suffix, parse-and-clamp-and-snap on commit.
/// Pair with a `Slider` on the same `value` binding to give the user
/// both a coarse-drag and an exact-type affordance.
///
/// - Parses free-form input via `parse` (typically `Double.init` with
///   non-digit characters stripped), so pasting `"3.2%"` works.
/// - Clamps parsed values into `range` — out-of-bound inputs snap to
///   the nearest endpoint rather than being rejected.
/// - Snaps to `step` so the number matches what the paired slider
///   would produce (no more `1.27%` when step is `0.1`).
/// - Invalid input (no parseable number) reverts the field to the
///   current bound value on blur/submit; no exception, no bad write.
///
/// **Unit suffix behavior.** Rendered next to the number when idle
/// ("`1.5%`") and hidden when focused ("`1.5`") so users aren't
/// typing around a suffix glyph. Pass `""` for unit-less values.
public struct EditableNumericField: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let unitSuffix: String
    public let format: (Double) -> String
    public let parse: (String) -> Double?

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: String = ""
    @FocusState private var focused: Bool

    public init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unitSuffix: String = "",
        format: @escaping (Double) -> String,
        parse: @escaping (String) -> Double?
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.unitSuffix = unitSuffix
        self.format = format
        self.parse = parse
    }

    public var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $editing)
                .textFieldStyle(.plain)
                .font(.cairnScaled(size: 13, design: .monospaced).monospacedDigit())
                .foregroundStyle(t.textMuted)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                // No keyboard-toolbar Done button — on iOS 26 it
                // renders as a detached floating pill that collides
                // with nav chrome. Dismissal paths:
                //   - drag-to-dismiss via the parent ScrollView's
                //     `.scrollDismissesKeyboard(.interactively)`,
                //   - tap-to-dismiss via the screen-level background
                //     tap installed in each form (Settings,
                //     InitialScan, Setup).
                // Focus changes fire `commitEditing` via
                // `.onChange(of: focused)` regardless of *how* focus
                // was lost, so both dismissal paths commit cleanly.
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { commitEditing() }
                .onChange(of: focused) { _, nowFocused in
                    if !nowFocused { commitEditing() }
                }
                .frame(minWidth: 32)
                .fixedSize()
            if !unitSuffix.isEmpty && !focused {
                Text(unitSuffix)
                    .font(.cairnScaled(size: 13, design: .monospaced).monospacedDigit())
                    .foregroundStyle(t.textMuted)
            }
        }
        // Hitbox hugs the value more tightly than the original
        // "generous" pass — the persistent border already makes
        // the field read as interactive, so the horizontal air
        // around short values was wasted. Vertical padding stays
        // generous so the tap target is comfortable top-to-bottom;
        // `.contentShape` + `.onTapGesture` keep the whole padded
        // rectangle tappable.
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 32)
        .background(focused ? t.surfaceAlt : t.surfaceAlt.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? t.textMuted.opacity(0.6) : t.divider, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(reduceMotion ? .none : .snappy(duration: 0.12), value: focused)
        // Mirror binding → text field while the user isn't actively
        // typing. Re-running on every `value` tick keeps them synced
        // during slider drags; the `!focused` guard avoids clobbering
        // mid-entry input.
        .onChange(of: value) { _, newValue in
            if !focused { editing = format(newValue) }
        }
        .onAppear { editing = format(value) }
    }

    /// Parse + clamp into `range`, snap to `step`, commit back to the
    /// binding. Invalid input (unparseable) reverts the field to the
    /// current bound value without writing — matches Apple's
    /// "text field rejects bad numeric input on blur" idiom.
    private func commitEditing() {
        if let parsed = parse(editing) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            let snapped = (clamped / step).rounded() * step
            value = snapped
            editing = format(snapped)
        } else {
            editing = format(value)
        }
    }
}

// MARK: - Tab bar

public struct CairnTab: Hashable, Sendable {
    public let id: String
    public let label: String
    public let systemImage: String?

    public init(id: String, label: String, systemImage: String?) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }

    public static let status   = CairnTab(id: "status",   label: "Status",   systemImage: nil) // uses CairnMark
    public static let runs     = CairnTab(id: "runs",     label: "Runs",     systemImage: "list.bullet")
    public static let settings = CairnTab(id: "settings", label: "Settings", systemImage: "gearshape")
    public static let all: [CairnTab] = [.status, .runs, .settings]
}

/// Bottom tab bar matching the prototype's three-tab layout.
///
/// Tapping a tab that's already active fires `onReselect` instead of
/// `onChange` — the standard iOS idiom for "scroll the active page
/// back to the top." Hosts wire this to a per-tab token that each
/// screen observes via `ScrollViewReader.scrollTo(...)`.
public struct CairnTabBar: View {
    @Binding public var active: CairnTab
    public let onChange: ((CairnTab) -> Void)?
    public let onReselect: ((CairnTab) -> Void)?

    @Environment(\.cairnTokens) private var t

    public init(
        active: Binding<CairnTab>,
        onChange: ((CairnTab) -> Void)? = nil,
        onReselect: ((CairnTab) -> Void)? = nil
    ) {
        self._active = active
        self.onChange = onChange
        self.onReselect = onReselect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(CairnTab.all, id: \.id) { tab in
                Button {
                    if active.id == tab.id {
                        onReselect?(tab)
                    } else {
                        active = tab
                        onChange?(tab)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if tab.id == "status" {
                                CairnMark(size: 22)
                            } else if let sym = tab.systemImage {
                                Image(systemName: sym)
                                    .font(.cairnScaled(size: 18))
                            }
                        }
                        .frame(height: 22)
                        Text(tab.label.loc)
                            .font(.cairnScaled(size: 11, weight: .medium))
                    }
                    .foregroundStyle(active.id == tab.id ? t.text : t.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label.loc)
                .accessibilityAddTraits(active.id == tab.id ? [.isSelected] : [])
            }
        }
        .background(t.surface)
        .overlay(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Mock thumbnail

/// Deterministic gradient-tile placeholder until real Immich thumbnails
/// land. Matches the prototype's `thumb.jsx` approach: hash the filename
/// to a stable hue, render as a soft gradient. Lets the layouts feel
/// populated without HTTP plumbing.
public struct MockAssetThumb: View {
    public let filename: String
    public let size: CGFloat
    public let isLivePair: Bool

    @Environment(\.cairnTokens) private var t

    public init(filename: String, size: CGFloat = 76, isLivePair: Bool = false) {
        self.filename = filename
        self.size = size
        self.isLivePair = isLivePair
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [color1, color2],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if isLivePair {
                Image(systemName: "livephoto")
                    .font(.cairnScaled(size: max(10, size * 0.18), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(4)
            }
        }
    }

    private var hue: Double {
        // Stable hash → 0…1 hue.
        var h: UInt64 = 1469598103934665603
        for byte in filename.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return Double(h % 360) / 360.0
    }

    private var color1: Color { Color(hue: hue, saturation: 0.30, brightness: 0.85) }
    private var color2: Color { Color(hue: hue, saturation: 0.55, brightness: 0.55) }
}

// MARK: - Segmented picker

/// Cairn-tokenized replacement for `Picker(...).pickerStyle(.segmented)`.
///
/// Equal-width segments so the selection pill purely translates when the
/// user taps a neighbor — no simultaneous width-resize, which is what
/// made the UIKit-backed default read as jittery. Pill slide uses
/// `matchedGeometryEffect` + `.cairnSpringSnappy` so the pill slide
/// feels immediate on tap while keeping the spring vocabulary shared
/// with banner enter/exit.
///
/// Generic over any `Hashable` value — drop-in for `DeletionStrictness`,
/// `AppearanceOverride`, or any other small enum picker.
public struct CairnSegmentedPicker<Value: Hashable>: View {
    /// One option in the picker. `label` is rendered; `value` flows
    /// back through `selection`.
    public struct Option: Identifiable {
        public let value: Value
        public let label: String
        public var id: some Hashable { value }
        public init(value: Value, label: String) {
            self.value = value
            self.label = label
        }
    }

    @Binding public var selection: Value
    public let options: [Option]

    @Namespace private var pillNamespace
    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(t.surfaceAlt)
        )
    }

    @ViewBuilder
    private func segment(for option: Option) -> some View {
        let isSelected = option.value == selection
        Button {
            withAnimation(reduceMotion ? .none : .cairnSpringSnappy) {
                selection = option.value
            }
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(t.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(t.divider.opacity(0.6), lineWidth: 0.5)
                        )
                        .matchedGeometryEffect(id: "cairn-segmented-pill", in: pillNamespace)
                }
                Text(option.label.loc)
                    .font(.cairnScaled(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? t.text : t.textMuted)
                    .padding(.vertical, 7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Use isSelected trait + label-from-option so VoiceOver
        // announces "Settings, button" with the option label and the
        // selected state, rather than the previous "selected /
        // empty-string-value" pattern. The full picker behaves like a
        // standard radio group on iOS.
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Radio list

/// Stacked radio-style list for picking one value out of N, where each
/// option benefits from an inline subtitle (e.g. the onboarding
/// Strictness step where the choice is load-bearing and the user needs
/// the mode's meaning explained in-place).
///
/// The whole row is tappable — indicator ring + title + subtitle.
/// Selection change pops the indicator's inner dot using the shared
/// `.cairnSpringSnappy` so the feel matches segmented-picker pill
/// slides (direct-manipulation class) rather than banner enter/exit.
public struct CairnRadioList<Value: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        public let subtitle: String?
        public var id: some Hashable { value }
        public init(value: Value, title: String, subtitle: String? = nil) {
            self.value = value
            self.title = title
            self.subtitle = subtitle
        }
    }

    @Binding public var selection: Value
    public let options: [Option]

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                row(for: option)
                if index < options.count - 1 {
                    Rectangle()
                        .fill(t.divider)
                        .frame(height: 0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(t.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func row(for option: Option) -> some View {
        let isSelected = option.value == selection
        Button {
            withAnimation(reduceMotion ? .none : .cairnSpringSnappy) {
                selection = option.value
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                radioIndicator(isSelected: isSelected)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title.loc)
                        .font(.cairnScaled(size: 15, weight: .semibold))
                        .foregroundStyle(t.text)
                    if let subtitle = option.subtitle {
                        Text(subtitle.loc)
                            .font(.cairnScaled(size: 13))
                            .foregroundStyle(t.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Compose VoiceOver text from title + optional subtitle so the
        // user hears the full meaning of each option, not just "title,
        // Selected". The `.isSelected` trait announces selection state
        // separately so the rotor + the row layout match expectations.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.subtitle.map { "\(option.title). \($0)" } ?? option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    @ViewBuilder
    private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? t.primary : t.divider, lineWidth: 1.5)
                .frame(width: 20, height: 20)
            Circle()
                .fill(t.primary)
                .frame(width: 10, height: 10)
                .scaleEffect(isSelected ? 1 : 0.01)
                .opacity(isSelected ? 1 : 0)
        }
    }
}

#if DEBUG
#Preview("CairnSegmentedPicker — 2 options") {
    struct Host: View {
        @State var value: String = "a"
        var body: some View {
            VStack(spacing: 20) {
                CairnSegmentedPicker(
                    selection: $value,
                    options: [
                        .init(value: "a", label: "Cautious"),
                        .init(value: "b", label: "Balanced"),
                    ]
                )
                CairnSegmentedPicker(
                    selection: $value,
                    options: [
                        .init(value: "a", label: "Auto"),
                        .init(value: "b", label: "Light"),
                        .init(value: "c", label: "Dark"),
                    ]
                )
            }
            .padding()
        }
    }
    return Host().cairnTheme()
}

#Preview("CairnRadioList") {
    struct Host: View {
        @State var value: String = "strict"
        var body: some View {
            CairnRadioList(
                selection: $value,
                options: [
                    .init(value: "strict",   title: "Cautious", subtitle: "Only move server photos that iOS directly confirmed were deleted."),
                    .init(value: "trusting", title: "Balanced", subtitle: "Move anything that's no longer on your device, confirmed or not."),
                ]
            )
            .padding()
        }
    }
    return Host().cairnTheme()
}
#endif

// MARK: - Sync phase indicator

/// One-line current-phase indicator that lives under the sync card on
/// Status. Replaced the previous three-row checklist after the SyncPhase
/// expansion to six cases (idle/preparing/fetchingServer/hashing/
/// reconciling/finalizing) made the static-list rendering cluttered.
/// The full timeline lives in `SyncDetailSheet` — Status stays quiet
/// for the steady-state user; the curious user opens the sheet.
///
/// The struct is still named `SyncPhaseChecklist` so the existing
/// `SyncChecklistAnimator` wrapper, its layout-grow timing, and
/// `Self.checklistHeight` keep working unchanged.
public struct SyncPhaseChecklist: View {
    public let phase: CairnAppModel.SyncPhase

    @Environment(\.cairnTokens) private var t

    public init(phase: CairnAppModel.SyncPhase) {
        self.phase = phase
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted.circle")
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.pendingInk)
            Text(phase.displayName.loc)
                .font(.cairnScaled(size: 12, weight: .medium))
                .foregroundStyle(t.textBody)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

// MARK: - Processing breakdown

public struct ProcessingBreakdown: View {
    public let indexed: Int
    public let deferredQueueCount: Int
    public let processed: Int

    @Environment(\.cairnTokens) private var t

    public init(indexed: Int, deferredQueueCount: Int, processed: Int) {
        self.indexed = indexed
        self.deferredQueueCount = deferredQueueCount
        self.processed = processed
    }

    private var skipped: Int { max(0, processed - indexed - deferredQueueCount) }

    public var body: some View {
        if deferredQueueCount > 0 || skipped > 0 {
            HStack(spacing: 4) {
                Text(CairnL10n.isChinese ? "\(indexed.formatted(.number)) 已建立索引" : "\(indexed.formatted(.number)) indexed")
                    .foregroundStyle(t.textBody)
                if deferredQueueCount > 0 {
                    Text("·").foregroundStyle(t.textHint)
                    Text(CairnL10n.isChinese ? "\(deferredQueueCount.formatted(.number)) 排队中" : "\(deferredQueueCount.formatted(.number)) queued")
                        .foregroundStyle(t.textMuted)
                }
                if skipped > 0 {
                    Text("·").foregroundStyle(t.textHint)
                    Text(CairnL10n.isChinese ? "\(skipped.formatted(.number)) 超出上限" : "\(skipped.formatted(.number)) over cap")
                        .foregroundStyle(t.textMuted)
                }
            }
            .font(.cairnScaled(size: 12))
        }
    }
}
