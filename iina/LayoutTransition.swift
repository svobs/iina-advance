//
//  LayoutTransition.swift
//  iina
//
//  Created by Matt Svoboda on 10/3/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

extension PlayWindowController {
  /// `LayoutTransition`: data structure which holds metadata needed to execute a series of animations which transition
  /// a single `PlayerWindow` from one layout (`inputLayout`) to another (`outputLayout`). Instances of `PlayWindowGeometry`
  /// are also used along the way to dictate window location/size, video container size, sidebar sizes, & other geometry.
  ///
  /// See `buildLayoutTransition()`, where an instance of this class is assembled.
  /// Other important variables: `currentLayout`, `windowedModeGeometry`, `musicModeGeometry` (in `PlayWindowController`)
  class LayoutTransition {
    let name: String  // just used for debugging

    let inputLayout: LayoutState
    let outputLayout: LayoutState

    let inputGeometry: PlayWindowGeometry
    var middleGeometry: PlayWindowGeometry?
    let outputGeometry: PlayWindowGeometry

    /// Should only be true when setting layout on window open. See `setInitialWindowLayout()` in `PlayWindowController`.
    let isInitialLayout: Bool

    var animationTasks: [CocoaAnimation.Task] = []

    init(name: String, from inputLayout: LayoutState, from inputGeometry: PlayWindowGeometry,
         to outputLayout: LayoutState, to outputGeometry: PlayWindowGeometry,
         middleGeometry: PlayWindowGeometry? = nil,
         isInitialLayout: Bool = false) {
      self.name = name
      self.inputLayout = inputLayout
      self.inputGeometry = inputGeometry
      self.middleGeometry = middleGeometry
      self.outputLayout = outputLayout
      self.outputGeometry = outputGeometry
      self.isInitialLayout = isInitialLayout
    }

    var isOSCChanging: Bool {
      return (inputLayout.enableOSC != outputLayout.enableOSC) || (inputLayout.oscPosition != outputLayout.oscPosition)
    }

    var needsFadeOutOldViews: Bool {
      return isTogglingLegacyStyle || isTopBarPlacementChanging
      || (inputLayout.spec.mode != outputLayout.spec.mode)
      || (inputLayout.bottomBarPlacement == .insideVideo && outputLayout.bottomBarPlacement == .outsideVideo)
      || (inputLayout.enableOSC != outputLayout.enableOSC)
      || (inputLayout.enableOSC && (inputLayout.oscPosition != outputLayout.oscPosition))
      || (inputLayout.leadingSidebarToggleButton.isShowable && !outputLayout.leadingSidebarToggleButton.isShowable)
      || (inputLayout.trailingSidebarToggleButton.isShowable && !outputLayout.trailingSidebarToggleButton.isShowable)
      || (inputLayout.pinToTopButton.isShowable && !outputLayout.pinToTopButton.isShowable)
    }

    var needsFadeInNewViews: Bool {
      return isTogglingLegacyStyle || isTopBarPlacementChanging
      || (inputLayout.spec.mode != outputLayout.spec.mode)
      || (inputLayout.bottomBarPlacement == .outsideVideo && outputLayout.bottomBarPlacement == .insideVideo)
      || (inputLayout.enableOSC != outputLayout.enableOSC)
      || (outputLayout.enableOSC && (inputLayout.oscPosition != outputLayout.oscPosition))
      || (!inputLayout.leadingSidebarToggleButton.isShowable && outputLayout.leadingSidebarToggleButton.isShowable)
      || (!inputLayout.trailingSidebarToggleButton.isShowable && outputLayout.trailingSidebarToggleButton.isShowable)
      || (!inputLayout.pinToTopButton.isShowable && outputLayout.pinToTopButton.isShowable)
    }

    var needsCloseOldPanels: Bool {
      if isEnteringFullScreen {
        // Avoid bounciness and possible unwanted video scaling animation (not needed for ->FS anyway)
        return false
      }
      return isHidingLeadingSidebar || isHidingTrailingSidebar || isTopBarPlacementChanging || isBottomBarPlacementChanging
      || (inputLayout.spec.isLegacyStyle != outputLayout.spec.isLegacyStyle)
      || (inputLayout.spec.mode != outputLayout.spec.mode)
      || (inputLayout.enableOSC != outputLayout.enableOSC)
      || (inputLayout.enableOSC && (inputLayout.oscPosition != outputLayout.oscPosition))
    }

    var isAddingLegacyStyle: Bool {
      return !inputLayout.spec.isLegacyStyle && outputLayout.spec.isLegacyStyle
    }

    var isRemovingLegacyStyle: Bool {
      return inputLayout.spec.isLegacyStyle && !outputLayout.spec.isLegacyStyle
    }

    var isTogglingLegacyStyle: Bool {
      return inputLayout.spec.isLegacyStyle != outputLayout.spec.isLegacyStyle
    }

    var isTogglingFullScreen: Bool {
      return inputLayout.isFullScreen != outputLayout.isFullScreen
    }

    var isEnteringFullScreen: Bool {
      return !inputLayout.isFullScreen && outputLayout.isFullScreen
    }

    var isExitingFullScreen: Bool {
      return inputLayout.isFullScreen && !outputLayout.isFullScreen
    }

    var isEnteringNativeFullScreen: Bool {
      return isEnteringFullScreen && outputLayout.spec.isNativeFullScreen
    }

    var isEnteringLegacyFullScreen: Bool {
      return isEnteringFullScreen && outputLayout.isLegacyFullScreen
    }

    var isExitingLegacyFullScreen: Bool {
      return isExitingFullScreen && inputLayout.isLegacyFullScreen
    }

    var isTogglingLegacyFullScreen: Bool {
      return isEnteringLegacyFullScreen || isExitingLegacyFullScreen
    }

    var isEnteringMusicMode: Bool {
      return !inputLayout.isMusicMode && outputLayout.isMusicMode
    }

    var isExitingMusicMode: Bool {
      return inputLayout.isMusicMode && !outputLayout.isMusicMode
    }

    var isTogglingMusicMode: Bool {
      return inputLayout.isMusicMode != outputLayout.isMusicMode
    }

    var isTopBarPlacementChanging: Bool {
      return inputLayout.topBarPlacement != outputLayout.topBarPlacement
    }

    var isBottomBarPlacementChanging: Bool {
      return inputLayout.bottomBarPlacement != outputLayout.bottomBarPlacement
    }

    var isLeadingSidebarPlacementChanging: Bool {
      return inputLayout.leadingSidebarPlacement != outputLayout.leadingSidebarPlacement
    }

    var isTrailingSidebarPlacementChanging: Bool {
      return inputLayout.trailingSidebarPlacement != outputLayout.trailingSidebarPlacement
    }

    lazy var isShowingLeadingSidebar: Bool = {
      return isShowing(.leadingSidebar)
    }()

    lazy var isShowingTrailingSidebar: Bool = {
      return isShowing(.trailingSidebar)
    }()

    lazy var isHidingLeadingSidebar: Bool = {
      return isHiding(.leadingSidebar)
    }()

    lazy var isHidingTrailingSidebar: Bool = {
      return isHiding(.trailingSidebar)
    }()

    lazy var isTogglingVisibilityOfAnySidebar: Bool = {
      return isShowingLeadingSidebar || isShowingTrailingSidebar || isHidingLeadingSidebar || isHidingTrailingSidebar
    }()

    /// Is opening given sidebar?
    func isShowing(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = inputLayout.sidebar(withID: sidebarID)
      let newState = outputLayout.sidebar(withID: sidebarID)
      if !oldState.isVisible && newState.isVisible {
        return true
      }
      return isHidingAndThenShowing(sidebarID)
    }

    /// Is closing given sidebar?
    func isHiding(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = inputLayout.sidebar(withID: sidebarID)
      let newState = outputLayout.sidebar(withID: sidebarID)
      if oldState.isVisible {
        if !newState.isVisible {
          return true
        }
        if let oldVisibleTabGroup = oldState.visibleTabGroup, let newVisibleTabGroup = newState.visibleTabGroup,
           oldVisibleTabGroup != newVisibleTabGroup {
          return true
        }
        if let visibleTabGroup = oldState.visibleTabGroup, !newState.tabGroups.contains(visibleTabGroup) {
          Logger.log("isHiding(sidebarID:): visibleTabGroup \(visibleTabGroup.rawValue.quoted) is not present in newState!", level: .error)
          return true
        }
      }
      return isHidingAndThenShowing(sidebarID)
    }

    func isHidingAndThenShowing(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = inputLayout.sidebar(withID: sidebarID)
      let newState = outputLayout.sidebar(withID: sidebarID)
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
  
}