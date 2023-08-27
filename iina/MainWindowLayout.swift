//
//  MainWindowLayout.swift
//  iina
//
//  Created by Matt Svoboda on 8/20/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// Size of a side the 3 square playback button icons (Play/Pause, LeftArrow, RightArrow):
fileprivate var oscBarPlaybackIconSize: CGFloat {
  CGFloat(Preference.integer(for: .oscBarPlaybackIconSize)).clamped(to: 8...OSCToolbarButton.oscBarHeight)
}
/// Scale of spacing to the left & right of each playback button (for top/bottom OSC):
fileprivate var oscBarPlaybackIconSpacing: CGFloat {
  max(0, CGFloat(Preference.integer(for: .oscBarPlaybackIconSpacing)))
}

fileprivate let oscFloatingPlayBtnsSize: CGFloat = 24
fileprivate let oscFloatingPlayBtnsHPad: CGFloat = 8
fileprivate let oscFloatingToolbarButtonIconSize: CGFloat = 14
fileprivate let oscFloatingToolbarButtonIconPadding: CGFloat = 5

// TODO: reimplement OSC title bar feature
fileprivate let oscTitleBarPlayBtnsSize: CGFloat = 18
fileprivate let oscTitleBarPlayBtnsHPad: CGFloat = 6
fileprivate let oscTitleBarToolbarButtonIconSize: CGFloat = 14
fileprivate let oscTitleBarToolbarButtonIconPadding: CGFloat = 5

fileprivate extension NSStackView.VisibilityPriority {
  static let detachEarly = NSStackView.VisibilityPriority(rawValue: 850)
  static let detachEarlier = NSStackView.VisibilityPriority(rawValue: 800)
  static let detachEarliest = NSStackView.VisibilityPriority(rawValue: 750)
}

extension MainWindowController {

  /// `struct LayoutSpec`: data structure which is the blueprint for building a `LayoutPlan`
  struct LayoutSpec {
    let leadingSidebar: Sidebar
    let trailingSidebar: Sidebar

    let isFullScreen:  Bool
    let isLegacyMode: Bool

    let topBarPlacement: Preference.PanelPlacement
    let bottomBarPlacement: Preference.PanelPlacement
    var leadingSidebarPlacement: Preference.PanelPlacement { return leadingSidebar.placement }
    var trailingSidebarPlacement: Preference.PanelPlacement { return trailingSidebar.placement }

    let enableOSC: Bool
    let oscPosition: Preference.OSCPosition

    /// Factory method. Matches what is shown in the XIB
    static func initial() -> LayoutSpec {
      let leadingSidebar = Sidebar(.leadingSidebar, tabGroups: Sidebar.TabGroup.fromPrefs(for: .leadingSidebar),
                                   placement: Preference.enum(for: .leadingSidebarPlacement),
                                   visibility: .hide)
      let trailingSidebar = Sidebar(.trailingSidebar, tabGroups: Sidebar.TabGroup.fromPrefs(for: .trailingSidebar),
                                    placement: Preference.enum(for: .trailingSidebarPlacement),
                                    visibility: .hide)
      return LayoutSpec(leadingSidebar: leadingSidebar,
                        trailingSidebar: trailingSidebar,
                        isFullScreen: false,
                        isLegacyMode: false,
                        topBarPlacement:.insideVideo,
                        bottomBarPlacement: .insideVideo,
                        enableOSC: false,
                        oscPosition: .floating)
    }

    /// Factory method. Init from preferences (and fill in remainder from given `LayoutSpec`)
    static func fromPreferences(andSpec prevSpec: LayoutSpec) -> LayoutSpec {
      // If in fullscreen, top & bottom bars are always .insideVideo

      let leadingSidebar = prevSpec.leadingSidebar.clone(tabGroups: Sidebar.TabGroup.fromPrefs(for: .leadingSidebar),
                                                         placement: Preference.enum(for: .leadingSidebarPlacement))
      let trailingSidebar = prevSpec.trailingSidebar.clone(tabGroups: Sidebar.TabGroup.fromPrefs(for: .trailingSidebar),
                                                           placement: Preference.enum(for: .trailingSidebarPlacement))
      return LayoutSpec(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar,
                        isFullScreen: prevSpec.isFullScreen,
                        isLegacyMode: prevSpec.isFullScreen ? prevSpec.isLegacyMode : Preference.bool(for: .useLegacyWindowedMode),
                        topBarPlacement: Preference.enum(for: .topBarPlacement),
                        bottomBarPlacement: Preference.enum(for: .bottomBarPlacement),
                        enableOSC: Preference.bool(for: .enableOSC),
                        oscPosition: Preference.enum(for: .oscPosition))
    }

    // Specify any properties to override; if nil, will use self's property values.
    func clone(leadingSidebar: Sidebar? = nil,
               trailingSidebar: Sidebar? = nil,
               isFullScreen: Bool? = nil,
               topBarPlacement: Preference.PanelPlacement? = nil,
               bottomBarPlacement: Preference.PanelPlacement? = nil,
               enableOSC: Bool? = nil,
               oscPosition: Preference.OSCPosition? = nil,
               isLegacyMode: Bool? = nil) -> LayoutSpec {
      return LayoutSpec(leadingSidebar: leadingSidebar ?? self.leadingSidebar,
                        trailingSidebar: trailingSidebar ?? self.trailingSidebar,
                        isFullScreen: isFullScreen ?? self.isFullScreen,
                        isLegacyMode: isLegacyMode ?? self.isLegacyMode,
                        topBarPlacement: topBarPlacement ?? self.topBarPlacement,
                        bottomBarPlacement: bottomBarPlacement ?? self.bottomBarPlacement,
                        enableOSC: enableOSC ?? self.enableOSC,
                        oscPosition: self.oscPosition)
    }
  }

  /// `LayoutPlan`: data structure which contains all the variables which describe a single way to layout the `MainWindow`.
  /// ("Layout" might have been a better name for this class, but it's already used by AppKit). Notes:
  /// • With all the different window layout configurations which are now possible, it's crucial to use this class in order for animations
  ///   to work reliably.
  /// • It should be treated like a read-only object after it's built. Its member variables are only mutable to make it easier to build.
  /// • When any member variable inside it needs to be changed, a new `LayoutPlan` object should be constructed to describe the new state,
  ///   and a `LayoutTransition` should be built to describe the animations needs to go from old to new.
  /// • The new `LayoutPlan`, once active, should be stored in the `currentLayout` of `MainWindowController` for future reference.
  class LayoutPlan {
    // All other variables in this class are derived from this spec:
    let spec: LayoutSpec

    // Visiblity of views/categories:

    var titleIconAndText: Visibility = .hidden
    var trafficLightButtons: Visibility = .hidden
    var titlebarAccessoryViewControllers: Visibility = .hidden
    var leadingSidebarToggleButton: Visibility = .hidden
    var trailingSidebarToggleButton: Visibility = .hidden
    var pinToTopButton: Visibility = .hidden

    var controlBarFloating: Visibility = .hidden

    var bottomBarView: Visibility = .hidden
    var topBarView: Visibility = .hidden

    // Geometry:

    var cameraHousingOffset: CGFloat = 0
    var titleBarHeight: CGFloat = 0
    var topOSCHeight: CGFloat = 0

    /// Bar widths/heights:

    var topBarHeight: CGFloat {
      self.titleBarHeight + self.topOSCHeight
    }
    /// NOTE: Is mutable!
    var trailingBarWidth: CGFloat {
      return spec.trailingSidebar.currentWidth
    }
    var bottomBarHeight: CGFloat = 0

    /// NOTE: Is mutable!
    var leadingBarWidth: CGFloat {
      return spec.leadingSidebar.currentWidth
    }

    /// Bar widths/heights IF `outsideVideo`:

    var topBarOutsideHeight: CGFloat {
      return topBarPlacement == .outsideVideo ? topBarHeight : 0
    }

    /// NOTE: Is mutable!
    var trailingBarOutsideWidth: CGFloat {
      return trailingSidebarPlacement == .outsideVideo ? trailingBarWidth : 0
    }

    var bottomBarOutsideHeight: CGFloat {
      return bottomBarPlacement == .outsideVideo ? bottomBarHeight : 0
    }

    /// NOTE: Is mutable!
    var leadingBarOutsideWidth: CGFloat {
      return leadingSidebarPlacement == .outsideVideo ? leadingBarWidth : 0
    }

    /// This exists as a fallback for the case where the title bar has a transparent background but still shows its items.
    /// For most cases, spacing between OSD and top of `videoContainerView` >= 8pts
    var osdMinOffsetFromTop: CGFloat = 8

    var setupControlBarInternalViews: TaskFunc? = nil

    init(spec: LayoutSpec) {
      self.spec = spec
    }

    // Derived attributes & convenience accesstors

    var isFullScreen: Bool {
      return spec.isFullScreen
    }

    var isLegacyFullScreen: Bool {
      return spec.isFullScreen && spec.isLegacyMode
    }

    var enableOSC: Bool {
      return spec.enableOSC
    }

    var oscPosition: Preference.OSCPosition {
      return spec.oscPosition
    }

    var topBarPlacement: Preference.PanelPlacement {
      return spec.topBarPlacement
    }

    var bottomBarPlacement: Preference.PanelPlacement {
      return spec.bottomBarPlacement
    }

    var leadingSidebarPlacement: Preference.PanelPlacement {
      return spec.leadingSidebarPlacement
    }

    var trailingSidebarPlacement: Preference.PanelPlacement {
      return spec.trailingSidebarPlacement
    }

    var leadingSidebar: Sidebar {
      return spec.leadingSidebar
    }

    var trailingSidebar: Sidebar {
      return spec.trailingSidebar
    }

    var hasFloatingOSC: Bool {
      return enableOSC && oscPosition == .floating
    }

    var hasTopOSC: Bool {
      return enableOSC && oscPosition == .top
    }

    var hasPermanentOSC: Bool {
      return enableOSC && ((oscPosition == .top && topBarPlacement == .outsideVideo) ||
                           (oscPosition == .bottom && bottomBarPlacement == .outsideVideo))
    }

    func sidebar(withID id: Preference.SidebarLocation) -> Sidebar {
      switch id {
      case .leadingSidebar:
        return leadingSidebar
      case .trailingSidebar:
        return trailingSidebar
      }
    }

    func computePinToTopButtonVisibility(isOnTop: Bool) -> Visibility {
      let showOnTopStatus = Preference.bool(for: .alwaysShowOnTopIcon) || isOnTop
      if isFullScreen || !showOnTopStatus {
        return .hidden
      }

      if topBarPlacement == .insideVideo {
        return .showFadeableNonTopBar
      }

      return .showAlways
    }
  }  // end class LayoutPlan

  // MARK: - Visibility States

  enum Visibility {
    case hidden
    case showAlways
    case showFadeableTopBar  // fade in as part of the top bar
    case showFadeableNonTopBar          // fade in as a fadeable view which is not top bar

    var isShowable: Bool {
      return self != .hidden
    }
  }

  private func apply(visibility: Visibility, to view: NSView) {
    switch visibility {
    case .hidden:
      view.alphaValue = 0
      view.isHidden = true
      fadeableViews.remove(view)
      fadeableViewsTopBar.remove(view)
    case .showAlways:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.remove(view)
      fadeableViewsTopBar.remove(view)
    case .showFadeableTopBar:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViewsTopBar.insert(view)
    case .showFadeableNonTopBar:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.insert(view)
    }
  }

  private func apply(visibility: Visibility, _ views: NSView?...) {
    for view in views {
      if let view = view {
        apply(visibility: visibility, to: view)
      }
    }
  }

  private func applyHiddenOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility == .hidden else { return }
    apply(visibility: visibility, view)
  }

  private func applyShowableOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility != .hidden else { return }
    apply(visibility: visibility, view)
  }

  // MARK: - Layout Transitions

  class LayoutTransition {
    let fromLayout: LayoutPlan
    let toLayout: LayoutPlan
    let isInitialLayout: Bool
    var windowGeometry: MainWindowGeometry? = nil

    var animationTasks: [UIAnimation.Task] = []

    init(from fromLayout: LayoutPlan, to toLayout: LayoutPlan, isInitialLayout: Bool = false) {
      self.fromLayout = fromLayout
      self.toLayout = toLayout
      self.isInitialLayout = isInitialLayout
    }

    var isTogglingTitledWindowStyle: Bool {
      return fromLayout.spec.isLegacyMode != toLayout.spec.isLegacyMode
    }

    var isTogglingFullScreen: Bool {
      return fromLayout.isFullScreen != toLayout.isFullScreen
    }

    var isTogglingToFullScreen: Bool {
      return !fromLayout.isFullScreen && toLayout.isFullScreen
    }

    var isTogglingFromFullScreen: Bool {
      return fromLayout.isFullScreen && !toLayout.isFullScreen
    }

    var isTopBarPlacementChanging: Bool {
      return fromLayout.topBarPlacement != toLayout.topBarPlacement
    }

    var isBottomBarPlacementChanging: Bool {
      return fromLayout.bottomBarPlacement != toLayout.bottomBarPlacement
    }

    var isLeadingSidebarPlacementChanging: Bool {
      return fromLayout.leadingSidebarPlacement != toLayout.leadingSidebarPlacement
    }

    var isTrailingSidebarPlacementChanging: Bool {
      return fromLayout.trailingSidebarPlacement != toLayout.trailingSidebarPlacement
    }

    lazy var mustOpenLeadingSidebar: Bool = {
      return mustOpen(.leadingSidebar)
    }()

    lazy var mustOpenTrailingSidebar: Bool = {
      return mustOpen(.trailingSidebar)
    }()

    lazy var mustCloseLeadingSidebar: Bool = {
      return mustClose(.leadingSidebar)
    }()

    lazy var mustCloseTrailingSidebar: Bool = {
      return mustClose(.trailingSidebar)
    }()

    lazy var isOpeningOrClosingAnySidebar: Bool = {
      return mustOpenLeadingSidebar || mustOpenTrailingSidebar || mustCloseLeadingSidebar || mustCloseTrailingSidebar
    }()

    func mustOpen(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if !oldState.isVisible && newState.isVisible {
        return true
      }
      return mustCloseAndReopen(sidebarID)
    }

    func mustClose(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if oldState.isVisible {
        if !newState.isVisible {
          return true
        }
        if let oldVisibleTabGroup = oldState.visibleTabGroup, let newVisibleTabGroup = newState.visibleTabGroup,
           oldVisibleTabGroup != newVisibleTabGroup {
          return true
        }
        if let visibleTabGroup = oldState.visibleTabGroup, !newState.tabGroups.contains(visibleTabGroup) {
          Logger.log("mustClose(sidebarID:): visibleTabGroup \(visibleTabGroup.rawValue.quoted) is not present in newState!", level: .error)
          return true
        }
      }
      return mustCloseAndReopen(sidebarID)
    }

    func mustCloseAndReopen(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if oldState.isVisible && newState.isVisible {
        if oldState.placement != newState.placement {
          return true
        }
        guard let oldGroup = oldState.visibleTabGroup, let newGroup = newState.visibleTabGroup else {
          Logger.log("needToCloseAndReopen(sidebarID:): visibleTabGroup missing!", level: .error)
          return false
        }
        if oldGroup != newGroup {
          return true
        }
      }
      return false
    }
  }

  func setWindowLayoutFromPrefs() {
    log.verbose("Transitioning to initial layout from prefs")
    let initialLayoutSpec = LayoutSpec.fromPreferences(andSpec: currentLayout.spec)
    let initialLayout = buildFutureLayoutPlan(from: initialLayoutSpec)

    let transition = LayoutTransition(from: currentLayout, to: initialLayout, isInitialLayout: true)
    // For initial layout (when window is first shown), to reduce jitteriness when drawing,
    // do all the layout in a single animation block

    UIAnimation.disableAnimation{
      controlBarFloating.isDragging = false
      currentLayout = initialLayout
      fadeOutOldViews(transition)
      closeOldPanels(transition)
      updateHiddenViewsAndConstraints(transition)
      openNewPanels(transition)
      fadeInNewViews(transition)
      updatePanelBlendingModes(to: transition.toLayout)
      apply(visibility: transition.toLayout.titleIconAndText, titleTextField, documentIconButton)
      fadeableViewsAnimationState = .shown
      fadeableTopBarAnimationState = .shown
      resetFadeTimer()
    }
  }

  // TODO: Prevent sidebars from opening if not enough space?
  /// First builds a new `LayoutPlan` based on the given `LayoutSpec`, then builds & returns a `LayoutTransition`,
  /// which contains all the information needed to animate the UI changes from the current `LayoutPlan` to the new one.
  func buildLayoutTransition(from fromLayout: LayoutPlan,
                             to layoutSpec: LayoutSpec,
                             totalStartingDuration: CGFloat? = nil,
                             totalEndingDuration: CGFloat? = nil) -> LayoutTransition {

    let toLayout = buildFutureLayoutPlan(from: layoutSpec)
    let transition = LayoutTransition(from: fromLayout, to: toLayout, isInitialLayout: false)
    transition.windowGeometry = buildGeometryFromCurrentLayout()

    let startingAnimationDuration: CGFloat
    if transition.isTogglingFullScreen {
      startingAnimationDuration = 0
    } else if let totalStartingDuration = totalStartingDuration {
      startingAnimationDuration = totalStartingDuration / 3
    } else {
      startingAnimationDuration = UIAnimation.DefaultDuration
    }

    let endingAnimationDuration: CGFloat = totalEndingDuration ?? UIAnimation.DefaultDuration

    let panelTimingName: CAMediaTimingFunctionName?
    if transition.isTogglingFullScreen {
      panelTimingName = nil
    } else if transition.isOpeningOrClosingAnySidebar {
      panelTimingName = .easeIn
    } else {
      panelTimingName = .linear
    }

    log.verbose("Refreshing title bar & OSC layout. EachStartDuration: \(startingAnimationDuration), EachEndDuration: \(endingAnimationDuration)")

    // Starting animations:

    // Set initial var or other tasks which happen before main animations
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      doPreTransitionTask(transition)
    })

    // StartingAnimation 1: Show fadeable views from current layout
    for fadeAnimation in buildAnimationToShowFadeableViews(restartFadeTimer: false, duration: startingAnimationDuration, forceShowTopBar: true) {
      transition.animationTasks.append(fadeAnimation)
    }

    // StartingAnimation 2: Fade out views which no longer will be shown but aren't enclosed in a panel.
    transition.animationTasks.append(UIAnimation.Task(duration: startingAnimationDuration, { [self] in
      fadeOutOldViews(transition)
    }))

    if !transition.isTogglingToFullScreen {  // Avoid bounciness and possible unwanted video scaling animation (not needed for ->FS anyway)
      // StartingAnimation 3: Minimize panels which are no longer needed.
      transition.animationTasks.append(UIAnimation.Task(duration: startingAnimationDuration, timing: panelTimingName, { [self] in
        closeOldPanels(transition)
      }))
    }

    // Middle point: update style & constraints. Should have minimal visual changes
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      // This also can change window styleMask
      updateHiddenViewsAndConstraints(transition)
    })

    // Ending animations:

    // EndingAnimation: Open new panels and fade in new views
    transition.animationTasks.append(UIAnimation.Task(duration: endingAnimationDuration, timing: panelTimingName, { [self] in
      // If toggling fullscreen, this also changes the window frame:
      openNewPanels(transition)

      if transition.isTogglingFullScreen {
        // Fullscreen animations don't have much time. Combine fadeIn step in same animation:
        fadeInNewViews(transition)
      }
    }))

    if !transition.isTogglingFullScreen {
      transition.animationTasks.append(UIAnimation.Task(duration: endingAnimationDuration, timing: panelTimingName, { [self] in
        fadeInNewViews(transition)
      }))
    }

    // After animations all finish
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      doPostTransitionTask(transition)
    })

    return transition
  }

  // MARK: Transition Tasks

  private func doPreTransitionTask(_ transition: LayoutTransition) {
    Logger.log("doPreTransitionTask")
    controlBarFloating.isDragging = false
    /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
    /// To avoid possible bugs as a result, let's update this at the very beginning.
    currentLayout = transition.toLayout

    guard let window = window else { return }

    if transition.isTogglingToFullScreen {
      // Entering FullScreen
      let isLegacy = transition.toLayout.isLegacyFullScreen

      // Do not move this block. It needs to go here.
      if !isLegacy {
        // Hide traffic light buttons & title during the animation:
        hideBuiltInTitleBarItems()
      }

      if #unavailable(macOS 10.14) {
        // Set the appearance to match the theme so the title bar matches the theme
        let iinaTheme = Preference.enum(for: .themeMaterial) as Preference.Theme
        switch(iinaTheme) {
        case .dark, .ultraDark: window.appearance = NSAppearance(named: .vibrantDark)
        default: window.appearance = NSAppearance(named: .vibrantLight)
        }
      }

      setWindowFloatingOnTop(false, updateOnTopStatus: false)

      if isLegacy {
        // Legacy fullscreen cannot handle transition while playing and will result in a black flash or jittering.
        // This will briefly freeze the video output, which is slightly better
        videoView.videoLayer.suspend()

        // stylemask
        log.verbose("Removing window styleMask.titled")
        if #available(macOS 10.16, *) {
          window.styleMask.remove(.titled)
        } else {
          window.styleMask.insert(.fullScreen)
        }
      }
      // Let mpv decide the correct render region in full screen
      player.mpv.setFlag(MPVOption.Window.keepaspect, true)

      resetViewsForFullScreenTransition()
      constrainVideoViewForFullScreen()

    } else if transition.isTogglingFromFullScreen {
      // Exiting FullScreen

      let wasLegacy = transition.fromLayout.isLegacyFullScreen

      resetViewsForFullScreenTransition()

      apply(visibility: .hidden, to: additionalInfoView)

      fsState.startAnimatingToWindow()

      if wasLegacy {
        videoView.videoLayer.suspend()
      } else {  // !isLegacy
        // Hide traffic light buttons & title during the animation:
        hideBuiltInTitleBarItems()
      }

      player.mpv.setFlag(MPVOption.Window.keepaspect, false)
    }

    if transition.mustCloseLeadingSidebar && leadingSidebarAnimationState == .shown {
      leadingSidebarAnimationState = .willHide
    }
    if transition.mustCloseTrailingSidebar && trailingSidebarAnimationState == .shown {
      trailingSidebarAnimationState = .willHide
    }
  }

  private func fadeOutOldViews(_ transition: LayoutTransition) {
    let futureLayout = transition.toLayout
    log.verbose("FadeOutOldViews")

    // Title bar & title bar accessories:

    let needToHideTopBar = transition.isTopBarPlacementChanging || transition.isTogglingTitledWindowStyle

    // Hide all title bar items if top bar placement is changing
    if needToHideTopBar || futureLayout.titleIconAndText == .hidden {
      apply(visibility: .hidden, documentIconButton, titleTextField)
    }

    if needToHideTopBar || futureLayout.trafficLightButtons == .hidden {
      /// Workaround for Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on the "minimize" button will
      /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1` instead.
      for button in trafficLightButtons {
        button.isHidden = true
      }
    }

    if needToHideTopBar || futureLayout.titlebarAccessoryViewControllers == .hidden {
      // Hide all title bar accessories (if needed):
      leadingTitleBarAccessoryView.alphaValue = 0
      fadeableViewsTopBar.remove(leadingTitleBarAccessoryView)
      trailingTitleBarAccessoryView.alphaValue = 0
      fadeableViewsTopBar.remove(trailingTitleBarAccessoryView)
    } else {
      /// We may have gotten here in response to one of these buttons' visibility being toggled in the prefs,
      /// so we need to allow for showing/hiding these individually.
      /// Setting `.isHidden = true` for these icons visibly messes up their layout.
      /// So just set alpha value for now, and hide later in `updateHiddenViewsAndConstraints()`
      if futureLayout.leadingSidebarToggleButton == .hidden {
        leadingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(leadingSidebarToggleButton)
      }
      if futureLayout.trailingSidebarToggleButton == .hidden {
        trailingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(trailingSidebarToggleButton)
      }
      if futureLayout.pinToTopButton == .hidden {
        pinToTopButton.alphaValue = 0
        fadeableViewsTopBar.remove(pinToTopButton)
      }
    }

    // Change blending modes
    if transition.isTogglingFullScreen {
      /// Need to use `.withinWindow` during animation or else panel tint can change in odd ways
      topBarView.blendingMode = .withinWindow
      bottomBarView.blendingMode = .withinWindow
      leadingSidebarView.blendingMode = .withinWindow
      trailingSidebarView.blendingMode = .withinWindow
    }
  }

  private func closeOldPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("CloseOldPanels: title_H=\(futureLayout.titleBarHeight), topOSC_H=\(futureLayout.topOSCHeight)")

    if futureLayout.titleBarHeight == 0 {
      titleBarHeightConstraint.animateToConstant(0)
    }
    if futureLayout.topOSCHeight == 0 {
      topOSCHeightConstraint.animateToConstant(0)
    }
    if futureLayout.osdMinOffsetFromTop == 0 {
      osdMinOffsetFromTopConstraint.animateToConstant(0)
    }

    // Update heights of top & bottom bars:

    let windowFrame = window.frame
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    var needsTopBarHeightUpdate = false
    var newTopBarHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isTopBarPlacementChanging {
      needsTopBarHeightUpdate = true
      // close completely. will animate reopening if needed later
      newTopBarHeight = 0
    } else if futureLayout.topBarHeight < transition.fromLayout.topBarHeight {
      needsTopBarHeightUpdate = true
      newTopBarHeight = futureLayout.topBarHeight
    }

    if needsTopBarHeightUpdate {
      // By default, when the window size changes, the system will add or subtract space from the bottom of the window.
      // Override this behavior to expand/contract upwards instead.
      if transition.fromLayout.topBarPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
      }
      if transition.toLayout.topBarPlacement == .outsideVideo {
        windowHeightDelta += newTopBarHeight
      }

      updateTopBarHeight(to: newTopBarHeight, transition: transition)
    }

    var needsBottomBarHeightUpdate = false
    var newBottomBarHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isBottomBarPlacementChanging {
      needsBottomBarHeightUpdate = true
      // close completely. will animate reopening if needed later
      newBottomBarHeight = 0
    } else if futureLayout.bottomBarHeight < transition.fromLayout.bottomBarHeight {
      needsBottomBarHeightUpdate = true
      newBottomBarHeight = futureLayout.bottomBarHeight
    }

    if needsBottomBarHeightUpdate {
      /// Because we are calling `setFrame()` to update the top bar, we also need to take the bottom bar into
      /// account. Otherwise the system may choose to move the window in an unwanted arbitrary direction.
      /// We want the bottom bar, if "outside" the video, to expand/collapse on the bottom side.
      if transition.fromLayout.bottomBarPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
        windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      }
      if transition.toLayout.bottomBarPlacement == .outsideVideo {
        windowHeightDelta += newBottomBarHeight
        windowYDelta += newBottomBarHeight
      }

      updateBottomBarHeight(to: newBottomBarHeight, transition: transition)
    }

    // Update sidebar vertical alignments to match:
    if futureLayout.topBarHeight < transition.fromLayout.topBarHeight {
      updateSidebarVerticalConstraints(layout: futureLayout)
    }

    let needsFrameUpdate = windowYDelta != 0 || windowHeightDelta != 0
    // Do not do this when first opening the window though, because it will cause the window location restore to be incorrect.
    // Also do not apply when toggling fullscreen because it is not relevant and will cause glitches in the animation.
    if needsFrameUpdate && !transition.isInitialLayout && !transition.isTogglingFullScreen && !futureLayout.isFullScreen {
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      log.debug("Calling setFrame() from closeOldPanels with newWindowFrame \(newWindowFrame)")
      (window as! MainWindow).setFrameImmediately(newWindowFrame)
    }

    if transition.fromLayout.hasFloatingOSC && !futureLayout.hasFloatingOSC {
      // Hide floating OSC
      apply(visibility: futureLayout.controlBarFloating, to: controlBarFloating)
    }

    // Sidebars (if closing)
    animateShowOrHideSidebars(layout: transition.fromLayout,
                              setLeadingTo: transition.mustCloseLeadingSidebar ? .hide : nil,
                              setTrailingTo: transition.mustCloseTrailingSidebar ? .hide : nil)

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("UpdateHiddenViewsAndConstraints")

    /// if `isTogglingTitledWindowStyle==true && isTogglingFromFullScreen==true`, we are toggling out of legacy FS
    /// -> don't change `styleMask` to `.titled` here - it will look bad if screen has camera housing. Change at end of animation
    if transition.isTogglingTitledWindowStyle && !transition.isTogglingFromFullScreen {
      if transition.toLayout.spec.isLegacyMode {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
      } else if !transition.toLayout.isFullScreen {
        log.verbose("Inserting window styleMask.titled")
        window.styleMask.insert(.titled)

        // Remove fake traffic light buttons (if any)
        if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
          for subview in fakeLeadingTitleBarView.subviews {
            subview.removeFromSuperview()
          }
          fakeLeadingTitleBarView.removeFromSuperview()
          self.fakeLeadingTitleBarView = nil
        }

        /// Setting `.titled` style will show buttons & title by default, but we don't want to show them until after panel open animation:
        for button in trafficLightButtons {
          button.isHidden = true
        }
        window.titleVisibility = .hidden
      }
      // Changing the window style while paused will lose displayed video. Draw it again:
      videoView.videoLayer.draw(forced: true)
    }

    applyHiddenOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    updateSpacingForTitleBarAccessories(futureLayout)

    if futureLayout.titleIconAndText == .hidden || transition.isTopBarPlacementChanging {
      /// Note: MUST use `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      window.titleVisibility = .hidden
    }

    /// These should all be either 0 height or unchanged from `transition.fromLayout`
    apply(visibility: futureLayout.bottomBarView, to: bottomBarView)
    if !transition.isTogglingToFullScreen {
      apply(visibility: futureLayout.topBarView, to: topBarView)
    }

    // Remove subviews from OSC
    for view in [fragVolumeView, fragToolbarView, fragPlaybackControlButtonsView, fragPositionSliderView] {
      view?.removeFromSuperview()
    }

    if let setupControlBarInternalViews = futureLayout.setupControlBarInternalViews {
      log.verbose("Setting up control bar: \(futureLayout.oscPosition)")
      setupControlBarInternalViews()
    }

    if transition.isTopBarPlacementChanging {
      updateTopBarPlacement(placement: futureLayout.topBarPlacement)
    }

    if transition.isBottomBarPlacementChanging {
      updateBottomBarPlacement(placement: futureLayout.bottomBarPlacement)
    }

    // Sidebars: finish closing (if closing)
    if transition.mustCloseLeadingSidebar, let visibleTab = transition.fromLayout.leadingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }
    if transition.mustCloseTrailingSidebar, let visibleTab = transition.fromLayout.trailingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }

    // Sidebars: if (re)opening
    if let tabToShow = transition.toLayout.leadingSidebar.visibleTab {
      if transition.mustOpenLeadingSidebar {
        prepareLayoutForOpening(leadingSidebar: transition.toLayout.leadingSidebar)
      } else if transition.fromLayout.leadingSidebar.visibleTabGroup == transition.toLayout.leadingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }
    if let tabToShow = transition.toLayout.trailingSidebar.visibleTab {
      if transition.mustOpenTrailingSidebar {
        prepareLayoutForOpening(trailingSidebar: transition.toLayout.trailingSidebar)
      } else if transition.fromLayout.trailingSidebar.visibleTabGroup == transition.toLayout.trailingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }

    updateDepthOrderOfBars(topBar: futureLayout.topBarPlacement, bottomBar: futureLayout.bottomBarPlacement,
                           leadingSidebar: futureLayout.leadingSidebarPlacement, trailingSidebar: futureLayout.trailingSidebarPlacement)

    // So that panels toggling between "inside" and "outside" don't change until they need to (different strategy than fullscreen)
    if !transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: futureLayout)
    }

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func openNewPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("OpenNewPanels. TitleHeight: \(futureLayout.titleBarHeight), TopOSC: \(futureLayout.topOSCHeight)")

    // Fullscreen: change window frame
    if transition.isTogglingToFullScreen {
      // Entering FullScreen
      if transition.toLayout.isLegacyFullScreen {
        // set window frame and in some cases content view frame
        setWindowFrameForLegacyFullScreen()
      } else {
        let screen = bestScreen
        Logger.log("Calling setFrame() to animate into full screen, to: \(screen.frameWithoutCameraHousing)", level: .verbose)
        window.setFrame(screen.frameWithoutCameraHousing, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
      }
    } else if transition.isTogglingFromFullScreen {
      // Exiting FullScreen
      let topHeight = transition.toLayout.topBarOutsideHeight
      let bottomHeight = transition.toLayout.bottomBarOutsideHeight
      let leadingWidth = transition.toLayout.leadingBarOutsideWidth
      let trailingWidth = transition.toLayout.trailingBarOutsideWidth

      guard let priorFrame = fsState.priorWindowedFrame else { return }
      let priorWindowFrame = priorFrame.resizeOutsideBars(newTopHeight: topHeight,
                                                          newTrailingWidth: trailingWidth,
                                                          newBottomHeight: bottomHeight,
                                                          newLeadingWidth: leadingWidth).windowFrame

      let isLegacy = transition.fromLayout.isLegacyFullScreen
      Logger.log("Calling setFrame() exiting \(isLegacy ? "legacy " : "")full screen, from priorWindowedFrame: \(priorWindowFrame)",
                 level: .verbose, subsystem: player.subsystem)
      window.setFrame(priorWindowFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    }

    // Update heights to their final values:
    topOSCHeightConstraint.animateToConstant(futureLayout.topOSCHeight)
    titleBarHeightConstraint.animateToConstant(futureLayout.titleBarHeight)
    osdMinOffsetFromTopConstraint.animateToConstant(futureLayout.osdMinOffsetFromTop)

    // Update heights of top & bottom bars:

    let windowFrame = window.frame
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    if transition.fromLayout.topBarPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
    }
    if transition.toLayout.topBarPlacement == .outsideVideo {
      windowHeightDelta += futureLayout.topBarHeight
    }
    updateTopBarHeight(to: futureLayout.topBarHeight, transition: transition)

    if transition.fromLayout.bottomBarPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
    }
    if transition.toLayout.bottomBarPlacement == .outsideVideo {
      windowHeightDelta += futureLayout.bottomBarHeight
      windowYDelta += futureLayout.bottomBarHeight
    }
    updateBottomBarHeight(to: futureLayout.bottomBarHeight, transition: transition)

    if !transition.isInitialLayout && !transition.isTogglingFullScreen && !futureLayout.isFullScreen {
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      log.debug("Calling setFrame() from openNewPanels with newWindowFrame \(newWindowFrame)")
      (window as! MainWindow).setFrameImmediately(newWindowFrame)
    }

    // Sidebars (if opening)
    let leadingSidebar = transition.toLayout.leadingSidebar
    let trailingSidebar = transition.toLayout.trailingSidebar
    animateShowOrHideSidebars(layout: transition.toLayout,
                              setLeadingTo: transition.mustOpenLeadingSidebar ? leadingSidebar.visibility : nil,
                              setTrailingTo: transition.mustOpenTrailingSidebar ? trailingSidebar.visibility : nil)

    // Update sidebar vertical alignments
    updateSidebarVerticalConstraints(layout: futureLayout)

    bottomBarView.layoutSubtreeIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func fadeInNewViews(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("FadeInNewViews")

    if futureLayout.titleIconAndText.isShowable {
      window.titleVisibility = .visible
    }

    applyShowableOnly(visibility: futureLayout.controlBarFloating, to: controlBarFloating)

    if futureLayout.isFullScreen {
      if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
        apply(visibility: .showFadeableNonTopBar, to: additionalInfoView)
      }
    } else {
      /// Special case for `trafficLightButtons` due to quirks. Do not use `fadeableViews`. ALways set `alphaValue = 1`.
      for button in trafficLightButtons {
        button.alphaValue = 1
      }
      titleTextField?.alphaValue = 1
      documentIconButton?.alphaValue = 1

      if futureLayout.trafficLightButtons != .hidden {
        if futureLayout.spec.isLegacyMode && fakeLeadingTitleBarView == nil {
          // Add fake traffic light buttons. Needs a lot of work...
          let btnTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
          let trafficLightButtons: [NSButton] = btnTypes.compactMap{ NSWindow.standardWindowButton($0, for: .titled) }
          let leadingStackView = NSStackView(views: trafficLightButtons)
          leadingStackView.wantsLayer = true
          leadingStackView.layer?.backgroundColor = .clear
          leadingStackView.orientation = .horizontal
          window.contentView!.addSubview(leadingStackView)
          leadingStackView.leadingAnchor.constraint(equalTo: leadingStackView.superview!.leadingAnchor).isActive = true
          leadingStackView.trailingAnchor.constraint(equalTo: leadingStackView.superview!.trailingAnchor).isActive = true
          leadingStackView.topAnchor.constraint(equalTo: leadingStackView.superview!.topAnchor).isActive = true
          leadingStackView.heightAnchor.constraint(equalToConstant: MainWindowController.standardTitleBarHeight).isActive = true
          leadingStackView.detachesHiddenViews = false
          leadingStackView.spacing = 6
          /// Because of possible top OSC, `titleBarView` may have reduced height.
          /// So do not vertically center the buttons. Use offset from top instead:
          leadingStackView.alignment = .top
          leadingStackView.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 6)
          for btn in trafficLightButtons {
            btn.alphaValue = 1
//            btn.isHighlighted = true
            btn.display()
          }
          leadingStackView.layout()
          fakeLeadingTitleBarView = leadingStackView
        }

        // This works for legacy too
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }

      /// Title bar accessories get removed by legacy fullscreen or if window `styleMask` did not include `.titled`.
      /// Add them back:
      addTitleBarAccessoryViews()
    }

    applyShowableOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    // Add back title bar accessories (if needed):
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
  }

  private func doPostTransitionTask(_ transition: LayoutTransition) {
    Logger.log("doPostTransitionTask")
    // Update blending mode:
    updatePanelBlendingModes(to: transition.toLayout)
    /// This should go in `fadeInNewViews()`, but for some reason putting it here fixes a bug where the document icon won't fade out
    apply(visibility: transition.toLayout.titleIconAndText, titleTextField, documentIconButton)

    fadeableViewsAnimationState = .shown
    fadeableTopBarAnimationState = .shown
    resetFadeTimer()

    guard let window = window else { return }

    if transition.isTogglingToFullScreen {
      // Entered FullScreen

      let isLegacy = transition.toLayout.isLegacyFullScreen
      if isLegacy {
        // Enter legacy full screen
        window.styleMask.insert(.borderless)
        window.styleMask.remove(.resizable)

        // auto hide menubar and dock (this will freeze all other animations, so must do it last)
        NSApp.presentationOptions.insert(.autoHideMenuBar)
        NSApp.presentationOptions.insert(.autoHideDock)

        window.level = .floating
      } else {
        /// Special case: need to wait until now to call `trafficLightButtons.isHidden = false` due to their quirks
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if isLegacy {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .blackOutMonitor) {
        blackOutOtherMonitors()
      }

      if player.info.isPaused {
        if Preference.bool(for: .playWhenEnteringFullScreen) {
          player.resume()
        } else {
          // When playback is paused the display link is stopped in order to avoid wasting energy on
          // needless processing. It must be running while transitioning to full screen mode. Now that
          // the transition has completed it can be stopped.
          videoView.displayIdle()
        }
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: true)
      }

      updateWindowParametersForMPV()

      // Exit PIP if necessary
      if pipStatus == .inPIP,
         #available(macOS 10.12, *) {
        exitPIP()
      }

      fsState.finishAnimating()
      player.events.emit(.windowFullscreenChanged, data: true)
      saveWindowFrame()

    } else if transition.isTogglingFromFullScreen {
      // Exited FullScreen

      let wasLegacy = transition.fromLayout.isLegacyFullScreen
      let isLegacyWindowedMode = transition.toLayout.spec.isLegacyMode
      if wasLegacy {
        // Go back to titled style
        window.styleMask.remove(.borderless)
        window.styleMask.insert(.resizable)
        if #available(macOS 10.16, *) {
          if !isLegacyWindowedMode {
            log.verbose("Inserting window styleMask.titled")
            window.styleMask.insert(.titled)
          }
          window.level = .normal
        } else {
          window.styleMask.remove(.fullScreen)
        }

        restoreDockSettings()
      } else if isLegacyWindowedMode {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
      }

      constrainVideoViewForWindowedMode()

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }

      fsState.finishAnimating()

      if player.info.isPaused {
        // When playback is paused the display link is stopped in order to avoid wasting energy on
        // needless processing. It must be running while transitioning from full screen mode. Now that
        // the transition has completed it can be stopped.
        videoView.displayIdle()
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: false)
      }

      // Must not access mpv while it is asynchronously processing stop and quit commands.
      // See comments in resetViewsForFullScreenTransition for details.
      guard !isClosing else { return }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if wasLegacy {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .pauseWhenLeavingFullScreen) && player.info.isPlaying {
        player.pause()
      }

      // restore ontop status
      if player.info.isPlaying {
        setWindowFloatingOnTop(isOntop, updateOnTopStatus: false)
      }

      resetCollectionBehavior()
      updateWindowParametersForMPV()

      if wasLegacy {
        // Workaround for AppKit quirk : do this here to ensure document icon & title don't get stuck in "visible" or "hidden" states
        apply(visibility: transition.toLayout.titleIconAndText, documentIconButton, titleTextField)
        for button in trafficLightButtons {
          /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
          /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
          /// but should be ok for brief animations
          button.alphaValue = 1
          button.isHidden = false
        }
        window.titleVisibility = .visible
      }

      player.events.emit(.windowFullscreenChanged, data: false)
    }
    // Need to make sure this executes after styleMask is .titled
    addTitleBarAccessoryViews()
  }

  // MARK: - Bars Layout

  /**
   This ONLY updates the constraints to toggle between `inside` and `outside` placement types.
   Whether it is actually shown is a concern for somewhere else.
   "Outside"
   ┌─────────────┐
   │  Title Bar  │   Top of    Top of
   ├─────────────┤    Video    Video
   │   Top OSC   │        │    │            "Inside"
   ┌─────┼─────────────┼─────┐◄─┘    └─►┌─────┬─────────────┬─────┐
   │     │            V│     │          │     │  Title Bar V│     │
   │ Left│            I│Right│          │ Left├────────────I│Right│
   │ Side│            D│Side │          │ Side│   Top OSC  D│Side │
   │  bar│            E│bar  │          │  bar├────────────E│bar  │
   │     │  VIDEO     O│     │          │     │  VIDEO     O│     │
   └─────┴─────────────┴─────┘          └─────┴─────────────┴─────┘
   */
  private func updateTopBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating top bar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(topBarLeadingSpaceConstraint)
    contentView.removeConstraint(topBarTrailingSpaceConstraint)

    switch placement {
    case .insideVideo:
      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)

    case .outsideVideo:
      // Align left & right sides with window (sidebars go below top bar)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)

    }
    topBarLeadingSpaceConstraint.isActive = true
    topBarTrailingSpaceConstraint.isActive = true
  }

  private func updateTopBarHeight(to topBarHeight: CGFloat, transition: LayoutTransition) {
    let placement = transition.toLayout.topBarPlacement
    let cameraHousingOffset = transition.toLayout.cameraHousingOffset
    log.verbose("TopBar height: \(topBarHeight), placement: \(placement), cameraHousing: \(cameraHousingOffset)")

    switch placement {
    case .insideVideo:
      videoContainerTopOffsetFromTopBarBottomConstraint.animateToConstant(-topBarHeight)
      videoContainerTopOffsetFromTopBarTopConstraint.animateToConstant(0)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(0 + cameraHousingOffset)
    case .outsideVideo:
      videoContainerTopOffsetFromTopBarBottomConstraint.animateToConstant(0)
      videoContainerTopOffsetFromTopBarTopConstraint.animateToConstant(topBarHeight)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(topBarHeight + cameraHousingOffset)
    }
  }

  func updateDepthOrderOfBars(topBar: Preference.PanelPlacement, bottomBar: Preference.PanelPlacement,
                                leadingSidebar: Preference.PanelPlacement, trailingSidebar: Preference.PanelPlacement) {
    guard let window = window, let contentView = window.contentView else { return }

    // If a sidebar is "outsideVideo", need to put it behind the video because:
    // (1) Don't want sidebar to cast a shadow on the video
    // (2) Animate sidebar open/close with "slide in" / "slide out" from behind the video
    if leadingSidebar == .outsideVideo {
      contentView.addSubview(leadingSidebarView, positioned: .below, relativeTo: videoContainerView)
    }
    if trailingSidebar == .outsideVideo {
      contentView.addSubview(trailingSidebarView, positioned: .below, relativeTo: videoContainerView)
    }

    contentView.addSubview(topBarView, positioned: .above, relativeTo: videoContainerView)
    contentView.addSubview(bottomBarView, positioned: .above, relativeTo: videoContainerView)

    if leadingSidebar == .insideVideo {
      contentView.addSubview(leadingSidebarView, positioned: .above, relativeTo: videoContainerView)

      if topBar == .insideVideo {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
      if bottomBar == .insideVideo {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
    }

    if trailingSidebar == .insideVideo {
      contentView.addSubview(trailingSidebarView, positioned: .above, relativeTo: videoContainerView)

      if topBar == .insideVideo {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
      if bottomBar == .insideVideo {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
    }
  }

  private func updateBottomBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating bottom bar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(bottomBarLeadingSpaceConstraint)
    contentView.removeConstraint(bottomBarTrailingSpaceConstraint)

    switch placement {
    case .insideVideo:
      bottomBarTopBorder.isHidden = true

      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    case .outsideVideo:
      bottomBarTopBorder.isHidden = false

      // Align left & right sides with window (sidebars go below top bar)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)
    }
    bottomBarLeadingSpaceConstraint.isActive = true
    bottomBarTrailingSpaceConstraint.isActive = true
  }

  private func updateBottomBarHeight(to bottomBarHeight: CGFloat, transition: LayoutTransition) {
    let placement = transition.toLayout.bottomBarPlacement
    log.verbose("Updating bottomBar height to: \(bottomBarHeight), placement: \(placement)")

    switch placement {
    case .insideVideo:
      videoContainerBottomOffsetFromBottomBarTopConstraint.animateToConstant(bottomBarHeight)
      videoContainerBottomOffsetFromBottomBarBottomConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(0)
    case .outsideVideo:
      videoContainerBottomOffsetFromBottomBarTopConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromBottomBarBottomConstraint.animateToConstant(-bottomBarHeight)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(bottomBarHeight)
    }
  }

  // This method should only make a layout plan. It should not alter or reference the current layout.
  func buildFutureLayoutPlan(from layoutSpec: LayoutSpec) -> LayoutPlan {
    let window = window!

    let futureLayout = LayoutPlan(spec: layoutSpec)

    // Title bar & title bar accessories:

    if futureLayout.isFullScreen {
      futureLayout.titleIconAndText = .showAlways
      futureLayout.trafficLightButtons = .showAlways

      if futureLayout.isLegacyFullScreen, let unusableHeight = window.screen?.cameraHousingHeight {
        // This screen contains an embedded camera. Want to avoid having part of the window obscured by the camera housing.
        futureLayout.cameraHousingOffset = unusableHeight
      }
    } else {
      let visibleState: Visibility = futureLayout.topBarPlacement == .insideVideo ? .showFadeableTopBar : .showAlways

      futureLayout.topBarView = visibleState
      futureLayout.trafficLightButtons = visibleState
      futureLayout.titleIconAndText = visibleState
      futureLayout.titleBarHeight = layoutSpec.isLegacyMode ? 0 : MainWindowController.standardTitleBarHeight  // may be overridden by OSC layout

      if futureLayout.topBarPlacement == .insideVideo {
        futureLayout.osdMinOffsetFromTop = futureLayout.titleBarHeight + 8
      }

      futureLayout.titlebarAccessoryViewControllers = visibleState

      // LeadingSidebar toggle button
      let hasLeadingSidebar = !layoutSpec.leadingSidebar.tabGroups.isEmpty
      if hasLeadingSidebar && Preference.bool(for: .showLeadingSidebarToggleButton) {
        futureLayout.leadingSidebarToggleButton = visibleState
      }
      // TrailingSidebar toggle button
      let hasTrailingSidebar = !layoutSpec.trailingSidebar.tabGroups.isEmpty
      if hasTrailingSidebar && Preference.bool(for: .showTrailingSidebarToggleButton) {
        futureLayout.trailingSidebarToggleButton = visibleState
      }

      // "On Top" (mpv) AKA "Pin to Top" (OS)
      futureLayout.pinToTopButton = futureLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    }

    // OSC:

    if futureLayout.enableOSC {
      // add fragment views
      switch futureLayout.oscPosition {
      case .floating:
        futureLayout.controlBarFloating = .showFadeableNonTopBar  // floating is always fadeable

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = controlBarFloating

          oscFloatingPlayButtonsContainerView.addView(fragPlaybackControlButtonsView, in: .center)
          // There sweems to be a race condition when adding to these StackViews.
          // Sometimes it still contains the old view, and then trying to add again will cause a crash.
          // Must check if it already contains the view before adding.
          if !oscFloatingUpperView.views(in: .leading).contains(fragVolumeView) {
            oscFloatingUpperView.addView(fragVolumeView, in: .leading)
          }
          let toolbarView = rebuildToolbar(iconSize: oscFloatingToolbarButtonIconSize, iconPadding: oscFloatingToolbarButtonIconPadding)
          oscFloatingUpperView.addView(toolbarView, in: .trailing)
          fragToolbarView = toolbarView

          oscFloatingUpperView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
          oscFloatingUpperView.setVisibilityPriority(.detachEarlier, for: toolbarView)
          oscFloatingUpperView.setClippingResistancePriority(.defaultLow, for: .horizontal)

          oscFloatingLowerView.addSubview(fragPositionSliderView)
          fragPositionSliderView.addConstraintsToFillSuperview()
          // center control bar
          let cph = Preference.float(for: .controlBarPositionHorizontal)
          let cpv = Preference.float(for: .controlBarPositionVertical)
          controlBarFloating.xConstraint.constant = window.frame.width * CGFloat(cph)
          controlBarFloating.yConstraint.constant = window.frame.height * CGFloat(cpv)

          playbackButtonsSquareWidthConstraint.constant = oscFloatingPlayBtnsSize
          playbackButtonsHorizontalPaddingConstraint.constant = oscFloatingPlayBtnsHPad
        }
      case .top:
        if !futureLayout.isFullScreen {
          futureLayout.titleBarHeight = MainWindowController.reducedTitleBarHeight
        }

        let visibility: Visibility = futureLayout.topBarPlacement == .insideVideo ? .showFadeableTopBar : .showAlways
        futureLayout.topBarView = visibility
        futureLayout.topOSCHeight = OSCToolbarButton.oscBarHeight

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = controlBarTop
          addControlBarViews(to: oscTopMainView,
                             playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)
        }

      case .bottom:
        futureLayout.bottomBarHeight = OSCToolbarButton.oscBarHeight
        futureLayout.bottomBarView = (futureLayout.bottomBarPlacement == .insideVideo) ? .showFadeableNonTopBar : .showAlways

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = bottomBarView
          addControlBarViews(to: oscBottomMainView,
                             playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)
        }
      }
    } else {  // No OSC
      currentControlBar = nil
    }

    return futureLayout
  }

  // MARK: - Title bar items

  func addTitleBarAccessoryViews() {
    guard let window = window else { return }
    if leadingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      leadingTitlebarAccesoryViewController = controller
      controller.view = leadingTitleBarAccessoryView
      controller.layoutAttribute = .leading

      leadingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: MainWindowController.standardTitleBarHeight).isActive = true
    }
    if trailingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      trailingTitlebarAccesoryViewController = controller
      controller.view = trailingTitleBarAccessoryView
      controller.layoutAttribute = .trailing

      trailingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: MainWindowController.standardTitleBarHeight).isActive = true
    }
    if window.styleMask.contains(.titled) && window.titlebarAccessoryViewControllers.isEmpty {
      window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController!)
      window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController!)

      trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
      leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    }
  }

  func updateSpacingForTitleBarAccessories(_ layout: LayoutPlan? = nil) {
    let layout = layout ?? self.currentLayout

    updateSpacingForLeadingTitleBarAccessory(layout)
    updateSpacingForTrailingTitleBarAccessory(layout)
  }

  // Updates visibility of buttons on the left side of the title bar. Also when the left sidebar is visible,
  // sets the horizontal space needed to push the title bar right, so that it doesn't overlap onto the left sidebar.
  private func updateSpacingForLeadingTitleBarAccessory(_ layout: LayoutPlan) {
    var trailingSpace: CGFloat = 8  // Add standard space before title text by default

    let sidebarButtonSpace: CGFloat = layout.leadingSidebarToggleButton.isShowable ? leadingSidebarToggleButton.frame.width : 0

    let isSpaceNeededForSidebar = layout.leadingSidebar.currentWidth > 0
    if isSpaceNeededForSidebar {
      // Subtract space taken by the 3 standard buttons + other visible buttons
      trailingSpace = max(0, layout.leadingSidebar.currentWidth - trafficLightButtonsWidth - sidebarButtonSpace)
    }
    leadingTitleBarTrailingSpaceConstraint.constant = trailingSpace
    leadingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  // Updates visibility of buttons on the right side of the title bar. Also when the right sidebar is visible,
  // sets the horizontal space needed to push the title bar left, so that it doesn't overlap onto the right sidebar.
  private func updateSpacingForTrailingTitleBarAccessory(_ layout: LayoutPlan) {
    var leadingSpace: CGFloat = 0
    var spaceForButtons: CGFloat = 0

    if layout.trailingSidebarToggleButton.isShowable {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if layout.pinToTopButton.isShowable {
      spaceForButtons += pinToTopButton.frame.width
    }

    let isSpaceNeededForSidebar = layout.topBarPlacement == .insideVideo && layout.trailingSidebar.currentWidth > 0
    if isSpaceNeededForSidebar {
      leadingSpace = max(0, layout.trailingSidebar.currentWidth - spaceForButtons)
    }
    trailingTitleBarLeadingSpaceConstraint.constant = leadingSpace

    // Add padding to the side for buttons
    let isAnyButtonVisible = layout.trailingSidebarToggleButton.isShowable || layout.pinToTopButton.isShowable
    let buttonMargin: CGFloat = isAnyButtonVisible ? 8 : 0
    trailingTitleBarTrailingSpaceConstraint.constant = buttonMargin
    trailingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  private func hideBuiltInTitleBarItems() {
    apply(visibility: .hidden, documentIconButton, titleTextField)
    for button in trafficLightButtons {
      /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
      /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
      /// but should be ok for brief animations
      button.alphaValue = 0
      button.isHidden = false
    }
    window?.titleVisibility = .hidden
  }

  func updatePinToTopButton() {
    let buttonVisibility = currentLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    pinToTopButton.state = isOntop ? .on : .off
    apply(visibility: buttonVisibility, to: pinToTopButton)
    if buttonVisibility == .showFadeableTopBar {
      showFadeableViews()
    }
    updateSpacingForTitleBarAccessories()
  }

  // MARK: - Controller content layout

  private func addControlBarViews(to containerView: NSStackView, playBtnSize: CGFloat, playBtnSpacing: CGFloat,
                                  toolbarIconSize: CGFloat? = nil, toolbarIconSpacing: CGFloat? = nil) {
    let toolbarView = rebuildToolbar(iconSize: toolbarIconSize, iconPadding: toolbarIconSpacing)
    containerView.addView(fragPlaybackControlButtonsView, in: .leading)
    containerView.addView(fragPositionSliderView, in: .leading)
    containerView.addView(fragVolumeView, in: .leading)
    containerView.addView(toolbarView, in: .leading)
    fragToolbarView = toolbarView

    containerView.setClippingResistancePriority(.defaultLow, for: .horizontal)
    containerView.setVisibilityPriority(.mustHold, for: fragPositionSliderView)
    containerView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
    containerView.setVisibilityPriority(.detachEarlier, for: toolbarView)

    playbackButtonsSquareWidthConstraint.constant = playBtnSize
    playbackButtonsHorizontalPaddingConstraint.constant = playBtnSpacing
  }

  private func rebuildToolbar(iconSize: CGFloat? = nil, iconPadding: CGFloat? = nil) -> NSStackView {
    let buttonTypeRawValues = Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []
    var buttonTypes = buttonTypeRawValues.compactMap(Preference.ToolBarButton.init(rawValue:))
    if #available(macOS 10.12.2, *) {} else {
      buttonTypes = buttonTypes.filter { $0 != .pip }
    }
    log.verbose("Adding buttons to OSC toolbar: \(buttonTypes)")

    var toolButtons: [OSCToolbarButton] = []
    for buttonType in buttonTypes {
      let button = OSCToolbarButton()
      button.setStyle(buttonType: buttonType, iconSize: iconSize, iconPadding: iconPadding)
      button.action = #selector(self.toolBarButtonAction(_:))
      toolButtons.append(button)
    }

    if let stackView = fragToolbarView {
      stackView.views.forEach { stackView.removeView($0) }
      stackView.removeFromSuperview()
      fragToolbarView = nil
    }
    let toolbarView = NSStackView(views: toolButtons)
    toolbarView.orientation = .horizontal

    for button in toolButtons {
      toolbarView.setVisibilityPriority(.detachOnlyIfNecessary, for: button)
    }

    // FIXME: this causes a crash due to conflicting constraints. Need to rewrite layout for toolbar button spacing!
    // It's not possible to control the icon padding from inside the buttons in all cases.
    // Instead we can get the same effect with a little more work, by controlling the stack view:
    //    if !toolButtons.isEmpty {
    //      let button = toolButtons[0]
    //      toolbarView.spacing = 2 * button.iconPadding
    //      toolbarView.edgeInsets = .init(top: button.iconPadding, left: button.iconPadding,
    //                                     bottom: button.iconPadding, right: button.iconPadding)
    //      Logger.log("Toolbar spacing: \(toolbarView.spacing), edgeInsets: \(toolbarView.edgeInsets)", level: .verbose, subsystem: player.subsystem)
    //    }
    return toolbarView
  }

  // MARK: - VideoView Constraints

  private func addOrUpdate(_ existing: NSLayoutConstraint?,
                           _ attr: NSLayoutConstraint.Attribute, _ relation: NSLayoutConstraint.Relation, _ constant: CGFloat,
                           _ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
    let constraint: NSLayoutConstraint
    if let existing = existing {
      constraint = existing
      constraint.animateToConstant(constant)
    } else {
      constraint = existing ?? NSLayoutConstraint(item: videoView, attribute: attr, relatedBy: relation, toItem: videoContainerView,
                                                  attribute: attr, multiplier: 1, constant: constant)
    }
    constraint.priority = priority
    return constraint
  }

  func rebuildVideoViewConstraints(top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0,
                                   eqPriority: NSLayoutConstraint.Priority,
                                   gtPriority: NSLayoutConstraint.Priority,
                                   centerPriority: NSLayoutConstraint.Priority) -> VideoViewConstraints {
    let existing = self.videoViewConstraints
    let newConstraints = VideoViewConstraints(
      eqOffsetTop: addOrUpdate(existing?.eqOffsetTop, .top, .equal, top, eqPriority),
      eqOffsetRight: addOrUpdate(existing?.eqOffsetRight, .right, .equal, right, eqPriority),
      eqOffsetBottom: addOrUpdate(existing?.eqOffsetBottom, .bottom, .equal, bottom, eqPriority),
      eqOffsetLeft: addOrUpdate(existing?.eqOffsetLeft, .left, .equal, left, eqPriority),

      gtOffsetTop: addOrUpdate(existing?.gtOffsetTop, .top, .greaterThanOrEqual, top, gtPriority),
      gtOffsetRight: addOrUpdate(existing?.gtOffsetRight, .right, .lessThanOrEqual, right, gtPriority),
      gtOffsetBottom: addOrUpdate(existing?.gtOffsetBottom, .bottom, .lessThanOrEqual, bottom, gtPriority),
      gtOffsetLeft: addOrUpdate(existing?.gtOffsetLeft, .left, .greaterThanOrEqual, left, gtPriority),

      centerX: existing?.centerX ?? videoView.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
      centerY: existing?.centerY ?? videoView.centerYAnchor.constraint(equalTo: videoContainerView.centerYAnchor)
    )
    newConstraints.centerX.priority = centerPriority
    newConstraints.centerY.priority = centerPriority
    return newConstraints
  }

  // TODO: figure out why this 2px adjustment is necessary
  func constrainVideoViewForWindowedMode(top: CGFloat = -2, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = -2) {
    log.verbose("Contraining videoView for windowed mode")
    // Remove GT & center constraints. Use only EQ
    let existing = self.videoViewConstraints
    if let existing = existing {
      existing.gtOffsetTop.isActive = false
      existing.gtOffsetRight.isActive = false
      existing.gtOffsetBottom.isActive = false
      existing.gtOffsetLeft.isActive = false

      existing.centerX.isActive = false
      existing.centerY.isActive = false
    }
    let newConstraints = rebuildVideoViewConstraints(top: top, right: right, bottom: bottom, left: left,
                                                     eqPriority: .required,
                                                     gtPriority: .defaultLow,
                                                     centerPriority: .defaultLow)
    newConstraints.eqOffsetTop.isActive = true
    newConstraints.eqOffsetRight.isActive = true
    newConstraints.eqOffsetBottom.isActive = true
    newConstraints.eqOffsetLeft.isActive = true
    videoViewConstraints = newConstraints

    /// Go back to enforcing the aspect ratio via `windowWillResize()`, because finer-grained control is needed for windowed mode
    videoView.removeAspectRatioConstraint()

    window?.layoutIfNeeded()
  }

  private func constrainVideoViewForFullScreen() {
    // GT + center constraints are main priority, but include EQ as hint for ideal placement
    let newConstraints = rebuildVideoViewConstraints(eqPriority: .defaultLow,
                                                     gtPriority: .required,
                                                     centerPriority: .required)
    newConstraints.gtOffsetTop.isActive = true
    newConstraints.gtOffsetRight.isActive = true
    newConstraints.gtOffsetBottom.isActive = true
    newConstraints.gtOffsetLeft.isActive = true

    newConstraints.centerX.isActive = true
    newConstraints.centerY.isActive = true
    videoViewConstraints = newConstraints

    // Change aspectRatio into AutoLayout constraint to force the other constraints to work with it
    videoView.setAspectRatioConstraint()

    window?.layoutIfNeeded()
  }

  // MARK: - Misc support functions

  private func resetViewsForFullScreenTransition() {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // needless processing. It must be running while transitioning to/from full screen mode.
    videoView.displayActive()

    if isInInteractiveMode {
      exitInteractiveMode(immediately: true)
    }

    thumbnailPeekView.isHidden = true
    timePreviewWhenSeek.isHidden = true
    isMouseInSlider = false
  }

  private func updatePanelBlendingModes(to futureLayout: LayoutPlan) {
    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.topBarPlacement == .insideVideo || futureLayout.isFullScreen {
      topBarView.blendingMode = .withinWindow
    } else {
      topBarView.blendingMode = .behindWindow
    }

    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.bottomBarPlacement == .insideVideo || futureLayout.isFullScreen {
      bottomBarView.blendingMode = .withinWindow
    } else {
      bottomBarView.blendingMode = .behindWindow
    }

    updateSidebarBlendingMode(.leadingSidebar, layout: futureLayout)
    updateSidebarBlendingMode(.trailingSidebar, layout: futureLayout)
  }

}