//
//  PlayerWindowResizeExtension.swift
//  iina
//
//  Created by Matt Svoboda on 12/13/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// `PlayerWindowController` geometry functions
extension PlayerWindowController {

  /// Set window size when info available, or video size changed. Called in response to receiving `video-reconfig` msg
  func mpvVideoDidReconfig(_ videoParams: MPVVideoParams) {
    if !videoParams.hasValidSize && (player.isMiniPlayerWaitingToShowVideo ||
                                     (!musicModeGeometry.isVideoVisible && !player.info.isVideoTrackSelected)) {
      log.verbose("[MPVVideoReconfig] Ignoring reconfig because music mode is enabled and video is off")
      return
    }

    guard let videoDisplayRotatedSize = videoParams.videoDisplayRotatedSize else {
      log.error("[MPVVideoReconfig] Could not get videoDisplayRotatedSize from mpv! Cancelling adjustment")
      return
    }

    let newVideoAspect = videoDisplayRotatedSize.mpvAspect
    log.verbose("[MPVVideoReconfig Start] VideoRaw:\(videoParams.videoRawSize) VideoDR:\(videoDisplayRotatedSize) AspectDR:\(newVideoAspect) Rotation:\(videoParams.totalRotation) Scale:\(videoParams.videoScale)")

    let oldVideoParams = player.info.videoParams
    // Update cached values for use elsewhere:
    player.info.videoParams = videoParams

    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoDisplayRotatedSize
    }
    guard let screen = window?.screen else { return }
    let currentLayout = currentLayout

    if isInInteractiveMode, let cropController = self.cropSettingsView, cropController.cropBoxView.didSubmit {
      /// Interactive mode after submit: finish crop submission and exit interactive mode
      cropController.cropBoxView.didSubmit = false
      let uncroppedVideoSize = cropController.cropBoxView.actualSize
      let cropboxUnscaled = NSRect(x: cropController.cropx, y: cropController.cropyFlippedForMac,
                                   width: cropController.cropw, height: cropController.croph)

      exitInteractiveMode(cropVideoFrom: uncroppedVideoSize, to: cropboxUnscaled)

    } else if currentLayout.canEnterInteractiveMode, let prevCropFilter = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
      // Not yet in interactive mode, but the active crop was just disabled prior to entering it,
      // so that full video can be seen during interactive mode

      // Extra video-reconfig notifications are generated by this process. Ignore the ones we don't care about:
      let videoFullSize = videoParams.videoWithAspectOverrideSize
      let videoDisplaySize = videoParams.videoDisplaySize
      // FIXME: this is a junk fix. Find a better way to trigger this
      guard abs(videoDisplaySize.width - videoFullSize.width) <= 1 && abs(videoDisplaySize.height - videoFullSize.height) <= 1 else {
        log.verbose("[MPVVideoReconfig] Found a disabled crop filter \(prevCropFilter.stringFormat.quoted), but videoRawSize \(videoParams.videoRawSize) does not yet match videoDisplaySize \(videoParams.videoDisplaySize); ignoring")
        return
      }

      let prevCropbox = prevCropFilter.cropRect(origVideoSize: videoDisplayRotatedSize, flipY: true)
      log.verbose("[MPVVideoReconfig] Found a disabled crop filter: \(prevCropFilter.stringFormat.quoted). Will enter interactive crop.")
      log.verbose("[MPVVideoReconfig] VideoDisplayRotatedSize: \(videoDisplayRotatedSize), PrevCropbox: \(prevCropbox)")

      animationPipeline.submit(IINAAnimation.Task({ [self] in
        let uncroppedWindowedGeo = windowedModeGeometry.uncropVideo(videoDisplayRotatedSize: videoDisplayRotatedSize, cropbox: prevCropbox,
                                                                    videoScale: player.info.cachedWindowScale)
        // Update the cached objects even if not in windowed mode
        player.info.videoAspect = uncroppedWindowedGeo.videoAspect
        windowedModeGeometry = uncroppedWindowedGeo

        if currentLayout.mode == .fullScreen {

        } else if currentLayout.mode == .windowed {
          let uncroppedWindowedGeo = windowedModeGeometry.uncropVideo(videoDisplayRotatedSize: videoDisplayRotatedSize, cropbox: prevCropbox,
                                                                      videoScale: player.info.cachedWindowScale)
          applyWindowGeometry(uncroppedWindowedGeo)
        } else {
          assert(false, "Bad state! Invalid mode: \(currentLayout.spec.mode)")
          return
        }
        enterInteractiveMode(.crop)
      }))

    } else if player.info.isRestoring {
      if isInInteractiveMode {
        /// If restoring into interactive mode, we didn't have `videoDisplayRotatedSize` while doing layout. Add it now (if needed)
        animationPipeline.submitZeroDuration({ [self] in
          let videoSize: NSSize
          if currentLayout.isFullScreen {
            let fsInteractiveModeGeo = currentLayout.buildFullScreenGeometry(inside: screen, videoAspect: newVideoAspect)
            videoSize = fsInteractiveModeGeo.videoSize
            interactiveModeGeometry = fsInteractiveModeGeo
          } else { // windowed
            videoSize = interactiveModeGeometry?.videoSize ?? windowedModeGeometry.videoSize
          }
          log.debug("[MPVVideoReconfig] Restoring crop box origVideoSize=\(videoDisplayRotatedSize), videoSize=\(videoSize)")
          addOrReplaceCropBoxSelection(origVideoSize: videoDisplayRotatedSize, videoSize: videoSize)
        })

      } else {
        log.verbose("[MPVVideoReconfig A] Restore is in progress; ignoring mpv video-reconfig")
      }

    } else if currentLayout.mode == .musicMode {
      log.debug("[MPVVideoReconfig] Player is in music mode; calling applyMusicModeGeometry")
      /// Keep prev `windowFrame`. Just adjust height to fit new video aspect ratio
      /// (unless it doesn't fit in screen; see `applyMusicModeGeometry()`)
      let newGeometry = musicModeGeometry.clone(videoAspect: newVideoAspect)
      applyMusicModeGeometryInAnimationPipeline(newGeometry)

    } else { // Windowed or full screen
      if let oldVideoParams, oldVideoParams.videoRawSize.equalTo(videoParams.videoRawSize),
         let oldVideoDR = oldVideoParams.videoDisplayRotatedSize, oldVideoDR.equalTo(videoDisplayRotatedSize) {
        log.debug("[MPVVideoReconfig Done] No change to prev video params. Taking no action")
        return
      }

      let newWindowGeo = resizeWindowAfterVideoReconfig(videoDisplayRotatedSize: videoDisplayRotatedSize)
      if player.info.justStartedFile && currentLayout.mode == .windowed {
        // Update intended viewport to new size.
        player.info.intendedViewportSize = newWindowGeo.viewportSize
      }

      animationPipeline.submit(IINAAnimation.Task(duration: IINAAnimation.VideoReconfigDuration, timing: .easeInEaseOut, { [self] in
        /// Finally call `setFrame()`
        log.debug("[MPVVideoReconfig Apply] Applying result (FS:\(isFullScreen.yn)) → videoSize:\(newWindowGeo.videoSize) newWindowFrame: \(newWindowGeo.windowFrame)")

        if currentLayout.mode == .windowed {
          applyWindowGeometry(newWindowGeo)
        } else if currentLayout.mode == .fullScreen {
          // TODO: break FS into separate function
          applyWindowGeometry(newWindowGeo)
        } else {
          // Update this for later use if not currently in windowed mode
          windowedModeGeometry = newWindowGeo
        }
      }))

      // UI and slider
      player.events.emit(.windowSizeAdjusted, data: newWindowGeo.windowFrame)
    }

    log.debug("[MPVVideoReconfig Done]")
  }

  private func shouldResizeWindowAfterVideoReconfig() -> Bool {
    guard player.info.justStartedFile else {
      // video size changed during playback
      log.verbose("[MPVVideoReconfig C] JustStartedFile=NO → returning NO for shouldResize")
      return false
    }

    // resize option applies
    let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
    switch resizeTiming {
    case .always:
      log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='Always' → returning YES for shouldResize")
      return true
    case .onlyWhenOpen:
      log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='OnlyWhenOpen' → returning justOpenedFile (\(player.info.justOpenedFile.yesno)) for shouldResize")
      return player.info.justOpenedFile
    case .never:
      log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='Never' → returning NO for shouldResize")
      return false
    }
  }

  private func resizeWindowAfterVideoReconfig(videoDisplayRotatedSize: NSSize) -> PWindowGeometry {
    let windowGeo = windowedModeGeometry.clone(videoAspect: videoDisplayRotatedSize.mpvAspect)

    guard shouldResizeWindowAfterVideoReconfig() else {
      // video size changed during playback
      log.verbose("[MPVVideoReconfig C] JustStartedFile=NO → returning NO for shouldResize")
      return resizeMinimallyAfterVideoReconfig(from: windowGeo, videoDisplayRotatedSize: videoDisplayRotatedSize)
    }

    assert(player.info.justStartedFile)
    // get videoSize on screen
    var newVideoSize: NSSize = videoDisplayRotatedSize
    log.verbose("[MPVVideoReconfig C-1]  Starting calc: set newVideoSize := videoDisplayRotatedSize → \(videoDisplayRotatedSize)")

    let resizeWindowStrategy: Preference.ResizeWindowOption = Preference.enum(for: .resizeWindowOption)
    if resizeWindowStrategy != .fitScreen {
      let resizeRatio = resizeWindowStrategy.ratio
      newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
      log.verbose("[MPVVideoReconfig C-2] Applied resizeRatio (\(resizeRatio)) to newVideoSize → \(newVideoSize)")
    }

    let screenID = player.isInMiniPlayer ? musicModeGeometry.screenID : windowedModeGeometry.screenID
    let screenVisibleFrame = NSScreen.getScreenOrDefault(screenID: screenID).visibleFrame

    // check if have mpv geometry set (initial window position/size)
    if let mpvGeometry = player.getMPVGeometry() {
      log.verbose("[MPVVideoReconfig C-3] shouldApplyInitialWindowSize=Y. Converting mpv \(mpvGeometry) and constraining by screen \(screenVisibleFrame)")
      return windowGeo.apply(mpvGeometry: mpvGeometry, andDesiredVideoSize: newVideoSize)

    } else if resizeWindowStrategy == .fitScreen {
      log.verbose("[MPVVideoReconfig C-4] ResizeWindowOption=FitToScreen. Using screenFrame \(screenVisibleFrame)")
      return windowGeo.scaleViewport(to: screenVisibleFrame.size, fitOption: .centerInVisibleScreen)

    } else {
      log.verbose("[MPVVideoReconfig C-5] ResizeWindow=\(resizeWindowStrategy). Resizing & centering windowFrame")
      return windowGeo.scaleVideo(to: newVideoSize, fitOption: .centerInVisibleScreen)
    }
  }

  private func resizeMinimallyAfterVideoReconfig(from windowGeo: PWindowGeometry,
                                                 videoDisplayRotatedSize: NSSize) -> PWindowGeometry {
    // User is navigating in playlist. retain same window width.
    // This often isn't possible for vertical videos, which will end up shrinking the width.
    // So try to remember the preferred width so it can be restored when possible
    var desiredViewportSize = windowGeo.viewportSize

    if Preference.bool(for: .lockViewportToVideoSize) {
      if let intendedViewportSize = player.info.intendedViewportSize  {
        // Just use existing size in this case:
        desiredViewportSize = intendedViewportSize
        log.verbose("[MPVVideoReconfig D-1] Using intendedViewportSize \(intendedViewportSize)")
      }

      let minNewViewportHeight = round(desiredViewportSize.width / videoDisplayRotatedSize.mpvAspect)
      if desiredViewportSize.height < minNewViewportHeight {
        // Try to increase height if possible, though it may still be shrunk to fit screen
        desiredViewportSize = NSSize(width: desiredViewportSize.width, height: minNewViewportHeight)
      }
    }

    log.verbose("[MPVVideoReconfig D] Minimal resize: applying desiredViewportSize \(desiredViewportSize)")
    return windowGeo.scaleViewport(to: desiredViewportSize)
  }

  // MARK: - Window geometry functions

  func setVideoScale(_ desiredVideoScale: CGFloat) {
    guard let window = window else { return }
    let currentLayout = currentLayout
    guard currentLayout.mode == .windowed || currentLayout.mode == .musicMode else { return }
    guard let videoParams = player.mpv.queryForVideoParams() else { return }

    guard let videoDisplayRotatedSize = videoParams.videoDisplayRotatedSize else {
      log.error("SetWindowScale failed: could not get videoDisplayRotatedSize")
      return
    }

    var desiredVideoSize = NSSize(width: round(videoDisplayRotatedSize.width * desiredVideoScale),
                                  height: round(videoDisplayRotatedSize.height * desiredVideoScale))

    log.verbose("SetVideoScale: requested scale=\(desiredVideoScale)x, videoDisplayRotatedSize=\(videoDisplayRotatedSize) → desiredVideoSize=\(desiredVideoSize)")

    // TODO
    if false && Preference.bool(for: .usePhysicalResolution) {
      desiredVideoSize = window.convertFromBacking(NSRect(origin: window.frame.origin, size: desiredVideoSize)).size
      log.verbose("SetWindowScale: converted desiredVideoSize to physical resolution: \(desiredVideoSize)")
    }

    switch currentLayout.mode {
    case .windowed:
      let newGeoUnconstrained = windowedModeGeometry.scaleVideo(to: desiredVideoSize, fitOption: .noConstraints, mode: currentLayout.mode)
      // User has actively resized the video. Assume this is the new preferred resolution
      player.info.intendedViewportSize = newGeoUnconstrained.viewportSize

      let newGeometry = newGeoUnconstrained.refit(.keepInVisibleScreen)
      log.verbose("SetVideoScale: calling applyWindowGeometry")
      applyWindowGeometryInAnimationPipeline(newGeometry)
    case .musicMode:
      // will return nil if video is not visible
      guard let newMusicModeGeometry = musicModeGeometry.scaleVideo(to: desiredVideoSize) else { return }
      log.verbose("SetVideoScale: calling applyMusicModeGeometry")
      applyMusicModeGeometryInAnimationPipeline(newMusicModeGeometry)
    default:
      return
    }
  }

  /**
   Resizes and repositions the window, attempting to match `desiredViewportSize`, but the actual resulting
   video size will be scaled if needed so it is`>= AppData.minVideoSize` and `<= screen.visibleFrame`.
   The window's position will also be updated to maintain its current center if possible, but also to
   ensure it is placed entirely inside `screen.visibleFrame`.
   */
  func resizeViewport(to desiredViewportSize: CGSize? = nil, centerOnScreen: Bool = false) {
    guard currentLayout.mode == .windowed || currentLayout.mode == .musicMode else { return }

    switch currentLayout.mode {
    case .windowed:
      let newGeoUnconstrained = windowedModeGeometry.scaleViewport(to: desiredViewportSize, fitOption: .noConstraints)
      // User has actively resized the video. Assume this is the new preferred resolution
      player.info.intendedViewportSize = newGeoUnconstrained.viewportSize

      let fitOption: ScreenFitOption = centerOnScreen ? .centerInVisibleScreen : .keepInVisibleScreen
      let newGeometry = newGeoUnconstrained.refit(fitOption)
      log.verbose("Calling applyWindowGeometry from resizeViewport (center=\(centerOnScreen.yn)), to: \(newGeometry.windowFrame)")
      applyWindowGeometryInAnimationPipeline(newGeometry)
    case .musicMode:
      /// In music mode, `viewportSize==videoSize` always. Will get `nil` here if video is not visible
      guard let newMusicModeGeometry = musicModeGeometry.scaleVideo(to: desiredViewportSize) else { return }
      log.verbose("Calling applyMusicModeGeometry from resizeViewport, to: \(newMusicModeGeometry.windowFrame)")
      applyMusicModeGeometryInAnimationPipeline(newMusicModeGeometry)
    default:
      return
    }
  }

  func scaleVideoByIncrement(_ widthStep: CGFloat) {
    let currentViewportSize: NSSize
    switch currentLayout.mode {
    case .windowed:
      currentViewportSize = windowedModeGeometry.viewportSize
    case .musicMode:
      guard let viewportSize = musicModeGeometry.viewportSize else { return }
      currentViewportSize = viewportSize
    default:
      return
    }
    let heightStep = widthStep / currentViewportSize.mpvAspect
    let desiredViewportSize = CGSize(width: currentViewportSize.width + widthStep, height: currentViewportSize.height + heightStep)
    log.verbose("Incrementing viewport width by \(widthStep), to desired size \(desiredViewportSize)")
    resizeViewport(to: desiredViewportSize)
  }

  /// Updates the appropriate in-memory cached geometry (based on the current window mode) using the current window & view frames.
  /// Param `updatePreferredSizeAlso` only applies to `.windowed` mode.
  func updateCachedGeometry(updateMPVWindowScale: Bool = false) {
    guard !currentLayout.isFullScreen, !player.info.isRestoring else {
      log.verbose("Not updating cached geometry: isFS=\(currentLayout.isFullScreen.yn), isRestoring=\(player.info.isRestoring)")
      return
    }

    var ticket: Int = 0
    $updateCachedGeometryTicketCounter.withLock {
      $0 += 1
      ticket = $0
    }

    animationPipeline.submitZeroDuration({ [self] in
      guard ticket == updateCachedGeometryTicketCounter else { return }
      log.verbose("Updating cached \(currentLayout.mode) geometry from current window (tkt \(ticket))")
      let currentLayout = currentLayout

      switch currentLayout.mode {
      case .windowed, .windowedInteractive:
        let geo = currentLayout.buildGeometry(windowFrame: window!.frame, screenID: bestScreen.screenID, videoAspect: player.info.videoAspect)
        if currentLayout.mode == .windowedInteractive {
          assert(interactiveModeGeometry?.videoAspect == geo.videoAspect)
          interactiveModeGeometry = geo
        } else {
          assert(currentLayout.mode == .windowed)
          assert(windowedModeGeometry.videoAspect == geo.videoAspect)
          windowedModeGeometry = geo
        }
        if updateMPVWindowScale {
          player.updateMPVWindowScale(using: geo)
        }
        player.saveState()
      case .musicMode:
        musicModeGeometry = musicModeGeometry.clone(windowFrame: window!.frame,
                                                    screenID: bestScreen.screenID)
        if updateMPVWindowScale {
          player.updateMPVWindowScale(using: musicModeGeometry.toPWindowGeometry())
        }
        player.saveState()
      case .fullScreen, .fullScreenInteractive:
        return  // will never get here; see guard above
      }

    })
  }

  /// Encapsulates logic for `windowWillResize`, but specfically for windowed modes
  func resizeWindow(_ window: NSWindow, to requestedSize: NSSize) -> PWindowGeometry {
    let currentLayout = currentLayout
    assert(currentLayout.isWindowed, "Trying to resize in windowed mode but current mode is unexpected: \(currentLayout.mode)")
    let currentGeometry: PWindowGeometry
    switch currentLayout.spec.mode {
    case .windowed:
      currentGeometry = windowedModeGeometry.clone(windowFrame: window.frame)
    case .windowedInteractive:
      if let interactiveModeGeometry {
        currentGeometry = interactiveModeGeometry.clone(windowFrame: window.frame)
      } else {
        log.error("WindowWillResize: could not find interactiveModeGeometry; will substitute windowedModeGeometry")
        let updatedWindowedModeGeometry = windowedModeGeometry.clone(windowFrame: window.frame)
        currentGeometry = updatedWindowedModeGeometry.toInteractiveMode()
      }
      if requestedSize.width < Constants.InteractiveMode.minWindowWidth {
        log.verbose("WindowWillResize: requested width (\(requestedSize.width)) is less than min width for interactive mode (\(Constants.InteractiveMode.minWindowWidth)). Denying resize")
        return currentGeometry
      }
    default:
      log.error("WindowWillResize: requested mode is invalid: \(currentLayout.spec.mode). Will fall back to windowedModeGeometry")
      return windowedModeGeometry
    }

    assert(currentGeometry.mode == currentLayout.mode)

    if denyNextWindowResize {
      log.verbose("WindowWillResize: denying this resize; will stay at \(currentGeometry.windowFrame.size)")
      denyNextWindowResize = false
      return currentGeometry
    }

    if player.info.isRestoring {
      guard let savedState = player.info.priorState else { return currentGeometry }

      if let savedLayoutSpec = savedState.layoutSpec {
        // If getting here, restore is in progress. Don't allow size changes, but don't worry
        // about whether the saved size is valid. It will be handled elsewhere.
        if savedLayoutSpec.mode == .musicMode, let savedMusicModeGeo = savedState.musicModeGeometry {
          log.verbose("WindowWillResize: denying request due to restore; returning saved musicMode size \(savedMusicModeGeo.windowFrame.size)")
          return savedMusicModeGeo.toPWindowGeometry()
        } else if savedLayoutSpec.mode == .windowed, let savedWindowedModeGeo = savedState.windowedModeGeometry {
          log.verbose("WindowWillResize: denying request due to restore; returning saved windowedMode size \(savedWindowedModeGeo.windowFrame.size)")
          return savedWindowedModeGeo
        }
      }
      log.error("WindowWillResize: failed to restore window frame; returning existing: \(currentGeometry.windowFrame.size)")
      return currentGeometry
    }

    if !window.inLiveResize {  // Only applies to system requests to resize (not user resize)
      let minWindowWidth = currentGeometry.minWindowWidth(mode: currentLayout.mode)
      let minWindowHeight = currentGeometry.minWindowHeight(mode: currentLayout.mode)
      if (requestedSize.width < minWindowWidth) || (requestedSize.height < minWindowHeight) {
        // Sending the current size seems to work much better with accessibilty requests
        // than trying to change to the min size
        log.verbose("WindowWillResize: requested smaller than min (\(minWindowWidth) x \(minWindowHeight)); returning existing \(currentGeometry.windowFrame.size)")
        return currentGeometry
      }
    }

    // Need to resize window to match video aspect ratio, while taking into account any outside panels.
    let lockViewportToVideoSize = Preference.bool(for: .lockViewportToVideoSize) || currentLayout.mode.alwaysLockViewportToVideoSize
    if !lockViewportToVideoSize {
      // No need to resize window to match video aspect ratio.
      let intendedGeo = currentGeometry.scaleWindow(to: requestedSize, fitOption: .noConstraints)

      if currentLayout.mode == .windowed && window.inLiveResize {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise. Do not constrain.
        player.info.intendedViewportSize = intendedGeo.viewportSize
      }
      return intendedGeo.refit(.keepInVisibleScreen)
    }

    // Option A: resize height based on requested width
    let widthDiff = requestedSize.width - currentGeometry.windowFrame.width
    let requestedVideoWidth = currentGeometry.videoSize.width + widthDiff
    let resizeFromWidthRequestedVideoSize = NSSize(width: requestedVideoWidth,
                                                   height: round(requestedVideoWidth / currentGeometry.videoAspect))
    let resizeFromWidthGeo = currentGeometry.scaleVideo(to: resizeFromWidthRequestedVideoSize)

    // Option B: resize width based on requested height
    let heightDiff = requestedSize.height - currentGeometry.windowFrame.height
    let requestedVideoHeight = currentGeometry.videoSize.height + heightDiff
    let resizeFromHeightRequestedVideoSize = NSSize(width: round(requestedVideoHeight * currentGeometry.videoAspect),
                                                    height: requestedVideoHeight)
    let resizeFromHeightGeo = currentGeometry.scaleVideo(to: resizeFromHeightRequestedVideoSize)

    log.verbose("WindowWillResize: PREV:\(currentGeometry), WIDTH:\(resizeFromWidthGeo), HEIGHT:\(resizeFromHeightGeo)")

    let chosenGeometry: PWindowGeometry
    if window.inLiveResize {
      /// Notes on the trickiness of live window resize:
      /// 1. We need to decide whether to (A) keep the width fixed, and resize the height, or (B) keep the height fixed, and resize the width.
      /// "A" works well when the user grabs the top or bottom sides of the window, but will not allow resizing if the user grabs the left
      /// or right sides. Similarly, "B" works with left or right sides, but will not work with top or bottom.
      /// 2. We can make all 4 sides allow resizing by first checking if the user is requesting a different height: if yes, use "B";
      /// and if no, use "A".
      /// 3. Unfortunately (2) causes resize from the corners to jump all over the place, because in that case either height or width will change
      /// in small increments (depending on how fast the user moves the cursor) but this will result in a different choice between "A" or "B" schemes
      /// each time, with very different answers, which causes the jumpiness. In this case either scheme will work fine, just as long as we stick
      /// to the same scheme for the whole resize. So to fix this, we add `isLiveResizingWidth`, and once set, stick to scheme "B".
      if window.frame.height != requestedSize.height {
        isLiveResizingWidth = true
      }

      if isLiveResizingWidth {
        chosenGeometry = resizeFromHeightGeo
      } else {
        chosenGeometry = resizeFromWidthGeo
      }

      if currentLayout.mode == .windowed {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise.
        player.info.intendedViewportSize = chosenGeometry.viewportSize
      }
    } else {
      // Resize request is not coming from the user. Could be BetterTouchTool, Retangle, or some window manager, or the OS.
      // These tools seem to expect that both dimensions of the returned size are less than the requested dimensions, so check for this.

      if resizeFromWidthGeo.windowFrame.width <= requestedSize.width && resizeFromWidthGeo.windowFrame.height <= requestedSize.height {
        chosenGeometry = resizeFromWidthGeo
      } else {
        chosenGeometry = resizeFromHeightGeo
      }
    }
    log.verbose("WindowWillResize isLive:\(window.inLiveResize.yn) req:\(requestedSize) lockViewport:Y prevVideoSize:\(currentGeometry.videoSize) returning:\(chosenGeometry.windowFrame.size)")

    // TODO: validate geometry
    return chosenGeometry
  }

  func updateFloatingOSCAfterWindowDidResize() {
    guard let window = window, currentLayout.oscPosition == .floating else { return }
    controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH,
                              originRatioV: floatingOSCOriginRatioV, layout: currentLayout, viewportSize: viewportView.frame.size)

    // Detach the views in oscFloatingUpperView manually on macOS 11 only; as it will cause freeze
    if #available(macOS 11.0, *) {
      if #unavailable(macOS 12.0) {
        guard let maxWidth = [fragVolumeView, fragToolbarView].compactMap({ $0?.frame.width }).max() else {
          return
        }

        // window - 10 - controlBarFloating
        // controlBarFloating - 12 - oscFloatingUpperView
        let margin: CGFloat = (10 + 12) * 2
        let hide = (window.frame.width
                    - oscFloatingPlayButtonsContainerView.frame.width
                    - maxWidth*2
                    - margin) < 0

        let views = oscFloatingUpperView.views
        if hide {
          if views.contains(fragVolumeView) {
            oscFloatingUpperView.removeView(fragVolumeView)
          }
          if let fragToolbarView = fragToolbarView, views.contains(fragToolbarView) {
            oscFloatingUpperView.removeView(fragToolbarView)
          }
        } else {
          if !views.contains(fragVolumeView) {
            oscFloatingUpperView.addView(fragVolumeView, in: .leading)
          }
          if let fragToolbarView = fragToolbarView, !views.contains(fragToolbarView) {
            oscFloatingUpperView.addView(fragToolbarView, in: .trailing)
          }
        }
      }
    }
  }

  // MARK: - Apply Geometry

  /// Set the window frame and if needed the content view frame to appropriately use the full screen.
  /// For screens that contain a camera housing the content view will be adjusted to not use that area of the screen.
  func applyLegacyFullScreenGeometry(_ geometry: PWindowGeometry) {
    guard let window = window else { return }
    let currentLayout = currentLayout
    if !currentLayout.isInteractiveMode {
      videoView.apply(geometry)
    }

    if currentLayout.hasFloatingOSC {
      controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH, originRatioV: floatingOSCOriginRatioV,
                                layout: currentLayout, viewportSize: geometry.viewportSize)
    }

    updateOSDTopOffset(geometry, isLegacyFullScreen: true)

    guard !geometry.windowFrame.equalTo(window.frame) else {
      log.verbose("No need to update windowFrame for legacyFullScreen - no change")
      return
    }

    log.verbose("Calling setFrame for legacyFullScreen, to \(geometry)")
    player.window.setFrameImmediately(geometry.windowFrame)
    let topBarHeight = currentLayout.topBarPlacement == .insideViewport ? geometry.insideTopBarHeight : geometry.outsideTopBarHeight
    updateTopBarHeight(to: topBarHeight, topBarPlacement: currentLayout.topBarPlacement, cameraHousingOffset: geometry.topMarginHeight)
  }

  /// Updates/redraws current `window.frame` and its internal views from `newGeometry`. Animated.
  /// Also updates cached `windowedModeGeometry` and saves updated state.
  func applyWindowGeometryInAnimationPipeline(_ newGeometry: PWindowGeometry) {
    var ticket: Int = 0
    $geoUpdateTicketCounter.withLock {
      $0 += 1
      ticket = $0
    }

    animationPipeline.submit(IINAAnimation.Task(timing: .easeInEaseOut, { [self] in
      guard ticket == geoUpdateTicketCounter else {
        return
      }
      log.verbose("ApplyWindowGeometry (tkt \(ticket)) windowFrame: \(newGeometry.windowFrame), videoAspect: \(newGeometry.videoAspect)")
      applyWindowGeometry(newGeometry)
    }))
  }

  // TODO: split this into separate windowed & FS
  private func applyWindowGeometry(_ newGeometry: PWindowGeometry, setFrame: Bool = true) {
    // Update video aspect ratio always
    player.info.videoAspect = newGeometry.videoAspect
    let currentLayout = currentLayout
    switch currentLayout.spec.mode {

    case .musicMode, .windowedInteractive, .fullScreenInteractive:
      log.error("ApplyWindowGeometry is not used for \(currentLayout.spec.mode) mode")

    case .fullScreen:
      if setFrame {
        // Make sure video constraints are up to date, even in full screen. Also remember that FS & windowed mode share same screen.
        let fsGeo = currentLayout.buildFullScreenGeometry(inScreenID: newGeometry.screenID,
                                                          videoAspect: newGeometry.videoAspect)
        log.verbose("ApplyWindowGeometry: Updating videoView (FS), videoSize: \(fsGeo.videoSize)")
        videoView.apply(fsGeo)
      }

    case .windowed:
      if setFrame {
        if !isWindowHidden {
          player.window.setFrameImmediately(newGeometry.windowFrame)
        }
        // Make sure this is up-to-date
        videoView.apply(newGeometry)
        windowedModeGeometry = newGeometry
      }
      log.verbose("ApplyWindowGeometry: Calling updateMPVWindowScale, videoSize: \(newGeometry.videoSize)")
      player.updateMPVWindowScale(using: newGeometry)
      player.saveState()
    }
  }

  /// For (1) pinch-to-zoom, (2) resizing outside sidebars when the whole window needs to be resized or moved.
  /// Not animated. Can be used in windowed mode or full screen modes. Can be used in music mode only if the playlist is hidden.
  func applyWindowGeometryForSpecialResize(_ newGeometry: PWindowGeometry) {
    log.verbose("ApplySpecialGeo: \(newGeometry)")
    let currentLayout = currentLayout
    // Need this if video is playing
    videoView.videoLayer.enterAsynchronousMode()

    // Update video aspect ratio
    player.info.videoAspect = newGeometry.videoAspect

    IINAAnimation.disableAnimation{
      if !isFullScreen {
        player.window.setFrameImmediately(newGeometry.windowFrame, animate: false)
      }

      // Make sure this is up-to-date
      videoView.apply(newGeometry)

      // These will no longer be aligned correctly. Just hide them
      thumbnailPeekView.isHidden = true
      timePositionHoverLabel.isHidden = true

      if currentLayout.hasFloatingOSC {
        // Update floating control bar position
        controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH,
                                  originRatioV: floatingOSCOriginRatioV, layout: currentLayout, viewportSize: newGeometry.viewportSize)
      }
    }
  }

  /// Same as `applyMusicModeGeometry()`, but enqueues inside an `IINAAnimation.Task` for a nice smooth animation
  func applyMusicModeGeometryInAnimationPipeline(_ geometry: MusicModeGeometry, setFrame: Bool = true, animate: Bool = true, updateCache: Bool = true) {
    animationPipeline.submit(IINAAnimation.Task(timing: .easeInEaseOut, { [self] in
      applyMusicModeGeometry(geometry)
    }))
  }

  /// Updates the current window and its subviews to match the given `MusicModeGeometry`.
  /// If `updateCache` is true, updates `musicModeGeometry` and saves player state.
  @discardableResult
  func applyMusicModeGeometry(_ geometry: MusicModeGeometry, setFrame: Bool = true, animate: Bool = true, updateCache: Bool = true) -> MusicModeGeometry {
    let geometry = geometry.refit()  // enforces internal constraints, and constrains to screen
    log.verbose("Applying \(geometry), setFrame=\(setFrame.yn) updateCache=\(updateCache.yn)")

    videoView.videoLayer.enterAsynchronousMode()

    // Update defaults:
    Preference.set(geometry.isVideoVisible, for: .musicModeShowAlbumArt)
    Preference.set(geometry.isPlaylistVisible, for: .musicModeShowPlaylist)

    player.info.videoAspect = geometry.videoAspect

    updateMusicModeButtonsVisibility()

    /// Try to detect & remove unnecessary constraint updates - `updateBottomBarHeight()` may cause animation glitches if called twice
    var hasChange: Bool = !geometry.windowFrame.equalTo(window!.frame)
    let isVideoVisible = !(viewportViewHeightContraint?.isActive ?? false)
    if geometry.isVideoVisible != isVideoVisible {
      hasChange = true
    }
    if let newVideoSize = geometry.videoSize, let oldVideoSize = musicModeGeometry.videoSize, !oldVideoSize.equalTo(newVideoSize) {
      hasChange = true
    }

    if hasChange {
      if setFrame {
        player.window.setFrameImmediately(geometry.windowFrame, animate: animate)
      }
      /// Make sure to call `apply` AFTER `applyVideoViewVisibilityConstraints`:
      miniPlayer.applyVideoViewVisibilityConstraints(isVideoVisible: geometry.isVideoVisible)
      updateBottomBarHeight(to: geometry.bottomBarHeight, bottomBarPlacement: .outsideViewport)
      videoView.apply(geometry.toPWindowGeometry())
    } else {
      log.verbose("Not updating music mode windowFrame or constraints - no changes needed")
    }

    if updateCache {
      musicModeGeometry = geometry
      player.saveState()
    }

    /// For the case where video is hidden but playlist is shown, AppKit won't allow the window's height to be changed by the user
    /// unless we remove this constraint from the the window's `contentView`. For all other situations this constraint should be active.
    /// Need to execute this in its own task so that other animations are not affected.
    let shouldDisableConstraint = !geometry.isVideoVisible && geometry.isPlaylistVisible
    animationPipeline.submitZeroDuration({ [self] in
      viewportBottomOffsetFromContentViewBottomConstraint.isActive = !shouldDisableConstraint
    })

    return geometry
  }

}
