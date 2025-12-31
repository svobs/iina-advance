//
//  VideoView.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

/// This is the video canvas. It is usually a child view of `ViewportView`, though not in some
/// states such as PiP.
///
/// `VideoView.swift`: mouse events, drag & drop, color & EDR configuration.
/// See also:
/// `VideoView_DisplayLink.swift`: for managing the Core Video DisplayLink.
/// `VideoView_Constraints.swift`: for enforcing aspect ratio & other AutoLayout constraints.
/// `GLVideoLayer.swift`: the OpenGL video layer for this view.
class VideoView: NSView {
  /// `true`: use legacy OpenGL / libmpv
  /// `false`: use gpu-next / Vulkan
  let useOpenGL = true

  unowned var player: PlayerCore!
  var link: CVDisplayLink?

  var log: any Logger.Subsystem {
    return player.log
  }

  /// The GLVideoLayer layer, if using OpenGL with proper init
  var glLayer: GLVideoLayer? { layer as? GLVideoLayer }
  /// The Metal layer, if using MoltenVK with proper init
  var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

  /// Roughly equivalent to `player.info.isVideoTrackSelected`, but more performant
  var isVidEnabled = false
  var isVidAlbumArt = false
  var isReadyToRender = false

  var layerColorspace: CGColorSpace? {
    return glLayer?.colorspace ?? metalLayer?.colorspace
  }

  @Atomic var isUninited = false

  // cached indicator to prevent unnecessary updates of DisplayLink
  var currentDisplay: UInt32?
  
  let displayIdleTimer = TimeoutTimer(timeout: Constants.TimeInterval.displayIdleTimeout)

  private let logHDR: any Logger.Subsystem

  static let SRGB = CGColorSpaceCreateDeviceRGB()

  // MARK: Init

  init(frame: CGRect, player: PlayerCore) {
    self.logHDR = Logger.makeSubsystem(player, fmt: Constants.String.iinaHdrCategoryFmt)
    self.player = player
    super.init(frame: frame)
    self.idString = "VideoView"

    displayIdleTimer.action = displayIdleDidTimeout

    translatesAutoresizingMaskIntoConstraints = false
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.defaultLow, for: .vertical)

    // dragging init
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
  }

  convenience init(player: PlayerCore) {
    self.init(frame: .zero, player: player)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: De-Init

  deinit {
    uninit()
  }

  /// Uninitialize this view.
  ///
  /// This method will stop drawing and free the mpv render context. This is done before sending a quit command to mpv.
  /// - Important: Once mpv has been instructed to quit accessing the mpv core can result in a crash, therefore locks must be
  ///     used to coordinate uninitializing the view so that other threads do not attempt to use the mpv core while it is shutting down.
  func uninit() {
    log.verbose("VideoView uninit start")
    stopDisplayLink()
    guard lockAndSetOpenGLContext() else { return }
    defer { unlockOpenGLContext() }
    $isUninited.withLock() { [self] isUninited in
      guard !isUninited else {
        log.verbose("VideoView uninit already done, skipping")
        return
      }
      isUninited = true

      glLayer?.deinitGLRendering()
      log.verbose("VideoView uninit done")
    }
  }

  // MARK: - Mouse events

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  /// In native full screen, `VideoView` receives mouse events instead of the window, so it is necessary to forward them
  /// to the window controller for handling.
  override func mouseDown(with event: NSEvent) {
    player.pwc.mouseDown(with: event)
    super.mouseDown(with: event)
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// See `PlayerWindowController.workaroundCursorDefect` and the issue for details on this workaround.
  override func rightMouseDown(with event: NSEvent) {
    player.pwc.rightMouseDown(with: event)
    super.rightMouseDown(with: event)
  }

  /// Workaround for issue #3211, Legacy fullscreen is broken (11.0.1)
  ///
  /// Changes in Big Sur broke the legacy full screen feature. The `PlayerWindowController` method `legacyAnimateToWindowed`
  /// had to be changed to get this feature working again. Under Big Sur that method now calls the AppKit method
  /// `window.styleMask.insert(.titled)`. This is a part of restoring the window's style mask to the way it was before entering
  /// full screen mode. A side effect of restoring the window's title is that AppKit stops calling `PlayerWindowController.mouseUp`.
  /// This appears to be a defect in the Cocoa framework. See the issue for details. As a workaround the mouse up event is caught in
  /// the view which then calls the window controller's method.
  override func mouseUp(with event: NSEvent) {
    // Only check for Big Sur or greater, not if the preference use legacy full screen is enabled as
    // that can be changed while running and once the window title has been removed and added back
    // AppKit malfunctions from then on. The check for running under Big Sur or later isn't really
    // needed as it would be fine to always call the controller. The check merely makes it clear
    // that this is only needed due to macOS changes starting with Big Sur.
    if #available(macOS 11, *) {
      player.pwc.mouseUp(with: event)
    } else {
      super.mouseUp(with: event)
    }
  }

  // MARK: - Drag and drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

  // MARK: - OpenGL Rendering

  /// Called when property `self.wantsLayer` is set to `true`.
  override func makeBackingLayer() -> CALayer {
    if useOpenGL {
      return GLVideoLayer(self)
    } else {
      return MetalVideoLayer()
    }
  }

  @MainActor
  func initVideoLayer() {
    if useOpenGL {
      log.verbose("Init OpenGL layer")
      /// This will create & add the layer if it was not already init'd:
      wantsLayer = true
      glLayer?.initGLRendering()
      displayActive()
    } else {
      log.verbose("Init Metal layer")
      wantsLayer = true
    }
  }

  /// Lock the OpenGL context associated with the mpv renderer and set it to be the current context for this thread.
  ///
  /// This method is needed to meet this requirement from `mpv/render.h`:
  ///
  /// If the OpenGL backend is used, for all functions the OpenGL context must be "current" in the calling thread, and it must be the
  /// same OpenGL context as the `mpv_render_context` was created with. Otherwise, undefined behavior will occur.
  ///
  /// - Reference: [mpv render.h](https://github.com/mpv-player/mpv/blob/master/libmpv/render.h)
  /// - Reference: [Concurrency and OpenGL](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_threading/opengl_threading.html)
  /// - Reference: [OpenGL Context](https://www.khronos.org/opengl/wiki/OpenGL_Context)
  /// - Attention: Do not forget to unlock the OpenGL context by calling `unlockOpenGLContext`
  @discardableResult
  func lockAndSetOpenGLContext() -> Bool {
    guard let glVideoLayer = layer as? GLVideoLayer else { return false }
    return glVideoLayer.lockAndSetOpenGLContext()
  }

  /// Unlock the OpenGL context associated with the mpv renderer.
  func unlockOpenGLContext() {
    guard let glVideoLayer = layer as? GLVideoLayer else { return }
    glVideoLayer.unlockOpenGLContext()
  }

  // MARK: - Misc

  func needsForcedRedraws() -> Bool {
    guard player.pwc.loaded, player.isActive else { return false }
    guard player.videoView.isVidEnabled, player.videoView.isVidAlbumArt || player.info.isPaused else { return false }
    return true
  }

  func activateForcedRedraws() {
    guard needsForcedRedraws() else { return }
    log.trace("Activating forced redraws")
    enterAsynchronousMode()
    displayActive()
  }

  /// Deprecated! Use `activateForcedRedraws` instead.
  func forceDraw() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard needsForcedRedraws() else { return }
    glLayer?.drawAsync(forced: true)
  }

  func addShadowForInteractiveMode() {
    guard let videoLayer = layer else { return }
    videoLayer.shadowColor = .black
    videoLayer.shadowOffset = .zero
    videoLayer.shadowOpacity = 1
    videoLayer.shadowRadius = 3
  }

  func enterAsynchronousMode() {
    glLayer?.enterAsynchronousMode()
  }

  /// Returns `true` if screenScaleFactor changed
  @discardableResult
  func refreshContentsScale() -> Bool {
    // Grab window from PlayerWindowController! Don't assume VideoView is currently attached.
    guard let window = player.pwc.window else { return false }
    guard player.isActive else { return false }
    guard let videoLayer = layer else { return false }
    let oldScaleFactor = videoLayer.contentsScale
    let newScaleFactor = window.backingScaleFactor
    if oldScaleFactor != newScaleFactor {
      log.verbose("Window backingScaleFactor changed: \(oldScaleFactor) → \(newScaleFactor)")
      videoLayer.contentsScale = newScaleFactor
      return true
    }
    log.verbose("No change to window backingScaleFactor (\(oldScaleFactor))")
    return false
  }

  func refreshAllVideoDisplayState() {
    guard player.pwc.loaded, player.isActive && !player.isRestoring else { return }
    log.verbose("Refreshing all VideoView display state")
    updateDisplayLink()
    refreshContentsScale()
    refreshEdrMode()
  }

  // MARK: - Color

  func setICCProfile() {
    guard let glLayer else {
      // TODO: is this relevant for Metal layer?
      logHDR.verbose("Skipping ICC profile: no OpenGL layer")
      return
    }
    let screenColorSpace = player.pwc.window?.screen?.colorSpace
    if !Preference.bool(for: .loadIccProfile) {
      logHDR.verbose("Not using ICC profile due to user preference")
    } else if let screenColorSpace {
      let name = screenColorSpace.localizedName ?? "unnamed"
      logHDR.verbose("Using the ICC profile of the color space \(name.quoted)")
      // This MUST be locked via openGLContext

      guard lockAndSetOpenGLContext() else { return }
      defer { unlockOpenGLContext() }
      $isUninited.withLock() { isUninited in
        guard !isUninited else { return }
        // Set MPV_RENDER_PARAM_ICC_PROFILE before enabling icc-profile-auto to true as mpv requires
        // that parameter be set in the render context when icc-profile-auto is in use.
        glLayer.setRenderICCProfile(screenColorSpace)
      }

    } else {
      logHDR.warn("Cannot set auto ICC profile; no screen color space")
    }

    let sdrColorSpace = screenColorSpace?.cgColorSpace ?? VideoView.SRGB
    if glLayer.colorspace != sdrColorSpace {
      let name = sdrColorSpace.name as? String ?? screenColorSpace?.localizedName ?? "Unspecified"
      logHDR.verbose("Setting layer color space to \(name.quoted)")
      glLayer.colorspace = sdrColorSpace
      glLayer.wantsExtendedDynamicRangeContent = false
    }

    player.mpv.queue.async { [self] in
      guard player.isActive, player.info.isFileLoaded else { return }
      let useAutoICC = Preference.bool(for: .loadIccProfile) && screenColorSpace != nil
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, useAutoICC)

      player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.targetPeak, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.toneMapping, "auto")
      // Check first to avoid spurious error in mpv 0.40.0 log complaining about the value being out of range
      if player.mpv.getString(MPVOption.GPURendererOptions.toneMappingParam) != "default" {
        player.mpv.setString(MPVOption.GPURendererOptions.toneMappingParam, "default")
      }
      player.mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, false)
    }
  }

  // MARK: - HDR

  /// See also: `refreshAllVideoDisplayState`. Cannot execute until player is started & file is loaded.
  func refreshEdrMode() {
    guard player.pwc.loaded else { return }
    guard player.info.isFileLoaded else { return }
    guard let displayId = currentDisplay else { return }
    if let screen = self.window?.screen {
      NSScreen.logEDR("Refreshing HDR for \(player.subsystem.rawValue) on display\(displayId)",
                      screen, subsystem: logHDR)
    }
    requestEdrMode(then: { [self] edrEnabled in
      DispatchQueue.main.execOrAsync { [self] in
        let edrAvailable = edrEnabled != false
        if player.info.hdrAvailable != edrAvailable {
          player.info.hdrAvailable = edrAvailable
          player.pwc.quickSettingView.setHdrAvailability(to: edrAvailable)
        }
        if edrEnabled != true { setICCProfile() }
      }
    })
  }

  private func requestEdrMode(then doAfter: @escaping (Bool?) -> Void) {
    player.mpv.queue.async { [self] in
      guard player.info.isFileLoaded, let mpv = player.mpv else {
        return doAfter(false)
      }

      guard let primaries = mpv.getString(MPVProperty.videoParamsPrimaries), let gamma = mpv.getString(MPVProperty.videoParamsGamma) else {
        logHDR.debug("Video gamma and primaries not available")
        return doAfter(false)
      }

      let peak = mpv.getDouble(MPVProperty.videoParamsSigPeak)
      logHDR.debug("Video gamma=\(gamma), primaries=\(primaries), sig_peak=\(peak)")

      // HDR videos use a Hybrid Log Gamma (HLG) or a Perceptual Quantization (PQ) transfer function.
      guard gamma == "hlg" || gamma == "pq" else {
        return doAfter(false)
      }

      let name: CFString
      switch primaries {
      case "display-p3":
        if #available(macOS 10.15.4, *) {
          name = CGColorSpace.displayP3_PQ
        } else {
          name = CGColorSpace.displayP3_PQ_EOTF
        }

      case "bt.2020":
        if #unavailable(macOS 10.15.4) {
          name = CGColorSpace.itur_2020_PQ_EOTF
        } else if #unavailable(macOS 11.0) {
          name = CGColorSpace.itur_2020_PQ
        } else {
          name = CGColorSpace.itur_2100_PQ
        }

      case "bt.709":
        // SDR
        return doAfter(false)

      default:
        logHDR.warn("Unsupported color space: gamma=\(gamma) primaries=\(primaries)")
        return doAfter(false)
      }

      DispatchQueue.main.async { [self] in
        guard let window = player.pwc.window else { return }
        let maxRangeEDR = window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        guard maxRangeEDR > 1.0 else {
          logHDR.debug("HDR video was found but the display does not support EDR mode (maxEDR=\(maxRangeEDR))")
          return doAfter(false)
        }

        guard player.info.hdrEnabled else {
          return doAfter(nil)
        }

        guard let glLayer else {
          // TODO: is this relevant for Metal layer?
          logHDR.verbose("Aborting HDR mode: no OpenGL layer")
          return doAfter(nil)
        }

        logHDR.debug("Using HDR color space instead of ICC profile (maxEDR=\(maxRangeEDR))")
        glLayer.wantsExtendedDynamicRangeContent = true
        glLayer.colorspace = CGColorSpace(name: name)

        player.mpv.queue.async { [self] in
          guard player.isActive else {
            return doAfter(false)
          }

          mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
          mpv.setString(MPVOption.GPURendererOptions.targetPrim, primaries)
          // PQ videos will be display as it was, HLG videos will be converted to PQ
          mpv.setString(MPVOption.GPURendererOptions.targetTrc, "pq")
          mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, true)

          if Preference.bool(for: .enableToneMapping) {
            var targetPeak = Preference.integer(for: .toneMappingTargetPeak)
            // If the target peak is set to zero then IINA attempts to determine peak brightness of the
            // display.
            if targetPeak == 0 {
              if let displayInfo = CoreDisplay_DisplayCreateInfoDictionary(currentDisplay!)?.takeRetainedValue() as? [String: AnyObject] {
                logHDR.debug("Successfully obtained information about the display")
                // Apple Silicon Macs use the key NonReferencePeakHDRLuminance.
                if let hdrLuminance = displayInfo["NonReferencePeakHDRLuminance"] as? Int {
                  logHDR.debug("Found NonReferencePeakHDRLuminance: \(hdrLuminance)")
                  targetPeak = hdrLuminance
                } else if let hdrLuminance = displayInfo["DisplayBacklight"] as? Int {
                  // Intel Macs use the key DisplayBacklight.
                  logHDR.debug("Found DisplayBacklight: \(hdrLuminance)")
                  targetPeak = hdrLuminance
                } else {
                  logHDR.debug("Didn't find NonReferencePeakHDRLuminance or DisplayBacklight, assuming HDR400")
                  logHDR.debug("Display info dictionary: \(displayInfo)")
                  targetPeak = 400
                }
              } else {
                logHDR.warn("Unable to obtain display information, assuming HDR400")
                targetPeak = 400
              }
            }
            let algorithm = Preference.ToneMappingAlgorithmOption(rawValue: Preference.integer(for: .toneMappingAlgorithm))?.mpvString
            ?? Preference.ToneMappingAlgorithmOption.defaultValue.mpvString

            logHDR.debug("Will enable tone mapping: target-peak=\(targetPeak) algorithm=\(algorithm)")
            mpv.setInt(MPVOption.GPURendererOptions.targetPeak, targetPeak)
            mpv.setString(MPVOption.GPURendererOptions.toneMapping, algorithm)
          } else {
            mpv.setString(MPVOption.GPURendererOptions.targetPeak, "auto")
            mpv.setString(MPVOption.GPURendererOptions.toneMapping, "")
          }
        }
        return doAfter(true)
      }
    }
  }
}
