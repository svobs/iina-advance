//
//  ControlBarGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 2024/09/08.
//

import Foundation

fileprivate let spacingTicksMin: Int = 0
fileprivate let spacingTicksMax: Int = 4
fileprivate let iconSizeTicksMin: Int = 0
fileprivate let iconSizeTicksMax: Int = 3

/// Icons can never shrink smaller than this fraction of the available height.
fileprivate let iconSizeMinScaleMultiplier: CGFloat = 0.5

fileprivate let playIconSpacingScaleMultiplier: CGFloat = 0.35
fileprivate let toolSpacingScaleMultiplier: CGFloat = 0.25

fileprivate let floatingToolbarIconSize: CGFloat = 24
fileprivate let floatingToolbarIconSpacing: CGFloat = 6
fileprivate let floatingPlayIconSize: CGFloat = 28
fileprivate let floatingPlayIconSpacing: CGFloat = 20
fileprivate let floatingVolumeIconSize: CGFloat = 28
fileprivate let floatingFullIconHeight: CGFloat = max(floatingToolbarIconSize, floatingPlayIconSize)
fileprivate let floatingPlaySliderHeight: CGFloat = 37

fileprivate let musicModeBarHeight: CGFloat = 48
fileprivate let musicModePlayIconSize: CGFloat = 24
fileprivate let musicModePlayIconSpacing: CGFloat = 12
fileprivate let musicModeToolbarIconSize: CGFloat = 14
fileprivate let musicModeToolbarIconSpacing: CGFloat = 12

fileprivate let stepIconScaleFactor: CGFloat = 0.85
fileprivate let systemArrowSymbolScaleFactor: CGFloat = 0.85
fileprivate let volumeIconTwoRowScaleFactor: CGFloat = 0.85

// TODO: reimplement OSC title bar feature

struct ControlBarGeometry: Sendable, CustomStringConvertible {
  // MARK: Stored properties

  let mode: PlayerWindowMode
  let position: Preference.OSCPosition

  let arrowButtonAction: Preference.ArrowButtonAction

  /// If true, always use single-row style OSC, even if qualifying for multi-line OSC.
  /// (Only applies to top & bottom OSCs).
  let forceSingleRowStyle: Bool
  /// Only used if two-row OSC
  let oscTimeLabelsAlwaysWrapSlider: Bool

  /// Preferred height for "full-width" OSCs (i.e. top or bottom, not floating or music mode)
  let barHeight: CGFloat

  /// Needed if using "multiLine" style OSC; otherwise same as `barHeight`
  let fullIconHeight: CGFloat

  let playIconSizeTicks: Int
  let playIconSpacingTicks: Int
  let toolIconSizeTicks: Int
  let toolIconSpacingTicks: Int

  let toolIconSize: CGFloat
  let toolIconSpacing: CGFloat

  /// Size of a side the 3 square playback button icons (Play/Pause, LeftArrow, RightArrow):
  let playIconSize: CGFloat

  /// This is usually the same as `playIconSize`, but can vary based on icon type
  let arrowIconHeight: CGFloat

  /// Depends on `arrowIconHeight` and aspect ratio of arrow image
  let arrowIconWidth: CGFloat

  /// Scale of spacing to the left & right of each playback button (for top/bottom OSC):
  let playIconSpacing: CGFloat

  let toolbarItems: [Preference.ToolBarButton]

  /// Height of the entire `PlaySlider` view, including unused space.
  ///
  /// It is useful to expand slider height so that hovers are more likely to register.
  /// But its height is also a useful metric for configuring spacing elsewhere.
  /// See also: `sliderScale`
  let playSliderHeight: CGFloat

  var description: String {
    "ControlBarGeo(\(mode) pos=\(position) barH=\(barHeight) fullIconH=\(fullIconHeight) playIcon=\(playIconSize);spacing=\(playIconSpacing) toolIcon=\(toolIconSize);spacing=\(toolIconSpacing) ticks=[\(playIconSizeTicks) \(playIconSpacingTicks) \(toolIconSizeTicks) \(toolIconSpacing)] arrowIcon=\(arrowIconWidth)x\(arrowIconHeight) arrowBtn=\(arrowButtonAction) forceSingleRow=\(forceSingleRowStyle.yn) timeLabelsAlwaysWrapSlider=\(oscTimeLabelsAlwaysWrapSlider.yn))"
  }

  // MARK: Init

  /// All fields are optional. Any omitted fields will be filled in from preferences
  init(mode: PlayerWindowMode,
       oscPosition: Preference.OSCPosition? = nil,
       toolbarItems: [Preference.ToolBarButton]? = nil,
       arrowButtonAction: Preference.ArrowButtonAction? = nil,
       barHeight desiredBarHeight: CGFloat? = nil,
       forceSingleRowStyle: Bool? = nil,
       oscTimeLabelsAlwaysWrapSlider: Bool? = nil,
       toolIconSizeTicks: Int? = nil, toolIconSpacingTicks: Int? = nil,
       playIconSizeTicks: Int? = nil, playIconSpacingTicks: Int? = nil) {
    self.mode = mode
    self.toolbarItems = toolbarItems ?? ControlBarGeometry.oscToolbarItems
    let forceSingleRowStyle = forceSingleRowStyle ?? (Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .oscForceSingleRow))
    self.forceSingleRowStyle = forceSingleRowStyle
    self.oscTimeLabelsAlwaysWrapSlider = oscTimeLabelsAlwaysWrapSlider ?? Preference.bool(for: .oscTimeLabelsAlwaysWrapSlider)

    // Actual cardinal sizes should be downstream from tick values
    let playIconSizeTicks = playIconSizeTicks ?? Preference.integer(for: .oscBarPlayIconSizeTicks)
    self.playIconSizeTicks = playIconSizeTicks
    let playIconSpacingTicks = playIconSpacingTicks ?? Preference.integer(for: .oscBarPlayIconSpacingTicks)
    self.playIconSpacingTicks = playIconSpacingTicks
    let toolIconSizeTicks = toolIconSizeTicks ?? Preference.integer(for: .oscBarToolIconSizeTicks)
    self.toolIconSizeTicks = toolIconSizeTicks
    let toolIconSpacingTicks = toolIconSpacingTicks ?? Preference.integer(for: .oscBarToolIconSpacingTicks)
    self.toolIconSpacingTicks = toolIconSpacingTicks

    let oscPosition = oscPosition ?? Preference.enum(for: .oscPosition)

    let barHeight: CGFloat
    let fullIconHeight: CGFloat
    if mode == .musicMode {
      barHeight = musicModeBarHeight
      fullIconHeight = barHeight
      self.playSliderHeight = Constants.MusicMode.positionSliderWrapperViewHeight - 4
      self.playIconSize = musicModePlayIconSize
      self.toolIconSize = musicModeToolbarIconSize
      self.toolIconSpacing = musicModeToolbarIconSpacing
      self.playIconSpacing = musicModePlayIconSpacing

    } else if oscPosition == .floating {
      barHeight = FloatingControlBar.barHeight  // not really useful here anyway
      fullIconHeight = floatingFullIconHeight
      self.playSliderHeight = floatingPlaySliderHeight
      self.toolIconSize = floatingToolbarIconSize
      self.toolIconSpacing = floatingToolbarIconSpacing
      self.playIconSize = floatingPlayIconSize
      self.playIconSpacing = floatingPlayIconSpacing

    } else {
      // First establish bar height
      let desiredBarHeight = desiredBarHeight ?? CGFloat(Preference.integer(for: .oscBarHeight))
      // We need a bar height of 0 in some cases, such as resetting at window close, so do not enforce minimum bar height
      barHeight = desiredBarHeight.clamped(to: 0...Constants.maxOSCBarHeight)
      let isTwoRowOSC = !forceSingleRowStyle && ControlBarGeometry.qualifiesForMultiLineOSC(barHeight: barHeight, oscPosition, mode)
      if isTwoRowOSC {
        let playSliderHeight: CGFloat
        if Constants.twoRowOSC_LimitPlaySliderHeight {
          // Cap PlaySlider height at 2x its minimum
          playSliderHeight = min(barHeight * 0.5, Constants.Slider.minPlaySliderHeight * 2).rounded()
        } else {
          // Use half the bar height for the play slider
          playSliderHeight = (barHeight * 0.5).rounded()
        }
        let iconVerticalMarginsTotal = ControlBarGeometry.twoRowOSC_BottomMargin(playSliderHeight: playSliderHeight)
        let remainingFreeHeight = barHeight - playSliderHeight - iconVerticalMarginsTotal
        fullIconHeight = remainingFreeHeight
        self.playSliderHeight = playSliderHeight

        let playIconSizeTicks = isTwoRowOSC ? iconSizeTicksMax - 1 : iconSizeTicksMax - 2
        let toolIconSizeTicks = iconSizeTicksMax - 1
        let toolIconSpacingTicks = spacingTicksMax + 1
        let playIconSpacingTicks = isTwoRowOSC ? spacingTicksMax : spacingTicksMax - 1

        self.playIconSize = ControlBarGeometry.iconSize(fromTicks: playIconSizeTicks, fullHeight: fullIconHeight)
        self.toolIconSize = ControlBarGeometry.iconSize(fromTicks: toolIconSizeTicks, fullHeight: fullIconHeight)
        self.toolIconSpacing = ControlBarGeometry.toolIconSpacing(fromTicks: toolIconSpacingTicks, fullHeight: fullIconHeight)
        self.playIconSpacing = ControlBarGeometry.playIconSpacing(fromTicks: playIconSpacingTicks, fullHeight: fullIconHeight)
      } else {
        // Is single-line OSC
        self.playSliderHeight = barHeight
        // Reduce max button size so they don't touch edges or (if .top) icons above
        fullIconHeight = max(0, barHeight - 8)

        // Single row configuration: icon sizes & spacing are adjustable
        self.toolIconSize = ControlBarGeometry.iconSize(fromTicks: toolIconSizeTicks, fullHeight: fullIconHeight)
        self.toolIconSpacing = ControlBarGeometry.toolIconSpacing(fromTicks: toolIconSpacingTicks, fullHeight: fullIconHeight)
        self.playIconSize = ControlBarGeometry.iconSize(fromTicks: playIconSizeTicks, fullHeight: fullIconHeight)
        self.playIconSpacing = ControlBarGeometry.playIconSpacing(fromTicks: playIconSpacingTicks, fullHeight: fullIconHeight)
      }
    }

    self.barHeight = barHeight
    self.fullIconHeight = fullIconHeight

    self.position = oscPosition

    // Compute size of arrow buttons
    let arrowButtonAction = arrowButtonAction ?? Preference.enum(for: .arrowButtonAction)
    let arrowIconHeight: CGFloat
    switch arrowButtonAction {
    case .unused:
      arrowIconHeight = 0
    case .seek:
      arrowIconHeight = (playIconSize * stepIconScaleFactor).rounded()
    case .speed, .playlist:
      arrowIconHeight = (playIconSize * systemArrowSymbolScaleFactor).rounded()
    }
    let leftArrowImage = ControlBarGeometry.leftArrowImage(given: arrowButtonAction)
    self.arrowIconWidth = leftArrowImage.deriveWidth(fromHeight: arrowIconHeight)
    self.arrowButtonAction = arrowButtonAction
    self.arrowIconHeight = arrowIconHeight
  }

  func clone(mode: PlayerWindowMode) -> ControlBarGeometry {
    return ControlBarGeometry(mode: mode, oscPosition: self.position,
                              toolbarItems: self.toolbarItems, arrowButtonAction: self.arrowButtonAction,
                              barHeight: self.barHeight,
                              toolIconSizeTicks: self.toolIconSizeTicks, toolIconSpacingTicks: self.toolIconSpacingTicks,
                              playIconSizeTicks: self.playIconSizeTicks, playIconSpacingTicks: self.playIconSpacingTicks)
  }

  var isValid: Bool {
    let playIconSizeTicks = playIconSizeTicks
    guard playIconSizeTicks.isBetweenInclusive(iconSizeTicksMin, and: iconSizeTicksMax) else { return false }
    let playIconSpacingTicks = playIconSpacingTicks
    guard playIconSpacingTicks.isBetweenInclusive(spacingTicksMin, and: spacingTicksMax) else { return false }
    let toolIconSizeTicks = toolIconSizeTicks
    guard toolIconSizeTicks.isBetweenInclusive(iconSizeTicksMin, and: iconSizeTicksMax) else { return false }
    let toolIconSpacingTicks = toolIconSpacingTicks
    guard toolIconSpacingTicks.isBetweenInclusive(spacingTicksMin, and: spacingTicksMax) else { return false }
    return true
  }

  var hasArrowButtons: Bool { arrowIconWidth > 0 }

  var isTwoRowBarOSC: Bool { !forceSingleRowStyle && ControlBarGeometry.qualifiesForMultiLineOSC(barHeight: barHeight, position, mode) }

  var leftArrowImage: NSImage { ControlBarGeometry.leftArrowImage(given: arrowButtonAction) }
  var rightArrowImage: NSImage { ControlBarGeometry.rightArrowImage(given: arrowButtonAction) }

  
  // MARK: - Sliders

  /// Ratio of the current slider's height vs the standard height.
  /// Useful for growing/shrinking related views & offsets.
  var sliderScale: CGFloat {
    if mode == .musicMode {
      return 1.0
    }

    let scaleMultiplier: CGFloat
    switch position {
    case .floating:
      return 1.0
    case .top,
        .bottom:
      scaleMultiplier = 0.8
    }
    return (playSliderHeight * scaleMultiplier / Constants.Slider.minPlaySliderHeight).clamped(to: 1.0...3.0)
  }

  /// Height of the `PlaySlider` & `VolumeSlider` bars, in "normal" mode (i.e. not focused).
  /// This is only the slider's progress bar, not the whole bounds of its view. In fact it must be less than the height
  /// of its bounds, to prevent clipping.
  var sliderBarHeightNormal: CGFloat {
    if position == .floating {
      return (Constants.Slider.unscaledBarNormalHeight * 1.5).rounded()
    }
    let height = (sliderScale * Constants.Slider.unscaledBarNormalHeight * 0.8).rounded()
    return max(Constants.Slider.unscaledBarNormalHeight, height)
  }

  var sliderKnobWidth: CGFloat {
    return (Constants.Slider.defaultKnobWidth * sliderScale).rounded()
  }

  var sliderKnobHeight: CGFloat {
    return (Constants.Slider.defaultKnobHeight * sliderScale).rounded()
  }

  var sliderIndicatorSize: NSSize {
    let width = max(1.0, (sliderKnobWidth * 0.25).rounded())
    let height = sliderKnobHeight - 2.0
    return NSSize(width: width, height: height)
  }

  var volumeIconHeight: CGFloat {
    if mode == .musicMode {
      return 18.0
    }
    if position == .floating {
      return floatingVolumeIconSize
    }
    let isConfiguredForTwoRow = !forceSingleRowStyle && position == .bottom
    if isConfiguredForTwoRow {
      return playIconSize * volumeIconTwoRowScaleFactor
    }
    return playIconSize
  }


  var volumeSliderWidth: CGFloat {
    if mode == .musicMode {
      return 100.0
    }
    return (Constants.Slider.unscaledVolumeSliderWidth * sliderScale).rounded()
  }

  /// Horizontal spacing between PlaySlider & time labels (if `timeLabelsWrapSlider==YES`). Also: horizontal spacing between VolumeSlider & volume icon.
  var hSpacingAroundSliders: CGFloat {
    if mode == .musicMode || position == .floating {
      return 6.0
    }
    return (max(6.0, hStackSpacing * 0.667)).rounded()
  }

  // MARK: Time Labels

  /// Elapsed & current time labels are placed to left & right of slider, respectively?
  var timeLabelsWrapSlider: Bool {
    return !isTwoRowBarOSC || oscTimeLabelsAlwaysWrapSlider
  }

  var timeLabelFontSize: CGFloat {
    if mode == .musicMode {
      // Decrease font size of time labels for more compact display
      return 9
    }
    switch position {
    case .floating:
      return 12.0
    case .top, .bottom:
      if isTwoRowBarOSC && !oscTimeLabelsAlwaysWrapSlider {
        // Time labels go under slider; plenty of space
        let normalSize = 11.0
        return (sliderScale * normalSize).rounded().clamped(to:normalSize...(normalSize * 3))
      }
      let normalSize = 10.0
      return (sliderScale * normalSize).rounded().clamped(to:normalSize...(normalSize * 3))
    }
  }

  /// Font for each of `leftTimeLabel`, `rightTimeLabel`, to the left & right of the play slider, respectively.
  var timeLabelFont: NSFont {
    let timeLabelFontSize = timeLabelFontSize
    let weight: NSFont.Weight
    if mode == .musicMode {
      weight = .light
    } else {
      weight = .regular
    }
    return NSFont.monospacedDigitSystemFont(ofSize: timeLabelFontSize, weight: weight)
  }

  // MARK: - Other Layout

  /// Horizontal spacing between each of the set of controls in the bar (e.g., `playSliderAndTimeLabelsView`, `oscToolbarView`, etc.
  var hStackSpacing: CGFloat {
    if isTwoRowBarOSC {
      return (Constants.TwoRowOSC.oscSectionHSpacing * (barHeight / Constants.Slider.minPlaySliderHeight)).rounded()
    } else {
      return (Constants.oscSectionHSpacing_SingleRow + barHeight / 5).rounded()
    }
  }

  /// Row 1: Play slider + maybe time labels
  var leadingSpace_Row1: CGFloat {
    let space = (sliderScale * 8 - 6).rounded()
    return space
  }

  var trailingSpace_Row1: CGFloat {
    return leadingSpace_Row1
  }

  /// Row 2: Playback controls, volume, toolbar
  var leadingSpace_Row2: CGFloat {
    return (sliderScale * 8 - 6).rounded()
  }

  var trailingSpace_Row2: CGFloat {
    return leadingSpace_Row1
  }

  /// Font size for Seek Preview time label (shown while hovering over PlaySlider and/or seeking).
  var seekPreviewTimeLabelFontSize: CGFloat {
    let normalSize = 11.0
    if mode == .musicMode {
      return normalSize
    }
    return (sliderScale * 1.1 * normalSize).rounded().clamped(to: normalSize...24)
  }

  /// Font size for Seek Preview time label (shown while hovering over PlaySlider and/or seeking).
  var seekPreviewChapterLabelFontSize: CGFloat {
    let normalSize = 10.0
    if mode == .musicMode {
      return normalSize
    }
    return (sliderScale * normalSize).rounded().clamped(to: normalSize...24)
  }

  var speedLabelFontSize: CGFloat {
    let idealSize = playIconSize * 0.25
    let freeHeight = fullIconHeight - playIconSize
    let deficit: CGFloat = max(0.0, idealSize - freeHeight)
    let compromise = idealSize - (0.7 * deficit)
    return compromise.rounded().clamped(to: 8...36)
  }

  // MARK: - Playback Controls

  /// Width of left, right, play btns + their spacing.
  /// Items will have `playIconSpacing` between each item, and `playIconSpacing * 0.5` for each of left margin & right margin.
  var totalPlayControlsWidth: CGFloat {
    let itemSizes = self.arrowButtonAction == .unused ? [playIconSize] : [arrowIconWidth, playIconSize, arrowIconWidth]
    let totalIconSpace = itemSizes.reduce(0, +)
    let totalInterIconSpace = playIconSpacing * CGFloat(itemSizes.count)
    return totalIconSpace + totalInterIconSpace
  }

  var leftArrowCenterXOffset: CGFloat {
    -rightArrowCenterXOffset
  }

  var rightArrowCenterXOffset: CGFloat {
    hasArrowButtons ? (playIconSize + arrowIconWidth) * 0.5 + playIconSpacing : 0.0
  }

  // MARK: - Toolbar

  var totalToolbarWidth: CGFloat {
    let totalIconSpacing: CGFloat = 2 * toolIconSpacing * CGFloat(toolbarItems.count + 1)
    let totalIconWidth = toolIconSize * CGFloat(toolbarItems.count)
    return totalIconWidth + totalIconSpacing
  }

  func toolbarItemsAreSame(as otherGeo: ControlBarGeometry) -> Bool {
    let ours = toolbarItems.compactMap({ $0.rawValue })
    let theirs = otherGeo.toolbarItems.compactMap({ $0.rawValue })
    if ours.count != theirs.count {
      return false
    }
    for (o, t) in zip(ours, theirs) {
      if o != t {
        return false
      }
    }
    return true
  }

  // MARK: Static

  static func buttonSize(iconSize: CGFloat, iconSpacing: CGFloat) -> CGFloat {
    return iconSize + max(0, 2 * iconSpacing)
  }

  static var oscToolbarItems: [Preference.ToolBarButton] {
    get {
      return (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []).compactMap(Preference.ToolBarButton.init(rawValue:))
    }
  }

  /// Prefs UI ticks → CGFloat
  private static func iconSize(fromTicks ticks: Int, fullHeight: CGFloat) -> CGFloat {
    let fixedMinHeight = fullHeight * iconSizeMinScaleMultiplier
    let adjustableHeight = fullHeight - fixedMinHeight

    let height = fixedMinHeight + (adjustableHeight * (CGFloat(ticks) / CGFloat(iconSizeTicksMax)))
    return height.rounded()
  }

  /// Prefs UI ticks → CGFloat
  private static func playIconSpacing(fromTicks ticks: Int, fullHeight: CGFloat) -> CGFloat {
    let spacing = fullHeight * CGFloat(ticks) / CGFloat(spacingTicksMax - 1) * playIconSpacingScaleMultiplier
    return spacing.rounded()
  }

  /// Prefs UI ticks → CGFloat
  private static func toolIconSpacing(fromTicks ticks: Int, fullHeight: CGFloat) -> CGFloat {
    let spacing = fullHeight * CGFloat(ticks) / CGFloat(spacingTicksMax - 1) * toolSpacingScaleMultiplier
    return spacing.rounded()
  }

  static func leftArrowImage(given arrowButtonAction: Preference.ArrowButtonAction) -> NSImage {
    switch arrowButtonAction {
    case .playlist:
      return Images.prevTrack
    case .speed, .unused:
      return Images.rewind
    case .seek:
      return Images.stepBackward10
    }
  }

  static func rightArrowImage(given arrowButtonAction: Preference.ArrowButtonAction) -> NSImage {
    switch arrowButtonAction {
    case .playlist:
      return Images.nextTrack
    case .speed, .unused:
      return Images.fastForward
    case .seek:
      return Images.stepForward10
    }
  }

  private static func qualifiesForMultiLineOSC(barHeight: CGFloat, _ position: Preference.OSCPosition, _ mode: PlayerWindowMode) -> Bool {
    guard mode != .musicMode else { return false }
    guard position != .floating else { return false }
    return barHeight >= Constants.TwoRowOSC.minQualifyingBarHeight
  }

  /// Derives desired bottom margin from playSliderHeight (TwoRowOSC style only)
  static func twoRowOSC_BottomMargin(playSliderHeight: CGFloat) -> CGFloat {
    return(playSliderHeight * 0.15).rounded()
  }
}
