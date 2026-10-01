//
//  PlayerWinResizeExtension.swift
//  iina
//
//  Created by Matt Svoboda on 12/13/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// `PlayerWindowController` geometry functions
extension PlayerWindowController {
  // MARK: - Window Delegate: Zoom

  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> NSRect {
    let newSize = resizeSubviews(of: window, to: newFrame.size)
    let newNewFrame = NSRect(origin: newFrame.origin, size: newSize)
    log.verbose("WndWillZoom: \(window.frame) → \(newFrame) → \(newNewFrame)")
    return newNewFrame
  }

  func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
    return windowShouldZoom(window, toFrame: defaultFrame)
  }

  // MARK: - Window Delegate: Resize

  func windowWillStartLiveResize(_ notification: Notification) {
    log.trace("WndWillStartLiveResize")
    isLiveResizingWidth = nil  // reset this
    // Shut down all animations for the duration of live resize!
    // This way the asynchrounous unprotected updates in `windowWillResize` will (hopefully) not interfere with other
    // animations.
    animationPipeline.enableRunning = false
    videoView.glLayer?.inLiveResize = true
    videoView.displayActive()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    log.trace("WndDidEndLiveResize")
    videoView.glLayer?.inLiveResize = false
    // Kick-start the animation pipeline:
    animationPipeline.enableRunning = true
    animationPipeline.submitInstantTask{}
  }

  func windowDidResize(_ notification: Notification) {
    // Trigger forced draws (plugs loophole for window resize when not covered by windowWillResize):
    videoView.displayActive()
  }

  /// NSWindowDelegate: `windowWillResize`: pretty important. Called by AppKit when it wants to resize the window.
  ///
  /// # Notes for other NSWindowDelegate notifications:
  /// * `windowDidResize`: Called after window is resized from (almost) any cause. Can be called many times during
  ///    every call to
  ///   `window.setFrame`. Do not use for anything too serious because it seems to sometimes fire during animations in
  ///   progress.
  /// * `windowDidEndLiveResize`: Never use! It is unreliable. Use `windowDidResize` if anything.
  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    guard !isAnimatingLayoutTransition, !isApplyingPWinGeo else {
      log.verbose("[WndWillResize] isAnimatingLayoutTransition=\(isAnimatingLayoutTransition.yn) " +
                  "isApplyingPWinGeo=\(isApplyingPWinGeo.yn): will grant requestedSize=\(requestedSize)")
      return requestedSize
    }
    guard !isMagnifying else {
      // Don't interfere when resetting zoom
      log.verbose("[WndWillResize] Denying req=\(requestedSize): isMagnifying=Y: Will stay at \(window.frame.size)")
      return window.frame.size
    }
    guard !isInWindowResizeDenialPeriod() else {
      log.verbose("[WndWillResize] Denying req=\(requestedSize): still inside denial period. Will stay at \(window.frame.size)")
      pendingResizeForScreenChange = false  // should be safe to reset this now
      return window.frame.size
    }
    if !window.inLiveResize && isLeftMouseButtonDown {
      // Looks like user is moving the window, but not resizing it. Prevent the system from trying to resize it..
      log.verbose("[WndWillResize] Denying req=\(requestedSize): left mouseBtn down, but not resizing")
      return window.frame.size
    }

    return resizeSubviews(of: window, to: requestedSize)
  }

  /// Calculates the size to return for either:
  /// - `windowWillResize`
  /// - `windowShouldZoom`.
  ///
  /// Also resizes the window's subviews appropriately.
  private func resizeSubviews(of window: NSWindow, to requestedSize: NSSize) -> NSSize {
    let currentLayout = currentLayout
    let inLiveResize = window.inLiveResize
    let lockViewport = currentLayout.mode.alwaysLockViewportToVideoSize || Preference.bool(for: .lockViewportToVideoSize)
    log.verbose("[WndWillResize] \(currentLayout.mode) Curr=\(window.frame.size) Req=\(requestedSize) " +
                "Live=\(inLiveResize.yn) LockViewport=\(lockViewport.yn)")

    if lockViewport && inLiveResize {
      /// Notes on the trickiness of live window resize:
      /// 1. We need to decide whether to (A) keep the width fixed, and resize the height, or (B) keep the height fixed,
      /// and resize the width. "A" works well when the user grabs the top or bottom sides of the window, but will not
      /// allow resizing if the user grabs the left or right sides. Similarly, "B" works with left or right sides, but
      /// will not work with top or bottom.
      /// 2. We can make all 4 sides allow resizing by first checking if the user is requesting a different height: if
      /// yes, use "B"; and if no, use "A".
      /// 3. Unfortunately (2) causes resize from the corners to jump all over the place, because in that case either
      /// height or width will change in small increments (depending on how fast the user moves the cursor) but this
      /// will result in a different choice between "A" or "B" schemes each time, with very different answers, which
      /// causes the jumpiness. In this case either scheme will work fine, just as long as we stick to the same scheme
      /// for the whole resize. So to fix this, we add `isLiveResizingWidth`, and once set, stick to scheme "B".
      if isLiveResizingWidth == nil {
        if window.frame.height != requestedSize.height {
          isLiveResizingWidth = false
        } else if window.frame.width != requestedSize.width {
          isLiveResizingWidth = true
        }
      }
      log.verbose("[WndWillResize] choseWidth=\(self.isLiveResizingWidth?.yn ?? "nil")")
    }

    let newGeo: PWinGeometry
    let isLiveResizingWidth = isLiveResizingWidth ?? true

    // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
    switch currentLayout.mode {

    case .windowedNormal, .windowedInteractive:
      guard !sessionState.isRestoring else {
        log.error("[WndWillResize] Still restoring; returning existing geo=\(windowedModeGeo.windowFrame.size)")
        return windowedModeGeo.windowFrame.size
      }

      let currentGeo = windowedGeoForCurrentFrame()
      assert(currentGeo.mode == currentLayout.mode,
             "[WndWillResize] currentGeo.mode (\(currentGeo.mode)) != currentLayout.mode (\(currentLayout.mode))")

      newGeo = currentGeo.resizingWindow(to: requestedSize, lockViewportToVideoSize: lockViewport,
                                         inLiveResize: inLiveResize, isLiveResizingWidth: isLiveResizingWidth)

    case .fullScreenNormal, .fullScreenInteractive:
      if currentLayout.isNativeFullScreen {
        // This method can be called as a side effect of the animation. If so, ignore.
        return requestedSize
      }

      newGeo = currentLayout.buildFullScreenGeometry(inScreenID: windowedModeGeo.screenID, geo.video)

    case .musicMode:
      guard !sessionState.isRestoring else {
        log.error("[WndWillResize] Still restoring; returning existing musicModeGeo=\(musicModeGeo.windowFrame.size)")
        return musicModeGeo.windowFrame.size
      }

      // Use explicit `isViewportShown`, `playlistShown`: these are derived from the windowFrame, but when we update
      // from current we can end up with small imprecisions which could alter their values.
      let oldGeo = musicModeGeoForCurrentFrame().cloneMusicMode(isViewportShown: musicModeGeo.isViewportShown,
                                                                playlistShown: musicModeGeo.isMusicModePlaylistShown)
      newGeo = oldGeo.resizingWindowInMusicMode(to: requestedSize,
                                                inLiveResize: inLiveResize, isLiveResizingWidth: isLiveResizingWidth)
    }

    // Needed to prevent floating OSC lagginess, offsets for pref `keepVideoAwayFromBars`, possibly other constraints.
    IINAAnimation.disableAnimation {
      /// AppKit calls `setFrame` after this method returns, and we cannot access that code to ensure it is encapsulated
      /// within the same animation transaction as the code below. But the existing `VideoView` constraints should
      /// ensure that everything resizes properly.
      /// Update: need to update `VideoView` layout to ensure that cropbox in interactive mode is resized properly!
      resizeWindowSubviews(using: newGeo)
    }

    let newWindowSize = newGeo.windowFrame.size
    log.verbose("[WndWillResize] Returning size=\(newWindowSize) for \(currentLayout.mode)")
    return newWindowSize
  }

  /// This method is used to move & resize a `PlayerWindow`. It performs additional work needed beyond what `setFrame`
  /// provides. Do not ever call `PlayerWindow.setFrame()` directly - call this instead!
  ///
  /// By default, `setFrame()` has its own implicit animation, and this can create an undesirable effect when combined
  /// with other animations. This function uses a `0` duration animation via the `animationResizeTime` callback to
  /// effectively remove the implicit default animation.
  /// • Also resizes window subviews.
  /// • It will still animate if used inside an `NSAnimationContext` or `IINAAnimation.Task` with non-zero duration.
  func applyPWinGeometry(_ geometry: PWinGeometry,
                         setWindowFrame: Bool = true,
                         updateViewportConstraints: Bool = true,
                         _ transitionCategory: TransitionCategory = .none,
                         submitUpdate: Bool = false) {
    log.verbose("[PWin.setFrame] Entered: viewport=\(updateViewportConstraints.yn) cat=\(transitionCategory) " +
                "save=\(submitUpdate.yn) \(geometry)")

    resizeWindowSubviews(using: geometry, updateViewportConstraints: updateViewportConstraints, transitionCategory)
    updateOSDTopOffsetConstraints(for: geometry)
    updateTopBarHeight(using: geometry)

    if setWindowFrame, let window = (window as? PlayerWindow) {
      if window.frame.equalTo(geometry.windowFrame) {
        log.verbose("[PWin.setFrame] No change to windowFrame")
      } else {
        log.verbose("[PWin.setFrame] Setting frame=\(geometry.windowFrame)")
        window.useZeroDurationForAnimationResize = true
        window.setFrame(geometry.windowFrame, display: true, animate: true)
        window.useZeroDurationForAnimationResize = false

        if !geometry.mode.isFullScreen {
          player.events.emit(.windowResized, data: window.frame)
        }
      }
    }

    guard submitUpdate else { return }

    // Cache geometry, update mpv with latest window-scale, save to prefs:

    switch geometry.mode {
    case .musicMode:
      musicModeGeo = geometry
      // Update defaults:
      Preference.set(geometry.isViewportShown, for: .musicModeShowAlbumArt)
      Preference.set(geometry.isMusicModePlaylistShown, for: .musicModeShowPlaylist)
    case .windowedNormal, .windowedInteractive:
      windowedModeGeo = geometry
    case .fullScreenNormal, .fullScreenInteractive:
      if windowedModeGeo.screenID != geometry.screenID {
        // Update screenID at least, so that window won't go back to other screen when exiting FS
        windowedModeGeo = windowedModeGeo.clone(screenID: geometry.screenID)
      }
    }

    log.verbose("Submit: Calling sendWindowScaleToMPV")
    sendWindowScaleToMPV(basedOn: geometry)

    player.saveState()
  }

  /// Intended to be used only for resizing one or more of PlayerWindow's subviews, or to accomodate a window resize.
  /// Resizes *only* the subviews in the window, not the window frame. May update other state needed relating to resize.
  ///
  /// This method cannot handle complex layout changes. For that, use a `LayoutTransition`
  /// (see `PWin_LayoutTxBuilder.swift`).
  private func resizeWindowSubviews(using newGeometry: PWinGeometry,
                                    updateViewportConstraints: Bool = true,
                                    _ transitionCategory: TransitionCategory = .none) {

    // Trigger forced draws so that mpv can [try its best to] redraw the video without distortion during window resize:
    videoView.displayActive()

    // These may no longer be aligned correctly. Just hide them
    hideSeekPreviewImmediately()
    magnificationHandler.resetZoomIfNotMaximized(newGeometry)

    if updateViewportConstraints {
      viewportView.apply(newGeometry, transitionCategory)
    }

    // Update floating control bar position if applicable
    adjustFloatingControllerOrigin(for: newGeometry)

    if osd.animationState == .shown {
      updateOSDViews(updateSizeFrom: newGeometry)
    }
  }

  // MARK: - Window Resize Denial Period
  // Trying to wrestle control of the window size away from MacOS. Hopefully someday a proper solution will be
  // discovered...

  func restartWindowResizeDenialPeriod(_ reason: String) {
    // Do not allow MacOS to change the window size
    log.verbose("Restarting window resize denial period due to: \(reason)")
    denyWindowResizePeriodStartTime = CFAbsoluteTimeGetCurrent()
  }

  func isInWindowResizeDenialPeriod() -> Bool {
    guard !currentLayout.isFullScreen else { return false }
    let timeElapsed = CFAbsoluteTimeGetCurrent() - denyWindowResizePeriodStartTime
    let denyWindowResize = timeElapsed - TimeConstants.denyWindowResizeTimeout < 0
    log.trace("Time elapsed=\(timeElapsed), timeout=\(TimeConstants.denyWindowResizeTimeout) → " +
              "DenyWinResize=\(denyWindowResize.yn)")
    return denyWindowResize
  }

  func restartWindowScrollDenialPeriod() {
    // Do not allow MacOS to change the window size
    log.trace("Restarting window scroll denial period")
    denyWindowScrollPeriodStartTime = CFAbsoluteTimeGetCurrent()
  }

  func isInWindowScrollDenialPeriod() -> Bool {
    guard !currentLayout.isFullScreen else { return false }
    let timeElapsed = CFAbsoluteTimeGetCurrent() - denyWindowScrollPeriodStartTime
    let denyWindowScroll = timeElapsed - TimeConstants.denyWindowScrollTimeout < 0
    log.trace("Time elapsed=\(timeElapsed), timeout=\(TimeConstants.denyWindowResizeTimeout) → " +
              "DenyWinScroll=\(denyWindowScroll.yn)")
    return denyWindowScroll
  }

  // MARK: - Other window resize methods

  /// Changes video scale to `targetVideoScale`, where a value of `1.0` is the video's native scale.
  /// This actually scales the entire viewport, if pref `lockViewportToVideoSize` is enabled, but the size of the
  /// displayed video should match the desired scale.
  @MainActor
  func setVideoScale(to targetVideoScale: Double) {
    animationPipeline.submitInstantTask{ [self] in
      // Not supported in music mode at this time. Need to resolve backing scale bugs
      guard currentLayout.mode == .windowedNormal else {
        log.verbose("[mpv-window-scale] SetVideoScale: skipping; mode is unsupported: \(currentLayout.mode)")
        return
      }
      guard targetVideoScale > 0.0 else {
        log.error("[mpv-window-scale] SetVideoScale: requested scale is invalid: \(targetVideoScale)")
        return
      }

      let oldWindowedGeo = windowedGeoForCurrentFrame()
      let newGeo = oldWindowedGeo.scalingViewport(toVideoScale: targetVideoScale)
      log.verbose("[mpv-window-scale] SetVideoScale: from targetVideoScale=\(targetVideoScale) → " +
                  "sending derived mpvWindowScale=\(newGeo.mpvWindowScale())")
      buildApplyPWinGeoTasks(to: newGeo, thenRun: true)
    }
  }

  /// Scales the viewport (which is equivalent to mpv's concept of a window) to the given `desiredMpvWindowScale`.
  ///
  /// This method is really only useful for responding to mpv's `window-scale` property, because this property is
  /// meaningless to a casual user due to the way it is calculated using the viewport size; they should normally care
  /// about the video scale instead. To change the video scale, call `setVideoScale`.
  ///
  /// Not supported in music mode at this time. Need to resolve backing scale bugs.
  ///
  /// See also: `PWinGeometry.mpvWindowScale`.
  func sendWindowScaleToMPV(basedOn geometry: PWinGeometry) {
    assert(DispatchQueue.isExecutingIn(.main))
    // Do not call while resizing the window, as doing so has race conditions.
    guard loaded, let window, !window.inLiveResize else { return }

    let scaleFromGeo = geometry.mpvWindowScale()
    guard scaleFromGeo > 0.0 else {
      log.verbose("[mpv-window-scale] SendWindowScaleToMPV: scaleFromGeo (\(scaleFromGeo)) is invalid; aborting")
      return
    }

    log.verbose("[mpv-window-scale] SendWindowScaleToMPV: sending scaleFromGeo=\(scaleFromGeo)")
    player.mpv.queue.async { [self] in
      guard player.isActive, player.info.isFileLoaded else {
        log.debug("[mpv-window-scale] SendWindowScaleToMPV: aborting; player not ready")
        return
      }
      let mpvWindowScaleExisting = player.mpv.getWindowScale()
      guard mpvWindowScaleExisting != scaleFromGeo else {
        log.verbose("[mpv-window-scale] SendWindowScaleToMPV: aborting; mpv already has window-scale: \(scaleFromGeo)")
        return
      }

      player.mpv.windowScalesExpected.prepend(scaleFromGeo)
      log.trace("[mpv-window-scale] SendWindowScaleToMPV: appended to list \(scaleFromGeo); " +
                "windowScalesExpected.count=\(player.mpv.windowScalesExpected.count)")
      player.mpv.setDouble(MPVProperty.windowScale, scaleFromGeo)
    }
  }

  /// After receiving an updated `window-scale` (the `newMpvWindowScale` param) via an mpv property change event,
  /// this method is called to scale the window's viewport (which for mpv is equivalent to its concept of a window)
  /// to match as best as possible.
  ///
  /// This method is really only useful for responding to mpv's `window-scale` property, because this property is
  /// meaningless to a casual user due to the way it is calculated using the viewport size; they should normally care about
  /// the video scale instead. To change the video scale, call `setVideoScale`.
  ///
  /// Not supported in music mode at this time. Need to resolve backing scale bugs.
  ///
  /// See also: `PWinGeometry.mpvWindowScale`.
  @MainActor
  func mpvWindowScaleDidUpdate(to newMpvWindowScale: CGFloat) {
    // Do not call while resizing the window, as doing so has race conditions.
    guard loaded, let window, !window.inLiveResize, !isAnimatingLayoutTransition, !isApplyingPWinGeo else { return }
    guard !isMagnifying else { return }
    guard currentLayout.mode == .windowedNormal || currentLayout.mode == .musicMode else {
      // Not supported in music mode at this time. Need to resolve backing scale bugs
      log.error("[mpv-window-scale] mpvWindowScaleDidUpdate: aborting; unsupported mode: \(currentLayout.mode)")
      return
    }

    let sessionStateTF: GeometryTransform.PWinSessionStateTF = { prevSessionState, ctx -> PWinSessionState? in
      if case .existingSession_continuing = prevSessionState, ctx.currentPlayback.state.isAtLeast(.loadedAndSized) {
        return prevSessionState
      } else {
        return nil  // abort
      }
    }

    let windowedTF: GeometryTransform.PWinGeometryTF = { [self] ctx -> PWinGeometry? in
      let inputGeo: PWinGeometry

      // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
      switch ctx.inputLayout.mode {
      case .musicMode:
        inputGeo = ctx.inputGeoSet.musicMode
      case .windowedNormal, .windowedInteractive:
        inputGeo = ctx.inputGeoSet.windowed
      default:
        log.verbose("[mpv-window-scale] mpvWindowScaleDidUpdate: Skipping; wrong mode (\(ctx.inputLayout.mode))")
        return nil
      }

      let currentMpvWindowScale = inputGeo.mpvWindowScale()

      guard newMpvWindowScale != currentMpvWindowScale else {
        log.verbose("[mpv-window-scale] mpvWindowScaleDidUpdate: No change from current (\(newMpvWindowScale))")
        return nil
      }

      // TODO: if Preference.bool(for: .usePhysicalResolution) {}

      let rescaledGeo = inputGeo.scalingViewport(fromMpvWindowScale: newMpvWindowScale)
      let newComputedScale = rescaledGeo.mpvWindowScale()
      log.verbose("[mpv-window-scale] mpvWindowScaleDidUpdate: current=\(currentMpvWindowScale) " +
                  "fromMPV=\(newMpvWindowScale) newComputedScale=\(newComputedScale)" +
                  (newMpvWindowScale == newComputedScale ? "" : " → mismatch! Will send newComputedScale to mpv"))
      if newMpvWindowScale != newComputedScale {
        // Could not match desired value (e.g. window would be larger than screen). Notify mpv of updated value:
        sendWindowScaleToMPV(basedOn: rescaledGeo)
      }
      return rescaledGeo
    }

    let gtf = GeometryTransform("MPVWindowScaleDidUpdate", player,
                                sessionState: sessionStateTF,
                                windowed: windowedTF)
    gtf.submit()
  }

  /// Resizes and repositions the window, attempting to match `desiredViewportSize`, but the actual resulting
  /// video size will be scaled if needed so it is `<= screen.visibleFrame`.
  /// The window's position will also be updated to maintain its current center if possible, but also to
  /// ensure it is placed entirely inside `screen.visibleFrame`.
  func buildResizeViewportTasks(to desiredViewportSize: CGSize? = nil, centerOnScreen: Bool = false,
                                duration: CGFloat = Constants.AnimationDuration.standard) -> [IINAAnimation.Task] {
    assert(DispatchQueue.isExecutingIn(.main))

    // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
    let inputGeo: PWinGeometry
    let outputGeo: PWinGeometry
    switch currentLayout.mode {
    case .windowedNormal, .windowedInteractive:
      inputGeo = windowedGeoForCurrentFrame()
      let screenFit: ScreenFit = centerOnScreen ? .centerInside : .stayInside
      outputGeo = inputGeo.scalingViewport(to: desiredViewportSize, screenFit: screenFit)
      log.verbose("Calling applyPWinGeo from resizeViewport (center=\(centerOnScreen.yn)), to: \(outputGeo.windowFrame)")
    case .musicMode:
      /// In music mode, `viewportSize==videoSize` always. Will get `nil` here if video is not visible
      inputGeo = musicModeGeoForCurrentFrame()
      outputGeo = inputGeo.scalingViewport(to: desiredViewportSize)
      log.verbose("Calling applyPWinGeo from resizeViewport, to: \(outputGeo.windowFrame)")
    default:
      return []
    }
    // windowed or music mode
    return buildApplyPWinGeoTasks(to: outputGeo, duration: duration)
  }


  // TODO: interpolate this
  @MainActor
  func scaleVideoByIncrement(_ widthStep: Int) {
    let currentLayout = currentLayout

    guard currentLayout.isWindowed || currentLayout.isMusicMode else { return }

    func scaleByWidthStep(_ viewportSize: CGSize) -> CGSize {
      let widthNew = (viewportSize.width + CGFloat(widthStep)).rounded()
      let heightNew = (widthNew / viewportSize.mpvAspect).rounded()
      return CGSize(width: widthNew, height: heightNew)
    }

    let gtf = GeometryTransform("ScaleVideoWidthBy\(widthStep.signString)\(abs(widthStep))pts", player,
                                windowed: { [self] ctx -> PWinGeometry? in
      let mode = ctx.outputLayout.mode
      switch mode {

      case .musicMode:
        let inputGeo = ctx.inputGeoSet.musicMode
        let inputViewportSize = inputGeo.viewportSize
        guard inputGeo.isViewportShown else { return nil }
        let desiredViewportSize = scaleByWidthStep(inputViewportSize)
        log.verbose("Stepping viewport scale: mode=\(mode) stepW=\(widthStep)pt → \(desiredViewportSize)")
        return inputGeo.scalingViewport(to: desiredViewportSize)

      case .windowedNormal, .windowedInteractive:
        let inputGeo = ctx.inputGeoSet.windowed
        let desiredViewportSize = scaleByWidthStep(inputGeo.viewportSize)
        log.verbose("Stepping viewport scale: mode=\(mode) stepW=\(widthStep)pt → \(desiredViewportSize)")
        return inputGeo.scalingViewport(to: desiredViewportSize, screenFit: .stayInside)

      case .fullScreenInteractive, .fullScreenNormal:
        return nil
      }
    })
    gtf.submit()
  }

  // MARK: - Apply PWinGeometry (General Cases)

  /// Generates tasks which, when executed, will update the layout of `PlayerWindow` & its internal views to match the
  /// state described by `outputGeo`. Animated. Can be used for all `PlayerWindowMode` cases.
  ///
  /// Also updates cached `windowedModeGeo` and saves updated state.
  @discardableResult
  func buildApplyPWinGeoTasks(to outputGeo: PWinGeometry,
                              duration: CGFloat = Constants.AnimationDuration.standard,
                              timing: CAMediaTimingFunctionName = .easeInEaseOut,
                              save: Bool = true,
                              showDefaultArt: Bool? = nil,
                              thenRun: Bool = false) -> [IINAAnimation.Task] {

    log.verbose("ApplyPWinGeo entered: duration=\(duration) showDefaultArt=\(showDefaultArt?.yn ?? "nil") " +
                "run=\(thenRun.yn) save=\(save.yn) \(outputGeo)")

    var tasks: [IINAAnimation.Task] = []

    // TASK 1: Background prep
    tasks.append(.instantTask{ [self] in
      isApplyingPWinGeo = true            /// Try not to trigger `windowDidResize` while animating
      videoView.displayActive()           /// Enable smooth video redraws while animating

      hideSeekPreviewImmediately()        /// Thumbnail location may become invalid during window resize; just hide it

      // Show art if videoView is already visible, or before it needs to be shown:
      if outputGeo.isViewportShown {
        updateDefaultArtVisibility(to: showDefaultArt)
      }

      if !currentLayout.isInPiP {
        // Reset the rotation preview, if any.
        // Seems that this looks better if done before updating the window frame...
        // FIXME: this isn't perfect - a bad frame briefly appears during transition
        rotationHandler.rotateVideoView(toDegrees: 0, animate: false)
      }
    })

    // TASK 2: Apply animation
    tasks.append(.init(duration: duration, timing: timing, { [self] in
      switch outputGeo.mode {
      case .fullScreenNormal, .fullScreenInteractive:
        // Make sure video constraints are up to date, even in full screen.
        // Also remember that FS & windowed mode share the same screen.
        log.verbose("ApplyPWinGeo: updating videoView for FS, videoSize=\(outputGeo.videoSize)")
        viewportView.apply(outputGeo)

      case .windowedNormal, .windowedInteractive, .musicMode:
        // This is only needed to achieve "fade-in" effect when opening window:
        updateWindowBorderAndOpacity()
        log.verbose("ApplyPWinGeo: " + (isWindowHidden ? "window is hidden; updating VP constraints but not setFrame"
                                        : "calling setFrame (duration=\(duration))"))
        applyPWinGeometry(outputGeo, setWindowFrame: !isWindowHidden, submitUpdate: save)
      }

    }))

    // TASK 3: Post-animation background state updates
    tasks.append(.instantTask{ [self] in
      isApplyingPWinGeo = false

      // OSD messages may have been supressed because isApplyingPWinGeo was set.
      // Display now if needed (see note about OSD in `buildApplyPWinGeoTasks`)
      videoView.displayActive()
      if !outputGeo.mode.isFullScreen {
        player.events.emit(.windowSizeAdjusted, data: outputGeo.windowFrame)
      }
    })

    if thenRun {
      animationPipeline.submit(tasks)
      return []
    }
    return tasks
  }

}
