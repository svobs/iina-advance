//
//  PWinGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// Data structure containing size values of four sides
struct MarginQuad: Equatable, CustomStringConvertible {
  let top: CGFloat
  let trailing: CGFloat
  let bottom: CGFloat
  let leading: CGFloat

  var totalWidth: CGFloat {
    return leading + trailing
  }

  var totalHeight: CGFloat {
    return top + bottom
  }

  var totalSize: CGSize {
    return CGSize(width: totalWidth, height: totalHeight)
  }

  var description: String {
    return "(↑:\(top.strMin) →:\(trailing.strMin) ↓:\(bottom.strMin) ←:\(leading.strMin))"
  }

  init(top: CGFloat = 0, trailing: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0) {
    self.top = top
    self.trailing = trailing
    self.bottom = bottom
    self.leading = leading
  }

  func clone(top: CGFloat? = nil, trailing: CGFloat? = nil,
             bottom: CGFloat? = nil, leading: CGFloat? = nil) -> MarginQuad {
    return MarginQuad(top: top ?? self.top,
                      trailing: trailing ?? self.trailing,
                      bottom: bottom ?? self.bottom,
                      leading: leading ?? self.leading)
  }

  func addingTo(top: CGFloat = 0, trailing: CGFloat = 0,  bottom: CGFloat = 0,  leading: CGFloat = 0) -> MarginQuad {
    return MarginQuad(top: self.top + top,
                      trailing: self.trailing + trailing,
                      bottom: self.bottom + bottom,
                      leading: self.leading + leading)
  }

  func subtractingFrom( top: CGFloat = 0,  trailing: CGFloat = 0, bottom: CGFloat = 0,  leading: CGFloat = 0) -> MarginQuad {
    return addingTo(top: -top, trailing: -trailing, bottom: -bottom, leading: -leading)
  }

  static let zero = MarginQuad(top: 0, trailing: 0, bottom: 0, leading: 0)
}

/// Describes how a given player window must fit inside its given screen.
enum ScreenFitOption: Int {

  case noConstraints = 0

  /// Constrains inside `screen.visibleFrame`
  case stayInside

  /// Constrains and centers inside `screen.visibleFrame`
  case centerInside

  /// Constrains inside `screen.frame`
  case legacyFullScreen

  /// Constrains inside `screen.frameWithoutCameraHousing`. Provided here for completeness, but not used at present.
  case nativeFullScreen

  var isFullScreen: Bool {
    switch self {
    case .legacyFullScreen, .nativeFullScreen:
      return true
    default:
      return false
    }
  }

  var shouldMoveWindowToKeepInContainer: Bool {
    switch self {
    case .legacyFullScreen, .nativeFullScreen:
      return true
    case .stayInside, .centerInside:
      if Preference.bool(for: .enableAdvancedSettings) {
        return Preference.bool(for: .moveWindowIntoVisibleScreenOnResize)
      }
      return true
    default:
      return false
    }
  }
}

/**
`PWinGeometry`
 Data structure which describes the basic layout configuration of a player window (`PlayerWindowController`).

 For `let wc = PlayerWindowController()`, an instance of this class describes:
 1. The size & position (`windowFrame`) of an IINA player `NSWindow`.
 2. The size of the window's viewport (`viewportView` in a `PlayerWindowController` instance).
    The viewport contains the `videoView` and all of the `Preference.PanelPlacement.inside` views (`viewportSize`).
    Size is inferred by subtracting the bar sizes from `windowFrame`.
 3. Either the height or width of each of the 4 `outsideViewport` bars, measured as the distance between the
    outside edge of `viewportView` and the outermost edge of the bar. This is the minimum needed to determine
    its size & position; the rest can be inferred from `windowFrame` and `viewportSize`.
    If instead the bar is hidden or is shown as `insideViewport`, its outside value will be `0`.
 4. Either  height or width of each of the 4 `insideViewport` bars. These are measured from the nearest outside wall of
    `viewportView`.  If instead the bar is hidden or is shown as `outsideViewport`, its inside value will be `0`.
 5. The size of the video itself (`videoView`), which may or may not be equal to the size of `viewportView`,
    depending on whether empty space is allowed around the video.
 6. The video aspect ratio. This is stored here mainly to create a central reference for it, to avoid differing
    values which can arise if calculating it from disparate sources.

 Below is an example of a player window with letterboxed video, where the viewport is taller than `videoView`.
 • Identifiers beginning with `wc.` refer to fields in the `PlayerWindowController` instance.
 • Identifiers beginning with `geo.` are `PWinGeometry` fields.
 • The window's frame (`windowFrame`) is the outermost rectangle.
 • The frame of `wc.videoView` is the innermost dotted-lined rectangle.
 • The frame of `wc.viewportView` contains `wc.videoView` and additional space for black bars.
 •
 ~                               `geo.viewportSize.width`
 ~                                (of `wc.viewportView`)
 ~                             ◄--------------------------►
 ┌────────────────────────────────────────────────────────────────────────────────────────┐`geo.windowFrame`
 │                                            ▲                                           │
 │                                            │`geo.topMarginHeight`                      │
 │                                            ▼ (only nonzero when covering Macbook notch)│
 ├────────────────────────────────────────────────────────────────────────────────────────┤
 │                                          ▲                                             │
 │                                          │`geo.outsideTopBarHeight`                    │
 │                                          ▼   (`wc.topBarView`)                         │
 ├────────────────────────────┬────────────────────────────┬──────────────────────────────┤ ─ ◄--- `geo.insideTopBarHeight == 0`
 │                            │   `viewportMargins.top`    │                              │ ▲
 │                            ├─────┬────────────────┬─────┤                              │ │ `geo.viewportSize.height`
 │◄--------------------------►│ [€] │ `geo.videoSize`│ [¥] │◄----------------------------►│ │  (of `wc.viewportView`)
 │                            │     │(`wc.videoView`)│     │ `geo.outsideTrailingBarWidth`│ │
 │`geo.outsideLeadingBarWidth`├─────┴────────────────┴─────┤ (of `wc.trailingSidebarView`)│ │
 │(of `wc.leadingSidebarView`)│  `viewportMargins.bottom`  │                              │ ▼
 ├────────────────────────────┴────────────────────────────┴──────────────────────────────┤ ─ ◄--- `geo.insideBottomBarHeight == 0`
 │                                      ▲                                                 │
 │                                      │`geo.outsideBottomBarHeight`                     │  [€] = `viewportMargins.leading`
 │                                      ▼   (of `wc.bottomBarView`)                       │  [¥] = `viewportMargins.trailing`
 └────────────────────────────────────────────────────────────────────────────────────────┘
 */
struct PWinGeometry: Equatable, CustomStringConvertible {
  // MARK: - Stored properties

  // - Screen:
  // The ID of the screen on which this window is displayed
  let screenID: String
  let fitOption: ScreenFitOption
  // The mode affects lockViewportToVideo behavior and minimum sizes
  let mode: PlayerWindowMode

  // - Window dimensions, outermost → innermost

  /// The size & position (`window.frame`) of an IINA player `NSWindow`.
  let windowFrame: NSRect

  // Extra black space (if any) above outsideTopBar, used for covering MacBook's magic camera housing while in legacy fullscreen
  let topMarginHeight: CGFloat

  /// Outside panels
  let outsideBars: MarginQuad
  // TODO: remove all uses of these. Use only `outsideBars`
  var outsideTopBarHeight: CGFloat { outsideBars.top }
  var outsideTrailingBarWidth: CGFloat { outsideBars.trailing }
  var outsideBottomBarHeight: CGFloat { outsideBars.bottom }
  var outsideLeadingBarWidth: CGFloat { outsideBars.leading }

  /// Inside panels
  var insideBars: MarginQuad
  // TODO: remove all uses of these. Use only `insideBars`
  var insideTopBarHeight: CGFloat { insideBars.top }
  var insideTrailingBarWidth: CGFloat { insideBars.trailing }
  var insideBottomBarHeight: CGFloat { insideBars.bottom }
  var insideLeadingBarWidth: CGFloat { insideBars.leading }

  let viewportMargins: MarginQuad

  let videoAspect: CGFloat
  let videoSize: NSSize

  // MARK: - Initializers / Factory Methods

  /// Derives `viewportSize` and `videoSize` from `windowFrame`, `viewportMargins` and `videoAspect`
  init(windowFrame: NSRect, screenID: String, fitOption: ScreenFitOption, mode: PlayerWindowMode, topMarginHeight: CGFloat,
       outsideBars: MarginQuad, insideBars: MarginQuad, viewportMargins: MarginQuad? = nil, videoAspect: CGFloat) {

    self.windowFrame = windowFrame
    self.screenID = screenID
    self.fitOption = fitOption
    self.mode = mode

    assert(topMarginHeight >= 0, "Expected topMarginHeight >= 0, found \(topMarginHeight)")
    self.topMarginHeight = topMarginHeight

    assert(outsideBars.top >= 0, "Expected outsideBars.top >= 0, found \(outsideBars.top)")
    assert(outsideBars.trailing >= 0, "Expected outsideBars.trailing >= 0, found \(outsideBars.trailing)")
    assert(outsideBars.bottom >= 0, "Expected outsideBars.bottom >= 0, found \(outsideBars.bottom)")
    assert(outsideBars.leading >= 0, "Expected outsideBars.leading >= 0, found \(outsideBars.leading)")
    self.outsideBars = outsideBars

    assert(insideBars.top >= 0, "Expected insideBars.top >= 0, found \(insideBars.top)")
    assert(insideBars.trailing >= 0, "Expected insideBars.trailing >= 0, found \(insideBars.trailing)")
    assert(insideBars.bottom >= 0, "Expected insideBars.bottom >= 0, found \(insideBars.bottom)")
    assert(insideBars.leading >= 0, "Expected insideBars.leading >= 0, found \(insideBars.leading)")
    self.insideBars = insideBars

    let viewportSize = PWinGeometry.deriveViewportSize(from: windowFrame, topMarginHeight: topMarginHeight, outsideBars: outsideBars)
    let videoSize = PWinGeometry.computeVideoSize(withAspectRatio: videoAspect, toFillIn: viewportSize, 
                                                  minViewportMargins: viewportMargins, mode: mode)
    self.videoSize = videoSize
    self.viewportMargins = viewportMargins ?? PWinGeometry.computeBestViewportMargins(viewportSize: viewportSize, videoSize: videoSize,
                                                                                      insideBars: insideBars, mode: mode)

    self.videoAspect = videoAspect
  }

  static func fullScreenWindowFrame(in screen: NSScreen, legacy: Bool) -> NSRect {
    if legacy {
      return screen.frame
    } else {
      return screen.frameWithoutCameraHousing
    }
  }

  /// See also `LayoutState.buildFullScreenGeometry()`.
  static func forFullScreen(in screen: NSScreen, legacy: Bool, mode: PlayerWindowMode,
                            outsideBars: MarginQuad, insideBars: MarginQuad,
                            videoAspect: CGFloat,
                            allowVideoToOverlapCameraHousing: Bool) -> PWinGeometry {

    let windowFrame = fullScreenWindowFrame(in: screen, legacy: legacy)
    let fitOption: ScreenFitOption
    let topMarginHeight: CGFloat
    if legacy {
      topMarginHeight = allowVideoToOverlapCameraHousing ? 0 : screen.cameraHousingHeight ?? 0
      fitOption = .legacyFullScreen
    } else {
      topMarginHeight = 0
      fitOption = .nativeFullScreen
    }

    return PWinGeometry(windowFrame: windowFrame, screenID: screen.screenID, fitOption: fitOption,
                        mode: mode, topMarginHeight: topMarginHeight, outsideBars: outsideBars, insideBars: insideBars,
                        videoAspect: videoAspect)
  }

  func clone(windowFrame: NSRect? = nil, screenID: String? = nil, fitOption: ScreenFitOption? = nil,
             mode: PlayerWindowMode? = nil, topMarginHeight: CGFloat? = nil,
             outsideBars: MarginQuad? = nil, insideBars: MarginQuad? = nil,
             viewportMargins: MarginQuad? = nil,
             videoAspect: CGFloat? = nil) -> PWinGeometry {

    var windowFrame = windowFrame ?? self.windowFrame
    let fitOption = fitOption ?? self.fitOption
    if let screenID, screenID != self.screenID, fitOption.shouldMoveWindowToKeepInContainer {
      windowFrame = moveOriginToMatchScreen(screenID: screenID, fitOption: fitOption, windowFrame: windowFrame)
    }

    return PWinGeometry(windowFrame: windowFrame,
                        screenID: screenID ?? self.screenID,
                        fitOption: fitOption,
                        mode: mode ?? self.mode,
                        topMarginHeight: topMarginHeight ?? self.topMarginHeight,
                        outsideBars: outsideBars ?? self.outsideBars,
                        insideBars: insideBars ?? self.insideBars,
                        viewportMargins: viewportMargins,
                        videoAspect: videoAspect ?? self.videoAspect)
  }

  // MARK: - Computed properties

  var description: String {
    return "PWinGeometry(\(screenID.quoted) \(mode) \(fitOption) notchH=\(topMarginHeight.strMin) outBars=\(outsideBars) inBars=\(insideBars) viewportMargins=\(viewportMargins) videoSize=\(videoSize) aspect=\(videoAspect) windowFrame=\(windowFrame))"
  }

  /// Calculated from `windowFrame`.
  /// This will be equal to `videoSize`, unless IINA is configured to allow the window to expand beyond
  /// the bounds of the video for a letterbox/pillarbox effect (separate from anything mpv includes)
  var viewportSize: NSSize {
    return NSSize(width: windowFrame.width - outsideTrailingBarWidth - outsideLeadingBarWidth,
                  height: windowFrame.height - outsideTopBarHeight - outsideBottomBarHeight)
  }

  var viewportFrameInScreenCoords: NSRect {
    let origin = CGPoint(x: windowFrame.origin.x + outsideLeadingBarWidth,
                         y: windowFrame.origin.y + outsideBottomBarHeight)
    return NSRect(origin: origin, size: viewportSize)
  }

  var videoFrameInScreenCoords: NSRect {
    let videoFrameInWindowCoords = videoFrameInWindowCoords
    let origin = CGPoint(x: windowFrame.origin.x + videoFrameInWindowCoords.origin.x,
                         y: windowFrame.origin.y + videoFrameInWindowCoords.origin.y)
    return NSRect(origin: origin, size: videoSize)
  }

  var videoFrameInWindowCoords: NSRect {
    let viewportSize = viewportSize
    assert(viewportSize.width - videoSize.width >= 0)
    assert(viewportSize.height - videoSize.height >= 0)
    let leadingBlackSpace = (viewportSize.width - videoSize.width) * 0.5
    let bottomBlackSpace = (viewportSize.height - videoSize.height) * 0.5
    let origin = CGPoint(x: outsideLeadingBarWidth + leadingBlackSpace,
                         y: outsideBottomBarHeight + bottomBlackSpace)
    return NSRect(origin: origin, size: videoSize)
  }

  var outsideBarsTotalWidth: CGFloat {
    return outsideBars.totalWidth
  }

  var outsideBarsTotalHeight: CGFloat {
    return outsideBars.totalHeight
  }

  var outsideBarsTotalSize: NSSize {
    return outsideBars.totalSize
  }

  var hasTopPaddingForCameraHousing: Bool {
    return topMarginHeight > 0
  }

  // MARK: - "Minimum" calculations

  static func minViewportMargins(forMode mode: PlayerWindowMode) -> MarginQuad {
    switch mode {
    case .windowedInteractive, .fullScreenInteractive:
      return Constants.InteractiveMode.viewportMargins
    default:
      return MarginQuad.zero
    }
  }

  /// Finds minimum video size of the current geometry, assuming bars, mode, video aspect stay constant
  func minVideoSize() -> CGSize {
    return PWinGeometry.minViewportSize(mode: mode, videoAspect: videoAspect, insideBars: insideBars)
  }

  /// Finds the smallest box whose size matches the given `aspect` but with width >= `minWidth` & height >= `minHeight`.
  /// Note: `minWidth` & `minHeight` can be any positive integers. They do not need to match `aspect`.
  static func computeMinSize(withAspect aspect: CGFloat, minWidth: CGFloat, minHeight: CGFloat) -> CGSize {
    let sizeKeepingMinWidth = NSSize(width: minWidth, height: round(minWidth / aspect))
    if sizeKeepingMinWidth.height >= minHeight {
      return sizeKeepingMinWidth
    }

    let sizeKeepingMinHeight = NSSize(width: round(minHeight * aspect), height: minHeight)
    if sizeKeepingMinHeight.width >= minWidth {
      return sizeKeepingMinHeight
    }

    // Negative aspect, but just barely?
    if minWidth < minHeight {
      let width = round(minWidth * aspect)
      let sizeScalingUpWidth = NSSize(width: width, height: round(width / aspect))
      if sizeScalingUpWidth.width >= minWidth, sizeScalingUpWidth.height >= minHeight {
        return sizeScalingUpWidth
      }
    }
    let scaledUpHeight = round(minHeight * aspect)
    let sizeScalingUpHeight = NSSize(width: round(scaledUpHeight * aspect), height: scaledUpHeight)
    assert(sizeScalingUpHeight.width >= minWidth && sizeScalingUpHeight.height >= minHeight, "sizeScalingUpHeight \(sizeScalingUpHeight) < \(minWidth)x\(minHeight)")
    return sizeScalingUpHeight
  }

  // This also accounts for videoAspect, and space needed by inside sidebars, if any
  func minViewportSize(mode: PlayerWindowMode? = nil) -> NSSize {
    let mode = mode ?? self.mode
    return PWinGeometry.minViewportSize(mode: mode, videoAspect: videoAspect, insideBars: insideBars)
  }

  func minWindowWidth(mode: PlayerWindowMode? = nil) -> CGFloat {
    return minWindowSize(mode: mode).width
  }

  func minWindowHeight(mode: PlayerWindowMode? = nil) -> CGFloat {
    return minWindowSize(mode: mode).height
  }

  func minWindowSize(mode: PlayerWindowMode? = nil) -> NSSize {
    let mode = mode ?? self.mode
    return PWinGeometry.minWindowSize(mode: mode, videoAspect: videoAspect, outsideBars: outsideBars, insideBars: insideBars)
  }

  static func minViewportSize(mode: PlayerWindowMode, videoAspect: CGFloat, insideBars: MarginQuad) -> NSSize {
    var viewportMinW: CGFloat
    switch mode {
    case .windowed, .fullScreen:
      viewportMinW = Constants.WindowedMode.minViewportSize.width
      // Take sidebars into account:
      viewportMinW = max(viewportMinW, insideBars.totalWidth + Constants.Sidebar.minWidthBetweenInsideSidebars)
      return NSSize(width: viewportMinW, height: Constants.WindowedMode.minViewportSize.height)
    case .windowedInteractive, .fullScreenInteractive:
      viewportMinW = Constants.InteractiveMode.minWindowWidth
      // assume viewport aspect is same as video for now
      return NSSize(width: viewportMinW, height: Constants.WindowedMode.minViewportSize.height)
    case .musicMode:
      // note that a viewport height of zero would be ok if video was disabled in music mode
      return NSSize(width: Constants.Distance.MusicMode.minWindowWidth, height: 0)
    }
  }

  static func minWindowSize(mode: PlayerWindowMode, videoAspect: CGFloat, outsideBars: MarginQuad, insideBars: MarginQuad) -> NSSize {
    let minViewportSize = minViewportSize(mode: mode, videoAspect: videoAspect, insideBars: insideBars)

    let minWinWidth = minViewportSize.width + outsideBars.totalWidth
    let minWinHeight = minViewportSize.height + outsideBars.totalHeight
    return NSSize(width: minWinWidth, height: minWinHeight)
  }

  // MARK: - "Maximum" calculations

  fileprivate func computeMaxViewportSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    return NSSize(width: containerSize.width - outsideBarsTotalWidth,
                  height: containerSize.height - outsideBarsTotalHeight - topMarginHeight)
  }

  // Computes & returns the max video size with proper aspect ratio which can fit in the given container,
  // after subtracting outside bars
  fileprivate func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    let maxViewportSize = computeMaxViewportSize(in: containerSize)
    return PWinGeometry.computeVideoSize(withAspectRatio: videoAspect, toFillIn: maxViewportSize, mode: mode)
  }

  // MARK: - Static Functions

  static func areEqual(windowFrame1: NSRect? = nil, windowFrame2: NSRect? = nil, videoSize1: NSSize? = nil, videoSize2: NSSize? = nil) -> Bool {
    if let windowFrame1, let windowFrame2 {
      if !windowFrame1.equalTo(windowFrame2) {
        return false
      }
    }
    if let videoSize1, let videoSize2 {
      if !(videoSize1.width == videoSize2.width && videoSize1.height == videoSize2.height) {
        return false
      }
    }
    return true
  }

  /// Returns the limiting frame for the given `fitOption`, inside which the player window must fit.
  /// If no fit needed, returns `nil`.
  static func getContainerFrame(forScreenID screenID: String, fitOption: ScreenFitOption) -> NSRect? {
    let screen = NSScreen.getScreenOrDefault(screenID: screenID)

    switch fitOption {
    case .noConstraints:
      return nil
    case .stayInside, .centerInside:
      return screen.visibleFrame
    case .legacyFullScreen:
      return screen.frame
    case .nativeFullScreen:
      return screen.frameWithoutCameraHousing
    }
  }

  static func deriveViewportSize(from windowFrame: NSRect, topMarginHeight: CGFloat, outsideBars: MarginQuad) -> NSSize {
    return NSSize(width: windowFrame.width - outsideBars.trailing - outsideBars.leading,
                  height: windowFrame.height - outsideBars.top - outsideBars.bottom - topMarginHeight)
  }

  /// Snap `value` to `otherValue` if they are less than 1 px apart. If it can't snap, the number is rounded to
  /// the nearest integer.
  ///
  /// This helps smooth out division imprecision. The goal is to end up with whole numbers in calculation results
  /// without having to distort things. Fractional values will be interpreted differently by mpv, Core Graphics,
  /// AppKit, which can ultimately result in jarring visual glitches during Core animations.
  ///
  /// It is the requestor's responsibility to ensure that `otherValue` is already an integer.
  static func snap(_ value: CGFloat, to otherValue: CGFloat) -> CGFloat {
    if abs(value - otherValue) < 1 {
      return otherValue
    } else {
      let intVal = Int(round(value))
      return CGFloat(intVal.isOdd ? intVal : intVal)
    }
  }

  static func computeVideoSize(withAspectRatio videoAspect: CGFloat, toFillIn viewportSize: NSSize,
                               minViewportMargins minMargins: MarginQuad? = nil, mode: PlayerWindowMode) -> NSSize {
    if viewportSize.width == 0 || viewportSize.height == 0 {
      return NSSize.zero
    }

    let minMargins = minMargins ?? minViewportMargins(forMode: mode)
    let usableViewportSize = NSSize(width: viewportSize.width - minMargins.totalWidth,
                                    height: viewportSize.height - minMargins.totalHeight)
    let videoSize: NSSize
    /// Compute `videoSize` to fit within `viewportSize` while maintaining `videoAspect`:
    let videoWidth = snap(usableViewportSize.height * videoAspect, to: usableViewportSize.width)
    if videoWidth <= usableViewportSize.width {  // video aspect is taller than viewport: shrink its width
      videoSize = NSSize(width: videoWidth, height: usableViewportSize.height)
    } else {  // video is wider, shrink to meet width
      let videoHeight = snap(usableViewportSize.width / videoAspect, to: usableViewportSize.height)
      // Make sure to end up with whole numbers here! Decimal values can be interpreted differently by
      // mpv, Core Graphics, AppKit, which will cause animation glitches
      videoSize = NSSize(width: usableViewportSize.width, height: videoHeight)
    }

    assert((usableViewportSize.width - videoSize.width >= 0) && (usableViewportSize.height - videoSize.height >= 0),
           "videoSize \(videoSize) cannot be larger than usableViewportSize \(usableViewportSize)! (videoAspect: \(videoAspect), viewportSize: \(viewportSize), minViewportMargins: \(minMargins))")
    return videoSize
  }

  static func computeBestViewportMargins(viewportSize: NSSize, videoSize: NSSize, insideBars: MarginQuad, mode: PlayerWindowMode) -> MarginQuad {
    guard viewportSize.width > 0 && viewportSize.height > 0 else {
      return MarginQuad.zero
    }
    if mode == .musicMode {
      // Viewport size is always equal to video size in music mode
      return MarginQuad.zero
    }
    var leadingMargin: CGFloat = 0
    var trailingMargin: CGFloat = 0

    var unusedWidth = max(0, viewportSize.width - videoSize.width)
    if unusedWidth > 0 {

      if mode == .fullScreen {
        leadingMargin += (unusedWidth * 0.5)
        trailingMargin += (unusedWidth * 0.5)
      } else {
        let leadingSidebarWidth = insideBars.leading
        let trailingSidebarWidth = insideBars.trailing

        let viewportMidpointX = viewportSize.width * 0.5
        let leadingVideoIdealX = viewportMidpointX - (videoSize.width * 0.5)
        let trailingVideoIdealX = viewportMidpointX + (videoSize.width * 0.5)

        let leadingSidebarClearance = leadingVideoIdealX - leadingSidebarWidth
        let trailingSidebarClearance = viewportSize.width - trailingVideoIdealX - trailingSidebarWidth
        let freeViewportWidthTotal = viewportSize.width - videoSize.width - leadingSidebarWidth - trailingSidebarWidth

        if leadingSidebarClearance >= 0 && trailingSidebarClearance >= 0 {
          // Easy case: just center the video in the viewport:
          leadingMargin += (unusedWidth * 0.5)
          trailingMargin += (unusedWidth * 0.5)
        } else if freeViewportWidthTotal >= 0 {
          // We have enough space to realign video to fit within sidebars
          leadingMargin += leadingSidebarWidth
          trailingMargin += trailingSidebarWidth
          unusedWidth = unusedWidth - leadingSidebarWidth - trailingSidebarWidth
          let leadingSidebarDeficit = leadingSidebarClearance > 0 ? 0 : -leadingSidebarClearance
          let trailingSidebarDeficit = trailingSidebarClearance > 0 ? 0 : -trailingSidebarClearance

          if trailingSidebarDeficit > 0 {
            leadingMargin += unusedWidth
          } else if leadingSidebarDeficit > 0 {
            trailingMargin += unusedWidth
          }
        } else if leadingSidebarWidth == 0 {
          // Not enough margin to fit both sidebar and video, + only trailing sidebar visible.
          // Allocate all margin to trailing sidebar
          trailingMargin += unusedWidth
        } else if trailingSidebarWidth == 0 {
          // Not enough margin to fit both sidebar and video, + only leading sidebar visible.
          // Allocate all margin to leading sidebar
          leadingMargin += unusedWidth
        } else {
          // Not enough space for everything. Just center video between sidebars
          let leadingSidebarTrailingX = leadingSidebarWidth
          let trailingSidebarLeadingX = viewportSize.width - trailingSidebarWidth
          let midpointBetweenSidebarsX = ((trailingSidebarLeadingX - leadingSidebarTrailingX) * 0.5) + leadingSidebarTrailingX
          var leadingMarginNeededToCenter = midpointBetweenSidebarsX - (videoSize.width * 0.5)
          var trailingMarginNeededToCenter = viewportSize.width - (midpointBetweenSidebarsX + (videoSize.width * 0.5))
          // Do not allow negative margins. They would cause the video to move outside the viewport bounds
          if leadingMarginNeededToCenter < 0 {
            // Give the margin back to the other sidebar
            trailingMarginNeededToCenter -= leadingMarginNeededToCenter
            leadingMarginNeededToCenter = 0
          }
          if trailingMarginNeededToCenter < 0 {
            leadingMarginNeededToCenter -= trailingMarginNeededToCenter
            trailingMarginNeededToCenter = 0
          }
          // Allocate the scarce amount of unusedWidth proportionately to the demand:
          let allocationFactor = unusedWidth / (leadingMarginNeededToCenter + trailingMarginNeededToCenter)

          leadingMargin += leadingMarginNeededToCenter * allocationFactor
          trailingMargin += trailingMarginNeededToCenter * allocationFactor
        }
      }

      // Round to integers for a smoother animation
      leadingMargin = leadingMargin.rounded(.down)
      trailingMargin = trailingMargin.rounded(.up)
    }

    if Logger.isTraceEnabled {
      let remainingWidthForVideo = viewportSize.width - (leadingMargin + trailingMargin)
      Logger.log("[geo] Viewport: Sidebars=[lead:\(insideBars.leading), trail:\(insideBars.trailing)] leadMargin: \(leadingMargin), trailMargin: \(trailingMargin), remainingWidthForVideo: \(remainingWidthForVideo), videoWidth: \(videoSize.width)")
    }
    let unusedHeight = viewportSize.height - videoSize.height
    let computedMargins = MarginQuad(top: (unusedHeight * 0.5).rounded(.down), trailing: trailingMargin,
                                  bottom: (unusedHeight * 0.5).rounded(.up), leading: leadingMargin)
    return computedMargins
  }

  // MARK: - Instance Functions

  func hasEqual(windowFrame windowFrame2: NSRect? = nil, videoSize videoSize2: NSSize? = nil) -> Bool {
    return PWinGeometry.areEqual(windowFrame1: windowFrame, windowFrame2: windowFrame2, videoSize1: videoSize, videoSize2: videoSize2)
  }

  private func getContainerFrame(fitOption: ScreenFitOption? = nil) -> NSRect? {
    return PWinGeometry.getContainerFrame(forScreenID: screenID, fitOption: fitOption ?? self.fitOption)
  }

  /// Checks if origin of `windowFrame` does not belong to `screenID`. If it does not, adjusts its origin to move it inside that screen
  private func moveOriginToMatchScreen(screenID: String, fitOption: ScreenFitOption, windowFrame: NSRect) -> NSRect {
    guard let currentScreenID = NSScreen.getOwnerScreenID(forViewRect: windowFrame) else {
      return windowFrame
    }
    if screenID == currentScreenID {
      return windowFrame
    }
    guard let newScreenFrame = PWinGeometry.getContainerFrame(forScreenID: screenID, fitOption: fitOption) else {
      return windowFrame
    }
    guard let currentScreenFrame = PWinGeometry.getContainerFrame(forScreenID: currentScreenID, fitOption: fitOption) else {
      return windowFrame
    }

    let originOffset = NSPoint(x: newScreenFrame.origin.x - currentScreenFrame.origin.x, y: newScreenFrame.origin.y - currentScreenFrame.origin.y)
    let newOrigin = NSPoint(x: windowFrame.origin.x + originOffset.x, y: windowFrame.origin.y + originOffset.y)
    let newWindowFrame = NSRect(origin: newOrigin, size: windowFrame.size)

    Logger.log("[geo] Adjusting window origin to put inside screenID \(screenID.quoted) (was: \(currentScreenID.quoted), fitOption: \(fitOption)) → \(newWindowFrame)", level: .verbose)
    return newWindowFrame
  }

  /// Adjusts the window origin for given `newWindowSize` such that the window's center does not move.
  private func adjustWindowOrigin(forNewWindowSize newWindowSize: NSSize) -> NSPoint {
    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = ((newWindowSize.width - windowFrame.size.width) / 2).rounded(.down)
    let deltaY = ((newWindowSize.height - windowFrame.size.height) / 2).rounded(.down)
    let newOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                            y: windowFrame.origin.y - deltaY)
    return newOrigin
  }

  func refit(_ newFit: ScreenFitOption? = nil, lockViewportToVideoSize: Bool? = nil) -> PWinGeometry {
    return scaleViewport(fitOption: newFit, lockViewportToVideoSize: lockViewportToVideoSize)
  }

  /// Computes a new `PWinGeometry`, attempting to attain the given window size.
  func scaleWindow(to desiredWindowSize: NSSize? = nil,
                   screenID: String? = nil,
                   fitOption: ScreenFitOption? = nil) -> PWinGeometry {
    let requestedViewportSize: NSSize?
    if let desiredWindowSize = desiredWindowSize {
      let outsideBarsTotalSize = outsideBarsTotalSize
      requestedViewportSize = NSSize(width: desiredWindowSize.width - outsideBarsTotalSize.width,
                                     height: desiredWindowSize.height - outsideBarsTotalSize.height)
    } else {
      requestedViewportSize = nil
    }
    return scaleViewport(to: requestedViewportSize, screenID: screenID, fitOption: fitOption)
  }

  /// Computes a new `PWinGeometry` from this one:
  /// • If `desiredSize` is given, the `windowFrame` will be shrunk or grown as needed, as will the `videoSize` which will
  /// be resized to fit in the new `viewportSize` based on `videoAspect`.
  /// • If `mode` is provided, it will be applied to the resulting `PWinGeometry`.
  /// • If (1) `lockViewportToVideoSize` is specified, its value will be used (this should only be specified in rare cases).
  /// Otherwise (2) if `mode.alwaysLockViewportToVideoSize==true`, then `viewportSize` will be shrunk to the same size as `videoSize`,
  /// and `windowFrame` will be resized accordingly; otherwise, (3) `Preference.bool(for: .lockViewportToVideoSize)` will be used.
  /// • If `screenID` is provided, it will be associated with the resulting `PWinGeometry`; otherwise `self.screenID` will be used.
  /// • If `fitOption` is provided, it will be applied to the resulting `PWinGeometry`; otherwise `self.fitOption` will be used.
  func scaleViewport(to desiredSize: NSSize? = nil,
                     screenID: String? = nil,
                     fitOption: ScreenFitOption? = nil,
                     lockViewportToVideoSize: Bool? = nil,
                     mode: PlayerWindowMode? = nil) -> PWinGeometry {
    guard videoAspect >= 0 else {
      Logger.log("[geo] PWinGeometry cannot scale viewport: videoAspect (\(videoAspect)) is invalid!", level: .error)
      return self
    }

    // -- First, set up needed variables

    let mode = mode ?? self.mode
    let lockViewportToVideoSize = lockViewportToVideoSize ?? Preference.bool(for: .lockViewportToVideoSize) || mode.alwaysLockViewportToVideoSize
    // do not center in screen again unless explicitly requested
    let newFitOption = fitOption ?? (self.fitOption == .centerInside ? .stayInside : self.fitOption)
    let outsideBarsSize = self.outsideBarsTotalSize
    let newScreenID = screenID ?? self.screenID
    let containerFrame: NSRect? = PWinGeometry.getContainerFrame(forScreenID: newScreenID, fitOption: newFitOption)
    let maxViewportSize: NSSize?
    if let containerFrame {
      maxViewportSize = computeMaxViewportSize(in: containerFrame.size)
    } else {
      maxViewportSize = nil
    }
    let minViewportSize = minViewportSize(mode: mode)

    var newViewportSize = desiredSize ?? viewportSize
    if Logger.isTraceEnabled {
      Logger.log("[geo] ScaleViewport start, newViewportSize=\(newViewportSize), lockViewport=\(lockViewportToVideoSize.yn)", level: .verbose)
    }

    // -- Viewport size calculation

    if lockViewportToVideoSize {
      /// Make sure viewport size is at least as large as min.
      /// This is especially important when inside sidebars are taking up most of the space & `lockViewportToVideoSize` is `true`.
      /// Take min viewport margins into acocunt
      newViewportSize = NSSize(width: max(minViewportSize.width, newViewportSize.width),
                               height: max(minViewportSize.height, newViewportSize.height))

      if let maxViewportSize {
        /// Constrain `viewportSize` within `containerFrame`. Gotta do this BEFORE computing videoSize.
        /// So we do it again below. Big deal. Been mucking with this code way too long. It's fine.
        newViewportSize = NSSize(width: min(newViewportSize.width, maxViewportSize.width),
                                 height: min(newViewportSize.height, maxViewportSize.height))
      }

      /// Compute `videoSize` to fit within `viewportSize` (minus `viewportMargins`) while maintaining `videoAspect`:
      let newVideoSize = PWinGeometry.computeVideoSize(withAspectRatio: videoAspect, toFillIn: newViewportSize, mode: mode)
      // Add min margins back in (needed for Interactive Mode)
      let minViewportMargins = PWinGeometry.minViewportMargins(forMode: mode)
      newViewportSize = NSSize(width: newVideoSize.width + minViewportMargins.totalWidth,
                               height: newVideoSize.height + minViewportMargins.totalHeight)
    }

    // Now enforce min & max viewport size [again]:
    newViewportSize = NSSize(width: max(minViewportSize.width, newViewportSize.width),
                             height: max(minViewportSize.height, newViewportSize.height))
    if let maxViewportSize {
      newViewportSize = NSSize(width: min(newViewportSize.width, maxViewportSize.width),
                               height: min(newViewportSize.height, maxViewportSize.height))
    }

    let oldViewportSize = viewportSize
    newViewportSize = NSSize(width: PWinGeometry.snap(newViewportSize.width, to: oldViewportSize.width),
                             height: PWinGeometry.snap(newViewportSize.height, to: oldViewportSize.height))

    // -- Window size calculation

    let newWindowSize = NSSize(width: round(newViewportSize.width + outsideBarsSize.width),
                               height: round(newViewportSize.height + outsideBarsSize.height))

    let adjustedOrigin = adjustWindowOrigin(forNewWindowSize: newWindowSize)
    var newWindowFrame = NSRect(origin: adjustedOrigin, size: newWindowSize)
    if let containerFrame, newFitOption.shouldMoveWindowToKeepInContainer {
      newWindowFrame = newWindowFrame.constrain(in: containerFrame)
      if newFitOption == .centerInside {
        newWindowFrame = newWindowFrame.size.centeredRect(in: containerFrame)
      }
      if Logger.isTraceEnabled {
        Logger.log("[geo] ScaleViewport: constrainedIn=\(containerFrame) → windowFrame=\(newWindowFrame)",
                   level: .verbose)
      }
    } else if Logger.isTraceEnabled {
      Logger.log("[geo] ScaleViewport: → windowFrame=\(newWindowFrame)", level: .verbose)
    }

    return self.clone(windowFrame: newWindowFrame, screenID: newScreenID, fitOption: newFitOption, mode: mode)
  }

  func scaleVideo(to desiredVideoSize: NSSize,
                  screenID: String? = nil,
                  fitOption: ScreenFitOption? = nil,
                  lockViewportToVideoSize: Bool? = nil,
                  mode: PlayerWindowMode? = nil) -> PWinGeometry {

    let mode = mode ?? self.mode
    let lockViewportToVideoSize = lockViewportToVideoSize ?? Preference.bool(for: .lockViewportToVideoSize) || mode.alwaysLockViewportToVideoSize
    if Logger.isTraceEnabled {
      Logger.log("[geo] ScaleVideo start, desiredVideoSize: \(desiredVideoSize), videoAspect: \(videoAspect), lockViewportToVideoSize: \(lockViewportToVideoSize)", level: .debug)
    }

    // do not center in screen again unless explicitly requested
    var newFitOption = fitOption ?? (self.fitOption == .centerInside ? .stayInside : self.fitOption)
    if newFitOption == .legacyFullScreen || newFitOption == .nativeFullScreen {
      // Programmer screwed up
      Logger.log("[geo] ScaleVideo: invalid fit option: \(newFitOption). Defaulting to 'none'", level: .error)
      newFitOption = .noConstraints
    }

    var newVideoSize = desiredVideoSize

    let minVideoSize = minVideoSize()
    let newWidth = max(minVideoSize.width, desiredVideoSize.width)
    /// Enforce `videoView` aspectRatio: Recalculate height using width
    newVideoSize = NSSize(width: newWidth, height: round(newWidth / videoAspect))

    let containerFrame: NSRect? = PWinGeometry.getContainerFrame(forScreenID: screenID ?? self.screenID, fitOption: newFitOption)
    if let containerFrame {
      // Scale down to fit in bounds of container
      if newVideoSize.width > containerFrame.width {
        newVideoSize = NSSize(width: containerFrame.width, height: round(containerFrame.width / videoAspect))
      }

      if newVideoSize.height > containerFrame.height {
        newVideoSize = NSSize(width: round(containerFrame.height * videoAspect), height: containerFrame.height)
      }
    }

    let minViewportMargins = PWinGeometry.minViewportMargins(forMode: mode)
    let newViewportSize: NSSize
    if lockViewportToVideoSize {
      /// Use `videoSize` for `desiredViewportSize`:
      newViewportSize = NSSize(width: newVideoSize.width + minViewportMargins.totalWidth,
                               height: newVideoSize.height + minViewportMargins.totalHeight)
    } else {
      // Scale existing viewport
      let scaleRatio = newVideoSize.width / videoSize.width
      let viewportSizeWithoutMinMargins = NSSize(width: viewportSize.width - minViewportMargins.totalWidth,
                                                 height: viewportSize.height - minViewportMargins.totalHeight)
      let scaledViewportWithoutMargins = viewportSizeWithoutMinMargins.multiply(scaleRatio)
      newViewportSize = NSSize(width: scaledViewportWithoutMargins.width + minViewportMargins.totalWidth,
                               height: scaledViewportWithoutMargins.height + minViewportMargins.totalHeight)
    }

    return scaleViewport(to: newViewportSize, screenID: screenID, fitOption: fitOption, mode: mode)
  }

  // Resizes the window appropriately to add or subtract from outside bars. Adjusts window origin to prevent the viewport from moving
  // (but clamps each dimension's size to the container/screen, if any).
  func withResizedOutsideBars(newOutsideTopBarHeight: CGFloat? = nil, newOutsideTrailingBarWidth: CGFloat? = nil,
                              newOutsideBottomBarHeight: CGFloat? = nil, newOutsideLeadingBarWidth: CGFloat? = nil) -> PWinGeometry {
    assert((newOutsideTopBarHeight ?? 0) >= 0)
    assert((newOutsideTrailingBarWidth ?? 0) >= 0)
    assert((newOutsideBottomBarHeight ?? 0) >= 0)
    assert((newOutsideLeadingBarWidth ?? 0) >= 0)

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newOutsideTopBarHeight {
      let ΔTop = newOutsideTopBarHeight - self.outsideTopBarHeight
      ΔH += ΔTop
    }
    if let newOutsideTrailingBarWidth {
      let ΔRight = newOutsideTrailingBarWidth - self.outsideTrailingBarWidth
      ΔW += ΔRight
    }
    if let newOutsideBottomBarHeight {
      let ΔBottom = newOutsideBottomBarHeight - self.outsideBottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newOutsideLeadingBarWidth {
      let ΔLeft = newOutsideLeadingBarWidth - self.outsideLeadingBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }

    var newX = windowFrame.origin.x + ΔX
    var newY = windowFrame.origin.y + ΔY
    var newWindowWidth = windowFrame.width + ΔW
    var newWindowHeight = windowFrame.height + ΔH

    // Special logic if output has reached out the size of the screen.
    // Do not allow it to get bigger than the screen.
    if let screenFrame = PWinGeometry.getContainerFrame(forScreenID: screenID, fitOption: fitOption) {
      if newWindowWidth > screenFrame.width {
        newWindowWidth = screenFrame.width
        newX = windowFrame.origin.x  // don't move in X
      }

      if newWindowHeight > screenFrame.height {
        newWindowHeight = screenFrame.height
        newY = windowFrame.origin.y
      }
    }

    let newWindowFrame = CGRect(x: newX, y: newY, width: newWindowWidth, height: newWindowHeight)
    let newScreenID = NSScreen.getOwnerOrDefaultScreenID(forViewRect: newWindowFrame)
    let newOutsideBars = MarginQuad(top: newOutsideTopBarHeight ?? outsideBars.top,
                                    trailing: newOutsideTrailingBarWidth ?? outsideBars.trailing,
                                    bottom: newOutsideBottomBarHeight ?? outsideBars.bottom,
                                    leading: newOutsideLeadingBarWidth ?? outsideBars.leading)
    return self.clone(windowFrame: newWindowFrame, screenID: newScreenID, outsideBars: newOutsideBars)
  }

  /// Like `withResizedOutsideBars`, but can resize the inside bars at the same time.
  /// If `keepFullScreenDimensions` is `true` and the window's width or height,independently, is at max, that dimension will stay at max.
  /// This way the window will seem to "stick" to the screen edges when already maximized.
  /// But if the window is already smaller, the window will be allowed to shrink or grow normally.
  /// This should be more intuitive to the user which is expecting "near" full screen behavior when maximized.
  func withResizedBars(fitOption: ScreenFitOption? = nil, mode: PlayerWindowMode? = nil,
                       outsideTopBarHeight: CGFloat? = nil, outsideTrailingBarWidth: CGFloat? = nil,
                       outsideBottomBarHeight: CGFloat? = nil, outsideLeadingBarWidth: CGFloat? = nil,
                       insideTopBarHeight: CGFloat? = nil, insideTrailingBarWidth: CGFloat? = nil,
                       insideBottomBarHeight: CGFloat? = nil, insideLeadingBarWidth: CGFloat? = nil,
                       videoAspect: CGFloat? = nil,
                       keepFullScreenDimensions: Bool = false) -> PWinGeometry {

    let newInsideBars = MarginQuad(top: insideTopBarHeight ?? insideBars.top,
                                    trailing: insideTrailingBarWidth ?? insideBars.trailing,
                                    bottom: insideBottomBarHeight ?? insideBars.bottom,
                                    leading: insideLeadingBarWidth ?? insideBars.leading)
    // Inside bars
    let resizedInsideBarsGeo = clone(fitOption: fitOption, mode: mode, insideBars: newInsideBars, videoAspect: videoAspect)

    var resizedBarsGeo = resizedInsideBarsGeo.withResizedOutsideBars(newOutsideTopBarHeight: outsideTopBarHeight,
                                                                     newOutsideTrailingBarWidth: outsideTrailingBarWidth,
                                                                     newOutsideBottomBarHeight: outsideBottomBarHeight,
                                                                     newOutsideLeadingBarWidth: outsideLeadingBarWidth)

    if keepFullScreenDimensions {
      resizedBarsGeo = preserveFullScreenDimensions(of: resizedBarsGeo)
    }
    return resizedBarsGeo
  }

  private func preserveFullScreenDimensions(of geo: PWinGeometry) -> PWinGeometry {
    guard let screenFrame = PWinGeometry.getContainerFrame(forScreenID: screenID, fitOption: geo.fitOption) else { return geo }
    let isFullScreenWidth = windowFrame.width == screenFrame.width
    let isFullScreenHeight = windowFrame.height == screenFrame.height

    let ΔOutsideWidth = geo.outsideBarsTotalWidth - outsideBarsTotalWidth
    let ΔOutsideHeight = geo.outsideBarsTotalHeight - outsideBarsTotalHeight

    Logger.log("[ResizeBars] ΔW:\(ΔOutsideWidth.strMin) fsW:\(isFullScreenWidth.yn) ΔH:\(ΔOutsideHeight.strMin) fsH:\(isFullScreenHeight.yn) keepInScreen:\(geo.fitOption.shouldMoveWindowToKeepInContainer.yesno)")

    let resizedViewport: NSSize
    // If window already fills screen width, do not shrink window width when collapsing outside sidebars.
    if ΔOutsideWidth != 0, isFullScreenWidth {
      let newViewportWidth = screenFrame.width - geo.outsideBarsTotalWidth
      let widthRatio = newViewportWidth / viewportSize.width
      let newViewportHeight = isFullScreenHeight ? viewportSize.height : round(viewportSize.height * widthRatio)
      resizedViewport = NSSize(width: newViewportWidth, height: newViewportHeight)
    } else if ΔOutsideHeight != 0, isFullScreenHeight {
      // If window already fills screen height, keep window height (do not shrink window) when collapsing outside bars.
      let newViewportHeight = screenFrame.height - geo.outsideBarsTotalHeight
      let heightRatio = newViewportHeight / viewportSize.height
      let newViewportWidth = isFullScreenWidth ? viewportSize.width : round(viewportSize.width * heightRatio)
      resizedViewport = NSSize(width: newViewportWidth, height: newViewportHeight)
    } else {
      return geo
    }

    var resizedGeo = geo.scaleViewport(to: resizedViewport, mode: geo.mode)

    if !resizedGeo.fitOption.shouldMoveWindowToKeepInContainer {
      /// Kludge to fix unwanted window movement when opening/closing sidebars and `Preference.moveWindowIntoVisibleScreenOnResize==false`.
      // Use previous origin, because scaleViewport() causes it to move when we don't want it to.
      let newOrigin = CGPoint(x: isFullScreenWidth ? windowFrame.origin.x : resizedGeo.windowFrame.origin.x,
                              y: isFullScreenHeight ? windowFrame.origin.y : resizedGeo.windowFrame.origin.y)
      let newWindowFrame = NSRect(origin: newOrigin, size: resizedGeo.windowFrame.size)
      resizedGeo = resizedGeo.clone(windowFrame: newWindowFrame)
    }
    /// Else window origin was already changed by `scaleViewport` to keep it on screen. No change needed
    return resizedGeo
  }

  /// Calculate the window frame from a parsed struct of mpv's `geometry` option.
  func apply(mpvGeometry: MPVGeometryDef, desiredWindowSize: NSSize) -> PWinGeometry {
    guard let screenFrame: NSRect = getContainerFrame() else {
      Logger.log("Cannot apply mpv geometry: no container frame found (fitOption: \(fitOption))", level: .error)
      return self
    }
    let maxWindowSize = screenFrame.size
    let minWindowSize = minWindowSize(mode: .windowed)

    var newWindowSize = desiredWindowSize
    var isWidthSet = false
    var isHeightSet = false
    var isXSet = false
    var isYSet = false

    if let strw = mpvGeometry.w, let wInt = Int(strw), wInt > 0 {
      var w = CGFloat(wInt)
      if mpvGeometry.wIsPercentage {
        w = w * 0.01 * Double(maxWindowSize.width)
      }
      newWindowSize.width = max(minWindowSize.width, w)
      isWidthSet = true
    }

    if let strh = mpvGeometry.h, let hInt = Int(strh), hInt > 0 {
      var h = CGFloat(hInt)
      if mpvGeometry.hIsPercentage {
        h = h * 0.01 * Double(maxWindowSize.height)
      }
      newWindowSize.height = max(minWindowSize.height, h)
      isHeightSet = true
    }

    // 1. If both width & height are set, video will scale to fit inside it, but there may be empty margins.
    // 2. If only width or height is set, but not both: derive the other from the aspect ratio.
    // 3. Otherwise default to desiredVideoSize.
    if isWidthSet && !isHeightSet {
      // Calculate height based on width and aspect
      let newViewportWidth = newWindowSize.width - outsideBarsTotalWidth
      let newViewportHeight = round(newViewportWidth / videoAspect)
      newWindowSize.height = newViewportHeight + (outsideBarsTotalHeight + topMarginHeight)

      var mustRecomputeWidth = false
      if newWindowSize.height > maxWindowSize.height {
        // Shrink if exceeded max height
        newWindowSize.height = maxWindowSize.height
        mustRecomputeWidth = true
      } else if newWindowSize.height < minWindowSize.height {
        newWindowSize.height = minWindowSize.height
        mustRecomputeWidth = true
      }
      if mustRecomputeWidth {
        // Recalculate width based on height and aspect
        let newViewportHeight = newWindowSize.height - (outsideBarsTotalHeight + topMarginHeight)
        let newViewportWidth = round(newViewportHeight * videoAspect)
        newWindowSize.width = newViewportWidth + outsideBarsTotalWidth
      }
    } else if !isWidthSet && isHeightSet {
      // Calculate width based on height and aspect
      let newViewportHeight = newWindowSize.height - (outsideBarsTotalHeight + topMarginHeight)
      let newViewportWidth = round(newViewportHeight * videoAspect)
      newWindowSize.width = newViewportWidth + outsideBarsTotalWidth

      var mustRecomputeHeight = false
      if newWindowSize.width > maxWindowSize.width {
        // Shrink if exceeded max width
        newWindowSize.width = maxWindowSize.width
        mustRecomputeHeight = true
      } else if newWindowSize.width < minWindowSize.width {
        newWindowSize.width = minWindowSize.width
        mustRecomputeHeight = true
      }
      if mustRecomputeHeight {
        // Recalculate height based on width and aspect
        let newViewportWidth = newWindowSize.width - outsideBarsTotalWidth
        let newViewportHeight = round(newViewportWidth / videoAspect)
        newWindowSize.height = newViewportHeight + (outsideBarsTotalHeight + topMarginHeight)
      }
    }

    var newOrigin = screenFrame.origin
    // x
    if let strx = mpvGeometry.x, let xInt = Int(strx), let xSign = mpvGeometry.xSign {
      let unusedScreenWidth = max(0, screenFrame.width - newWindowSize.width)
      var xOffset = CGFloat(xInt)
      if mpvGeometry.xIsPercentage {
        xOffset = xOffset * 0.01 * Double(screenFrame.width)
      }
      // Reduce/eliminate offset if not enough space on screen
      xOffset = min(unusedScreenWidth, xOffset)
      // If xSign == "-", interpret as offset of right side of window from right side of screen
      if xSign == "-" {  // Offset from RIGHT
        newOrigin.x += (screenFrame.width - newWindowSize.width)
        newOrigin.x -= xOffset
      } else {  // Offset from LEFT
        newOrigin.x += xOffset
      }
      isXSet = true
    }

    // y
    if let stry = mpvGeometry.y, let yInt = Int(stry), let ySign = mpvGeometry.ySign {
      let unusedScreenHeight = max(0, screenFrame.height - newWindowSize.height)
      var yOffset = CGFloat(yInt)
      if mpvGeometry.yIsPercentage {
        yOffset = yOffset * 0.01 * Double(screenFrame.height)
      }
      // Reduce/eliminate offset if not enough space on screen
      yOffset = min(unusedScreenHeight, yOffset)

      if ySign == "-" {  // Offset from BOTTOM
        newOrigin.y += yOffset
      } else {  // Offset from TOP
        newOrigin.y += (screenFrame.height - newWindowSize.height)
        newOrigin.y -= yOffset
      }
      isYSet = true
    }

    // If X or Y are not set, just adjust the previous values according to the change in window width or height, respectively
    let adjustedOrigin = adjustWindowOrigin(forNewWindowSize: newWindowSize)
    if !isXSet {
      newOrigin.x = adjustedOrigin.x
    }
    if !isYSet {
      newOrigin.y = adjustedOrigin.y
    }

    let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
    Logger.log("Calculated windowFrame from mpv geometry: \(newWindowFrame)", level: .debug)
    return self.clone(windowFrame: newWindowFrame)
  }

  // MARK: Interactive mode

  static func buildInteractiveModeWindow(windowFrame: NSRect, screenID: String, videoAspect: CGFloat) -> PWinGeometry {
    let outsideBars = MarginQuad(top: Constants.InteractiveMode.outsideTopBarHeight, trailing: 0,
                                 bottom: Constants.InteractiveMode.outsideBottomBarHeight, leading: 0)
    return PWinGeometry(windowFrame: windowFrame, screenID: screenID, fitOption: .stayInside,
                        mode: .windowedInteractive, topMarginHeight: 0,
                        outsideBars: outsideBars,
                        insideBars: MarginQuad.zero,
                        videoAspect: videoAspect)
  }

  // Transition windowed mode geometry to Interactive Mode geometry. Note that this is not a direct conversion; it will modify the view sizes
  func toInteractiveMode() -> PWinGeometry {
    assert(fitOption != .legacyFullScreen && fitOption != .nativeFullScreen)
    assert(mode == .windowed)
    // TODO: preserve window size better when lockViewportToVideoSize==false
    let lockViewportToVideoSize = Preference.bool(for: .lockViewportToVideoSize)
    /// Close the sidebars. Top and bottom bars are resized for interactive mode controls.
    let resizedGeo = withResizedBars(mode: .windowedInteractive,
                                     outsideTopBarHeight: Constants.InteractiveMode.outsideTopBarHeight,
                                     outsideTrailingBarWidth: 0,
                                     outsideBottomBarHeight: Constants.InteractiveMode.outsideBottomBarHeight,
                                     outsideLeadingBarWidth: 0,
                                     insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                     insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                                     keepFullScreenDimensions: !lockViewportToVideoSize)
    return resizedGeo.refit()
  }

  /// Transition `windowedInteractive` mode geometry to `windowed` geometry.
  /// Note that this is not a direct conversion; it will modify the view sizes.
  func fromWindowedInteractiveMode() -> PWinGeometry {
    assert(fitOption != .legacyFullScreen && fitOption != .nativeFullScreen)
    assert(mode == .windowedInteractive)
    /// Close the sidebars. Top and bottom bars are resized for interactive mode controls.
    let resizedGeo = withResizedBars(mode: .windowed,
                                     outsideTopBarHeight: 0, outsideTrailingBarWidth: 0,
                                     outsideBottomBarHeight: 0, outsideLeadingBarWidth: 0,
                                     insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                     insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                                     keepFullScreenDimensions: true)
    return resizedGeo
  }

  // Mark: Crop

  /// Here, `videoSizeUnscaled` and `cropBox` must be the same scale, which may be different than `self.videoSize`.
  /// The cropBox is the section of the video rect which remains after the crop. Its origin is the lower left of the video.
  /// This func assumes that the currently displayed video (`videoSize`) is uncropped. Returns a new geometry which expanding the margins
  /// while collapsing the viewable video down to the cropped portion. The window size does not change.
  func cropVideo(from videoSizeOrig: NSSize, to cropBox: NSRect) -> PWinGeometry {
    // First scale the cropBox to the current window scale
    let scaleRatio = videoSize.width / videoSizeOrig.width
    let cropBoxInWinCoords = NSRect(x: round(cropBox.origin.x * scaleRatio),
                               y: round(cropBox.origin.y * scaleRatio),
                               width: round(cropBox.width * scaleRatio),
                               height: round(cropBox.height * scaleRatio))

    if cropBoxInWinCoords.origin.x > videoSize.width || cropBoxInWinCoords.origin.y > videoSize.height {
      Logger.log("[geo] Cannot crop video: the cropBox is completely outside the video! CropBoxInWinCoords: \(cropBoxInWinCoords), videoSize: \(videoSize)", level: .error)
      return self
    }

    // Collapse the viewable video without changing the window size. Do this by expanding the margins
    let bottomHeightOutsideCropBox = round(cropBoxInWinCoords.origin.y)
    let topHeightOutsideCropBox = max(0, videoSize.height - cropBoxInWinCoords.height - bottomHeightOutsideCropBox)    // cannot be < 0
    let leadingWidthOutsideCropBox = round(cropBoxInWinCoords.origin.x)
    let trailingWidthOutsideCropBox = max(0, videoSize.width - cropBoxInWinCoords.width - leadingWidthOutsideCropBox)  // cannot be < 0
    let newViewportMargins = MarginQuad(top: viewportMargins.top + topHeightOutsideCropBox,
                                        trailing: viewportMargins.trailing + trailingWidthOutsideCropBox,
                                        bottom: viewportMargins.bottom + bottomHeightOutsideCropBox,
                                        leading: viewportMargins.leading + leadingWidthOutsideCropBox)

    Logger.log("[geo] Cropping from cropBox \(cropBox) x windowScale (\(scaleRatio)) → newVideoSize:\(cropBoxInWinCoords), newViewportMargins:\(newViewportMargins)")

    let newVideoAspect = cropBox.size.mpvAspect

    let newFitOption = self.fitOption == .centerInside ? .stayInside : self.fitOption
    Logger.log("[geo] Cropped to new videoAspect: \(newVideoAspect), screenID: \(screenID), fitOption: \(newFitOption)")
    return self.clone(fitOption: newFitOption, viewportMargins: newViewportMargins, videoAspect: newVideoAspect)
  }
}
