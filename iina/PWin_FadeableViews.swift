//
//  PWin_FadeableViews.swift
//  iina
//
//  Created by Matt Svoboda on 2024-10-19.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

/// This file encapsulates logic to:
/// - Show/hide fadeable views (AKA "fadeables", AKA "inside panels").
/// - Show/hide default album art
extension PlayerWindowController {

  class FadeableViewsHandler {

    /// Views that will show/hide when cursor moving in/out of the window
    var fadeables = Set<NSView>()
    /// Similar to `fadeables`, but may fade in differently depending on configuration of top bar.
    var fadeablesInTopBar = Set<NSView>()
    var animationState: UIAnimationState = .shown
    var topBarAnimationState: UIAnimationState = .shown

    var isShowingFadeableViewsForSeek = false

    /// For auto hiding UI after a timeout.
    /// Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    let hideTimer = TimeoutTimer(timeout: max(TimeConstants.fadeableViewsTimeoutMin, Preference.double(for: .controlBarAutoHideTimeout)))

    @Atomic fileprivate(set) var showHideTicketCount: Int = 0
    /// Need to carry an extra bit of info for this
    fileprivate var pendingShowTopPanel: Bool = false
    fileprivate var log: any Logger.Subsystem

    init(_ log: any Logger.Subsystem) {
      self.log = log
    }

    func clearFadeableSets() {
      log.verbose("Clearing fadeables sets")
      fadeables = Set<NSView>()
      fadeablesInTopBar = Set<NSView>()
    }

    func applyVisibility(_ visibility: VisibilityMode, to fadeableView: NSView) {
      log.verbose("ApplyVisibility: \(fadeableView.idString.quoted) ≔ \(visibility)")

      switch visibility {
      case .hidden:
        fadeableView.alphaValue = 0
        fadeableView.isHidden = true
        fadeables.remove(fadeableView)
        fadeablesInTopBar.remove(fadeableView)
      case .showAlways:
        fadeableView.alphaValue = 1
        fadeableView.isHidden = false
        fadeables.remove(fadeableView)
        fadeablesInTopBar.remove(fadeableView)
      case .showFadeableTopBar:
        fadeableView.alphaValue = 1
        fadeableView.isHidden = false
        fadeablesInTopBar.insert(fadeableView)
      case .showFadeableNonTopBar:
        fadeableView.alphaValue = 1
        fadeableView.isHidden = false
        fadeables.insert(fadeableView)
      }
    }

    func applyVisibility(_ visibility: VisibilityMode, _ views: NSView?...) {
      for fadeableView in views {
        if let fadeableView {
          applyVisibility(visibility, to: fadeableView)
        }
      }
    }

    func applyOnlyIfHidden(_ visibility: VisibilityMode, to fadeableView: NSView) {
      guard visibility == .hidden else { return }
      applyVisibility(visibility, fadeableView)
    }

    func applyOnlyIfHidden(_ visibility: VisibilityMode, _ views: NSView?...) {
      guard visibility == .hidden else { return }
      for fadeableView in views {
        if let fadeableView {
          applyVisibility(visibility, to: fadeableView)
        }
      }
    }

    func applyOnlyIfShowable(_ visibility: VisibilityMode, to fadeableView: NSView) {
      guard visibility != .hidden else { return }
      applyVisibility(visibility, fadeableView)
    }

  }  // end class FadeableViewsHandler


  // MARK: - PlayerWindowController

  func showFadeableViewsForMouseLocation(_ pointInWindow: NSPoint) {
    let isTopBarHoverEnabled = Preference.isAdvancedEnabled && Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.topBarHover
    let forceShowTopBar = isTopBarHoverEnabled && isMouseInTopBarArea(pointInWindow) && fadeableViews.topBarAnimationState == .hidden
    // Check whether mouse is in OSC
    let shouldRestartFadeTimer = !isMouseInsideFadeableView(pointInWindow)
    log.trace("ShouldRestartFadeTimer=\(shouldRestartFadeTimer.yesno) forceShowTopBar=\(forceShowTopBar.yesno)")
    showFadeableViews(thenRestartFadeTimer: shouldRestartFadeTimer, duration: 0, forceShowTopBar: forceShowTopBar)
  }

  // assumes mouse is in window
  private func isMouseInTopBarArea(_ mouseLocInWindow: NSPoint) -> Bool {
    guard currentLayout.topBarView.isShowable else {
      // e.g. music mode
      return false
    }
    guard let window = window, let contentView = window.contentView else { return false }
    let heightThreshold = contentView.frame.height - currentLayout.topBarHeight
    let isAboveThreshold = mouseLocInWindow.y >= heightThreshold
    log.trace("Is mouse in top bar? mouseHeight=\(mouseLocInWindow.y) heightThreshold=\(heightThreshold) → \(isAboveThreshold.yn)")
    return isAboveThreshold
  }

  /// Shows fadeables via fade-in animation
  func showFadeableViews(thenRestartFadeTimer restartFadeTimer: Bool = true,
                         duration: CGFloat = Constants.AnimationDuration.standard,
                         forceShowTopBar: Bool = false) {
    guard !player.disableUI && !isInInteractiveMode else { return }

    /// Default `showTopBarTrigger` setting to `.windowHover` if advanced settings not enabled
    let wantsTopBarVisible = forceShowTopBar || (!Preference.isAdvancedEnabled || Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.windowHover)

    guard (wantsTopBarVisible && fadeableViews.topBarAnimationState == .hidden) || (fadeableViews.animationState == .hidden) else {
      if restartFadeTimer {
        fadeableViews.hideTimer.restart()
      } else {
        fadeableViews.hideTimer.cancel()
      }
      return
    }

    let tasks = buildAnimationToShowFadeableViews(targetLayout: currentLayout,
                                                  restartFadeTimer: restartFadeTimer,
                                                  duration: duration,
                                                  forceShowTopBar: wantsTopBarVisible)
    animationPipeline.submit(tasks)
  }

  /// This is only expected to be called by `showFadeableViews()` and by the animation transition builder. Do not call directly from elsewhere.
  func buildAnimationToShowFadeableViews(targetLayout: LayoutState,
                                         restartFadeTimer: Bool = true,
                                         duration: CGFloat,
                                         forceShow: Bool = false,
                                         forceShowTopBar: Bool = false) -> [IINAAnimation.Task] {

    let currentTicket = fadeableViews.$showHideTicketCount.withLock {
      $0 += 1
      return $0
    }

    var fadeables: Set<NSView> = []
    var fadeablesInTopBar: Set<NSView> = []
    var fadeablesInTopBarNative: Set<NSView> = []

    let tasks = [
      IINAAnimation.Task(duration: duration, { [self] in
        // Note to Future Self: stop messing with this logic! It works fine and is fast enough!
        if forceShow {
          // Invalidate any pending shows & hides
          fadeableViews.$showHideTicketCount.withLock { $0 += 1 }
        } else {
          guard fadeableViews.animationState == .hidden || fadeableViews.animationState == .shown else {
            throw IINAError.cancelAnimationTransaction
          }

          guard currentTicket == fadeableViews.showHideTicketCount else {
            if forceShowTopBar {
              fadeableViews.pendingShowTopPanel = true
            }
            throw IINAError.cancelAnimationTransaction
          }
        }

        fadeableViews.animationState = .willShow

        fadeables = fadeableViews.fadeables
        fadeablesInTopBar = fadeableViews.fadeablesInTopBar
        log.verbose("SHOW fadeables: currentTkt=\(currentTicket) latestTkt=\(fadeableViews.showHideTicketCount) dur=\(duration) views=\(fadeables.map{$0.idString}) topBar=\(fadeablesInTopBar.map{$0.idString})")

        fadeableViews.hideTimer.cancel()

        for v in fadeables {
          v.alphaValue = 1
        }

        let pendingShowTopPanel = fadeableViews.pendingShowTopPanel
        let wantsTopBarVisible = forceShowTopBar || pendingShowTopPanel
        if wantsTopBarVisible {  // show top bar
          fadeableViews.pendingShowTopPanel = false
          fadeableViews.topBarAnimationState = .willShow
          for v in fadeablesInTopBar {
            v.alphaValue = 1
          }

          if targetLayout.titleBar == .showFadeableTopBar {
            if !targetLayout.isLegacyStyle {
              if targetLayout.trafficLightButtons == .showFadeableTopBar {
                for button in trafficLightButtons {
                  fadeablesInTopBarNative.insert(button)
                }
              }
              if targetLayout.titleIconAndText == .showFadeableTopBar {
                if let titleTextField {
                  fadeablesInTopBarNative.insert(titleTextField)
                }
                if let documentIconButton {
                  fadeablesInTopBarNative.insert(documentIconButton)
                }
              }
              for fadeableView in fadeablesInTopBarNative {
                fadeableView.alphaValue = 1
              }
            }
          }
        }  // end top bar
      }),

      // Not animated, but needs to wait until after fade is done
      .instantTask { [self] in
        fadeableViews.animationState = .shown
        // Do not cache fadeables for show. But cache them for hide (ensures additionalInfoView is shown/hidden correctly).
        for v in fadeables {
          v.isHidden = false
          v.needsDisplay = true
        }

        if restartFadeTimer {
          fadeableViews.hideTimer.restart()
        }

        if fadeableViews.topBarAnimationState == .willShow {
          fadeableViews.topBarAnimationState = .shown
          for v in fadeablesInTopBar {
            v.isHidden = false
            v.needsDisplay = true
          }
          for fadeableView in fadeablesInTopBarNative {
            fadeableView.isHidden = false
          }

        }  // end top bar
      }  // end Task

    ]

    if duration.isZero {
      return [.instantTask({
        for task in tasks {
          try task.runFunc()
        }
      })]
    } else {
      return tasks
    }
  }

  func hideFadeableViews(targetLayout givenLayout: LayoutState? = nil, hideCursorToo: Bool = false) {
    // Don't hide overlays when in PIP or when they are not actually shown
    let isWindowMinimized = window?.isMiniaturized ?? false
    let targetLayout = givenLayout ?? currentLayout

    guard !targetLayout.isInPiP, !isWindowMinimized else {
      log.trace("Aborting hide of fadeable views: isInPiP=\(targetLayout.isInPiP.yn), windowMinimized=\(isWindowMinimized)")
      return
    }

    // Don't hide UI when auto hide control bar is disabled
    assert(Preference.bool(for: .enableControlBarAutoHide)
           || Preference.bool(for: .hideFadeableViewsWhenOutsideWindow)
           || Preference.enum(for: .singleClickAction) == Preference.MouseClickAction.hideOSC)

    let currentTicket = fadeableViews.$showHideTicketCount.withLock {
      $0 += 1
      return $0
    }


    // Seek time & thumbnail can only be shown if the OSC is visible.
    // Need to hide them because the OSC is being hidden:
    let mustHideSeekPreview = !targetLayout.hasPermanentControlBar
    var fadeables: Set<NSView> = []
    var fadeablesInTopBar: Set<NSView> = []

    let preTask = IINAAnimation.Task.instantTask{ [self] in
      if log.isTraceEnabled {
        log.trace("HIDE fadeables: currentTicket=\(currentTicket), latest=\(fadeableViews.showHideTicketCount)")
      }

      // Ensure we are the most current ticket
      guard currentTicket == fadeableViews.showHideTicketCount else {
        throw IINAError.cancelAnimationTransaction
      }
      guard fadeableViews.animationState == .shown else {
        throw IINAError.cancelAnimationTransaction
      }

      // Do not allow more tasks to be enqueued between now & the first task execution:
      fadeableViews.hideTimer.cancel()

      if isMouseInsideFadeableView(mouseLocationInWindow) {
        log.trace("HIDE fadeables: cancelling; mouse is still in fadeable view")
        throw IINAError.cancelAnimationTransaction
      }
    }

    let fadeTask = IINAAnimation.Task(duration: Constants.AnimationDuration.standard) { [self] in
      fadeableViews.animationState = .willHide
      fadeableViews.topBarAnimationState = .willHide

      // Wait until here to build set! To avoid race
      fadeables = fadeableViews.fadeables
      fadeablesInTopBar = fadeableViews.fadeablesInTopBar

      for v in fadeables {
        v.animator().alphaValue = 0
      }
      for v in fadeablesInTopBar {
        v.animator().alphaValue = 0
      }
      /// Quirk 1: special handling for `trafficLightButtons`
      if targetLayout.titleBar == .showFadeableTopBar {
        if targetLayout.isLegacyStyle {
          customTitleBar?.view.alphaValue = 0
        } else {
          documentIconButton?.alphaValue = 0
          titleTextField?.alphaValue = 0
          for button in trafficLightButtons {
            button.alphaValue = 0
          }
        }
      }

      if mustHideSeekPreview {
        // Hide seek preview & thumbnail
        seekPreview.hideTimer.cancel()
        fadeOutSeekPreview()
      }
    }

    let postTask = IINAAnimation.Task.instantTask { [self] in
      // if no interrupt then hide animation
      guard fadeableViews.animationState == .willHide else {
        assert(false, "Expected fadeableViews.animationState to be .willHide; but found \(fadeableViews.animationState)")
        return
      }

      fadeableViews.animationState = .hidden
      fadeableViews.topBarAnimationState = .hidden
      for v in fadeables {
        v.isHidden = true
      }
      for v in fadeablesInTopBar {
        v.isHidden = true
      }
      /// Quirk 1: need to set `alphaValue` back to `1` so that each button's corresponding menu items still work
      if targetLayout.titleBar == .showFadeableTopBar {
        if targetLayout.isLegacyStyle {
          customTitleBar?.view.isHidden = true
        } else {
          hideNativeTitleBarViews(andSetAlpha: false)
        }
      }

      if mustHideSeekPreview, seekPreview.animationState == .willHide {
        log.trace("Hiding SeekPreview from fadeable views timeout")
        hideSeekPreviewImmediately()
      }

      let pointInWindow = mouseLocationInWindow
      if isMouseInsideFadeableView(pointInWindow) {
        log.verbose("After hiding fadeables: mouse is still in fadeable view; showing again")
        showFadeableViewsForMouseLocation(pointInWindow)
      } else if hideCursorToo {
        hideCursorAsConfigured()
      }
    }

    animationPipeline.submit([preTask, fadeTask, postTask])
  }

  func isMouseInsideFadeableView(_ pointInWindow: NSPoint) -> Bool {
    let fadeables = fadeableViews.fadeables
    let fadeablesInTopBar = fadeableViews.fadeablesInTopBar
    return isPoint(pointInWindow, inAnyOf: fadeables) || isPoint(pointInWindow, inAnyOf: fadeablesInTopBar)
  }

  func hideFadeableViewsAndCursor() {
    // don't hide UI when dragging control bar
    if currentDragObject != nil {
      log.trace("Aborting hide of fadeable views: dragObject != nil")
      return
    }

    hideFadeableViews(hideCursorToo: true)
  }

  /// Executed when `fadeableViews.hideTimer` fires
  @objc func hideTimeoutAction() {
    guard !isMouseInsideFadeableView(mouseLocationInWindow) else { return }
    hideFadeableViewsAndCursor()
  }

}
