//
//  GLVideoLayer.swift
//  iina
//
//  Created by lhc on 27/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import OpenGL.GL
import OpenGL.GL3

class GLVideoLayer: CAOpenGLLayer {

  unowned var videoView: VideoView!

  var player: PlayerCore { videoView.player }

  var mpvRenderContext: OpaquePointer?

  var openGLContext: CGLContextObj! = nil

  private var bufferDepth: GLint = 8

  private let cglContext: CGLContextObj
  private let cglPixelFormat: CGLPixelFormatObj

  private let mpvGLQueue = DispatchQueue(label: "com.iina_advance.mpvgl", qos: .userInteractive)
  @Atomic var currentQueueSize: Int = 0

  private var fbo: GLint = 1

  private var needsMPVRender = false
  var asynchronousModeStartTime: TimeInterval?

  var lastRenderTime: TimeInterval = CFAbsoluteTimeGetCurrent()

  /// To enable `LOG_VIDEO_LAYER`:
  /// 1. In Xcode, go to `iina` project > select `iina` target > Build Settings > search for `Other Swift Flags`
  /// (under `Swift Compiler - Custom Flags`)
  /// 2. Set flag using -D prefix (without white spaces), for Debug, Release, etc. So this is: `-DLOG_VIDEO_LAYER`
#if LOG_VIDEO_LAYER
  // For measuring frames per second
  var lastPrintTime = CFAbsoluteTimeGetCurrent()
  var displayCountTotal: Int = 0
  var displayCountLastPrint: Int = 0
  var canDrawCountTotal: Int = 0
  var canDrawCountLastPrint: Int = 0
  var drawCountTotal: Int = 0
  var drawCountLastPrint: Int = 0
  var forcedCountTotal: Int = 0
  var forcedCountLastPrint: Int = 0
  var lastWidth: Int32 = 0
  var lastHeight: Int32 = 0

  func printStats() {
    let now = CFAbsoluteTimeGetCurrent()
    let secsSinceLastPrint = now - lastPrintTime
    if secsSinceLastPrint >= 1.0 {  // print at most once per sec
      let displaysSinceLastPrint = displayCountTotal - displayCountLastPrint
      let canDrawCallsSinceLastPrint = canDrawCountTotal - canDrawCountLastPrint
      let drawsSinceLastPrint = drawCountTotal - drawCountLastPrint
      let forcedSinceLastPrint = forcedCountTotal - forcedCountLastPrint

      let fpsDraws = CGFloat(drawsSinceLastPrint) / secsSinceLastPrint
      lastPrintTime = now
      displayCountLastPrint = displayCountTotal
      canDrawCountLastPrint = canDrawCountTotal
      drawCountLastPrint = drawCountTotal
      forcedCountLastPrint = forcedCountTotal
      NSLog("FPS: \(fpsDraws.stringMaxFrac2) (\(drawsSinceLastPrint)/\(canDrawCallsSinceLastPrint) requests drawn, \(forcedSinceLastPrint) forced, \(displaysSinceLastPrint) displays over \(secsSinceLastPrint.twoDecimalPlaces)s) Scale: \(contentsScale.stringMaxFrac6), LayerSize: \(Int(frame.size.width))x\(Int(frame.size.height)), LastDrawSize: \(lastWidth)x\(lastHeight)")
    }
  }
#endif

  init(_ videoView: VideoView) {
    self.videoView = videoView
    (cglPixelFormat, bufferDepth) = GLVideoLayer.createPixelFormat(videoView.player)
    cglContext = GLVideoLayer.createContext(cglPixelFormat)
    super.init()
    isOpaque = true
    /// Do not set to `[.layerWidthSizable, .layerHeightSizable]` resizable! It messes up during window resize if the trailing inside sidebar is open.
    /// HOWEVER: the above mask *is* needed when in PiP so that it resizes with the PiP panel.
    autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    if bufferDepth > 8 {
      contentsFormat = .RGBA16Float
    }
  }

  override init(layer: Any) {
    let previousLayer = layer as! GLVideoLayer
    cglPixelFormat = previousLayer.cglPixelFormat
    bufferDepth = previousLayer.bufferDepth
    cglContext = previousLayer.cglContext
    videoView = previousLayer.videoView
    super.init()
    isOpaque = true
    asynchronousModeStartTime = previousLayer.asynchronousModeStartTime
    isAsynchronous = previousLayer.isAsynchronous
    autoresizingMask = previousLayer.autoresizingMask
    contentsFormat = previousLayer.contentsFormat
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj { cglPixelFormat }

  override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj { cglContext }

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
    guard let openGLContext else { return false }
    CGLLockContext(openGLContext)
    CGLSetCurrentContext(openGLContext)
    return true
  }

  /// Unlock the OpenGL context associated with the mpv renderer.
  func unlockOpenGLContext() {
    CGLUnlockContext(openGLContext)
  }

  // MARK: Draw

  override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
    guard lockAndSetOpenGLContext() else { return false }
    defer { unlockOpenGLContext() }
    guard !videoView.isUninited else { return false }
#if LOG_VIDEO_LAYER
    canDrawCountTotal += 1

    // Safely log CVTimeStamp values from optional pointer(s)
    let vidTSString: String
    let hostTSString: String
    // ts may be UnsafePointer<CVTimeStamp>? or UnsafePointer<UnsafePointer<CVTimeStamp>?>
    if let directPtr = ts {
      let tsVal = directPtr.pointee
      vidTSString = String(tsVal.videoTime)
      hostTSString = String(tsVal.hostTime)
    } else if let ptrToPtr = (unsafeBitCast(ts, to: Optional<UnsafePointer<UnsafePointer<CVTimeStamp>?>>.self)), let inner = ptrToPtr.pointee {
      let tsVal = inner.pointee
      vidTSString = String(tsVal.videoTime)
      hostTSString = String(tsVal.hostTime)
    } else {
      vidTSString = "nil"
      hostTSString = "nil"
    }
    NSLog("CAN_DRAW vidTS=\(vidTSString) layerTime=\(t) hostTS=\(hostTSString) queue=\(DispatchQueue.currentQueueLabel ?? "nil")")
    printStats()
#endif
    // Prevent crash if trying to use forceRender when vid=0 (usually when toggling video on or off)
    guard videoView.isReadyToRender else { return false }
    if isAsynchronous { return true }
    return shouldRenderUpdateFrame()
  }

  override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                     forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    assert(DispatchQueue.current == nil || DispatchQueue.current!.qos == DispatchQoS.userInteractive,
           "Unexpected DQ priority for: \(DispatchQueue.current!.label)")
    lockAndSetOpenGLContext()
    defer { unlockOpenGLContext() }

    guard !videoView.isUninited else { return }

    needsMPVRender = false

    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

    var i: GLint = 0
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &i)
    var dims: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_VIEWPORT), &dims);

    var flip: CInt = 1

    withUnsafeMutablePointer(to: &flip) { flip in
      if let context = mpvRenderContext {
        fbo = i != 0 ? i : fbo
#if LOG_VIDEO_LAYER
        lastWidth = Int32(dims[2])
        lastHeight = Int32(dims[3])
        drawCountTotal += 1
        printStats()

        // Safely log CVTimeStamp values from optional pointer(s)
        let vidTSString: String
        let hostTSString: String
        // ts may be UnsafePointer<CVTimeStamp>? or UnsafePointer<UnsafePointer<CVTimeStamp>?>
        if let directPtr = ts {
          let tsVal = directPtr.pointee
          vidTSString = String(tsVal.videoTime)
          hostTSString = String(tsVal.hostTime)
        } else if let ptrToPtr = (unsafeBitCast(ts, to: Optional<UnsafePointer<UnsafePointer<CVTimeStamp>?>>.self)), let inner = ptrToPtr.pointee {
          let tsVal = inner.pointee
          vidTSString = String(tsVal.videoTime)
          hostTSString = String(tsVal.hostTime)
        } else {
          vidTSString = "nil"
          hostTSString = "nil"
        }
        NSLog("DRAW fbo: \(fbo) vidTS=\(vidTSString) layerTime=\(t) hostTS=\(hostTSString)")

#endif
        var data = mpv_opengl_fbo(fbo: Int32(fbo),
                                  w: Int32(dims[2]),
                                  h: Int32(dims[3]),
                                  internal_format: 0)
        withUnsafeMutablePointer(to: &data) { data in
          withUnsafeMutablePointer(to: &bufferDepth) { bufferDepth in
            var params: [mpv_render_param] = [
              mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: .init(data)),
              mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: .init(flip)),
              mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data:.init(bufferDepth)),
              mpv_render_param()
            ]
            /// # IGNORE THIS XCODE HANG RISK WARNING!
            /// Calling this directly from the DisplayLink instead of enqueuing in its own DispatchQueue results in reduced draw latency, but
            /// it is only used for brief periods during animations which include a timeout.
            mpv_render_context_render(context, &params)
            ignoreGLError()
          }
        }
      } else {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
      }
    }
    glFlush()
  }

  /// We want `isAsynchronous = true` while executing any animation which causes the layer to resize.
  /// But we don't want to leave this on full-time, because it will result in extra draw requests and may
  /// throw off the timing of each draw.
  @MainActor
  func enterAsynchronousMode() {
    asynchronousModeStartTime = CFAbsoluteTimeGetCurrent()
    if !isAsynchronous {
      videoView.player.log.verbose("Entering asynchronous mode")
    }
    /// Set this to `true` to enable video redraws to match the timing of the view redraw during animations.
    /// This fixes a situation where the layer size may not match the size of its superview at each redraw,
    /// which would cause noticable clipping or wobbling during animations.
    isAsynchronous = true
  }

  /// Similar to `drawSync()`, but draws asynchronously by first enqueuing onto a `DispatchQueue`.
  /// This is also self-correcting under heavy load by dropping draw calls when the queue starts to grow.
  func drawAsync(onSuccess: OnSuccessCallback? = nil) {
    // Playback is noticeable smoother for ≥30fps videos if this is called immediately instead of enqueued…
    // Could this cause a race condition which results in the draw call being off by a frame? Do we care?
    mpvReportSwap()

    $currentQueueSize.withLock { $0 += 1 }
    mpvGLQueue.async { [self] in
      let queueSize = $currentQueueSize.withLock {
        $0 -= 1
        return $0
      }

      // Drop DQ tasks aggressively if under any load. Remember that one task is enqueued for each
      // DisplayLink callback, which occurs at the rate of the display's FPS, which may be much higher than
      // the video's FPS already. And it makes no sense to fall behind because that just creates video latency.
      guard queueSize <= 1 else { return }

      display()
      if let onSuccess {
        onSuccess()
      }
    }
  }

  /// Although this generates a warning in Xcode, synchronous drawing via the DisplayLink is far smoother during
  /// animations. Despite Xcode's warning, this should not result in a unrecoverable lockup because we only use this
  /// for brief & finite periods (during animations and/or resizing, as indicated by `isAsynchronous==true`). Under
  /// normal circumstances, `drawAsync` is used.
  func drawSync(onSuccess: OnSuccessCallback? = nil) {
    mpvReportSwap()
    display()

    if let onSuccess {
      onSuccess()
    }
  }

  override func display() {
    super.display()
    CATransaction.flush()

#if LOG_VIDEO_LAYER
    displayCountTotal += 1
#endif

    // Must lock the OpenGL context before calling mpv render methods. Can't wait until we have
    // checked the flags to see if a skip renderer is needed because the OpenGL context must always
    // be locked before locking the isUninited lock to avoid deadlocks. The flags can't be checked
    // without locking isUninited to avoid data races.
    guard lockAndSetOpenGLContext() else { return }
    defer { unlockOpenGLContext() }
    guard !videoView.isUninited else { return }

    guard needsMPVRender || isAsynchronous else { return }

    // Neither canDraw nor draw(inCGLContext:) were called by AppKit, needs a skip render.
    // This can happen when IINA is playing in another space, as might occur when just playing
    // audio. See issue #5025.
    if let renderContext = mpvRenderContext,
       shouldRenderUpdateFrame() {
      var skip: CInt = 1
      withUnsafeMutablePointer(to: &skip) { skip in
        var params: [mpv_render_param] = [
          mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: .init(skip)),
          mpv_render_param()
        ]
        mpv_render_context_render(renderContext, &params)
      }
    }
    needsMPVRender = false
  }

  /// Initialize the `mpv` renderer.
  ///
  /// This method creates and initializes the `mpv` renderer and sets the callback that `mpv` calls when a new video frame is available.
  ///
  /// - Note: Advanced control must be enabled for the screenshot command to work when the window flag is used. See issue
  ///         [#4822](https://github.com/iina/iina/issues/4822) for details.
  /// Initialize the `mpv` renderer.
  ///
  /// This method creates and initializes the `mpv` renderer and sets the callback that `mpv` calls when a new video frame is available.
  ///
  /// - Note: Advanced control must be enabled for the screenshot command to work when the window flag is used. See issue
  ///         [#4822](https://github.com/iina/iina/issues/4822) for details.
  func initGLRendering() {
    guard let mpv = player.mpv else {
      fatalError("initGLRendering() should be called after mpv handle being initialized!")
    }
    let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)

    func mpvGetOpenGLFunc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
      let symbolName: CFString = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
      guard let addr = CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier(CFStringCreateCopy(kCFAllocatorDefault, "com.apple.opengl" as CFString)), symbolName) else {
        Logger.fatal("Cannot get OpenGL function pointer!")
      }
      return addr
    }

    func mpvUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
      let layer = bridge(ptr: ctx!) as GLVideoLayer
      layer.videoView.isReadyToRender = true
    }

    var openGLInitParams = mpv_opengl_init_params(get_proc_address: mpvGetOpenGLFunc,
                                                  get_proc_address_ctx: nil)
    withUnsafeMutablePointer(to: &openGLInitParams) { openGLInitParams in
      var advanced: CInt = 1
      withUnsafeMutablePointer(to: &advanced) { advanced in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: openGLInitParams),
          mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
          mpv_render_param()
        ]
        mpv.chkErr(mpv_render_context_create(&mpvRenderContext, mpv.mpv, &params))
      }
      openGLContext = CGLGetCurrentContext()
      mpv_render_context_set_update_callback(mpvRenderContext!, mpvUpdateCallback, mutableRawPointerOf(obj: self))
    }
  }

  func deinitGLRendering() {
    guard let mpvRenderContext = mpvRenderContext else { return }
    player.log.verbose("Uninit mpv rendering")
    mpv_render_context_set_update_callback(mpvRenderContext, nil, nil)
    mpv_render_context_free(mpvRenderContext)
    self.mpvRenderContext = nil
  }

  /// Called repeated by DisplayLink callback
  func mpvReportSwap() {
    guard !videoView.isUninited else { return }
    guard let mpvRenderContext = mpvRenderContext else { return }
    mpv_render_context_report_swap(mpvRenderContext)
  }

  func shouldRenderUpdateFrame() -> Bool {
    guard let mpvRenderContext = mpvRenderContext else { return false }
    let flags: UInt64 = mpv_render_context_update(mpvRenderContext)
    return flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) > 0
  }

  /// Set an ICC profile for use with the mpv [icc-profile-auto](https://mpv.io/manual/stable/#options-icc-profile-auto)
  /// option.
  ///
  /// This method fulfills the mpv requirement that applications using libmpv with the render API provide the ICC profile via
  /// `MPV_RENDER_PARAM_ICC_PROFILE` in order for the `--icc-profile-auto` option to work. The ICC profile data will not
  /// be used by mpv unless the option is enabled.
  ///
  /// The IINA `Load ICC profile` setting is tied to the `--icc-profile-auto` option. This allows users to override IINA using
  /// the [--icc-profile](https://mpv.io/manual/stable/#options-icc-profile) option.
  func setRenderICCProfile(_ profile: NSColorSpace) {
    guard let renderContext = mpvRenderContext else { return }
    guard var iccData = profile.iccProfileData else {
      let name = profile.localizedName ?? "unnamed"
      player.log.warn("Color space \(name) does not contain ICC profile data")
      return
    }
    iccData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
      guard let baseAddress = ptr.baseAddress, ptr.count > 0 else { return }

      let u8Ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
      var icc = mpv_byte_array(data: u8Ptr, size: ptr.count)
      withUnsafeMutableBytes(of: &icc) { (ptr: UnsafeMutableRawBufferPointer) in
        let params = mpv_render_param(type: MPV_RENDER_PARAM_ICC_PROFILE, data: ptr.baseAddress)
        mpv_render_context_set_parameter(renderContext, params)
      }
    }
  }

  // MARK: - Core OpenGL Context and Pixel Format

  static let glVersions: [CGLOpenGLProfile] = [
    kCGLOGLPVersion_3_2_Core,
    kCGLOGLPVersion_Legacy
  ]

  static let glFormatBase: [CGLPixelFormatAttribute] = [
    kCGLPFAOpenGLProfile,
    kCGLPFAAccelerated,
    kCGLPFADoubleBuffer
  ]

  static let glFormatSoftwareBase: [CGLPixelFormatAttribute] = [
    kCGLPFAOpenGLProfile,
    kCGLPFARendererID,
    CGLPixelFormatAttribute(UInt32(kCGLRendererGenericFloatID)),
    kCGLPFADoubleBuffer
  ]

  static let glFormatOptional: [[CGLPixelFormatAttribute]] = [
    [kCGLPFABackingStore],
    [kCGLPFAAllowOfflineRenderers]
  ]

  static let glFormat10Bit: [CGLPixelFormatAttribute] = [
    kCGLPFAColorSize,
    _CGLPixelFormatAttribute(rawValue: 64),
    kCGLPFAColorFloat
  ]

  static let glFormatAutoGPU: [CGLPixelFormatAttribute] = [
    kCGLPFASupportsAutomaticGraphicsSwitching
  ]

  static let attributeLookUp: [UInt32: String] = [
    kCGLOGLPVersion_3_2_Core.rawValue: "kCGLOGLPVersion_3_2_Core",
    kCGLOGLPVersion_Legacy.rawValue: "kCGLOGLPVersion_Legacy",
    kCGLPFAOpenGLProfile.rawValue: "kCGLPFAOpenGLProfile",
    UInt32(kCGLRendererGenericFloatID): "kCGLRendererGenericFloatID",
    kCGLPFARendererID.rawValue: "kCGLPFARendererID",
    kCGLPFAAccelerated.rawValue: "kCGLPFAAccelerated",
    kCGLPFADoubleBuffer.rawValue: "kCGLPFADoubleBuffer",
    kCGLPFABackingStore.rawValue: "kCGLPFABackingStore",
    kCGLPFAColorSize.rawValue: "kCGLPFAColorSize",
    kCGLPFAColorFloat.rawValue: "kCGLPFAColorFloat",
    kCGLPFAAllowOfflineRenderers.rawValue: "kCGLPFAAllowOfflineRenderers",
    kCGLPFASupportsAutomaticGraphicsSwitching.rawValue: "kCGLPFASupportsAutomaticGraphicsSwitching"
  ]

  private static func createPixelFormat(_ player: PlayerCore) -> (CGLPixelFormatObj, GLint) {
    var pix: CGLPixelFormatObj?
    var depth: GLint = 8
    var err: CGLError = CGLError(rawValue: 0)
    let swRender: CocoaCbSwRenderer = player.mpv.getEnum(MPVOption.GPURendererOptions.cocoaCbSwRenderer)

    if swRender != .yes {
      (pix, depth, err) = GLVideoLayer.findPixelFormat(player)
    }

    if (err != kCGLNoError || pix == nil) && swRender != .no {
      (pix, depth, err) = GLVideoLayer.findPixelFormat(player, software: true)
    }

    guard let pixelFormat = pix, err == kCGLNoError else {
      Logger.fatal("Cannot create OpenGL pixel format!")
    }

    return (pixelFormat, depth)
  }

  private static func findPixelFormat(_ player: PlayerCore, software: Bool = false) -> (CGLPixelFormatObj?, GLint, CGLError) {
    var pix: CGLPixelFormatObj?
    var err: CGLError = CGLError(rawValue: 0)
    var npix: GLint = 0

    for ver in glVersions {
      var glBase = software ? glFormatSoftwareBase : glFormatBase
      glBase.insert(CGLPixelFormatAttribute(ver.rawValue), at: 1)

      var glFormat = [glBase]
      if player.mpv.getFlag(MPVOption.GPURendererOptions.cocoaCb10bitContext) {
        glFormat += [glFormat10Bit]
      }
      glFormat += glFormatOptional

      if !Preference.bool(for: .forceDedicatedGPU) {
        glFormat += [glFormatAutoGPU]
      }

      for index in stride(from: glFormat.count-1, through: 0, by: -1) {
        let format = glFormat.flatMap { $0 } + [_CGLPixelFormatAttribute(rawValue: 0)]
        err = CGLChoosePixelFormat(format, &pix, &npix)

        if err == kCGLBadAttribute || err == kCGLBadPixelFormat || pix == nil {
          glFormat.remove(at: index)
        } else {
          let attArray = format.map({ (value: _CGLPixelFormatAttribute) -> String in
            return attributeLookUp[value.rawValue] ?? String(value.rawValue)
          })

          player.log.debug("Created CGL pixel format with attributes: " +
                     "\(attArray.joined(separator: ", "))")
          return (pix, glFormat.contains(glFormat10Bit) ? 16 : 8, err)
        }
      }
    }

    let errS = String(cString: CGLErrorString(err))
    player.log.debug("Couldn't create a " + "\(software ? "software" : "hardware accelerated") " +
               "CGL pixel format: \(errS) (\(err.rawValue))")
    let swRenderer: CocoaCbSwRenderer = player.mpv.getEnum(MPVOption.GPURendererOptions.cocoaCbSwRenderer)
    if software == false && swRenderer == .auto {
      player.log.debug("Falling back to software renderer")
    }

    return (pix, 8, err)
  }

  private static func createContext(_ pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
    var ctx: CGLContextObj?
    CGLCreateContext(pixelFormat, nil, &ctx)

    guard let ctx = ctx else {
      Logger.fatal("Cannot create OpenGL context!")
    }

    // Sync to vertical retrace.
    var i: GLint = 1
    CGLSetParameter(ctx, kCGLCPSwapInterval, &i)

    // Enable multi-threaded GL engine.
    CGLEnable(ctx, kCGLCEMPEngine)

    CGLSetCurrentContext(ctx)
    return ctx
  }

  // MARK: Utils

  /** Check OpenGL error (for debug only). */
  func gle() {
    let e = glGetError()
    print(arc4random())
    switch e {
    case GLenum(GL_NO_ERROR):
      break
    case GLenum(GL_OUT_OF_MEMORY):
      print("GL_OUT_OF_MEMORY")
      break
    case GLenum(GL_INVALID_ENUM):
      print("GL_INVALID_ENUM")
      break
    case GLenum(GL_INVALID_VALUE):
      print("GL_INVALID_VALUE")
      break
    case GLenum(GL_INVALID_OPERATION):
      print("GL_INVALID_OPERATION")
      break
    case GLenum(GL_INVALID_FRAMEBUFFER_OPERATION):
      print("GL_INVALID_FRAMEBUFFER_OPERATION")
      break
    case GLenum(GL_STACK_UNDERFLOW):
      print("GL_STACK_UNDERFLOW")
      break
    case GLenum(GL_STACK_OVERFLOW):
      print("GL_STACK_OVERFLOW")
      break
    default:
      break
    }
  }

  func ignoreGLError() {
    glGetError()
  }
}
