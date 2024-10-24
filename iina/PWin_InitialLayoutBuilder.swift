//
//  PWInitialLayoutBldr.swift
//  iina
//
//  Created by Matt Svoboda on 8/5/24.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

/// Window Initial Layout
extension PlayerWindowController {


  enum WindowStateAtManualOpen: CustomStringConvertible {
    /// Not manually opening the file (i.e. current media changed via playlist navigation)
    case notApplicable

    /// Opening window (or reopening closed window) for new file
    case notOpen

    /// Reusing the existing window for new file
    case alreadyOpen

    /// Restoring the window from prior launch
    case restoring(playerState: PlayerSaveState)

    /// Need to specify this so that `playerState` is not included...
    var description: String {
      switch self {
      case .notApplicable:
        "notApplicable"
      case .notOpen:
        "notOpen"
      case .alreadyOpen:
        "alreadyOpen"
      case .restoring:
        "restoring"
      }
    }
  }

  /// Builds tasks to transition the window to its "initial" layout.
  ///
  /// Sets the window layout when one of the following is happening:
  /// 1. Opening window for new file
  /// 2. Reusing existing window for new file
  /// 3. Restoring from prior launch.
  ///
  /// See `WindowStateAtManualOpen`.
  func buildWindowInitialLayoutTasks(windowState: WindowStateAtManualOpen,
                                     currentPlayback: Playback,
                                     currentMediaAudioStatus: PlaybackInfo.CurrentMediaAudioStatus,
                                     newVidGeo: VideoGeometry,
                                     showDefaultArt: Bool? = nil) -> (LayoutState, [IINAAnimation.Task]) {
    assert(DispatchQueue.isExecutingIn(.main))

    var isRestoring = false
    var needsNativeFullScreen = false
    var tasks: [IINAAnimation.Task]
    let initialLayout: LayoutState

    switch windowState {
    case .restoring(let priorState):
      if let priorLayoutSpec = priorState.layoutSpec {
        log.verbose("[applyVideoGeo FileOpen] Transitioning to initial layout from prior window state")
        isRestoring = true

        let initialLayoutSpec: LayoutSpec
        if priorLayoutSpec.isNativeFullScreen {
          // Special handling for native fullscreen. Rely on mpv to put us in FS when it is ready
          initialLayoutSpec = priorLayoutSpec.clone(mode: .windowed)
          needsNativeFullScreen = true
        } else {
          initialLayoutSpec = priorLayoutSpec
        }
        initialLayout = LayoutState.buildFrom(initialLayoutSpec)
      } else {
        log.error("[applyVideoGeo FileOpen] Failed to read LayoutSpec object for restore! Will try to assemble window from prefs instead")
        let layoutSpecFromPrefs = LayoutSpec.fromPreferences(andMode: .windowed, fillingInFrom: lastWindowedLayoutSpec)
        initialLayout = LayoutState.buildFrom(layoutSpecFromPrefs)
      }

      let newGeoSet = configureFromRestore(priorState, initialLayout)
      tasks = buildTransitionTasks(from: currentLayout, to: initialLayout, newGeoSet,
                                   isRestoringFromPrevLaunch: isRestoring,
                                   needsNativeFullScreen: needsNativeFullScreen)

    case .alreadyOpen:
      initialLayout = currentLayout
      log.verbose("[applyVideoGeo FileOpen] Opening a new file in an already open window, mode=\(initialLayout.mode)")
      guard let window = self.window else { return (initialLayout, []) }

      /// `windowFrame` may be slightly off; update it
      if initialLayout.mode == .windowed {
        /// Set this so that `applyVideoGeoTransform` will use the correct default window frame if it looks for it.
        /// Side effect: future opened windows may use this size even if this window wasn't closed. Should be ok?
        PlayerWindowController.windowedModeGeoLastClosed = initialLayout.buildGeometry(windowFrame: window.frame,
                                                                                       screenID: bestScreen.screenID,
                                                                                       video: newVidGeo)
      } else if initialLayout.mode == .musicMode {
        /// Set this so that `applyVideoGeoTransform` will use the correct default window frame if it looks for it.
        PlayerWindowController.musicModeGeoLastClosed = musicModeGeo.clone(windowFrame: window.frame,
                                                                           screenID: bestScreen.screenID,
                                                                           video: newVidGeo)
      }
      // No additional layout needed
      tasks = []

    case .notOpen:
      log.verbose("[applyVideoGeo FileOpen] Transitioning to initial layout from app prefs")
      var mode: PlayerWindowMode = .windowed

      if Preference.bool(for: .autoSwitchToMusicMode) && currentMediaAudioStatus.isAudio {
        log.debug("[applyVideoGeo FileOpen] Opened media is audio: will auto-switch to music mode")
        mode = .musicMode
      } else if Preference.bool(for: .fullScreenWhenOpen) {
        player.didEnterFullScreenViaUserToggle = false
        let useLegacyFS = Preference.bool(for: .useLegacyFullScreen)
        log.debug("[applyVideoGeo] Changing to \(useLegacyFS ? "legacy " : "")fullscreen because \(Preference.Key.fullScreenWhenOpen.rawValue)==Y")
        if useLegacyFS {
          mode = .fullScreen
        } else {
          needsNativeFullScreen = true
        }
      }

      // Set to default layout, but use existing aspect ratio & video size for now, because we don't have that info yet for the new video
      let layoutSpecFromPrefs = LayoutSpec.fromPreferences(andMode: mode, fillingInFrom: lastWindowedLayoutSpec)
      initialLayout = LayoutState.buildFrom(layoutSpecFromPrefs)
      let newGeoSet = configureFromPrefs(initialLayout, newVidGeo)

      tasks = buildTransitionTasks(from: currentLayout, to: initialLayout, newGeoSet, isRestoringFromPrevLaunch: false,
                                   needsNativeFullScreen: needsNativeFullScreen)
    default:
      Logger.fatal("Invalid WindowStateAtManualOpen state: \(windowState)")
    }

    tasks.append(.instantTask{ [self] in
      defer {
        // If is network resource, may not be loaded yet. If file, it will be.
        if let currentPlayback = player.info.currentPlayback,
           currentPlayback.state.isAtLeast(.loaded) {
          player.postNotification(.iinaFileLoaded)
          player.events.emit(.fileLoaded, data: currentPlayback.url.absoluteString)
        }
        /// This will fire a notification to `AppDelegate` which will respond by calling `showWindow` when all windows are ready. Post this always.
        window?.postWindowIsReadyToShow()
      }

      player.refreshSyncUITimer()
      player.touchBarSupport.setupTouchBarUI()

      if let showDefaultArt {
        // May need to set this while restoring a network audio stream
        updateDefaultArtVisibility(to: showDefaultArt)
      }

      /// This check is after `reloadSelectedTracks` which will ensure that `info.aid` will have been updated with the
      /// current audio track selection, or `0` if none selected.
      /// Before `fileLoaded` it may change to `0` while the track info is still being processed, but this is unhelpful
      /// because it can mislead us into thinking that the user has deselected the audio track.
      if player.info.aid == 0 {
        muteButton.isEnabled = false
        volumeSlider.isEnabled = false
      }

      hideSeekTimeAndThumbnail()
      quickSettingView.reload()
      updateTitle()
      playlistView.scrollPlaylistToCurrentItem()

      // FIXME: here be race conditions
      if case .alreadyOpen = windowState {
        // Need to switch to music mode?
        if Preference.bool(for: .autoSwitchToMusicMode) {
          if player.overrideAutoMusicMode {
            log.verbose("[applyVideoGeo FileOpen] Skipping music mode auto-switch ∴ overrideAutoMusicMode=Y")
          } else if currentMediaAudioStatus.isAudio && !isInMiniPlayer && !isFullScreen {
            log.debug("[applyVideoGeo FileOpen] Opened media is audio: auto-switching to music mode")
            player.enterMusicMode(automatically: true, withNewVidGeo: newVidGeo)
            return  // do not even try to go to full screen if already going to music mode
          } else if currentMediaAudioStatus == .notAudio && isInMiniPlayer {
            log.debug("[applyVideoGeo FileOpen] Opened media is not audio: auto-switching to normal window")
            player.exitMusicMode(automatically: true, withNewVidGeo: newVidGeo)
            return  // do not even try to go to full screen if already going to windowed mode
          }
        }

        // Need to switch to full screen?
        if Preference.bool(for: .fullScreenWhenOpen) && !isFullScreen && !isInMiniPlayer {
          log.debug("[applyVideoGeo FileOpen] Changing to full screen because \(Preference.Key.fullScreenWhenOpen.rawValue)==Y")
          enterFullScreen()
        }
      }
    })

    return (initialLayout, tasks)
  }

  /// Generates animation tasks to adjust the window layout appropriately for a newly opened file.
  private func buildTransitionTasks(from inputLayout: LayoutState, to outputLayout: LayoutState, _ newGeoSet: GeometrySet,
                                    isRestoringFromPrevLaunch: Bool, needsNativeFullScreen: Bool) -> [IINAAnimation.Task] {

    var tasks: [IINAAnimation.Task] = []

    // Don't want window resize/move listeners doing something untoward
    isAnimatingLayoutTransition = true

    // Send GeometrySet object to builder so that it doesn't default to current window frame
    log.verbose("Setting initial \(outputLayout.spec), windowedModeGeo=\(newGeoSet.windowed), musicModeGeo=\(newGeoSet.musicMode)")

    let transitionName = "\(isRestoringFromPrevLaunch ? "Restore" : "Set")InitialLayout"
    let initialTransition = buildLayoutTransition(named: transitionName,
                                                  from: currentLayout, to: outputLayout.spec, isWindowInitialLayout: true, newGeoSet)

    tasks.append(.instantTask { [self] in

      // For initial layout (when window is first shown), to reduce jitteriness when drawing, do all the layout
      // in a single animation block.

      do {
        for task in initialTransition.tasks {
          try task.runFunc()
        }
      } catch {
        log.error("Failed to run initial layout tasks: \(error)")
      }

      if !isRestoringFromPrevLaunch {
        if outputLayout.mode == .windowed {
          player.info.intendedViewportSize = initialTransition.outputGeometry.viewportSize

          // Set window opacity to 0 initially to start fade-in effect
          updateWindowBorderAndOpacity(using: outputLayout, windowOpacity: 0.0)
        }

        if !outputLayout.isFullScreen, Preference.bool(for: .alwaysFloatOnTop) && !player.info.isPaused {
          log.verbose("Setting window OnTop=Y per app pref")
          setWindowFloatingOnTop(true)
        }
      }

      /// Note: `isAnimatingLayoutTransition` should be `false` now
      log.verbose("Done with transition to initial layout")
    })

    if needsNativeFullScreen {
      tasks.append(.instantTask { [self] in
        enterFullScreen()
      })
      return tasks
    }

    if isRestoringFromPrevLaunch {
      /// Stored window state may not be consistent with global IINA prefs.
      /// To check this, build another `LayoutSpec` from the global prefs, then compare it to the player's.
      let prefsSpec = LayoutSpec.fromPreferences(fillingInFrom: outputLayout.spec)
      if outputLayout.spec.hasSamePrefsValues(as: prefsSpec) {
        log.verbose("Saved layout is consistent with IINA global prefs")
      } else {
        // Not consistent. But we already have the correct spec, so just build a layout from it and transition to correct layout
        log.warn("Player's saved layout does not match IINA app prefs. Will fix & apply corrected layout")
        log.debug("SavedSpec: \(currentLayout.spec). PrefsSpec: \(prefsSpec)")
        let transition = buildLayoutTransition(named: "FixInvalidInitialLayout",
                                               from: initialTransition.outputLayout, to: prefsSpec)

        tasks.append(contentsOf: transition.tasks)
      }
    }
    return tasks
  }

  private func configureFromRestore(_ priorState: PlayerSaveState, _ initialLayout: LayoutState) -> GeometrySet {
    log.verbose("Setting geometries from prior state, windowed=\(priorState.geoSet.windowed), musicMode=\(priorState.geoSet.musicMode)")

    if initialLayout.mode == .musicMode {
      player.overrideAutoMusicMode = true
    }

    // Clean up windowedModeGeo if serious errors found with it
    let priorWindowedModeGeo = priorState.geoSet.windowed
    if !priorWindowedModeGeo.mode.isWindowed || priorWindowedModeGeo.fitOption.isFullScreen {
      log.error("While transitioning to initial layout: windowedModeGeo from prior state has invalid mode (\(priorWindowedModeGeo.mode)) or fitOption (\(priorWindowedModeGeo.fitOption)). Will generate a fresh windowedModeGeo from saved layoutSpec and last closed window instead")
      let lastClosedGeo = PlayerWindowController.windowedModeGeoLastClosed
      let windowed: PWinGeometry
      if lastClosedGeo.mode.isWindowed && !lastClosedGeo.fitOption.isFullScreen {
        windowed = initialLayout.convertWindowedModeGeometry(from: lastClosedGeo, video: priorState.geoSet.video,
                                                             keepFullScreenDimensions: false)
      } else {
        windowed = initialLayout.buildDefaultInitialGeometry(screen: bestScreen, video: priorState.geoSet.video)
      }
      return priorState.geoSet.clone(windowed: windowed)
    }
    return priorState.geoSet
  }

  private func configureFromPrefs(_ initialLayout: LayoutState, _ videoGeo: VideoGeometry) -> GeometrySet {
    // Should only be here if window is a new window or was previously closed. Copy layout from the last closed window

    let windowedModeGeo: PWinGeometry
    let musicModeGeo = PlayerWindowController.musicModeGeoLastClosed.clone(video: videoGeo)

    if initialLayout.isFullScreen {
      windowedModeGeo = PlayerWindowController.windowedModeGeoLastClosed

    } else if initialLayout.isMusicMode {
      windowedModeGeo = PlayerWindowController.windowedModeGeoLastClosed

    } else {
      /// Use `minVideoSize` at first when a new window is opened, so that when `applyVideoGeoTransform()` is called shortly after,
      /// it expands and creates a nice zooming effect. But try to start with video's correct aspect, if available
      let viewportSize = CGSize.computeMinSize(withAspect: videoGeo.videoViewAspect,
                                               minWidth: Constants.WindowedMode.minViewportSize.width,
                                               minHeight: Constants.WindowedMode.minViewportSize.height)
      let intendedWindowSize = NSSize(width: viewportSize.width + initialLayout.outsideLeadingBarWidth + initialLayout.outsideTrailingBarWidth,
                                      height: viewportSize.height + initialLayout.outsideTopBarHeight + initialLayout.outsideBottomBarHeight)
      let windowFrame = NSRect(origin: NSPoint.zero, size: intendedWindowSize)
      /// Change the window origin so that it opens where the mouse was when `openURLs` was called. This visually reinforces the user-initiated
      /// behavior and is less jarring than popping out of the periphery. It will move while zooming to its final location, which remains
      /// well-defined based on current user prefs and/or last closed window.
      let mouseLoc = PlayerCore.mouseLocationAtLastOpen ?? NSEvent.mouseLocation
      let mouseLocScreenID = NSScreen.getOwnerOrDefaultScreenID(forPoint: mouseLoc)
      let initialGeo = initialLayout.buildGeometry(windowFrame: windowFrame, screenID: mouseLocScreenID, video: videoGeo).refit(.stayInside)
      let windowSize = initialGeo.windowFrame.size
      let windowOrigin = NSPoint(x: round(mouseLoc.x - (windowSize.width * 0.5)), y: round(mouseLoc.y - (windowSize.height * 0.5)))
      log.verbose("Initial layout: starting with tiny window, videoAspect=\(videoGeo.videoViewAspect), windowSize=\(windowSize)")
      windowedModeGeo = initialGeo.clone(windowFrame: NSRect(origin: windowOrigin, size: windowSize)).refit(.stayInside)
    }

    return GeometrySet(windowed: windowedModeGeo, musicMode: musicModeGeo, video: videoGeo)
  }
}
