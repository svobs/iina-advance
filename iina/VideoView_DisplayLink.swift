//
//  VideoView_DisplayLink.swift
//  iina
//
//  Created by Matt Svoboda on 2025-01-16.
//  Copyright © 2025 lhc. All rights reserved.
//

extension VideoView {
  /// Returns a [Core Video](https://developer.apple.com/documentation/corevideo) display link.
  ///
  /// If a display link has already been created then that link will be returned, otherwise a display link will be created and returned.
  ///
  /// - Note: Issue [#4520](https://github.com/iina/iina/issues/4520) reports a case where it appears the call to
  ///[CVDisplayLinkCreateWithActiveCGDisplays](https://developer.apple.com/documentation/corevideo/1456863-cvdisplaylinkcreatewithactivecgd) is failing. In case that failure is
  ///encountered again this method is careful to log any failure and include the [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes) in the alert displayed
  /// by `Logger.fatal`.
  /// - Returns: A [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k).
  private func obtainDisplayLink() -> CVDisplayLink {
    if let link = link { return link }
    log.verbose("Obtaining DisplayLink")
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    checkResult(result, "CVDisplayLinkCreateWithActiveCGDisplays")
    guard let link = link else {
      Logger.fatal("Cannot create display link: \(codeToString(result)) (\(result))")
    }
    return link
  }

  @MainActor
  private func startDisplayLink() {
    let link = obtainDisplayLink()

    guard !CVDisplayLinkIsRunning(link) else { return }
    updateDisplayLink()

    if let glLayer {
      checkResult(CVDisplayLinkSetOutputCallback(link, displayLinkCallback, mutableRawPointerOf(obj: glLayer)),
                  "CVDisplayLinkSetOutputCallback")
    }
    checkResult(CVDisplayLinkStart(link), "CVDisplayLinkStart")
    log.verbose("DisplayLink started")
  }

  func stopDisplayLink() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard let link = link, CVDisplayLinkIsRunning(link) else { return }
    checkResult(CVDisplayLinkStop(link), "CVDisplayLinkStop")
    log.trace("DisplayLink stopped")
  }

  /// This should be called at start or if the window has changed displays
  func updateDisplayLink() {
    assert(DispatchQueue.isExecutingIn(.main))
    // Get window from pwc! Don't assume VideoView is attached to window yet
    guard let link, let displayId = player.pwc.window?.screen?.displayId else { return }

    // Do nothing if on the same display
    guard currentDisplay != displayId else {
      log.trace("No need to update DisplayLink; currentDisplayID (\(displayId)) is unchanged")
      return
    }
    log.verbose("DisplayLink: updating for displayID \(displayId)")
    currentDisplay = displayId

    checkResult(CVDisplayLinkSetCurrentCGDisplay(link, displayId), "CVDisplayLinkSetCurrentCGDisplay")
    let actualData = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    var actualFps: Double = 0

    if (nominalData.flags & Int32(CVTimeFlags.isIndefinite.rawValue)) < 1 {
      let nominalFps = Double(nominalData.timeScale) / Double(nominalData.timeValue)

      if actualData > 0 {
        actualFps = 1/actualData
      }

      if abs(actualFps - nominalFps) > 1 {
        log.debug("Switching to nominal display refresh rate: \(actualFps) → \(nominalFps)")
        actualFps = nominalFps
      }
    } else {
      log.debug("Switching standard display refresh rate: \(actualFps) → 60")
      actualFps = 60
    }
    player.mpv.queue.async { [self] in
      guard !player.isStopping else { return }
      player.mpv.setDouble(MPVOption.Video.displayFpsOverride, actualFps)
      log.verbose("DisplayLink: update done")
    }
  }


  // MARK: - Reducing Energy Use

  /// Starts the display link if it has been stopped in order to save energy.
  func displayActive() {
    let hasTimeout = player.info.isPaused
    log.trace("VideoView displayActive willTimeout=\(hasTimeout.yn)")
    assert(DispatchQueue.isExecutingIn(.main))
    if !hasTimeout {
      displayIdleTimer.cancel()
    }
    startDisplayLink()
    if hasTimeout {
      displayIdleTimer.restart()
    }
  }

  /// Reduces energy consumption when the display link does not need to be running.
  ///
  /// Adherence to energy efficiency best practices requires that IINA be absolutely idle when there is no reason to be performing any
  /// processing, such as when playback is paused. The [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k)
  /// is a high-priority thread that runs at the refresh rate of a display. If the display is not being updated it is desirable to stop the
  /// display link in order to not waste energy on needless processing.
  ///
  /// However, IINA will pause playback for short intervals when performing certain operations. In such cases it does not make sense to
  /// shutdown the display link only to have to immediately start it again. To avoid this a `Timer` is used to delay shutting down the
  /// display link. If playback becomes active again before the timer has fired then the `Timer` will be invalidated and the display link
  /// will not be shutdown.
  ///
  /// - Note: In addition to playback the display link must be running for operations such seeking, stepping and entering and leaving
  ///         full screen mode.
  func displayIdle() {
    // Because the display link is critical there is an internal setting that can be changed to
    // disable shutting down the display link should any problems with this energy saving feature
    // be discovered.
    guard Preference.bool(for: .enableDisplayIdle) else {
      displayIdleTimer.cancel()
      return
    }
    log.trace("VideoView displayIdle")
    assert(DispatchQueue.isExecutingIn(.main))
    displayIdleTimer.restart()
  }

  /// Triggered when `displayIdleTimer` times out
  @objc func displayIdleDidTimeout() {
    guard let glLayer else { return }
    assert(DispatchQueue.isExecutingIn(.main))
    glLayer.exitAsynchronousMode()
    glLayer.videoView.stopDisplayLink()
  }


  // MARK: - Error Logging

  /// Check the result of calling a [Core Video](https://developer.apple.com/documentation/corevideo) method.
  ///
  /// If the result code is not [kCVReturnSuccess](https://developer.apple.com/documentation/corevideo/kcvreturnsuccess)
  /// then a warning message will be logged. Failures are only logged because previously the result was not checked. We want to see if
  /// calls have been failing before taking any action other than logging.
  /// - Note: Error checking was added in response to issue [#4520](https://github.com/iina/iina/issues/4520)
  ///         where a core video method unexpectedly failed.
  /// - Parameters:
  ///   - result: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by the core video method.
  ///   - method: The core video method that returned the result code.
  private func checkResult(_ result: CVReturn, _ method: String) {
    guard result != kCVReturnSuccess else { return }
    log.warn("Core video method \(method) returned: \(codeToString(result)) (\(result))")
  }

  /// Return a string describing the given [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes).
  ///
  /// What is needed is an API similar to `strerr` for a `CVReturn` code. A search of Apple documentation did not find such a
  /// method.
  /// - Parameter code: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by a core video method.
  /// - Returns: A description of what the code indicates.
  private func codeToString(_ code: CVReturn) -> String {
    switch code {
    case kCVReturnSuccess:
      return "Function executed successfully without errors"
    case kCVReturnInvalidArgument:
      return "At least one of the arguments passed in is not valid. Either out of range or the wrong type"
    case kCVReturnAllocationFailed:
      return "The allocation for a buffer or buffer pool failed. Most likely because of lack of resources"
    case kCVReturnInvalidDisplay:
      return "A CVDisplayLink cannot be created for the given DisplayRef"
    case kCVReturnDisplayLinkAlreadyRunning:
      return "The CVDisplayLink is already started and running"
    case kCVReturnDisplayLinkNotRunning:
      return "The CVDisplayLink has not been started"
    case kCVReturnDisplayLinkCallbacksNotSet:
      return "The output callback is not set"
    case kCVReturnInvalidPixelFormat:
      return "The requested pixelformat is not supported for the CVBuffer type"
    case kCVReturnInvalidSize:
      return "The requested size (most likely too big) is not supported for the CVBuffer type"
    case kCVReturnInvalidPixelBufferAttributes:
      return "A CVBuffer cannot be created with the given attributes"
    case kCVReturnPixelBufferNotOpenGLCompatible:
      return "The Buffer cannot be used with OpenGL as either its size, pixelformat or attributes are not supported by OpenGL"
    case kCVReturnPixelBufferNotMetalCompatible:
      return "The Buffer cannot be used with Metal as either its size, pixelformat or attributes are not supported by Metal"
    case kCVReturnWouldExceedAllocationThreshold:
      return """
        The allocation request failed because it would have exceeded a specified allocation threshold \
        (see kCVPixelBufferPoolAllocationThresholdKey)
        """
    case kCVReturnPoolAllocationFailed:
      return "The allocation for the buffer pool failed. Most likely because of lack of resources. Check if your parameters are in range"
    case kCVReturnInvalidPoolAttributes:
      return "A CVBufferPool cannot be created with the given attributes"
    case kCVReturnRetry:
      return "a scan hasn't completely traversed the CVBufferPool due to a concurrent operation. The client can retry the scan"
    default:
      return "Unrecognized core video return code"
    }
  }
}

func displayLinkCallback(
  _ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>,
  _ inOutputTime: UnsafePointer<CVTimeStamp>,
  _ flagsIn: CVOptionFlags,
  _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
  _ context: UnsafeMutableRawPointer?) -> CVReturn {
    let glVideoLayer = unsafeBitCast(context, to: GLVideoLayer.self)
    glVideoLayer.videoView.$isUninited.withLock() { isUninited in
      guard !isUninited else { return }
      glVideoLayer.mpvReportSwap()
    }
    if glVideoLayer.isAsynchronous && glVideoLayer.videoView.needsForcedRedraws() {
      glVideoLayer.drawAsync(forced: true)
    }
    return kCVReturnSuccess
  }
