//
//  PWin_OSD.swift
//  iina
//
//  Created by Matt Svoboda on 6/11/24.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation
import Mustache

// Avoid constraint violations during window resize
fileprivate let mildPriority = 400
fileprivate let lowerPriorityInt = 300
fileprivate let lowestPriorityInt = 100
#if MACOS_26_AVAILABLE
// Increase space a bit to accomodate the rounder corners:
fileprivate let standardOffset: CGFloat = 12
#else
fileprivate let standardOffset: CGFloat = 8
#endif

/// Encapsulates all of the window's OSD state vars
///
/// OSD constraints: shown here in "upper-left" configuration.
/// For "upper-right" config: swap OSD & AdditionalInfo anchors in A & B, and invert all the params of B.
/// ```
/// ┌────────────────────────────┐
/// │ A ┌────┐C: ≥12 ┌───────┐ B │  A: leadingSide_LeadingConstraint
/// │◄─►│ OSD│◄─────►│ AddNfo│◄─►│  B: trailingSide_TrailingConstraint
/// │   └────┘       └───────┘   │  C: hSpaceBetweenViewsGEConstraint
/// └────────────────────────────┘
/// ```
final class OSDState {
  let log: any Logger.Subsystem

  // - Views

  var osdView: NSView
  var additionalInfoView: NSView
  let additionalInfoSubviews: AdditionalInfoSubviews
  fileprivate let osdVStackView: ClickThroughStackView
  fileprivate let osdIconImageView: NSImageView
  /// Use label constructor (even with empty string) to ensure proper styling
  fileprivate let osdLabel: NSTextField
  fileprivate let osdAccessoryText: NSTextField
  fileprivate let osdAccessoryProgress: FixedProgressBar

  // - Internal constraints (not actually optional)

  // Icon size
  fileprivate let osdIconWidthConstraint = OptionalConstraint("OSDIcon.width")
  fileprivate let osdIconHeightConstraint = OptionalConstraint("OSDIcon.height")
  // Internal padding
  fileprivate let osdTopPaddingConstraint = OptionalConstraint("OSD-TopPadding")
  fileprivate let osdTrailingPaddingConstraint = OptionalConstraint("OSD-TrailingPadding")
  fileprivate let osdLeadingPaddingConstraint = OptionalConstraint("OSD-LeadingPadding")
  fileprivate let osdBtmPaddingConstraint = OptionalConstraint("OSD-BtmPadding")

  fileprivate let osdProgressHeightConstraint = OptionalConstraint("OSDProgress.height")
  fileprivate let iconToVStackSpacingConstraint = OptionalConstraint("OSDIcon-to-VStack.hSpacing")

  // - Optional constraints

  // Vertical offsets
  fileprivate let leadingSide_TopOffsetConstraint = OptionalConstraint("LeadingOSD.top-offset-from-VP.top")
  fileprivate let leadingSide_BtmOffsetConstraint = OptionalConstraint("VP.btm-offset-from-LeadingOSD.btm")
  fileprivate let trailingSide_TopOffsetConstraint = OptionalConstraint("TrailingOSD-TopOffset")
  fileprivate let trailingSide_BtmOffsetConstraint = OptionalConstraint("TrailingOSD-BtmOffset")

  // Leading side
  /// Need extra (very weak) constraint to align with viewport in case leading sidebar is present but not yet shown
  fileprivate let leadingSide_WeakLeadingConstraint = OptionalConstraint("LeadingOSD-Weak-Leading")
  fileprivate let leadingSide_LeadingConstraint = OptionalConstraint("LeadingOSD-Leading")
  fileprivate let leadingSide_TrailingConstraint = OptionalConstraint("LeadingOSD-Trailing")

  // Trailing side
  fileprivate let trailingSide_LeadingConstraint = OptionalConstraint("TrailingOSD-Leading")
  fileprivate let trailingSide_TrailingConstraint = OptionalConstraint("TrailingOSD-Trailing")
  /// Need extra (very weak) constraint to align with viewport in case trailing sidebar is present but not yet shown
  fileprivate let trailingSide_TrailingWeakConstraint = OptionalConstraint("TrailingOSD-Weak-Trailing")

  // If we have both OSDs shown at the same time, don't let them overlap, but don't push them
  // off to either side except as last resort. If they don't both fit, first shrink the AdditionalInfo text.
  // #OSDPlusAdditionalInfoResizing
  fileprivate let hSpaceBetweenViewsGEConstraint = OptionalConstraint("HSpaceBetweenOSDViewsGE")
  fileprivate let hSpaceBetweenViewsLTConstraint = OptionalConstraint("HSpaceBetweenOSDViewsLT")

  fileprivate var optionalConstraints: [OptionalConstraint] {
    [
      leadingSide_TopOffsetConstraint, leadingSide_BtmOffsetConstraint,
      trailingSide_TopOffsetConstraint, trailingSide_BtmOffsetConstraint,
      leadingSide_WeakLeadingConstraint,
      leadingSide_LeadingConstraint, leadingSide_TrailingConstraint,
      trailingSide_LeadingConstraint, trailingSide_TrailingConstraint,
      trailingSide_TrailingWeakConstraint,
    ]
  }

  /// True if the current OSD needs user interaction to be dismissed, and thus should
  /// be given higher priority than regular OSDs while still being shown.
  /// Other user-interactive OSDs
  ///
  /// When this is true, it implies that `userInteractiveAccessory` should be non-nil.
  /// In upstream IINA, this field is called `isShowingPersistentOSD`, which is
  /// misleading because some are not persistent (such as screenshot OSD).
  var isShowingUserInteractiveOSD: Bool { userInteractiveAccessory != nil }

  /// Need to keep a reference to NSViewController here in order for its Objective-C selectors to work.
  var userInteractiveAccessory: NSViewController? = nil {
    willSet {
      guard newValue != userInteractiveAccessory else { return }
      log.verbose("Updating osd.userInteractiveAccessory to: \(newValue?.description ?? "nil")")
    }
  }

  var animationState: PlayerWindowController.UIAnimationState = .hidden
  /// Timeout action is `pwc.hideOSD()`
  let hideOSDTimer = TimeoutTimer(timeout: OSDState.osdTimeoutFromPrefs())
  var nextSeekIcon: NSImage? = nil
  var currentSeekIcon: NSImage? = nil
  var lastPlaybackPosition: Double? = nil
  var lastPlaybackDuration: Double? = nil
  private var lastDisplayedMsgTS: TimeInterval = 0
  fileprivate var lastDisplayedMsg: OSDMessage? = nil {
    didSet {
      guard lastDisplayedMsg != nil else { return }
      lastDisplayedMsgTS = CFAbsoluteTimeGetCurrent()
    }
  }
  var currentlyDisplayedMsg: OSDMessage? {
    return animationState == .shown ? lastDisplayedMsg : nil
  }
  /// "Recently" here is defined as: having been shown in the last 0.25 sec.
  fileprivate func didShowLastMsgRecently() -> Bool {
    return CFAbsoluteTimeGetCurrent() - lastDisplayedMsgTS < 0.25
  }
  fileprivate func didShowLastMsgSomewhatRecently() -> Bool {
    return CFAbsoluteTimeGetCurrent() - lastDisplayedMsgTS < 0.5
  }

  fileprivate var textSizeLast: CGFloat = 0
  @MainActor
  var queue = LinkedList<Callback>()

  fileprivate static func buildOSDView(_ colorScheme: Preference.PanelColorScheme,
                                       subviews: [NSView]) -> NSView {
    let osdView: NSView
    if #available(macOS 26, *), colorScheme == .clearGlass || colorScheme == .tintedGlass {
      let style: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
      let osdGlassView = OSDGlassEffectView(style)
      osdView = osdGlassView
      let contentView = NSView()
      osdGlassView.contentView = contentView
      contentView.subviews = subviews
    } else {
      osdView = OSDVisualEffectView()
      osdView.subviews = subviews
    }

    osdView.idString = "OSDView"
    osdView.translatesAutoresizingMaskIntoConstraints = false
    // Min width
    let osdMinWidthConstraint = osdView.widthAnchor.constraint(greaterThanOrEqualToConstant: 50)
    osdMinWidthConstraint.identifier = "OSDView-MinWidthConstraint"
    osdMinWidthConstraint.priority = .init(900)
    osdMinWidthConstraint.isActive = true

    if #available(macOS 26, *) {
      // MacOS Tahoe's style favors very round corners: try to fit in with it
      osdView.roundCorners(withRadius: Constants.glassCornerRadius)
    } else {
      // Pre-Tahoe
      osdView.roundCorners()
    }
    return osdView
  }

  fileprivate static func buildAdditionalInfoView(_ additionalInfoSubviews: AdditionalInfoSubviews) -> NSView {
    let aiView: NSView
    let colorScheme: Preference.PanelColorScheme = LayoutState.effectiveOSDColorSchemeFromPrefs
    if #available(macOS 26, *), colorScheme == .clearGlass || colorScheme == .tintedGlass {
      let style: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
      let glassView = AdditionalInfoGlassView(style)
      aiView = glassView
      let contentView = NSView()
      glassView.contentView = contentView
      additionalInfoSubviews.addAllTo(additionalInfoView: contentView)
    } else {
      aiView = AdditionalInfoVEView()
      additionalInfoSubviews.addAllTo(additionalInfoView: aiView)
    }

    aiView.idString = "AdditionalInfoView"
    aiView.translatesAutoresizingMaskIntoConstraints = false
    // #OSDPlusAdditionalInfoResizing
    aiView.setContentCompressionResistancePriority(.init(249), for: .horizontal)

    if #available(macOS 26, *) {
      // MacOS Tahoe's style favors very round corners: try to fit in with it
      aiView.roundCorners(withRadius: Constants.glassCornerRadius)
    } else {
      // Pre-Tahoe
      aiView.roundCorners()
    }
    return aiView
  }

  @MainActor
  func rebuildAdditionalInfoView() {
    guard Preference.bool(for: .displayTimeAndBatteryInFullScreen) else { return }
    let colorScheme: Preference.PanelColorScheme = LayoutState.effectiveOSDColorSchemeFromPrefs

    let needsRebuild: Bool
    if #available(macOS 26, *), colorScheme == .clearGlass || colorScheme == .tintedGlass {
      if let aiGlassView = additionalInfoView as? AdditionalInfoGlassView {
        let style: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
        aiGlassView.setStyle(style)
        needsRebuild = false
      } else {
        needsRebuild = true
      }
    } else {
      needsRebuild = (additionalInfoView as? AdditionalInfoVEView == nil)
    }

    guard needsRebuild else { return }
    let infoIsHidden = additionalInfoView.isHidden
    log.verbose("Rebuilding AdditionalInfoView for colorScheme: \(colorScheme.description) hidden=\(infoIsHidden.yn)")
    additionalInfoView.removeAllSubviews()
    additionalInfoView.removeFromSuperview()

    additionalInfoView = OSDState.buildAdditionalInfoView(additionalInfoSubviews)
    if infoIsHidden {
      additionalInfoView.isHidden = true
    }
  }

  @MainActor
  func rebuildOSDView() {
    guard Preference.bool(for: .enableOSD) else { return }
    let colorScheme: Preference.PanelColorScheme = LayoutState.effectiveOSDColorSchemeFromPrefs

    let needsRebuild: Bool
    if #available(macOS 26, *), colorScheme == .clearGlass || colorScheme == .tintedGlass {
      if let osdGlassView = osdView as? OSDGlassEffectView {
        let style: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
        osdGlassView.setStyle(style)
        needsRebuild = false
      } else {
        needsRebuild = true
      }
    } else {
      needsRebuild = (osdView as? OSDVisualEffectView == nil)
    }

    guard needsRebuild else { return }

    let osdIsHidden = osdView.isHidden
    log.verbose("Rebuilding OSDView for colorScheme=\(colorScheme.description) hidden=\(osdIsHidden.yn)")
    osdView.removeAllSubviews()
    osdView.removeFromSuperview()

    osdView = OSDState.buildOSDView(colorScheme, subviews: [osdIconImageView, osdVStackView])
    rebuildOSDViewConstraints()
    if osdIsHidden {
      osdView.isHidden = true
    }
  }

  @MainActor
  fileprivate func rebuildOSDViewConstraints() {
    osdTopPaddingConstraint.createOrUpdate(to: standardOffset, priorityInt: 1000, log) { [self] c in
      osdVStackView.topAnchor.constraint(equalTo: osdView.topAnchor, constant: c)
    }
    osdBtmPaddingConstraint.createOrUpdate(to: standardOffset, priorityInt: 1000, log) { [self] c in
      osdView.bottomAnchor.constraint(equalTo: osdVStackView.bottomAnchor, constant: c)
    }
    osdLeadingPaddingConstraint.createOrUpdate(to: standardOffset, priorityInt: 1000, log) { [self] c in
      osdIconImageView.leadingAnchor.constraint(equalTo: osdView.leadingAnchor, constant: c)
    }
    osdTrailingPaddingConstraint.createOrUpdate(to: standardOffset, priorityInt: 1000, log) { [self] c in
      osdView.trailingAnchor.constraint(equalTo: osdVStackView.trailingAnchor, constant: c)
    }

    // Space between icon & VStack to the right of it. Start with 0, assuming icon is not shown
    // [osdIconImageView]-4-[osdVStackView]
    iconToVStackSpacingConstraint.createOrUpdate(to: 0, priorityInt: 1000, log) { [self] c in
      osdVStackView.leadingAnchor.constraint(equalTo: osdIconImageView.trailingAnchor, constant: c)
    }

    // Center the icon vertically
    osdIconImageView.centerYAnchor.constraint(equalTo: osdView.centerYAnchor).isActive = true
  }

  @MainActor
  init(log: any Logger.Subsystem) {
    self.log = log

    log.verbose("Init OSD")

    // AdditionalInfo view

    let aiSubviews = AdditionalInfoSubviews()
    additionalInfoSubviews = aiSubviews
    additionalInfoView = OSDState.buildAdditionalInfoView(aiSubviews)

    // OSD subview 1: osdIconImageView
    osdIconImageView = NSImageView()
    osdIconImageView.idString = "OSDIconImageView"
    osdIconImageView.imageScaling = .scaleProportionallyUpOrDown
    osdIconImageView.imageAlignment = .alignLeft
    osdIconImageView.translatesAutoresizingMaskIntoConstraints = false
    osdIconImageView.refusesFirstResponder = true
    osdIconImageView.setContentHugging(h: 1000, v: 1000)
    osdIconImageView.setCCResistance(h: 1000, v: 1000)

    // OSD subview 2: osdVStackView

    /// Use label constructor (even with empty string) to ensure proper styling
    osdLabel = NSTextField(labelWithString: "")
    osdLabel.idString = "OSD-Label"
    osdLabel.translatesAutoresizingMaskIntoConstraints = false
    osdLabel.setContentHuggingPriority(.init(251), for: .horizontal)
    osdLabel.setContentCompressionResistancePriority(.init(499), for: .horizontal)
    osdLabel.setContentCompressionResistancePriority(.init(1000), for: .vertical)
    osdLabel.focusRingType = .none
    osdLabel.lineBreakMode = .byTruncatingTail
    osdLabel.alignment = .left
    osdLabel.usesSingleLineMode = true
    osdLabel.wantsLayer = true

    osdAccessoryText = NSTextField(labelWithString: "")
    osdAccessoryText.idString = "OSD-AccText"
    osdAccessoryText.wantsLayer = true
    osdAccessoryText.translatesAutoresizingMaskIntoConstraints = false
    osdAccessoryText.setContentHuggingPriority(.init(249), for: .horizontal)
    osdAccessoryText.setContentHuggingPriority(.init(750), for: .vertical)
    osdAccessoryText.setContentCompressionResistancePriority(.init(499), for: .horizontal)
    osdAccessoryText.setContentCompressionResistancePriority(.init(1000), for: .vertical)
    osdAccessoryText.focusRingType = .none
    osdAccessoryText.lineBreakMode = .byClipping
    osdAccessoryText.alignment = .justified
    osdAccessoryText.wantsLayer = true
    osdAccessoryText.font = .messageFont(ofSize: 11)
    osdAccessoryText.textColor = .disabledControlTextColor
    osdAccessoryText.backgroundColor = .controlColor

    osdAccessoryProgress = FixedProgressBar()
    osdAccessoryProgress.idString = "OSD-ProgressBar"
    osdAccessoryProgress.translatesAutoresizingMaskIntoConstraints = false
    osdAccessoryProgress.setContentHuggingPriority(.init(270), for: .horizontal)
    osdAccessoryProgress.setContentCompressionResistancePriority(.required, for: .vertical)

    osdVStackView = ClickThroughStackView()
    osdVStackView.idString = "OSD-VStackView"
    osdVStackView.wantsLayer = true
    osdVStackView.orientation = .vertical
    osdVStackView.alignment = .leading
    osdVStackView.distribution = .fillProportionally
    osdVStackView.spacing = 0
    osdVStackView.detachesHiddenViews = true
    osdVStackView.translatesAutoresizingMaskIntoConstraints = false
    osdVStackView.setHuggingPriority(.init(499), for: .vertical)
    // #OSDPlusAdditionalInfoResizing
    osdVStackView.setHuggingPriority(.init(500), for: .horizontal)

    osdVStackView.addView(osdLabel, in: .center)
    osdVStackView.addView(osdAccessoryText, in: .center)
    osdVStackView.addView(osdAccessoryProgress, in: .center)

    // Build root view & add subviews
    osdView = OSDState.buildOSDView(LayoutState.effectiveOSDColorSchemeFromPrefs,
                                    subviews: [osdIconImageView, osdVStackView])
    rebuildOSDViewConstraints()

    // Add views' internal constraints:

    // Use initial size of 0, in case MacOS 11 code never gets executed
    let initialIconSize: CGFloat = 0
    // Icon width
    osdIconWidthConstraint.createOrUpdate(to: initialIconSize, priorityInt: 1000, log) { [self] c in
      osdIconImageView.widthAnchor.constraint(equalToConstant: c)
    }
    // Icon height
    osdIconHeightConstraint.createOrUpdate(to: initialIconSize, priorityInt: 1000, log) { [self] c in
      osdIconImageView.heightAnchor.constraint(equalToConstant: c)
    }

    // Progress bar height
    osdProgressHeightConstraint.createOrUpdate(to: 0, priorityInt: 1000, log) { [self] c in
      osdAccessoryProgress.heightAnchor.constraint(equalToConstant: c)
    }

  }

  @MainActor
  fileprivate func updateIconSize(isIconVisible: Bool) {
    let iconHeight, iconWidth: CGFloat

    // Don't want to animate the following
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setAnimationDuration(0.0)

    if isIconVisible, let icon = osdIconImageView.image {
      let osdTextSize = textSizeLast
      let sliderBarHeight = getSliderBarHeight(forOSDTextSize: osdTextSize)

      // Use dimensions of a dummy image to keep the height fixed. Because all the components are vertically aligned
      // and each icon has a different height, this is needed to prevent the progress bar from jumping up and down
      // each time the OSD message changes.
      let attachment = NSTextAttachment()
      attachment.image = icon
      let iconString = NSMutableAttributedString(attachment: attachment)
      let osdIconTextSize = ((osdTextSize + sliderBarHeight) * 1.15).rounded()
      let osdIconFont = NSFont.monospacedDigitSystemFont(ofSize: osdIconTextSize, weight: .regular)
      iconString.addAttribute(.font, value: osdIconFont, range: NSRange(location: 0, length: iconString.length))
      iconHeight = iconString.size().height
      iconWidth = (icon.size.aspect * iconHeight)

    } else {
      iconHeight = 0.0
      iconWidth = 0.0
    }

    osdIconHeightConstraint.constraint?.animateToConstant(iconHeight)
    osdIconWidthConstraint.constraint?.animateToConstant(iconWidth)
    CATransaction.commit()
  }

  @MainActor
  func updateColors(windowAppearance: NSAppearance) {
    let osdColorScheme = LayoutState.effectiveOSDColorSchemeFromPrefs

    // Text size
    let osdTextSize = textSizeLast
    if osdTextSize > 0 {
      let sliderBarHeight = getSliderBarHeight(forOSDTextSize: osdTextSize)
      osdAccessoryProgress.barRenderer = BarRenderer(windowAppearance: windowAppearance,
                                                     colorScheme: osdColorScheme,
                                                     sliderBarHeight_Normal: sliderBarHeight)
      osdProgressHeightConstraint.constraint!.animateToConstant(sliderBarHeight * 2)
    }

    // Appearance (light or dark)
    let appearance = osdColorScheme.hasClearBG ? NSAppearance(iinaTheme: .dark)! : windowAppearance
    osdView.appearance = appearance
    additionalInfoView.appearance = appearance

    // Color scheme
    additionalInfoSubviews.titleLabel.addShadow(osdColorScheme, .text)
    additionalInfoSubviews.clockTimeLabel.addShadow(osdColorScheme, .text)
    additionalInfoSubviews.batteryView.addShadow(osdColorScheme, .text)

    osdIconImageView.addShadow(osdColorScheme, .text)
    osdLabel.addShadow(osdColorScheme, .text)
    osdAccessoryText.addShadow(osdColorScheme, .text)
  }


  static func osdTimeoutFromPrefs() -> Double {
    // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    return max(TimeConstants.osdTimeoutMin, Preference.double(for: .osdAutoHideTimeout))
  }

  fileprivate func getSliderBarHeight(forOSDTextSize osdTextSize: CGFloat) -> CGFloat {
    guard osdTextSize > 0 else { return 0 }

    switch osdTextSize {
    case ..<32:
      return 4
    default:
      return (osdTextSize / 8).rounded()
    }
  }

}

// MARK: - OSDView Classes

final class OSDVisualEffectView: ClickThroughVisualEffectView {
  init() {
    super.init(frame: .zero)
    blendingMode = .withinWindow
    material = .popover
    state = .active
  }
  
  @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@available(macOS 26.0, *)
final class OSDGlassEffectView: ClickThroughGlassEffectView {
}

// MARK: - AdditionalInfoView Classes

/// The Additional Info view displays a battery time indicator & the media title when in full screen.
class AdditionalInfoVEView: MouseIgnoringVisualEffectView {
  init() {
    super.init(frame: .zero)
    blendingMode = .withinWindow
    material = .popover
    state = .active
  }
  
  @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@available(macOS 26.0, *)
class AdditionalInfoGlassView: MouseIgnoringGlassEffectView {
}

/// Simple container for subviews of AdditionalInfo view.
class AdditionalInfoSubviews {
  let titleLabel: ResizableTextView
  let hStackView: NSStackView
  let labelContainerView: NSView
  let clockTimeLabel: NSTextField
  let batteryView: NSView
  let batteryLabel: NSTextField

  init() {
    titleLabel = ResizableTextView(lineBreakMode: .byTruncatingMiddle)
    titleLabel.idString = "AdditionalInfo-Title"
    titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
    titleLabel.alignment = .right
    // #OSDPlusAdditionalInfoResizing
    titleLabel.setContentCompressionResistancePriority(.init(252), for: .horizontal)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    clockTimeLabel = NSTextField(labelWithString: "99:99")
    clockTimeLabel.font = NSFont.systemFont(ofSize: 18, weight: .regular)
    clockTimeLabel.alignment = .right
    clockTimeLabel.textColor = .secondaryLabelColor
    clockTimeLabel.backgroundColor = .textBackgroundColor
    clockTimeLabel.idString = "AdditionalInfo-Label"
    clockTimeLabel.translatesAutoresizingMaskIntoConstraints = false

    labelContainerView = NSView()
    labelContainerView.translatesAutoresizingMaskIntoConstraints = false
    labelContainerView.heightAnchor.constraint(equalToConstant: 30).isActive = true
    labelContainerView.subviews = [clockTimeLabel]

    clockTimeLabel.leadingAnchor.constraint(equalTo: labelContainerView.leadingAnchor, constant: 6).isActive = true
    labelContainerView.trailingAnchor.constraint(equalTo: clockTimeLabel.trailingAnchor).isActive = true
    clockTimeLabel.centerYAnchor.constraint(equalTo: labelContainerView.centerYAnchor, constant: -1).isActive = true

    let verticalLine = NSBox()
    verticalLine.boxType = .separator
    verticalLine.translatesAutoresizingMaskIntoConstraints = false
    verticalLine.heightAnchor.constraint(equalToConstant: 12).isActive = true

    hStackView = NSStackView()
    hStackView.idString = "AdditionalInfo-HStackView"
    hStackView.orientation = .horizontal
    hStackView.alignment = .centerY
    hStackView.distribution = .fill
    hStackView.spacing = 6
    hStackView.wantsLayer = true
    hStackView.detachesHiddenViews = true
    hStackView.translatesAutoresizingMaskIntoConstraints = false

    // - Battery

    batteryView = NSView()
    batteryView.idString = "AdditionalInfoBatteryView"
    batteryView.wantsLayer = true
    batteryView.translatesAutoresizingMaskIntoConstraints = false
    batteryView.heightAnchor.constraint(equalToConstant: 30).isActive = true
    batteryView.widthAnchor.constraint(equalToConstant: 56).isActive = true

    batteryLabel = NSTextField(labelWithString: "100%")
    batteryLabel.idString = "AdditionalInfoBattery-Text"
    batteryLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
    batteryLabel.textColor = .secondaryLabelColor
    batteryLabel.backgroundColor = .textBackgroundColor
    batteryLabel.setContentHuggingPriority(.init(251), for: .horizontal)
    batteryLabel.translatesAutoresizingMaskIntoConstraints = false

    let batteryImage = NSImage(named: "battery")!
    let batteryImageView = NSImageView(image: batteryImage)
    batteryImageView.imageScaling = .scaleProportionallyUpOrDown
    batteryImageView.wantsLayer = true
    batteryImageView.setContentHugging(h: 251, v: 251)
    batteryImageView.translatesAutoresizingMaskIntoConstraints = false

    batteryView.subviews = [batteryLabel, batteryImageView]
    let batteryOffsetX: CGFloat = -4
    batteryImageView.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: batteryOffsetX, trailing: -batteryOffsetX)
    batteryLabel.centerXAnchor.constraint(equalTo: batteryView.centerXAnchor, constant: batteryOffsetX).isActive = true
    batteryLabel.centerYAnchor.constraint(equalTo: batteryView.centerYAnchor, constant: -0.5).isActive = true

    for subview in [labelContainerView, verticalLine, batteryView] {
      hStackView.addView(subview, in: .trailing)
      subview.autoresizesSubviews = false
    }
    batteryView.autoresizesSubviews = false
    batteryLabel.autoresizesSubviews = false
    batteryImageView.autoresizesSubviews = false
    titleLabel.autoresizesSubviews = false
  }

  func addAllTo(additionalInfoView view: NSView) {
    titleLabel.removeFromSuperview()
    hStackView.removeFromSuperview()
    
    view.subviews = [titleLabel, hStackView]
    titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8).isActive = true
    titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4).isActive = true
    view.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8).isActive = true

    hStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4).isActive = true
    hStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4).isActive = true
    view.trailingAnchor.constraint(equalTo: hStackView.trailingAnchor, constant: 8).isActive = true
    view.bottomAnchor.constraint(equalTo: hStackView.bottomAnchor, constant: 4).isActive = true
  }
}

// PlayerWindow UI: OSD
extension PlayerWindowController {
  /// Adds or removes one or both of the following floating overlay views, based on the given geometry &
  /// transition stage:
  /// `osdView`
  /// `additionalInfoView`
  func addOrRemoveOSDViews(for stage: LayoutTransition.Stage, _ stageGeo: PWinGeometry) {
    var addedSomething = false
    if stageGeo.shouldHaveOSD {
      if !viewportView.subviews.contains(osd.osdView) {
        log.verbose("[OSD] Adding osdView to viewportView")
        viewportView.addSubview(osd.osdView)  // will sort below
        addedSomething = true
      }

    } else {
      if osd.osdView.superview != nil {
        log.verbose("[OSD] Removing osdView from superview")
        osd.osdView.removeFromSuperview()
      }
    }

    if stageGeo.shouldHaveAdditionalInfo {
      if !viewportView.subviews.contains(osd.additionalInfoView) {
        log.verbose("[OSD] Adding additionalInfoView to viewportView")
        viewportView.addSubview(osd.additionalInfoView)  // will sort below
        fadeableViews.applyVisibility(.hidden, osd.additionalInfoView)  // hide for now. Will show in later stage
        addedSomething = true
      }
      updateAdditionalInfoContent()  // update content

    } else {
      if osd.additionalInfoView.superview != nil {
        log.verbose("[OSD] Removing additionalInfoView from superview")
        osd.additionalInfoView.removeFromSuperview()
      }
    }

    if addedSomething {
      updateOSDViews(updateSizeFrom: stageGeo)

      sortViewportViewSubviews()
      window?.contentView?.needsLayout = true
    }
  }

  /// - Enforces `Preference.Key.osdPosition` pref which allows OSD to be on either left or right.
  /// - For many of the constraints, priority=900 will be used to avoid problems with black swan layouts
  /// which might trigger constraint violations if priority=required were used.
  /// - Setting `skipAddConstraints` to `true` is a kludge for special use during layout transitions
  func updateConstraintsForFloatingViews(stageGeo: PWinGeometry, hasLeadingSidebar: Bool, hasTrailingSidebar: Bool) {
    for optCon in osd.optionalConstraints {
      optCon.weaken()
    }
    let offsetFromTop = stageGeo.osdOffsetFromTopOfViewport()
    let btmMinOffset = stageGeo.osdMinOffsetToBottomOfViewport()

    let hasOSD = stageGeo.shouldHaveOSD
    let hasAdditionalInfo = stageGeo.shouldHaveAdditionalInfo
    let osdPosition: Preference.OSDPosition = Preference.enum(for: .osdPosition)

    log.verbose("[OSD] Updating constraints: hasOSD=\(hasOSD.yn) hasAddlInfo=\(hasAdditionalInfo.yn) "
                + "leadingSB=\(hasLeadingSidebar.yn) trailingSB=\(hasTrailingSidebar.yn) offsetFromTop=\(offsetFromTop)")

    let leadingView = osdPosition == .topLeading ? (hasOSD ? osd.osdView : nil) :  (hasAdditionalInfo ? osd.additionalInfoView : nil)
    let trailingView = osdPosition == .topLeading ? (hasAdditionalInfo ? osd.additionalInfoView : nil) :  (hasOSD ? osd.osdView : nil)

    let otherAnchorLeading = hasLeadingSidebar ? leadingSidebarView.trailingAnchor : viewportView.leadingAnchor
    let otherAnchorTrailing = hasTrailingSidebar ? trailingSidebarView.leadingAnchor : viewportView.trailingAnchor

    if let leadingView {
      osd.leadingSide_WeakLeadingConstraint.createOrUpdate(to: standardOffset, priorityInt: lowestPriorityInt,
                                                           requiredFirstAnchor: leadingView.leadingAnchor,
                                                           requiredSecondAnchor: viewportView.leadingAnchor, log) { c in
        leadingView.leadingAnchor.constraint(equalTo: viewportView.leadingAnchor, constant: c)
      }
      osd.leadingSide_LeadingConstraint.createOrUpdate(to: standardOffset, priorityInt: mildPriority,
                                                       requiredFirstAnchor: leadingView.leadingAnchor,
                                                       requiredSecondAnchor: otherAnchorLeading, log) { c in
        leadingView.leadingAnchor.constraint(equalTo: otherAnchorLeading, constant: c)
      }

      osd.leadingSide_TrailingConstraint.createOrUpdate(to: standardOffset, priorityInt: lowerPriorityInt,
                                                        requiredFirstAnchor: otherAnchorTrailing,
                                                        requiredSecondAnchor: leadingView.trailingAnchor, log) { c in
        otherAnchorTrailing.constraint(greaterThanOrEqualTo: leadingView.trailingAnchor, constant: c)
      }

      osd.leadingSide_TopOffsetConstraint.createOrUpdate(to: offsetFromTop, priorityInt: mildPriority,
                                                         requiredFirstAnchor: leadingView.topAnchor,
                                                         requiredSecondAnchor: viewportView.topAnchor, log) { [self] c in
        leadingView.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: c)
      }

      osd.leadingSide_BtmOffsetConstraint.createOrUpdate(to: btmMinOffset, priorityInt: mildPriority,
                                                         requiredFirstAnchor: viewportView.bottomAnchor,
                                                         requiredSecondAnchor: leadingView.bottomAnchor, log) { [self] c in
        viewportView.bottomAnchor.constraint(greaterThanOrEqualTo: leadingView.bottomAnchor, constant: c)
      }
    }

    if let trailingView {
      osd.trailingSide_TrailingWeakConstraint.createOrUpdate(to: standardOffset, priorityInt: lowestPriorityInt,
                                                             requiredFirstAnchor: viewportView.trailingAnchor,
                                                         requiredSecondAnchor: trailingView.trailingAnchor, log) { c in
        otherAnchorTrailing.constraint(equalTo: trailingView.trailingAnchor, constant: c)
      }

      osd.trailingSide_TrailingConstraint.createOrUpdate(to: standardOffset, priorityInt: mildPriority,
                                                         requiredFirstAnchor: otherAnchorTrailing,
                                                         requiredSecondAnchor: trailingView.trailingAnchor, log) { c in
        otherAnchorTrailing.constraint(equalTo: trailingView.trailingAnchor, constant: c)
      }

      osd.trailingSide_LeadingConstraint.createOrUpdate(to: standardOffset, priorityInt: lowerPriorityInt,
                                                        requiredFirstAnchor: trailingView.leadingAnchor,
                                                        requiredSecondAnchor: otherAnchorLeading, log) { c in
        trailingView.leadingAnchor.constraint(greaterThanOrEqualTo: otherAnchorLeading, constant: c)
      }

      osd.trailingSide_TopOffsetConstraint.createOrUpdate(to: offsetFromTop, priorityInt: mildPriority,
                                                          requiredFirstAnchor: trailingView.topAnchor,
                                                          requiredSecondAnchor: viewportView.topAnchor, log) { [self] c in
        trailingView.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: c)
      }

      osd.trailingSide_BtmOffsetConstraint.createOrUpdate(to: btmMinOffset, priorityInt: mildPriority,
                                                          requiredFirstAnchor: viewportView.bottomAnchor,
                                                          requiredSecondAnchor: trailingView.bottomAnchor, log) { [self] c in
        viewportView.bottomAnchor.constraint(greaterThanOrEqualTo: trailingView.bottomAnchor, constant: c)
      }
    }

    // #OSDPlusAdditionalInfoResizing
    if let leadingView, let trailingView {
      osd.hSpaceBetweenViewsGEConstraint.createOrUpdate(to: standardOffset, priorityInt: mildPriority,
                                                      requiredFirstAnchor: trailingView.leadingAnchor,
                                                      requiredSecondAnchor: leadingView.trailingAnchor, log) { c in
        trailingView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingView.trailingAnchor, constant: c)
      }
      osd.hSpaceBetweenViewsLTConstraint.createOrUpdate(to: standardOffset, priorityInt: 249,
                                                        requiredFirstAnchor: trailingView.leadingAnchor,
                                                        requiredSecondAnchor: leadingView.trailingAnchor, log) { c in
        trailingView.leadingAnchor.constraint(lessThanOrEqualTo: leadingView.trailingAnchor, constant: c)
      }
    }
  }

  /// Update OSD view & Additional Info view constraints so they have the correct offset from top of screen.
  func updateOSDTopOffsetConstraints(for geometry: PWinGeometry) {
    let newOffsetFromTop = geometry.osdOffsetFromTopOfViewport()

    log.verbose("[OSD] Updating top constraint to: \(newOffsetFromTop)")
    osd.leadingSide_TopOffsetConstraint.animateToConstant(newOffsetFromTop)
    osd.trailingSide_TopOffsetConstraint.animateToConstant(newOffsetFromTop)
  }

  // MARK: - Additional Info Content Updates

  /// Update `additionalInfoView` with battery status & media title
  func updateAdditionalInfoContent() {
    let aiView = osd.additionalInfoView
    let title = player.info.currentPlayback?.url.lastPathComponent
    log.trace("[OSD] Updating additionalInfoView content with URL: \(title ?? "nil")")
    guard let title else { return }
    let sv = osd.additionalInfoSubviews
    sv.titleLabel.string = title
    sv.titleLabel.sizeToFit()
    sv.titleLabel.invalidateIntrinsicContentSize()
    aiView.needsLayout = true  // Need this for titleLabel to update

    if let capacity = PowerSource.getList().filter({ $0.type == "InternalBattery" }).first?.currentCapacity {
      sv.batteryLabel.stringValue = "\(capacity)%"
      sv.hStackView.setVisibilityPriority(.mustHold, for: sv.batteryView)
    } else {
      sv.hStackView.setVisibilityPriority(.notVisible, for: sv.batteryView)
    }
    sv.clockTimeLabel.stringValue = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
  }

  // MARK: - OSD Content Updates

  /// If `newMessage` is provided, the OSD will be updated to display it. Otherwise if the OSD is
  /// already shown and is displaying one of the message types which requires live updates, it will be updated.
  @MainActor
  func updateOSDViews(from newMessage: OSDMessage? = nil,
                      updateSize: Bool = true, updateSizeFrom givenGeo: PWinGeometry? = nil) {
    if updateSize {
      updateOSDSize(from: givenGeo)
    }

    let message: OSDMessage?

    if let newMessage {
      message = newMessage

    } else if let currentMsg = osd.currentlyDisplayedMsg,
              let position = player.info.playbackTime.positionSec,
              let duration = player.info.playbackTime.durationSec {
      // If the OSD is visible and is showing playback position, keep its displayed time up to date:
      switch currentMsg {
      case .pause:
        message = .pause(posSec: position, durSec: duration)
      case .resume:
        message = .resume(posSec: position, durSec: duration)
      case .seek(_, _):
        message = .seek(posSec: position, durSec: duration)
      default:
        message = nil
      }
    } else {
      message = nil
    }

    defer {
      osd.osdView.needsLayout = true
      osd.osdView.needsDisplay = true
    }

    if let displayedMesg = message ?? osd.lastDisplayedMsg {
      updateOSDIcon(from: displayedMesg)
    }

    guard let message else {
      // Often this method was called in response to a layout change.
      // For some reason the text wrap of the following is not recomputed or the text may be smashed/stretched,
      // so mark it expclitly as needing layout above before returning.
      return
    }


    let (osdText, osdType) = message.details()
    osd.osdLabel.stringValue = osdText

    // Most OSD messages are displayed based on the configured language direction.
    osd.osdAccessoryProgress.userInterfaceLayoutDirection = osd.osdVStackView.userInterfaceLayoutDirection
    osd.osdAccessoryText.baseWritingDirection = .natural
    osd.osdLabel.baseWritingDirection = .natural
    switch osdType {
    case .normal:
      osd.osdVStackView.setVisibilityPriority(.notVisible, for: osd.osdAccessoryText)
      osd.osdVStackView.setVisibilityPriority(.notVisible, for: osd.osdAccessoryProgress)
    case .withLeftToRightProgress(let value):
      // OSD messages displaying the playback position must always be displayed left to right.
      osd.osdAccessoryProgress.userInterfaceLayoutDirection = .leftToRight
      osd.osdLabel.baseWritingDirection = .leftToRight
      fallthrough
    case .withProgress(let value):
      osd.osdVStackView.setVisibilityPriority(.notVisible, for: osd.osdAccessoryText)
      osd.osdVStackView.setVisibilityPriority(.mustHold, for: osd.osdAccessoryProgress)
      osd.osdAccessoryProgress.doubleValue = value
      osd.osdAccessoryProgress.needsDisplay = true
    case .withLeftToRightText(let text):
      // OSD messages displaying the playback position must always be displayed left to right.
      osd.osdAccessoryText.baseWritingDirection = .leftToRight
      fallthrough
    case .withText(let text):
      guard !player.isStopping else { return }  /// prevent crash when `mpv.getInt()` is used below
      osd.osdVStackView.setVisibilityPriority(.mustHold, for: osd.osdAccessoryText)
      osd.osdVStackView.setVisibilityPriority(.notVisible, for: osd.osdAccessoryProgress)

      // data for mustache rendering
      let osdData: [String: String] = [
        "duration": VideoTime.string(from: player.info.playbackTime.durationSec),
        "position": VideoTime.string(from: player.info.playbackTime.positionSec),
        "currChapter": (player.mpv.getInt(MPVProperty.chapter) + 1).description,
        "chapterCount": player.info.chapters.count.description
      ]
      osd.osdAccessoryText.stringValue = try! (try! Template(string: text)).render(osdData)
    }
  }

  @MainActor
  fileprivate func updateOSDSize(from givenGeo: PWinGeometry? = nil) {
    guard let window else { return }
    let currentLayout = currentLayout
    let pwGeo: PWinGeometry
    if let givenGeo {
      pwGeo = givenGeo
    } else {
      // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
      switch currentLayout.mode {
      case .windowedNormal, .windowedInteractive:
        pwGeo = windowedGeoForCurrentFrame()
      case .fullScreenNormal, .fullScreenInteractive:
        pwGeo = currentLayout.buildFullScreenGeometry(inScreenID: bestScreen.screenID, geo.video)
      case .musicMode:
        pwGeo = musicModeGeoForCurrentFrame()
      }
    }

    let osdTextSize = pwGeo.getOSDTextSize()
    if osdTextSize != osd.textSizeLast {
      log.verbose("[OSD] Δ textSize: \(osd.textSizeLast) → \(osdTextSize)")
      osd.textSizeLast = osdTextSize

      // Also update progress bar height based on text size
      osd.updateColors(windowAppearance: window.effectiveAppearance)

      let osdAccessoryTextSize = (osdTextSize * 0.75).rounded().clamped(to: 11...25)
      osd.osdAccessoryText.font = NSFont.monospacedDigitSystemFont(ofSize: osdAccessoryTextSize, weight: .regular)

      let marginScalarH: Double
      let marginScalarV: Double
      if #available(macOS 26.0, *) {
        marginScalarH = 0.2
        marginScalarV = 0.2
      } else {
        marginScalarH = 0.15
        marginScalarV = 0.15
      }
      // Update padding around edges
      let marginH = 8 + (osdTextSize * marginScalarH).rounded()
      osd.osdTrailingPaddingConstraint.constraint?.animateToConstant(marginH)
      osd.osdLeadingPaddingConstraint.constraint?.animateToConstant(marginH)
      let marginV = 8 + (osdTextSize * marginScalarV).rounded()
      osd.osdTopPaddingConstraint.constraint?.animateToConstant(marginV)
      osd.osdBtmPaddingConstraint.constraint?.animateToConstant(marginV)

      // Update OSD label
      let osdLabelFont = NSFont.monospacedDigitSystemFont(ofSize: osdTextSize, weight: .regular)
      osd.osdLabel.font = osdLabelFont
    }
  }

  @MainActor
  private func updateOSDIcon(from message: OSDMessage) {
    var icon: NSImage? = nil
    var isIconGrayedOut = false

    if message.isSoundRelated {
      // Add sound icon which indicates current audio status.
      // Gray color == disabled. Slash == muted. Can be combined

      let isAudioDisabled = !player.info.isAudioTrackSelected
      let currentVolume = player.info.volume
      let isMuted = player.info.isMuted
      isIconGrayedOut = isAudioDisabled
      if isAudioDisabled {
        icon = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "No audio track is selected")!
      } else {
        icon = volumeIcon(volume: currentVolume, isMuted: isMuted)
      }
    } else {
      switch message {
      case .resume:
        icon = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")!
      case .pause:
        icon = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!
      case .stop:
        icon = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")!
      case .seek:
        icon = osd.currentSeekIcon
      default:
        break
      }
    }

    let isIconVisible = icon != nil
    // This will set icon width to 0 if it should not be visible so that VStackView can use its space.
    osd.updateIconSize(isIconVisible: isIconVisible)
    osd.osdIconImageView.isHidden = !isIconVisible

    if let icon {
      osd.osdIconImageView.image = icon
      osd.osdIconImageView.contentTintColor = isIconGrayedOut ? .disabledControlTextColor : .controlTextColor
      osd.iconToVStackSpacingConstraint.constraint?.constant = 4
    } else {
      // Need this only for OSD messages which use the icon
      osd.iconToVStackSpacingConstraint.constraint?.constant = 0
    }
    log.trace("[OSD] Icon visible=\(isIconVisible.yn) for msg: \(message)")
  }

  // MARK: - Show OSD

  /// Do not call `enqueueOSDForDisplay` directly. Call `PlayerCore.sendOSD` instead.
  ///
  /// There is a timing issue that can occur when the user holds down a key to rapidly repeat a key binding or menu item
  /// equivalent, which should result in an OSD being displayed for each keypress. But for some reason, the task to
  /// update the OSD, which is enqueued via `DispatchQueue.main.async` (or even `sync`), does not run at all while the
  /// key events continue to come in.
  /// To work around this issue, we instead enqueue the tasks to display OSD using a simple LinkedList and Lock.
  /// Then when `updateUIControls()` via the `DisplayLink` callback, the OSD messages will be dequeued & displayed.
  fileprivate func enqueueOSDForDisplay(_ msg: OSDMessage, autoHide: Bool, accessoryViewController: NSViewController?) {
    if case .debug = msg {
      log.verbose("DebugOSD: \(msg)")
    }

    guard !sessionState.isRestoring else { return }

    /// Check `isFileLoadedAndSized` early to prevent race condition
    let disableOSDForFileLoading: Bool = !player.info.isFileLoadedAndSized
    if disableOSDForFileLoading && !msg.isExternal {
      switch msg {
      case .fileStart,
          .resumeFromWatchLater,
          .debug:
        break
      default:
        return
      }
    }

    guard canShowOSD(message: msg) else { return }

    // Need to do the UI sync in the main queue
    DispatchQueue.main.async { [self] in
      log.verbose("[OSD] Enqueuing: \(msg)")
      // Enqueue first, in case main queue is blocked
      osd.queue.append({ [self] in
        log.verbose("[OSD] Dequeuing: \(msg)")
        // DO NOT use animationPipeline here. It is not needed, and will cause OSD to block
        displayOSD(msg, autoHide: autoHide, accessoryViewController: accessoryViewController)
      })
      player.syncTimeAndCacheUI()
    }
  }

  /// Do not call `displayOSD` directly. Call `PlayerCore.sendOSD` instead.
  @MainActor
  private func displayOSD(_ msg: OSDMessage, autoHide: Bool, accessoryViewController: NSViewController?) {
    // Check again. May have been enqueued a while
    guard canShowOSD(message: msg) else { return }

    // Filter out unwanted OSDs first
    guard !osd.isShowingUserInteractiveOSD || accessoryViewController != nil else { return }

    // If showing debug OSD, do not allow any other OSD type to replace it
    if case .debug = osd.currentlyDisplayedMsg {
      if case .debug = msg {
      } else {
        log.verbose("[OSD] Discarding '\(msg)' because a debug msg is visible")
        return
      }
    }

    if case .fileStart = osd.lastDisplayedMsg {
      if case .fileStart = msg {
        // Allow replacement if changing playbacks quickly
      } else {
        // Lots of junk messages are spewed at start. Ignore all but other .fileStart messages
        if !player.info.isFileLoaded
            || osd.didShowLastMsgSomewhatRecently() { return }
      }
    }

    var msg = msg
    switch msg {

    case .seek(_, _):
      /// Ignore `seek` in favor of these more important messages:
      if osd.didShowLastMsgRecently() {
        if case .speed = osd.lastDisplayedMsg { return }
        if case .frameStep = osd.lastDisplayedMsg { return }
        if case .frameStepBack = osd.lastDisplayedMsg { return }
      }

      /// Many redundant `MPV_EVENT_SEEK` messages are emitted from mpv at different times, and each triggers a call to
      /// show a `seek` OSD message. Show it only if either `position` or `duration` actually changed from their
      /// previously cached values.
      guard let position = player.info.playbackTime.positionSec,
            let duration = player.info.playbackTime.durationSec else {
        log.verbose("[OSD] Ignoring request for 'seek': position or duration is missing")
        return
      }
      let positionDelta = abs(position - (osd.lastPlaybackPosition ?? Double.greatestFiniteMagnitude))
      let durationDelta = abs(duration - (osd.lastPlaybackDuration ?? Double.greatestFiniteMagnitude))
      guard positionDelta > Constants.OSD.osdSeekMinDeltaSec ||
            durationDelta > Constants.OSD.osdSeekMinDeltaSec else {
        log.verbose("[OSD] Ignoring redundant request for 'seek'; neither position or duration has changed "
                    + "(Δp=\(positionDelta) Δd=\(durationDelta))")
        return
      }
      osd.lastPlaybackPosition = position
      osd.lastPlaybackDuration = duration

    case .pause, .resume:
      // Do not show pauses/resumes during an active seek
      guard !isScrollingOrDraggingPlaySlider else { return }

      if osd.didShowLastMsgRecently() {
        if case .speed = osd.lastDisplayedMsg, case .resume = msg { return }
        if case .frameStep = osd.lastDisplayedMsg { return }
        if case .frameStepBack = osd.lastDisplayedMsg { return }
      }

      osd.lastPlaybackPosition = player.info.playbackTime.positionSec
      osd.lastPlaybackDuration = player.info.playbackTime.durationSec

    case .crop(let newCropLabel):
      if newCropLabel == StringConstants.noneCropIdentifier,
         !isInInteractiveMode,
         player.info.videoFiltersDisabled[Constants.FilterLabel.crop] != nil {
        log.verbose("[OSD] Ignoring request for Crop 'None': looks like user starting to edit an existing crop")
        return
      }
      if osd.didShowLastMsgRecently() {
        // As of v1.4, partial rotations can trigger "crop" messages as a side effect. Show rotation msg only.
        if case .rotation = osd.lastDisplayedMsg { return }
      }

    case .resumeFromWatchLater:
      if case .fileStart(let filename, _) = osd.lastDisplayedMsg {
        // Append details msg indicating restore state to existing msg
        let detailsMsg = msg.details().0
        msg = .fileStart(filename, detailsMsg)
      }

    default:
      break
    }

    // End filtering

    log.verbose("[OSD] Setting lastDisplayedMsg = \(msg)")
    osd.lastDisplayedMsg = msg

    /// The pseudo-OSDMessage `seekRelative`, if present, contains the step time for a relative seek.
    /// But because it needs to be parsed from the mpv log, it is sent as a separate msg which arrives immediately
    /// prior to the `seek` msg. With some smart logic, the info from the two messages can be combined to display
    /// the most appropriate "jump" icon in the OSD in addition to the time display & progress bar.
    if case .seekRelative(let stepString) = msg, let step = Double(stepString) {
      log.verbose("[OSD] Showing '\(msg)'")

      let isBackward = step < 0
      let accDescription = "Relative Seek \(isBackward ? "Backward" : "Forward")"
      var name: String
      switch abs(step) {
      case 5, 10, 15, 30, 45, 60, 75, 90:
        let absStep = Int(abs(step))
        name = isBackward ? "gobackward.\(absStep)" : "goforward.\(absStep)"
      default:
        name = isBackward ? "gobackward.minus" : "goforward.plus"
      }
      /// Set icon for next msg, which is expected to be a `seek`
      osd.nextSeekIcon = NSImage(systemSymbolName: name, accessibilityDescription: accDescription)!
      /// Done with `seekRelative` msg. It is not used for display.
      return
    } else if case .seek(_, _) = msg {
      /// Shift next icon into current icon, which will be used until the next call to `displayOSD()`
      /// (although note that there can be subsequent calls to `updateOSDViews()` to update the OSD's displayed time
      /// while playing, but those do not count as "new" OSD messages, and thus will continue to use
      /// `osd.currentSeekIcon`).
      if isScrollingOrDraggingPlaySlider {
        // give up on fancy OSD for scroll wheel seek (for now)
        osd.currentSeekIcon = nil
        osd.nextSeekIcon = nil
      } else if osd.nextSeekIcon != nil {
        osd.currentSeekIcon = osd.nextSeekIcon
        osd.nextSeekIcon = nil
      }
    } else {
      osd.currentSeekIcon = nil
    }

    // Restart timer
    osd.hideOSDTimer.cancel()
    osd.animationState = .shown

    if autoHide {
      let forcedTimeout = msg.alwaysEnabled ? TimeConstants.osdTimeoutForAlwaysEnabledMessages : nil
      let timeout: Double = forcedTimeout ?? OSDState.osdTimeoutFromPrefs()
      log.verbose("[OSD] Showing '\(msg)' timeout=\(timeout)\(forcedTimeout != nil ? " (forced)" : "")")
      osd.hideOSDTimer.restart(withNewTimeout: timeout)
    } else {
      log.verbose("[OSD] Showing '\(msg)', no timeout")
    }

    let existingAccessoryViews = osd.osdVStackView.views(in: .bottom)
    if !existingAccessoryViews.isEmpty {
      for subview in osd.osdVStackView.views(in: .bottom) {
        osd.osdVStackView.removeView(subview)
      }
    }
    if let accessoryViewController {  // e.g., ScreenshootOSDView
      let accessoryView = accessoryViewController.view
      osd.userInteractiveAccessory = accessoryViewController

      osd.osdVStackView.addView(accessoryView, in: .bottom)
    }

    osd.osdView.alphaValue = 1
    osd.osdView.isHidden = false
    
    updateOSDViews(from: msg)
  }

  fileprivate func canShowOSD(message: OSDMessage) -> Bool {
    if message.alwaysEnabled { return true }

    if message.isDisabled { return false }
    /// Note: use `loaded` (querying `isWindowLoaded` will initialize pwc unexpectedly)
    if !loaded || !Preference.bool(for: .enableOSD) { return false }
    if player.isUsingMpvOSD || player.isRestoring || player.isInInteractiveMode { return false }

    if isInMiniPlayer {
      return musicModeGeo.isViewportShown && Preference.bool(for: .enableOSDInMusicMode)
    }

    return true
  }

  // MARK: - Hide OSD

  @MainActor
  func hideOSD(immediately: Bool = false) {
    guard loaded else { return }

    let duration = immediately ? 0 : Constants.AnimationDuration.osdAnimation

    if osd.animationState != .hidden {
      log.trace("[OSD] Will hide")
    }
    osd.animationState = .willHide
    osd.hideOSDTimer.cancel()

    IINAAnimation.runAsync(.init(duration: duration, { [self] in
      osd.osdView.alphaValue = 0

    }), then: { [self] in
      if osd.animationState == .willHide {
        osd.animationState = .hidden
        osd.osdView.isHidden = true
        osd.userInteractiveAccessory = nil
        for subview in osd.osdVStackView.views(in: .bottom) {
          osd.osdVStackView.removeView(subview)
        }
      }
    })
  }

}  /// end `extension PlayerWindowController`


extension PlayerCore {

  func sendOSD(_ msg: OSDMessage, autoHide: Bool = true, accessoryViewController: NSViewController? = nil) {
    guard let pwc, pwc.loaded else { return }
    pwc.enqueueOSDForDisplay(msg, autoHide: autoHide, accessoryViewController: accessoryViewController)
  }

  func hideOSD() {
    DispatchQueue.main.async { [self] in
      pwc.hideOSD()
    }
  }

}
