//
//  PWLayoutTransitionBuilder.swift
//  iina
//
//  Created by Matt Svoboda on 8/20/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// This file is not really a factory class due to limitations of the AppKit paradigm, but it contain
/// methods for creating/running `LayoutTransition`s to change between `LayoutState`s for the
/// given `PlayerWindowController`.
extension PlayerWindowController {

  // MARK: - Window Initial Layout

  func setInitialWindowLayout() {
    let initialLayout: LayoutState
    let isRestoringFromPrevLaunch: Bool
    var needsNativeFullScreen = false

    // Don't want window resize/move listeners doing something untoward
    isAnimatingLayoutTransition = true

    if let priorState = player.info.priorState, let priorLayoutSpec = priorState.layoutSpec {
      log.verbose("Transitioning to initial layout from prior window state")
      isRestoringFromPrevLaunch = true

      let initialLayoutSpec: LayoutSpec
      if priorLayoutSpec.isNativeFullScreen {
        // Special handling for native fullscreen. Rely on mpv to put us in FS when it is ready
        initialLayoutSpec = priorLayoutSpec.clone(mode: .windowed)
        needsNativeFullScreen = true
      } else {
        initialLayoutSpec = priorLayoutSpec
      }
      initialLayout = LayoutState.buildFrom(initialLayoutSpec)

      configureFromRestore(priorState, initialLayout)

    } else {
      log.verbose("Transitioning to initial layout from app prefs")
      isRestoringFromPrevLaunch = false

      let mode: PlayerWindowMode
      if Preference.bool(for: .fullScreenWhenOpen) {
        log.debug("Changing to fullscreen because \(Preference.Key.fullScreenWhenOpen.rawValue) == true")
        mode = .fullScreen
      } else {
        mode = .windowed
      }

      // Set to default layout, but use existing aspect ratio & video size for now, because we don't have that info yet for the new video
      let initialLayoutSpec = LayoutSpec.fromPreferences(andMode: mode, fillingInFrom: lastWindowedLayoutSpec)
      initialLayout = LayoutState.buildFrom(initialLayoutSpec)

      configureFromPrefs(initialLayout)
    }

    // Send Geometries object to builder so that it doesn't default to current window frame
    let geo = Geometries(windowedMode: windowedModeGeo, musicMode: musicModeGeo, videoAspect: player.info.videoAspect)
    log.verbose("Setting initial \(initialLayout.spec), windowedModeGeo=\(geo.windowedMode), musicModeGeo=\(geo.musicMode)")

    let transitionName = "\(isRestoringFromPrevLaunch ? "Restore" : "Set")InitialLayout"
    let initialTransition = buildLayoutTransition(named: transitionName,
                                                  from: currentLayout, to: initialLayout.spec, isInitialLayout: true, geo)

    // For initial layout (when window is first shown), to reduce jitteriness when drawing,
    // do all the layout in a single animation block
    IINAAnimation.disableAnimation {

      // Set window opacity to 0 initially to start fade-in effect
      updateCustomBorderBoxAndWindowOpacity(using: initialLayout, windowOpacity: 0.0)

      /// Although the animations in the `LayoutTransition` below will set the window layout, they
      /// mostly assume they are incrementally changing a previous layout, which can result in brief visual
      /// artifacts in the process if we start with an undefined layout.
      /// To smooth out the process, restore window position & size before laying out its internals.
      switch initialLayout.spec.mode {
      case .windowed, .windowedInteractive, .musicMode:
        videoView.apply(initialTransition.outputGeometry)
        player.window.setFrameImmediately(initialTransition.outputGeometry.windowFrame)
      case .fullScreen, .fullScreenInteractive:
        /// Don't need to set window frame here because it will be set by `LayoutTransition` to full screen (below).
        /// Similarly, when window exits full screen, the windowed mode position will be restored from `windowedModeGeo`.
        break
      }

      for task in initialTransition.tasks {
        task.runFunc()
      }
      /// Note: `isAnimatingLayoutTransition` should be `false` now
      log.verbose("Done with transition to initial layout")
    }

    if !isRestoringFromPrevLaunch {
      if initialLayout.mode == .windowed {
        player.info.intendedViewportSize = initialTransition.outputGeometry.viewportSize
      }

      if !initialLayout.isFullScreen, Preference.bool(for: .alwaysFloatOnTop) && !player.info.isPaused {
        log.verbose("Setting window OnTop=true per app pref")
        setWindowFloatingOnTop(true)
      }
    }

    if needsNativeFullScreen {
      animationPipeline.submitSudden({ [self] in
        enterFullScreen()
      })
      return
    }

    guard isRestoringFromPrevLaunch else { return }

    /// Stored window state may not be consistent with global IINA prefs.
    /// To check this, build another `LayoutSpec` from the global prefs, then compare it to the player's.
    let prefsSpec = LayoutSpec.fromPreferences(fillingInFrom: currentLayout.spec)
    if initialLayout.spec.hasSamePrefsValues(as: prefsSpec) {
      log.verbose("Saved layout is consistent with IINA global prefs")
    } else {
      // Not consistent. But we already have the correct spec, so just build a layout from it and transition to correct layout
      log.warn("Player's saved layout does not match IINA app prefs. Will fix and apply corrected layout")
      log.debug("SavedSpec: \(currentLayout.spec). PrefsSpec: \(prefsSpec)")
      buildLayoutTransition(named: "FixInvalidInitialLayout",
                            from: initialTransition.outputLayout, to: prefsSpec, thenRun: true)
    }
  }

  private func configureFromRestore(_ priorState: PlayerSaveState, _ initialLayout: LayoutState) {
    // Don't need this because we already know how to size the window
    isInitialSizeDone = true

    // Restore saved geometries
    if let priorWindowedModeGeo = priorState.windowedModeGeo {
      if !priorWindowedModeGeo.mode.isWindowed || priorWindowedModeGeo.fitOption.isFullScreen {
        log.error("While transitioning to initial layout: windowedModeGeo from prior state has invalid mode (\(priorWindowedModeGeo.mode)) or fitOption (\(priorWindowedModeGeo.fitOption)). Will generate a fresh windowedModeGeo from saved layoutSpec and last closed window instead")
        if !PlayerWindowController.windowedModeGeoLastClosed.mode.isWindowed || priorWindowedModeGeo.fitOption.isFullScreen {
          
        }
        windowedModeGeo = initialLayout.convertWindowedModeGeometry(from: PlayerWindowController.windowedModeGeoLastClosed,
                                                                    keepFullScreenDimensions: false)
      } else {
        log.verbose("Setting windowedModeGeo from prior state: \(priorWindowedModeGeo)")
        windowedModeGeo = priorWindowedModeGeo
      }
    } else {
      log.error("Failed to get player window geometry from prefs")
    }

    if let priorMusicModeGeometry = priorState.musicModeGeo {
      log.verbose("Setting musicModeGeo from prior state: \(priorMusicModeGeometry)")
      musicModeGeo = priorMusicModeGeometry
    } else {
      log.error("Failed to get player window layout and/or geometry from prefs")
    }

    if initialLayout.mode == .musicMode {
      player.overrideAutoMusicMode = true
    }
  }

  private func configureFromPrefs(_ initialLayout: LayoutState) {
    // Should only be here if window is a new window or was previously closed. Copy layout from the last closed window
    assert(!isOpen)
    assert(!isInitialSizeDone)

    let resizeTimingPref = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
    if resizeTimingPref == .always || resizeTimingPref == .onlyWhenOpen {
      /// Use `minVideoSize` at first when a new window is opened, so that when `resizeWindowAfterVideoReconfig()` is called shortly after,
      /// it expands and creates a nice zooming effect. But try to start with video's correct aspect, if available
      let videoAspect = player.info.videoAspect
      let viewportSize = PWGeometry.computeMinSize(withAspect: videoAspect,
                                                   minWidth: Constants.WindowedMode.minViewportSize.width,
                                                   minHeight: Constants.WindowedMode.minViewportSize.height)
      let intendedWindowSize = NSSize(width: viewportSize.width + initialLayout.outsideLeadingBarWidth + initialLayout.outsideTrailingBarWidth,
                                      height: viewportSize.height + initialLayout.outsideTopBarHeight + initialLayout.outsideBottomBarHeight)
      let windowFrame = NSRect(origin: NSPoint.zero, size: intendedWindowSize)
      /// Change the window origin so that it opens where the mouse is. This visually reinforces the user-initiated behavior and is less jarring
      /// than popping out of the periphery. The final location will be set after the file is completely done loading (which will be very soon).
      let mouseLoc = NSEvent.mouseLocation
      let mouseLocScreenID = NSScreen.getOwnerOrDefaultScreenID(forPoint: mouseLoc)
      let initialGeo = initialLayout.buildGeometry(windowFrame: windowFrame, screenID: mouseLocScreenID, videoAspect: videoAspect).refit(.stayInside)
      let windowSize = initialGeo.windowFrame.size
      let windowOrigin = NSPoint(x: round(mouseLoc.x - (windowSize.width * 0.5)), y: round(mouseLoc.y - (windowSize.height * 0.5)))
      log.verbose("Initial layout: starting with tiny window, videoAspect=\(videoAspect), windowSize=\(windowSize). Will resize using pref=\(resizeTimingPref)")
      windowedModeGeo = initialGeo.clone(windowFrame: NSRect(origin: windowOrigin, size: windowSize)).refit(.stayInside)
    } else {
      // No configured resize strategy. So just apply the last closed geometry right away, with no extra animations
      log.verbose("Initial layout: using last closed window's geometry")
      windowedModeGeo = initialLayout.convertWindowedModeGeometry(from: PlayerWindowController.windowedModeGeoLastClosed,
                                                                  keepFullScreenDimensions: false)
    }

    // Always use last geometry for music mode window:
    musicModeGeo = PlayerWindowController.musicModeGeoLastClosed
  }

  // MARK: - Building LayoutTransition

  /// First builds a new `LayoutState` based on the given `LayoutSpec`, then builds & returns a `LayoutTransition`,
  /// which contains all the information needed to animate the UI changes from the current `LayoutState` to the new one.
  @discardableResult
  func buildLayoutTransition(named transitionName: String,
                             from inputLayout: LayoutState,
                             to outputSpec: LayoutSpec,
                             isInitialLayout: Bool = false,
                             totalStartingDuration: CGFloat? = nil,
                             totalEndingDuration: CGFloat? = nil,
                             thenRun: Bool = false,
                             _ geo: Geometries? = nil) -> LayoutTransition {

    // use latest window frame in case it exists and was moved
    let geo = geo ?? self.geo(from: inputLayout)

    var transitionID: Int = 0
    $layoutTransitionCounter.withLock {
      $0 += 1
      transitionID = $0
    }
    let transitionName = "\(transitionName)-\(transitionID)"

    // This also applies to full screen, because full screen always uses the same screen as windowed.
    // Does not apply to music mode, which can be a different screen.
    let windowedModeScreen = NSScreen.getScreenOrDefault(screenID: geo.windowedMode.screenID)

    // Compile outputLayout
    let outputLayout = LayoutState.buildFrom(outputSpec)

    // - Build geometries

    // InputGeometry
    let inputGeometry: PWGeometry = buildInputGeometry(from: inputLayout, transitionName: transitionName, geo, windowedModeScreen: windowedModeScreen)
    log.verbose("[\(transitionName)] InputGeometry: \(inputGeometry)")

    // OutputGeometry
    let outputGeometry: PWGeometry = buildOutputGeometry(inputLayout: inputLayout, inputGeometry: inputGeometry,
                                                         outputLayout: outputLayout, geo, isInitialLayout: isInitialLayout)

    let transition = LayoutTransition(name: transitionName,
                                      from: inputLayout, from: inputGeometry,
                                      to: outputLayout, to: outputGeometry,
                                      isInitialLayout: isInitialLayout)

    // MiddleGeometry if needed (is applied after ClosePanels step)
    transition.middleGeometry = buildMiddleGeometry(forTransition: transition, geo)
    if let middleGeometry = transition.middleGeometry {
      log.verbose("[\(transitionName)] MiddleGeometry: \(middleGeometry)")
    } else {
      log.verbose("[\(transitionName)] MiddleGeometry: nil")
    }

    log.verbose("[\(transitionName)] OutputGeometry: \(outputGeometry)")

    let closeOldPanelsTiming: CAMediaTimingFunctionName
    let openFinalPanelsTiming: CAMediaTimingFunctionName
    let fadeInNewViewsTiming: CAMediaTimingFunctionName = .linear
    if transition.isTogglingFullScreen {
      closeOldPanelsTiming = .easeInEaseOut
      openFinalPanelsTiming = .easeInEaseOut
    } else if transition.isTogglingVisibilityOfAnySidebar {
      closeOldPanelsTiming = .easeIn
      openFinalPanelsTiming = .easeIn
    } else if transition.isExitingInteractiveMode {
      closeOldPanelsTiming = .easeOut
      openFinalPanelsTiming = .linear
    } else {
      closeOldPanelsTiming = .linear
      openFinalPanelsTiming = .linear
    }

    // - Determine durations

    var startingAnimationDuration = IINAAnimation.DefaultDuration
    if transition.isEnteringFullScreen {
      startingAnimationDuration = 0
    } else if transition.isEnteringMusicMode && !transition.isExitingFullScreen {
      startingAnimationDuration = IINAAnimation.DefaultDuration
    } else if let totalStartingDuration = totalStartingDuration {
      startingAnimationDuration = totalStartingDuration / 3
    }

    var showFadeableViewsDuration: CGFloat = startingAnimationDuration
    var fadeOutOldViewsDuration: CGFloat = startingAnimationDuration
    var closeOldPanelsDuration: CGFloat = startingAnimationDuration
    if transition.isEnteringMusicMode && !transition.isExitingFullScreen {
      showFadeableViewsDuration = startingAnimationDuration * 0.5
      fadeOutOldViewsDuration = startingAnimationDuration * 0.5
    } else if transition.isEnteringInteractiveMode {
      showFadeableViewsDuration = startingAnimationDuration * 0.25
      fadeOutOldViewsDuration = startingAnimationDuration * 0.5
    } else if transition.isExitingInteractiveMode {
      showFadeableViewsDuration = 0
      fadeOutOldViewsDuration = startingAnimationDuration * 0.5
    } else {
      if !transition.needsAnimationForShowFadeables {
        showFadeableViewsDuration = 0
      }
      if !transition.needsFadeOutOldViews {
        fadeOutOldViewsDuration = 0
      }
      if !transition.needsCloseOldPanels {
        closeOldPanelsDuration = 0
      }
    }

    let endingAnimationDuration: CGFloat = totalEndingDuration ?? IINAAnimation.DefaultDuration

    // Extra animation when entering legacy full screen: cover camera housing with black bar
    let useExtraAnimationForEnteringLegacyFullScreen = transition.isEnteringLegacyFullScreen && windowedModeScreen.hasCameraHousing && !transition.isInitialLayout && endingAnimationDuration > 0.0

    var fadeInNewViewsDuration = endingAnimationDuration * 0.5
    var openFinalPanelsDuration = endingAnimationDuration
    if useExtraAnimationForEnteringLegacyFullScreen {
      openFinalPanelsDuration *= 0.8
    } else if transition.isEnteringInteractiveMode {
      openFinalPanelsDuration *= 0.5
      fadeInNewViewsDuration *= 0.5
    } else {
      if !transition.needsFadeInNewViews {
        fadeInNewViewsDuration = 0
      }
      if !transition.needsAnimationForOpenFinalPanels {
        openFinalPanelsDuration = 0
      }
    }

    log.verbose("[\(transitionName)] Task durations: ShowOldFadeables=\(showFadeableViewsDuration), FadeOutOldViews:\(fadeOutOldViewsDuration), CloseOldPanels:\(closeOldPanelsDuration), FadeInNewViews:\(fadeInNewViewsDuration), OpenFinalPanels:\(openFinalPanelsDuration)")

    // - Starting animations:

    // 0: Set initial var or other tasks which happen before main animations
    transition.tasks.append(IINAAnimation.suddenTask{ [self] in
      doPreTransitionWork(transition)
    })

    // StartingAnimation 1: Show fadeable views from current layout
    for fadeAnimation in buildAnimationToShowFadeableViews(restartFadeTimer: false, duration: showFadeableViewsDuration, forceShowTopBar: true) {
      transition.tasks.append(fadeAnimation)
    }

    // StartingAnimation 2: Fade out views which no longer will be shown but aren't enclosed in a panel.
    if transition.needsFadeOutOldViews {
      transition.tasks.append(IINAAnimation.Task(duration: fadeOutOldViewsDuration, { [self] in
        fadeOutOldViews(transition)
      }))
    }

    // StartingAnimation 3: Close/Minimize panels which are no longer needed. Applies middleGeometry if it exists.
    // Not enabled for fullScreen transitions.
    if transition.needsCloseOldPanels {
      transition.tasks.append(IINAAnimation.Task(duration: closeOldPanelsDuration, timing: closeOldPanelsTiming, { [self] in
        closeOldPanels(transition)
      }))
    }

    // - Middle animations:

    // 0: Middle point: update style & constraints. Should have minimal visual changes
    transition.tasks.append(IINAAnimation.suddenTask{ [self] in
      // This also can change window styleMask
      updateHiddenViewsAndConstraints(transition)
    })

    // Extra task when entering or exiting music mode: move & resize video frame
    if transition.isTogglingMusicMode && !transition.isInitialLayout {
      transition.tasks.append(IINAAnimation.Task(duration: closeOldPanelsDuration, timing: .easeInEaseOut, { [self] in
        log.verbose("[\(transition.name)] Moving & resizing window")

        let intermediateGeo = transition.outputGeometry.clone(windowFrame: transition.outputGeometry.videoFrameInScreenCoords, topMarginHeight: 0,
                                                              outsideTopBarHeight: 0, outsideTrailingBarWidth: 0,
                                                              outsideBottomBarHeight: 0, outsideLeadingBarWidth: 0,
                                                              insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                                              insideBottomBarHeight: 0, insideLeadingBarWidth: 0)
        videoView.apply(intermediateGeo)
        player.window.setFrameImmediately(intermediateGeo.windowFrame)
        if transition.isEnteringMusicMode && !musicModeGeo.isVideoVisible {
          // Entering music mode when album art is hidden
          miniPlayer.updateVideoViewVisibilityConstraints(isVideoVisible: false)
        }
      }))
    }

    // - Ending animations:

    // EndingAnimation: Open new panels and fade in new views
    transition.tasks.append(IINAAnimation.Task(duration: openFinalPanelsDuration, timing: openFinalPanelsTiming, { [self] in
      // If toggling fullscreen, this also changes the window frame:
      openNewPanelsAndFinalizeOffsets(transition)

      if transition.isTogglingFullScreen {
        // Full screen animations don't have much time. Combine fadeIn step in same animation:
        fadeInNewViews(transition)
      }
    }))

    // EndingAnimation: Fade in new views
    if transition.needsFadeInNewViews {
      transition.tasks.append(IINAAnimation.Task(duration: fadeInNewViewsDuration, timing: fadeInNewViewsTiming, { [self] in
        fadeInNewViews(transition)
      }))
    }

    // If entering legacy full screen, will add an extra animation to hiding camera housing / menu bar / dock
    if useExtraAnimationForEnteringLegacyFullScreen {
      transition.tasks.append(IINAAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
        let topBlackBarHeight = Preference.bool(for: .allowVideoToOverlapCameraHousing) ? 0 : windowedModeScreen.cameraHousingHeight ?? 0
        let newGeo = transition.outputGeometry.clone(windowFrame: windowedModeScreen.frame, screenID: windowedModeScreen.screenID, topMarginHeight: topBlackBarHeight)
        log.verbose("[\(transition.name)] Updating legacy FS window to cover camera housing / menu bar / dock")
        applyLegacyFSGeo(newGeo)
      }))
    }

    // After animations all finish
    transition.tasks.append(IINAAnimation.suddenTask{ [self] in
      doPostTransitionWork(transition)
    })

    if thenRun {
      animationPipeline.submit(transition.tasks)
    }
    return transition
  }

  // MARK: - Geometry

  /// Builds `inputGeometry`.
  private func buildInputGeometry(from inputLayout: LayoutState, transitionName: String, _ geo: Geometries, windowedModeScreen: NSScreen) -> PWGeometry {
    // Restore window size & position
    switch inputLayout.mode {
    case .windowed:
      return geo.windowedMode
    case .fullScreen, .fullScreenInteractive:
      return inputLayout.buildFullScreenGeometry(inside: windowedModeScreen, videoAspect: geo.videoAspect)
    case .windowedInteractive:
      /// `geo.windowedMode` should already be correct for interactiveWindowed mode, but it is easy enough to derive it
      /// from a small number of variables, and safer to do that than assume it is correct:
      return PWGeometry.buildInteractiveModeWindow(windowFrame: geo.windowedMode.windowFrame, screenID: geo.windowedMode.screenID,
                                                   videoAspect: geo.windowedMode.videoAspect)
    case .musicMode:
      /// `musicModeGeo` should have already been deserialized and set.
      /// But make sure we correct any size problems
      return geo.musicMode.refit().toPWGeometry()
    }
  }

  /// Builds `outputGeometry`.
  /// Note that the result should not necessarily overrite `windowedModeGeo`. It is used by the transition animations.
  private func buildOutputGeometry(inputLayout: LayoutState, inputGeometry: PWGeometry, 
                                   outputLayout: LayoutState, _ geo: Geometries, isInitialLayout: Bool) -> PWGeometry {

    switch outputLayout.mode {
    case .windowed:
      let prevWindowedGeo: PWGeometry
      if inputGeometry.mode == .windowedInteractive {
        /// `windowedInteractive` -> `windowed`
        log.verbose("Exiting interactive mode: converting windowedInteractive geo to windowed for outputGeo")
        prevWindowedGeo = inputGeometry.fromWindowedInteractiveMode()
      } else if geo.windowedMode.mode == .windowedInteractive {
        prevWindowedGeo = geo.windowedMode.fromWindowedInteractiveMode()
      } else {
        prevWindowedGeo = geo.windowedMode
      }
      return outputLayout.convertWindowedModeGeometry(from: prevWindowedGeo, videoAspect: inputGeometry.videoAspect,
                                                      keepFullScreenDimensions: !isInitialLayout)

    case .windowedInteractive:
      if inputGeometry.mode == .windowedInteractive {
        log.verbose("Already in interactive mode: converting windowed geo to interactiveWindowed for outputGeo")
        return PWGeometry.buildInteractiveModeWindow(windowFrame: geo.windowedMode.windowFrame, screenID: geo.windowedMode.screenID,
                                                     videoAspect: geo.windowedMode.videoAspect)
      } else if inputGeometry.mode == .fullScreenInteractive {
        if geo.windowedMode.mode == .windowedInteractive {
          return PWGeometry.buildInteractiveModeWindow(windowFrame: geo.windowedMode.windowFrame, screenID: geo.windowedMode.screenID,
                                                       videoAspect: inputGeometry.videoAspect)
        }
        return geo.windowedMode.clone(videoAspect: inputGeometry.videoAspect).toInteractiveMode()
      }
      /// Entering interactive mode: convert from `windowed` to `windowedInteractive`
      return inputGeometry.toInteractiveMode()

    case .fullScreen, .fullScreenInteractive:
      // Full screen always uses same screen as windowed mode
      return outputLayout.buildFullScreenGeometry(inScreenID: inputGeometry.screenID, videoAspect: geo.videoAspect)

    case .musicMode:
      /// `videoAspect` may have gone stale while not in music mode. Update it (playlist height will be recalculated if needed):
      let musicModeGeoCorrected = geo.musicMode.clone(videoAspect: geo.videoAspect).refit()
      return musicModeGeoCorrected.toPWGeometry()

    }
  }

  /// Builds `middleGeometry`.
  // Currently there are 4 bars. Each can be either inside or outside, exclusively.
  func buildMiddleGeometry(forTransition transition: LayoutTransition, _ geo: Geometries) -> PWGeometry? {
    if transition.isTogglingInteractiveMode {
      if transition.inputLayout.isFullScreen {
        // Need to hide sidebars when entering interactive mode in full screen
        return transition.outputGeometry
      }

      let outsideTopBarHeight = transition.inputLayout.outsideTopBarHeight >= transition.outputLayout.topBarHeight ? transition.outputLayout.outsideTopBarHeight : 0

      if transition.isEnteringInteractiveMode {
        return transition.outputGeometry

      } else if transition.isExitingInteractiveMode {
        let videoFrame = transition.outputGeometry.videoFrameInScreenCoords
        let extraWidthNeeded = max(0, Constants.InteractiveMode.minWindowWidth - videoFrame.width)
        let newWindowFrame = NSRect(origin: NSPoint(x: videoFrame.origin.x - (extraWidthNeeded * 0.5), y: videoFrame.origin.y),
                                    size: CGSize(width: videoFrame.width + extraWidthNeeded, height: videoFrame.height + outsideTopBarHeight))
        let resizedGeo = PWGeometry(windowFrame: newWindowFrame, screenID: transition.outputGeometry.screenID, fitOption: transition.outputGeometry.fitOption, mode: .windowed, topMarginHeight: 0, outsideTopBarHeight: outsideTopBarHeight, outsideTrailingBarWidth: 0, outsideBottomBarHeight: 0, outsideLeadingBarWidth: 0, insideTopBarHeight: 0, insideTrailingBarWidth: 0, insideBottomBarHeight: 0, insideLeadingBarWidth: 0, videoAspect: transition.outputGeometry.videoAspect)
        return resizedGeo
      }

    } else if transition.isEnteringMusicMode {
      let baseGeo: PWGeometry
      if transition.inputLayout.isFullScreen {
        // Need middle geo so that sidebars get closed
        baseGeo = geo.musicMode.clone(videoAspect: geo.videoAspect, isPlaylistVisible: false).toPWGeometry()
      } else {
        baseGeo = transition.inputGeometry
      }

      let middleWindowFrame = baseGeo.videoFrameInScreenCoords
      return PWGeometry(windowFrame: middleWindowFrame, screenID: baseGeo.screenID,
                        fitOption: baseGeo.fitOption, mode: .musicMode, topMarginHeight: 0,
                        outsideTopBarHeight: 0, outsideTrailingBarWidth: 0, outsideBottomBarHeight: 0, outsideLeadingBarWidth: 0,
                        insideTopBarHeight: 0, insideTrailingBarWidth: 0, insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                        videoAspect: baseGeo.videoAspect)
    } else if transition.isExitingMusicMode {
      if transition.isEnteringFullScreen {
        return nil
      }
      // Only bottom bar needs to be closed. No need to constrain in screen
      return transition.inputGeometry.withResizedOutsideBars(newOutsideBottomBarHeight: 0)
    }

    // TOP
    let topBarHeight: CGFloat
    if !transition.isInitialLayout && transition.isTopBarPlacementChanging {
      topBarHeight = 0  // close completely. will animate reopening if needed later
    } else if transition.outputLayout.topBarHeight < transition.inputLayout.topBarHeight {
      topBarHeight = transition.outputLayout.topBarHeight
    } else {
      topBarHeight = transition.inputLayout.topBarHeight  // leave the same
    }
    let insideTopBarHeight = transition.outputLayout.topBarPlacement == .insideViewport ? topBarHeight : 0
    let outsideTopBarHeight = transition.outputLayout.topBarPlacement == .outsideViewport ? topBarHeight : 0

    // BOTTOM
    let insideBottomBarHeight: CGFloat
    let outsideBottomBarHeight: CGFloat
    if !transition.isInitialLayout && transition.isBottomBarPlacementChanging || transition.isTogglingMusicMode {
      // close completely. will animate reopening if needed later
      insideBottomBarHeight = 0
      outsideBottomBarHeight = 0
    } else if transition.outputGeometry.outsideBottomBarHeight < transition.inputGeometry.outsideBottomBarHeight {
      insideBottomBarHeight = 0
      outsideBottomBarHeight = transition.outputGeometry.outsideBottomBarHeight
    } else if transition.outputGeometry.insideBottomBarHeight < transition.inputGeometry.insideBottomBarHeight {
      insideBottomBarHeight = transition.outputGeometry.insideBottomBarHeight
      outsideBottomBarHeight = 0
    } else {
      insideBottomBarHeight = transition.inputGeometry.insideBottomBarHeight
      outsideBottomBarHeight = transition.inputGeometry.outsideBottomBarHeight
    }

    // LEADING
    let insideLeadingBarWidth: CGFloat
    let outsideLeadingBarWidth: CGFloat
    if transition.isHidingLeadingSidebar {
      insideLeadingBarWidth = 0
      outsideLeadingBarWidth = 0
    } else {
      insideLeadingBarWidth = transition.inputGeometry.insideLeadingBarWidth
      outsideLeadingBarWidth = transition.inputGeometry.outsideLeadingBarWidth
    }

    // TRAILING
    let insideTrailingBarWidth: CGFloat
    let outsideTrailingBarWidth: CGFloat
    if transition.isHidingTrailingSidebar {
      insideTrailingBarWidth = 0
      outsideTrailingBarWidth = 0
    } else {
      insideTrailingBarWidth = transition.inputGeometry.insideTrailingBarWidth
      outsideTrailingBarWidth = transition.inputGeometry.outsideTrailingBarWidth
    }

    if transition.outputLayout.isFullScreen {
      let screen = NSScreen.getScreenOrDefault(screenID: transition.inputGeometry.screenID)
      return PWGeometry.forFullScreen(in: screen, legacy: transition.outputLayout.isLegacyFullScreen,
                                      mode: transition.outputLayout.mode,
                                      outsideTopBarHeight: outsideTopBarHeight,
                                      outsideTrailingBarWidth: outsideTrailingBarWidth,
                                      outsideBottomBarHeight: outsideBottomBarHeight,
                                      outsideLeadingBarWidth: outsideLeadingBarWidth,
                                      insideTopBarHeight: insideTopBarHeight,
                                      insideTrailingBarWidth: insideTrailingBarWidth,
                                      insideBottomBarHeight: insideBottomBarHeight,
                                      insideLeadingBarWidth: insideLeadingBarWidth,
                                      videoAspect: transition.outputGeometry.videoAspect,
                                      allowVideoToOverlapCameraHousing: transition.outputLayout.hasTopPaddingForCameraHousing)
    }

    let resizedBarsGeo = transition.outputGeometry.withResizedBars(outsideTopBarHeight: outsideTopBarHeight,
                                                                   outsideTrailingBarWidth: outsideTrailingBarWidth,
                                                                   outsideBottomBarHeight: outsideBottomBarHeight,
                                                                   outsideLeadingBarWidth: outsideLeadingBarWidth,
                                                                   insideTopBarHeight: insideTopBarHeight,
                                                                   insideTrailingBarWidth: insideTrailingBarWidth,
                                                                   insideBottomBarHeight: insideBottomBarHeight,
                                                                   insideLeadingBarWidth: insideLeadingBarWidth,
                                                                   keepFullScreenDimensions: true)
    return resizedBarsGeo.refit()
  }

  // MARK: - Geometries

  struct Geometries {
    let windowedMode: PWGeometry
    let musicMode: MusicModeGeometry
    let videoAspect: CGFloat

    init(windowedMode: PWGeometry, musicMode: MusicModeGeometry, videoAspect: CGFloat) {
      self.windowedMode = windowedMode
      self.musicMode = musicMode
      self.videoAspect = videoAspect
    }
  }

  func geo(windowed: PWGeometry? = nil, musicMode: MusicModeGeometry? = nil, 
           videoAspect: CGFloat? = nil, from inputLayout: LayoutState? = nil) -> Geometries {
    let latestFrame = window?.frame
    return Geometries(windowedMode: windowed ?? ((inputLayout?.mode.isWindowed ?? false) ? windowedModeGeo.clone(windowFrame: latestFrame, screenID: bestScreen.screenID) : windowedModeGeo),
                      musicMode: musicMode ?? ((inputLayout?.mode == .musicMode) ? musicModeGeo.clone(windowFrame: latestFrame, screenID: bestScreen.screenID) : musicModeGeo),
                      videoAspect: videoAspect ?? self.player.info.videoAspect)
  }

}
