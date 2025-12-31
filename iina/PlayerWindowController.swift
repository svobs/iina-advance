//
//  PlayerWindowController.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

// TODO: gpu-next
// TODO: support parent playlist
// TODO: investigate generating thumbnails & Now Playing art from mpv screenshot cmd via RPC
final class PlayerWindowController: WindowController, NSWindowDelegate {
  let player: PlayerCore
  var log: any Logger.Subsystem { player.log }

  var undoHelper: PlayerWindowUndoHelper!

  var bestScreen: NSScreen {
    window?.screen ?? NSScreen.main!
  }

  /** For blacking out other screens. */
  var blackWindows: [NSWindow] = []

  /// See `PWin_Observers.swift`.
  var cachedEffectiveAppearanceName: String? = nil

  // MARK: - View Controllers

  /** The quick setting sidebar (video, audio, subtitles). */
  let quickSettingView = QuickSettingViewController()

  /** The playlist and chapter sidebar. */
  let playlistView = PlaylistViewController()

  let pluginView = PluginViewController()

  /// The music player panel.
  ///
  /// This is only shown while in music mode, and will be a subview of `bottomBarView`. It contains a "mini" OSC, and if configured, the
  /// playlist.
  var miniPlayer: MiniPlayerViewController!

  /** The control view for interactive mode. */
  var cropSettingsView: CropBoxViewController?

  let hdrWorkaroundView = NSView()

  // MARK: - Vars: Services

  // For Rotate gesture:
  let rotationHandler = RotationGestureHandler()

  // For Pinch To Magnify gesture:
  let magnificationHandler = MagnificationGestureHandler()

  nonisolated(unsafe)
  let animationPipeline: IINAAnimation.Pipeline

  /// Need to store this for use by `showWindow` when it is called asynchronously
  var pendingVideoGeoUpdateTasks: [IINAAnimation.Task] = []

  /// For responding to changes to app prefs & other notifications
  var notiHandler: NotificationHandler!

  var barFactory: BarFactory?
  let knobFactory = KnobFactory()

  // MARK: - Vars: State

  var isAnimating: Bool {
    return animationPipeline.isExecuting
  }

  // While true, disable window geometry listeners so they don't overwrite cache with intermediate data
  var isAnimatingLayoutTransition: Bool = false {
    didSet {
      log.verbose("Δ isAnimatingLayoutTransition ≔ \(isAnimatingLayoutTransition.yesno)")
    }
  }

  var sessionState: PWinSessionState = .noSession {
    willSet {
      log.verbose("Δ sessionState: \(sessionState) → \(newValue)")
      assert(DispatchQueue.isExecutingIn(DispatchQueue.main))
    }
  }
  
  var priorStateIfRestoring: PlayerSaveState? {
    if case .restoring(let priorState) = sessionState {
      return priorState
    }
    return nil
  }

  // - Mutually exclusive state bools:

  // TODO: replace these vars with window state var:
  /// WindowState enum cases: [.notYetLoaded, .loadedButClosed, .willOpen, .openVisible, .openDragging, .openMagnifying,
  /// .openLiveResizingWidth, .openLiveResizingHeight, .openDragging, .openHidden, .openMiniturized, .openMiniturizedPiP,
  /// .openInFullScreen, .closing]
  var loaded = false  // TODO: -> .isAtLeast(.loadedButClosed)
  var isWindowMiniturized = false
  var isWindowMiniaturizedDueToPip = false
  var isWindowPipDueToInactiveSpace = false
  /// Set only for PiP
  var isWindowHidden = false
  var isDragging: Bool = false
  var currentDragObject: NSView? = nil {
    didSet {
      log.verbose("Δ currentDragObject ≔ \(currentDragObject?.idString.quoted ?? "nil")")
      assert(currentDragObject == nil || (currentDragObject as? DraggableObject != nil),
             "Expected currentDragObject to conform to DraggableObject: id=\(currentDragObject?.idString.quoted ?? "nil"), obj=\(currentDragObject?.description ?? "nil")")
    }
  }
  var isLiveResizingWidth: Bool? = nil
  var isMagnifying = false
  /// If there is an active video-zoom, we need to know if it is the result of a previous pinch gesture, or done through some external mechanism.
  var isZoomedViaGesture: Bool = false

  // - Non-exclusive state bools:

  var isOnTop: Bool = false

  /// True if window is either visible, hidden, or minimized. False if window is closed.
  var isOpen: Bool {
    assert(DispatchQueue.isExecutingIn(.main))
    if !self.loaded {
      return false
    }
    guard let window = self.window else { return false }
    /// Also check if hidden due to PIP, or minimized.
    /// NOTE: `window.isVisible` returns `false` if the window is ordered out, which we do sometimes,
    /// as well as in the minimized or hidden states.
    /// Check against our internally tracked window state lists also:
    let savedStateName = window.savedStateName
    let isVisible = window.isVisible || UIState.shared.windowsOpen.contains(savedStateName)
    let isMinimized = UIState.shared.windowsMinimized.contains(savedStateName)
    return isVisible || isMinimized
  }

  /// Make sure the event loop is emptied before setting to false again. Otherwise a simple click can result in a resize.
  /// Very kludgey, but nothing better discovered yet.
  /// See: `restartWindowResizeDenialPeriod()`
  var denyWindowResizePeriodStartTime = Date()
  var pendingResizeForScreenChange = false

  var denyWindowScrollPeriodStartTime = Date()

  var isClosing: Bool {
    return player.state.isAtLeast(.stopping)
  }

  var modeToSetAfterExitingFullScreen: PlayerWindowMode? = nil

  var isPausedDueToInactive: Bool = false
  var isPausedDueToMiniaturization: Bool = false
  var isPausedPriorToInteractiveMode: Bool = false
  // TODO: also `player.pendingResumeWhenShowingWindow`

  // - Mouse: see PWin_Input.swift

  /// When the speed arrow buttons were last clicked.
  var lastForceTouchClick = Date()
  /// The maximum pressure recorded when clicking on the speed arrow buttons.
  var maxPressure: Int = 0
  /// The value of speedValueIndex before Force Touch.
  var oldSpeedValueIndex: Int = AppData.availableSpeedValues.count / 2

  /// Force Touch: for `PK.forceTouchAction`
  var isCurrentPressInSecondStage = false

  /// Responder chain is a mess. Use this to prevent duplicate event processing
  var lastMouseDownEventID: Int = -1
  /// In global coords
  var mouseDownLocation: CGPoint?
  var mouseDownLocationInWindow: CGPoint?

#if ENABLE_CUSTOM_WINDOW_DRAG
  var windowFrameAtMouseDown: CGRect?
#endif

  var lastKeyWindowStatus = false
  /// Special state needed to prevent hideOSC from happening on first mouse
  var wasKeyWindowAtMouseDown = false

  var lastMouseUpEventID: Int = -1
  /// Differentiate between single clicks and double clicks.
  var singleClickTimer: Timer?

  var lastRightMouseDownEventID: Int = -1
  var lastRightMouseUpEventID: Int = -1


  /// Scroll wheel (see `PWin_ScrollWheel.swift`)

  /// The window's virtual scroll wheel which may result in either volume or playback time seeking depending on direction
  var windowScrollWheel: PWinScrollWheel!

  var isScrollingOrDraggingPlaySlider: Bool {
    assert(DispatchQueue.isExecutingIn(.main))  // Must use main DQ to avoid error whe accessing playSlider.customCell
    if playSlider.customCell.isDragging {
      // Dragging play slider
      return true
    }
    if (playSlider.scrollWheelDelegate?.isScrolling() ?? false) {
      // Scrolling play slider directly
      return true
    }
    if windowScrollWheel.isScrolling() && (windowScrollWheel.delegate as? PlaySliderScrollWheel != nil) {
      // Scrolling play slider via in-window scroll
      return true
    }
    return false
  }

  var isScrollingOrDraggingVolumeSlider: Bool {
    if volumeSliderCell.isDragging  {
      return true
    }
    if (volumeSlider.scrollWheelDelegate?.isScrolling() ?? false) {
      // Scrolling volume slider directly
      return true
    }
    if windowScrollWheel.isScrolling() && (windowScrollWheel.delegate as? VolumeSliderScrollWheel != nil) {
      // Scrolling volume slider via in-window scroll
      return true
    }
    return false
  }

  /// - Sidebars: See file `Sidebars.swift`

  // Is non-nil if within the activation rect of one of the sidebars
  var customCursor: CursorType = .normalCursor

  // - Fadeable Views
  let fadeableViews: FadeableViewsHandler

  // Other visibility
  var hideCursorTimer = TimeoutTimer(timeout: Constants.TimeInterval.hideCursorMinTimeoutMS)

  // - PiP

  var pip: PIPState

  // MARK: - Vars: Window Layout State

  var currentLayout: LayoutState {
    didSet {
      log.verbose("Δ currentLayout: \(oldValue.mode) -> \(currentLayout.mode)")
      if currentLayout.mode == .windowedNormal {
        lastWindowedLayoutState = currentLayout
      } else if currentLayout.mode == .fullScreenNormal {
        lastWindowedLayoutState = LayoutState.fromPrefs(andMode: .windowedNormal, fillingInFrom: currentLayout)
      }
    }
  }
  /// For restoring windowed mode layout from music mode or other mode which does not support sidebars.
  /// Also used to preserve layout if a new file is dragged & dropped into this window
  var lastWindowedLayoutState: LayoutState = LayoutState.fromPrefs()

  // Only used for debug logging:
  @Atomic var layoutTransitionCounter: Int = 0

  let titleBarAndOSCUpdateDebouncer = Debouncer(delay: Constants.TimeInterval.playerTitleBarAndOSCUpdateThrottlingDelay)
  /// For throttling `windowDidChangeScreen` notifications. MacOS 14 often sends hundreds in short bursts
  let screenChangedDebouncer = Debouncer(delay: Constants.TimeInterval.windowDidChangeScreenThrottlingDelay)
  /// For throttling `windowDidChangeScreenParameters` notifications. MacOS 14 often sends hundreds in short bursts
  let screenParamsChangedDebouncer = Debouncer(delay: Constants.TimeInterval.windowDidChangeScreenParametersThrottlingDelay)
  let thumbDisplayDebouncer = Debouncer()

  var isFullScreen: Bool { currentLayout.isFullScreen }
  var isInMiniPlayer: Bool { currentLayout.isMusicMode }
  var isInInteractiveMode: Bool { currentLayout.isInteractiveMode }

  // MARK: - Vars: Window Geometry

  var geo: GeometrySet

  var windowedModeGeo: PWinGeometry {
    get {
      return geo.windowed
    } set {
      geo = geo.clone(windowed: newValue)
      log.verbose("Δ windowedModeGeo ≔ \(newValue)")
      assert(newValue.mode.isWindowed, "windowedModeGeo has unexpected mode: \(newValue.mode)")
      assert(!newValue.screenFit.isFullScreen, "windowedModeGeo has invalid screenFit: \(newValue.screenFit)")
    }
  }

  var musicModeGeo: PWinGeometry {
    get {
      return geo.musicMode
    } set {
      geo = geo.clone(musicMode: newValue)
      log.verbose("Updated musicModeGeo ≔ \(newValue)")
    }
  }

  // Remembers the geometry of the "last closed" window in windowed, so future windows will default to its layout.
  // The first "get" of this will load from saved pref. Every "set" of this will update the pref.
  static var windowedModeGeoLastClosed: PWinGeometry = {
    let csv = Preference.string(for: .uiLastClosedWindowedModeGeometry)
    if csv?.isEmpty ?? true {
      Logger.log.debug("Pref entry for \(Preference.quoted(.uiLastClosedWindowedModeGeometry)) is empty or could not be parsed. Falling back to default geometry")
    } else if let savedGeo = PWinGeometry.fromCSV(csv, Logger.log) {
      if savedGeo.mode.isWindowed && !savedGeo.screenFit.isFullScreen {
        Logger.log.verbose("Loaded pref \(Preference.quoted(.uiLastClosedWindowedModeGeometry)): \(savedGeo)")
        return savedGeo
      } else {
        Logger.log.error("Saved pref \(Preference.quoted(.uiLastClosedWindowedModeGeometry)) is invalid. Falling back to default geometry (found: \(savedGeo))")
      }
    }
    // Compute default geometry for main screen
    let defaultScreen = NSScreen.screens[0]
    return LayoutState.fromPrefs().buildDefaultInitialGeometry(screen: defaultScreen)
  }() {
    didSet {
      guard windowedModeGeoLastClosed.mode.isWindowed, !windowedModeGeoLastClosed.screenFit.isFullScreen else {
        Logger.log.errorDebugAlert("Will skip save of windowedModeGeoLastClosed because it is invalid: not in windowed mode! Found: \(windowedModeGeoLastClosed)")
        return
      }
      Preference.set(windowedModeGeoLastClosed.toCSV(), for: .uiLastClosedWindowedModeGeometry)
      Logger.log.verbose("Updated pref uiLastClosedWindowedModeGeometry ≔ \(windowedModeGeoLastClosed)")
    }
  }

  // Remembers the geometry of the "last closed" music mode window, so future music mode windows will default to its layout.
  // The first "get" of this will load from saved pref. Every "set" of this will update the pref.
  static var musicModeGeoLastClosed: PWinGeometry = {
    let csv = Preference.string(for: .uiLastClosedMusicModeGeometry)
    // Try to parse as modern CSV first. If it fails, try legacy music mode CSV
    if let savedGeo = PWinGeometry.fromCSV(csv, Logger.log) {
      Logger.log.verbose("Loaded pref \(Preference.quoted(.uiLastClosedMusicModeGeometry)): \(savedGeo)")
      return savedGeo
    } else if let savedGeo = PWinGeometry.fromMusicModeCSV(csv, Logger.log) {
      Logger.log.verbose("Loaded pref \(Preference.quoted(.uiLastClosedMusicModeGeometry)) from legacy music mode CSV: \(savedGeo)")
      return savedGeo
    }
    Logger.log.debug("Pref \(Preference.quoted(.uiLastClosedMusicModeGeometry)) is empty or could not be parsed. Falling back to default music mode geometry")
    let defaultScreen = NSScreen.screens[0]
    let defaultGeo = MiniPlayerViewController.buildMusicModeGeometryFromPrefs(screen: defaultScreen,
                                                                              video: VideoGeometry.defaultGeometry())
    return defaultGeo
  }() {
    didSet {
      Preference.set(musicModeGeoLastClosed.toCSV(), for: .uiLastClosedMusicModeGeometry)
      Logger.log.verbose("Updated musicModeGeoLastClosed ≔ \(musicModeGeoLastClosed)")
    }
  }

  // - MARK: Constraints

  let panelConstraints = PanelConstraints()

  // - Leading sidebar constraints

  /// If non-nil, activates all constraints in the new object reference.
  /// Any constraints in the old reference will be deactivated.
  var leadingSidebarConstraints: LeadingSidebarConstraints? = nil {
    willSet {
      // - Remove old constraints:
      if let old = leadingSidebarConstraints {
        log.verbose("Disabling old leading sidebar constraints")
        old.setActive(active: false)
      }
      if let newCons = newValue {
        log.verbose("Enabling new leading sidebar constraints")
        newCons.setActive(active: true)
      }
    }
  }

  struct LeadingSidebarConstraints {
    let viewportLeadingOffsetFromLeading: NSLayoutConstraint
    let viewportLeadingOffsetFromTrailing: NSLayoutConstraint
    let viewportLeadingClipTrailing: NSLayoutConstraint?

    let top: NSLayoutConstraint
    let bottom: NSLayoutConstraint

    func setActive(active: Bool) {
      viewportLeadingOffsetFromTrailing.isActive = active
      viewportLeadingOffsetFromLeading.isActive = active
      viewportLeadingClipTrailing?.isActive = active
      top.isActive = active
      bottom.isActive = active
    }
  }

  // - Trailing sidebar constraints

  /// If non-nil, activates all constraints in the new object reference.
  /// Any constraints in the old reference will be deactivated.
  var trailingSidebarConstraints: TrailingSidebarConstraints? = nil {
    willSet {
      // - Remove old constraints:
      if let old = trailingSidebarConstraints {
        log.verbose("Disabling old trailing sidebar constraints")
        old.setActive(active: false)
      }
      if let newCons = newValue {
        log.verbose("Enabling new trailing sidebar constraints")
        newCons.setActive(active: true)
      }
    }
  }

  struct TrailingSidebarConstraints {
    let viewportTrailingOffsetFromLeading: NSLayoutConstraint
    let viewportTrailingOffsetFromTrailing: NSLayoutConstraint
    let viewportTrailingClipLeading: NSLayoutConstraint?

    let top: NSLayoutConstraint
    let bottom: NSLayoutConstraint

    func setActive(active: Bool) {
      viewportTrailingOffsetFromLeading.isActive = active
      viewportTrailingOffsetFromTrailing.isActive = active
      viewportTrailingClipLeading?.isActive = active
      top.isActive = active
      bottom.isActive = active
    }
  }

  // - OSC internal constraints

  var fragPlaybackBtnsHeightConstraint: NSLayoutConstraint!
  var fragPlaybackBtnsWidthConstraint: NSLayoutConstraint!
  var speedLabelBtmConstraint: NSLayoutConstraint!

  /// Size of each side of the (square) `playButton`
  var playBtnHeightConstraint: NSLayoutConstraint!
  /// Size of each side of square buttons `leftArrowButton` & `rightArrowButton`
  var arrowBtnWidthConstraint: NSLayoutConstraint!

  var leftArrowBtn_CenterXOffsetConstraint: NSLayoutConstraint!
  var rightArrowBtn_CenterXOffsetConstraint: NSLayoutConstraint!

  var playSliderHeightConstraint: NSLayoutConstraint!

  var volumeIconHeightConstraint: NSLayoutConstraint!
  var volumeIconAspectConstraint: NSLayoutConstraint!
  var volumeSliderWidthConstraint: NSLayoutConstraint!

  // - MARK: Views

  // MiniPlayer buttons:
  let exitMusicModeButton = SymButton(id: "ExitMusicModeBtn")

  /// Contains `videoView` and margins around it
  let viewportView = ViewportView()

  @objc var videoView: VideoView {
    return player.videoView
  }

  /// Contains thumbnail preview & seek time.
  let seekPreview = SeekPreview()

  /// Contains info to be displayed while loading/buffering a network stream.
  let bufferIndicatorView = BufferIndicatorView()

  let defaultAlbumArtView = DefaultAlbumArtView()

  // OSD
  let osd: OSDState
  let additionalInfoView = AdditionalInfoView()

  /// Custom-built window border, used for legacy windowed mode
  /// #Deprecated: no longer needed for MacOS 26+
  let customWindowBorderBox = CustomWindowBorderBox(id: "CustomWndBorderBox", borderWidth: 1, borderColor: .customWindowBorder)
  /// Custom-built window border highlight, used for legacy windowed mode
  let customWindowBorderTopHighlightBox = CustomWindowBorderBox(id: "CustomWndBorderBox", borderWidth: 0.5, borderColor: .customWindowBorderHighlight)

  /// Custom-built title bar, used for legacy windowed mode
  var customTitleBar: CustomTitleBarViewController? = nil

  // Native Title Bar:

  var leadingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController?
  var trailingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController?
  let leadingTitleBarAccessoryView = NSStackView()
  let trailingTitleBarAccessoryView = NSStackView()
  /// "Pin to Top" icon in title bar, if configured to  be shown
  let onTopButton = SymButton()
  let leadingSidebarToggleButton = SymButton()
  let trailingSidebarToggleButton = SymButton()
  var hiddenObservation: NSKeyValueObservation?

  /// The document icon of the window's native title bar.
  var documentIconButton: NSButton? {
    window?.standardWindowButton(.documentIconButton)
  }

  var closeButton: NSButton? { window?.standardWindowButton(.closeButton) }
  var miniaturizeButton: NSButton? { window?.standardWindowButton(.miniaturizeButton) }
  var zoomButton: NSButton? { window?.standardWindowButton(.zoomButton) }

  /// The traffic light buttons of the window's native title bar (given that window's styleMask contains `.titled`).
  var trafficLightButtons: [NSButton] {
    if let window, window.styleMask.contains(.titled) {
      return ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
        window.standardWindowButton($0)
      }
    }
    return []
  }

  /// Computed property which gets the `NSTextField` of window's native title bar.
  var titleTextField: NSTextField? {
    return window?.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? NSTextField }).first
  }

  // - Bars

  /// Bar at top of window. May be `insideViewport` or `outsideViewport`. May contain `titleBarView` and/or `controlBarTop`
  /// depending on configuration.
  let topBarView = TopBarView()

  /// Control bar at bottom of window, if configured. May be `insideViewport` or `outsideViewport`.
  /// Used to hold other views in music mode & interactive mode
  var bottomBarView: NSView = BottomBarVisualEffectView()
  /// Top border of `bottomBarView`.
  let bottomBarTopBorder = BorderLineView(id: "BottomBar-TopBorder", fillColor: .titleBarBorder)

  let leadingSidebarView = ClickThroughVisualEffectView()
  /// Shown if leading sidebar is "outside"
  let leadingSidebarTrailingBorder = BorderLineView(id: "LeadingSidebar-TrailingBorder", fillColor: .quaternaryLabelColor)

  let trailingSidebarView = ClickThroughVisualEffectView()
  /// Shown if trailing sidebar is "outside"
  let trailingSidebarLeadingBorder = BorderLineView(id: "TrailingSidebar-LeadingBorder", fillColor: .quaternaryLabelColor)

  /// Floating OSC
  let controlBarFloating = FloatingControlBarView()

  /// Layout options for bar-type ("top" or "bottom" position) OSC controls inside `currentControlBar`.
  let oscOneRowView = SingleRowBarOSCView()
  let oscTwoRowView = TwoRowBarOSCView()

  /// Reference to the current OSC container view. May be top, bottom, floating, inside music mode window, or `nil`,
  /// depending on current user settings.
  var currentControlBar: NSView?

  // - OSC internal views

  /// Container for volume slider & mute button
  var fragVolumeView = ClickThroughView()
  let muteButton = OSCSymButton()
  let volumeSlider = ScrollableSlider(customCell: VolumeSliderCell())
  var volumeSliderCell: VolumeSliderCell { volumeSlider.cell as! VolumeSliderCell }

  /// Container for playback buttons
  let fragPlaybackBtnsView = ClickThroughView()
  /// Speed indicator label, when playing at speeds other than 1x
  let speedLabel = NSTextField()
  let playButton = OSCSymButton()
  let leftArrowButton = OSCSymButton()
  let rightArrowButton = OSCSymButton()

  /// Toolbar Buttons container
  let fragToolbarView = ClickThroughStackView()

  /// Container for legacy PlaySlider layout which shows time labels on left & right of slider.
  let playSliderAndTimeLabelsView = ClickThroughView()
  let playSlider = PlaySlider()
  let leftTimeLabel = DurationDisplayTextField()
  let rightTimeLabel = DurationDisplayTextField()

  // - Misc Views

  var mouseActionDisabledViews: [NSView?] {
    return [leadingSidebarView, trailingSidebarView, topBarView, currentControlBar, subPopoverView]
  }

  let pluginOverlayViewContainer = NSView(frame: .zero)

  lazy var subPopoverView = playlistView.subPopover?.contentViewController?.view

  // MARK: - Initialization

  /// NOTE: this inits this `NSWindowController` & its properties. However, its `window` will be created
  /// until `self.window` is first accessed, and not until then! None of its `@IBOutlet` properties
  /// should be accessed without first checking `isLoaded`, otherwise a crash can occur. Do not use
  /// `isWindowLoaded` because that will cause `window` to be loaded (and will definitely crash if not
  /// accessed on the main thread).
  @MainActor
  init(playerCore player: PlayerCore, geoSet: GeometrySet? = nil, initialLayout: LayoutState? = nil) {
    player.log.verbose("PlayerWindowController init")
    self.player = player
    self.animationPipeline = IINAAnimation.Pipeline(player)
    self.fadeableViews = FadeableViewsHandler(player.log)
    self.osd = OSDState(log: player.log)
    self.pip = PIPState(player)

    let layoutToUse = initialLayout ?? LayoutState.fromPrefs()
    self.currentLayout = layoutToUse

    let geoSetToUse: GeometrySet
    if let geoSet {
      geoSetToUse = geoSet
      player.log.verbose("PlayerWindowController init: using provided geoSet. Using \(initialLayout == nil ? "provided layout" : "layout from prefs"), mode=\(layoutToUse.mode)")
    } else {
      player.log.verbose("PlayerWindowController init: using lastClosed geometries for now")
      geoSetToUse = GeometrySet(windowed: PlayerWindowController.windowedModeGeoLastClosed,
                             musicMode: PlayerWindowController.musicModeGeoLastClosed,
                             video: VideoGeometry.defaultGeometry(player.log))
    }

    self.geo = geoSetToUse

    let contentRect = (layoutToUse.mode == .musicMode ? geoSetToUse.musicMode : geoSetToUse.windowed).windowFrame
    var style: NSWindow.StyleMask = [.fullSizeContentView, .closable, .resizable, .miniaturizable]
    if !Preference.bool(for: .useLegacyWindowedMode) {
      style.insert(.titled)
    }
    // Use the correct contentRect right away. When restoring windows with the `.titled` style, the window
    // sometimes briefly appears at the first supplied size & origin even if it is supposed to be resized while hidden.
    let playerWindow = PlayerWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
    playerWindow.autorecalculatesKeyViewLoop = false
    // incompatible with tabbed windows! But needed for pretty FS transition
    playerWindow.titlebarAppearsTransparent = true
    // FIXME: tabbed windows
    playerWindow.tabbingMode = .disallowed

    if let contentView = playerWindow.contentView {
      contentView.autoresizesSubviews = false
      contentView.autoresizingMask = [.width, .height]
    }

    super.init(window: playerWindow)
    playerWindow.delegate = self
    // Hide window until ready to show (when `windowIsReadyToShow` notification is sent, `showWindow()` will be triggered)
    playerWindow.orderOut(self)
    osd.hideOSDTimer.action = { self.hideOSD() }
    log.verbose("PlayerWindowController init: done")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func makeTouchBar() -> NSTouchBar? {
    return player.makeTouchBar()
  }

  /// Returns the position in seconds for the given percent of the total duration of the video the percentage represents.
  ///
  /// The number of seconds returned must be considered an estimate that could change. The duration of the video is obtained from
  /// the [mpv](https://mpv.io/manual/stable/) `duration` property. The documentation for this property cautions that
  /// mpv is not always able to determine the duration and when it does return a duration it may be an estimate. If the duration is
  /// unknown this method will fallback to using the current playback position, if that is known. Otherwise this method will return zero.
  /// - Parameter percent: Position in the video as a percentage of the duration.
  /// - Returns: The position in the video the given percentage represents.
  func percentToSeconds(_ percent: Double) -> Double {
    if let duration = player.info.playbackDurationSec {
      return duration * percent / 100
    } else if let position = player.info.playbackPositionSec {
      return position * percent / 100
    } else {
      return 0
    }
  }

  /// When entering "windowed" mode (either from initial load, PIP, or music mode), call this to add/return `viewportView`
  /// to this window, and add `videoView` and spacers to that. Will do nothing if all views are already in place.
  func addViewportAndSubviewsToWindowIfNeeded() {
    guard let window else { return }
    assert(loaded, "Must not be called if not done loading the window!")

    var didAddSubviewToViewport = false
    do {
      let hasOpenGL = videoView.lockAndSetOpenGLContext()
      defer {
        if hasOpenGL {
          videoView.unlockOpenGLContext()
        }
      }
      videoView.$isUninited.withLock() { isUninited in
        if !window.contentView!.containsSubview(viewportView) {
          log.verbose("Adding viewportView to window")
          window.contentView!.addSubview(viewportView)
        }
        if !viewportView.subviews.contains(videoView) {
          if currentLayout.isInPiP {
            log.debug("Aborting add of videoView to window: isInPiP=\(currentLayout.isInPiP.yn)")
          } else {
            log.verbose("Adding videoView to viewportView, screenScaleFactor: \(window.screenScaleFactor)")
            viewportView.addSubview(videoView)
            // Reset this in case it was changed for PiP. (Need to use optional to support initial load)
            videoView.layer?.autoresizingMask = []
            /// Add constraints. These get removed each time `videoView` changes superviews.
            videoView.translatesAutoresizingMaskIntoConstraints = false
            didAddSubviewToViewport = true
          }
        }

        let didAddSpacers = viewportView.addSpacers()
        didAddSubviewToViewport = didAddSubviewToViewport || didAddSpacers

        if didAddSubviewToViewport {
          sortViewportViewSubviews()
        }
      }
    }
    if didAddSubviewToViewport {
      // Screen may have changed. Refresh. Do not keep the OpenGL lock because it is locked in here
      videoView.refreshAllVideoDisplayState()
    }
  }

  /// Set material & theme (light or dark mode) for OSC and title bar.
  /// Make sure this is running inside an animation task too!
  func applyThemeMaterial(using layoutState: LayoutState? = nil, _ window: NSWindow, _ screen: NSScreen) {
    assert(DispatchQueue.isExecutingIn(.main))
    log.verbose("Applying theme material for screen \(screen.screenID.pii.quoted)")
    let theme: Preference.Theme = Preference.enum(for: .themeMaterial)
    // Can be nil, which means dynamic system appearance:
    let newAppearance: NSAppearance? = NSAppearance(iinaTheme: theme)
    window.appearance = newAppearance

    // Either dark or light, never nil:
    let effectiveAppearance: NSAppearance = newAppearance ?? window.effectiveAppearance

    let layoutState: LayoutState = layoutState ?? currentLayout
    let oscGeo = layoutState.controlBarGeo

    if playlistView.isViewLoaded {
      playlistView.updateTableColors()
    }

    let sliderAppearance = layoutState.effectiveOSCColorScheme == .clearGradient ? NSAppearance(iinaTheme: .dark)! : effectiveAppearance
    sliderAppearance.applyAppearanceFor {
      let barFactory = BarFactory(effectiveAppearance: effectiveAppearance, effectiveOSCColorScheme: layoutState.effectiveOSCColorScheme, sliderBarHeight_Normal: layoutState.controlBarGeo.sliderBarHeightNormal)
      self.barFactory = barFactory
      knobFactory.invalidateCachedKnobs()
      osd.updateProgressBarStyle(effectiveAppearance, effectiveOSCColorScheme: layoutState.effectiveOSCColorScheme)
      playSlider.abLoopA.updateKnobImage(to: .loopKnob)
      playSlider.abLoopB.updateKnobImage(to: .loopKnob)

      let scaleFactor = screen.backingScaleFactor
      if let hoverIndicator = playSlider.hoverIndicator {
        hoverIndicator.update(scaleFactor: scaleFactor, oscGeo: oscGeo, isDark: sliderAppearance.isDark)
      } else {
        playSlider.hoverIndicator = SliderHoverIndicator(slider: playSlider, oscGeo: oscGeo,
                                                         scaleFactor: scaleFactor, isDark: sliderAppearance.isDark)
      }
      playSlider.needsDisplay = true
      volumeSlider.needsDisplay = true
    }
  }

  func updateArrowButtonAccelerationFromPrefs() {
    let arrowButtonAction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
    let enableAccelerationForSpeed = Preference.bool(for: .useForceTouchForSpeedArrows)
    let enableAcceleration = enableAccelerationForSpeed && (arrowButtonAction == .speed)
    leftArrowButton.enableAcceleration = enableAcceleration
    rightArrowButton.enableAcceleration = enableAcceleration
  }

  /// Asynchronous with throttling!
  func updateTitleBarAndOSC() {
    titleBarAndOSCUpdateDebouncer.run { [self] in
      animationPipeline.submitInstantTask { [self] in
        let oldLayout = currentLayout
        let newLayoutState = LayoutState.fromPrefs(fillingInFrom: oldLayout)
        let transition = buildLayoutTransition(named: "UpdateTitleBarAndOSC", from: oldLayout, to: newLayoutState)
        buildTasks(for: transition, thenRun: true)
      }
    }
  }

  /// This expects to be executed after `fileLoaded` (i.e. toward the end of restore).
  /// Specifically, it expects that `self.currentLayout` & `self.geo` have already been set from `priorState`.
  func restoreFromMiscWindowBools(_ priorState: PlayerSaveState) -> (miniturized: Bool, hidden: Bool)? {
    let window = window!
    let isOnTop = priorState.bool(for: .isOnTop) ?? false
    setWindowFloatingOnTop(isOnTop, from: currentLayout, updateOnTopStatus: true)

    guard let (isMiniaturized, isHidden, isInPip,
               isWindowMiniaturizedDueToPip,
               isPausedPriorToInteractiveMode,
               isZoomedViaGesture) = PlayerSaveState.parseMiscWindowBools(priorState.properties) else {
      log.debug("Failed to restore from miscWindowBools; defaulting to visible window")
      return nil
    }

    if isZoomedViaGesture {
      log.verbose("Restoring window which is zoomed via gesture")
      self.isZoomedViaGesture = isZoomedViaGesture

      // Window needs to be maximized or FS to keep pinch-to-zoom.
      // Screen may have changed since last launch: check & maybe reset
      let currentGeo: PWinGeometry?
      let mode = currentLayout.mode
      switch mode {
      case .musicMode:
        currentGeo = geo.musicMode
      case .windowedNormal, .windowedInteractive:
        currentGeo = geo.windowed
      case .fullScreenNormal, .fullScreenInteractive:
        currentGeo = nil
      }
      if let currentGeo {
        magnificationHandler.resetZoomIfNotMaximized(currentGeo)
      }
    }

    // Process PIP options first, to make sure it's not miniturized due to PIP
    if isInPip {
      let pipOption: Preference.WindowBehaviorWhenPip
      if isHidden {  // currently this will only be true due to PIP
        pipOption = .hide
      } else if isWindowMiniaturizedDueToPip {
        pipOption = .minimize
      } else {
        pipOption = .doNothing
      }
      log.verbose("Restoring window which is in PiP (\(pipOption))")
      // Run in queue to avert race condition with window load
      animationPipeline.submitInstantTask({ [self] in
        enterPIP(usePipBehavior: pipOption, isRestoring: true)
      })
    } else if isMiniaturized {
      // Not in PIP, but miniturized
      // Run in queue to avert race condition with window load
      animationPipeline.submitInstantTask({
        window.miniaturize(nil)
      })
    }
    if isPausedPriorToInteractiveMode {
      self.isPausedPriorToInteractiveMode = isPausedPriorToInteractiveMode
    }
    return (isMiniaturized, isHidden)
  }

  // MARK: - Window delegate: Open / Close

  @MainActor
  override func openWindow(_ sender: Any?) {
    animationPipeline.submitInstantTask({ [self] in
      _openWindow()
    })
  }

  @MainActor
  func _openWindow() {
    guard let window = self.window else { return }

    guard AppDelegate.shared.isInteractiveLaunch else {
      log.verbose("PlayerWindow openWindow aborting: launch is non-interactive")
      return
    }
    log.verbose("PlayerWindow openWindow starting, playbackPath=\(player.info.currentPlayback?.path.pii.quoted ?? "nil")")
    guard player.info.currentPlayback != nil else {
      log.error("PlayerWindow openWindow aborting: currentPlayback is nil")
      return
    }

    // Must workaround an AppKit defect in some versions of macOS. This defect is known to exist in
    // Catalina and Big Sur. The problem was not reproducible in early versions of Monterey. It
    // reappeared in Ventura. The status of other versions of macOS is unknown, however the
    // workaround should be safe to apply in any version of macOS. The problem was reported in
    // issues #4229, #3159, #3097 and #3253. The titles of open windows shown in the "Window" menu
    // are automatically managed by the AppKit framework. To improve performance PlayerCore caches
    // and reuses player instances along with their windows. This technique is valid and recommended
    // by Apple. But in some versions of macOS, if a window is reused the framework will display the
    // title first used for the window in the "Window" menu even after IINA has updated the title of
    // the window. This problem can also be seen when right-clicking or control-clicking the IINA
    // icon in the dock. As a workaround reset the window's title to "Window" before it is reused.
    // This is the default title AppKit assigns to a window when it is first created. Surprising and
    // rather disturbing this works as a workaround, but it does.
    window.title = "Window"

    // Need to call this here because super.openWindow() is not called
    refreshWindowOpenCloseAnimation()

    /// See `PWin_Input.swift` for handling of tracking area events.
    updateTrackingAreas()

    // truncate middle for title
    if let attrTitle = titleTextField?.attributedStringValue.mutableCopy() as? NSMutableAttributedString, attrTitle.length > 0 {
      let p = attrTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSMutableParagraphStyle
      p.lineBreakMode = .byTruncatingMiddle
      attrTitle.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: attrTitle.length))
    }

    resetCollectionBehavior()

    /// Enqueue this in case `windowDidLoad` is not yet done
    animationPipeline.submitInstantTask{ [self] in
      if player.info.isNetworkResource {
        log.verbose("Showing bufferIndicatorView for network stream")
        let progressLabel = NSLocalizedString("main.opening_stream", comment:"Opening stream…")
        showBufferIndicator(animate: true, progressLabel: progressLabel, detailLabel: "")
      } else {
        log.verbose("Hiding bufferIndicatorView: not a network stream")
        hideBufferIndicator()
      }

      if !sessionState.isRestoring {
        // MUST register new window before closing welcome window. If welcome window was only window open,
        // doActionWhenLastWindowWillClose() can be triggered, which consults UIState.shared.windowsOpen to check for open or pending open windows
        if !window.isMiniaturized {
          UIState.shared.windowsOpen.insert(window.savedStateName)
        }
        // Referencing AppDelegate.shared.initialWindow directly will cause it to be loaded! So check list of open windows instead:
        if UIState.shared.windowsOpen.contains(WindowAutosaveName.welcome.string) ||
            UIState.shared.windowsMinimized.contains(WindowAutosaveName.welcome.string) {
          AppDelegate.shared.initialWindow.closePriorToOpeningPlayerWindow()
        }
      }
    }

    log.verbose("PlayerWindow openWindow done")
    // Don't wait for load for network stream; open immediately & show loading msg
    player.mpv.queue.async { [self] in
      if let currentPlayback = player.info.currentPlayback, currentPlayback.isNetworkResource {
        log.verbose("Current playback is network resource: calling transformGeometry now")
        let gtf = GeometryTransform("OpenNetStreamWindow", player)
        gtf.submit()
      }
    }
  }

  override func showWindow(_ sender: Any?) {
    guard player.state.isNotYet(.stopping) else {
      log.verbose("Aborting showWindow - player is stopping")
      return
    }
    guard AppDelegate.shared.isInteractiveLaunch else {
      // Should not even get here if everything else is working properly
      log.verbose("Aborting showWindow: launch is non-interactive")
      return
    }
    log.verbose("Showing PlayerWindow")
    super.showWindow(sender)

    // Registers this window for didChangeScreenProfileNotification.
    // Do not set this until now - have some suspicion that doing so can cause window to be displayed prematurely
    window!.displaysWhenScreenProfileChanges = true

    /// Need this as a kludge to ensure it runs after tasks in `transformGeometry`
    DispatchQueue.main.async { [self] in
      var animationTasks: [IINAAnimation.Task] = []

      animationTasks.append(.instantTask { [self] in
        refreshKeyWindowStatus()
        // Need to call this here, or else when opening directly to fullscreen, window title is just "Window"
        updateTitle()
        window?.isExcludedFromWindowsMenu = false
        videoView.activateForcedRedraws()  // needed if restoring while paused
      })

      let pendingTasks = pendingVideoGeoUpdateTasks
      pendingVideoGeoUpdateTasks = []
      if !pendingTasks.isEmpty {
        log.verbose("After opening window: will run \(pendingTasks.count) pending vidGeo update tasks")
        animationTasks += pendingTasks
      }

      animationTasks.append(.instantTask { [self] in
        // Launch to resume as the final task, right after window is finally shown:
        player.mpv.queue.async { [self] in
          resumeIfNeededForShowingWindow()
        }

        // Make sure to save after opening (possibly new) window
        player.saveState()
        // Especially need to save the updated windows list!
        // At launch, any unreferenced PWin entries will be deleted from prefs
        UIState.shared.saveCurrentOpenWindowList()
      })

      animationPipeline.submit(animationTasks)
    }
  }

  // this is getting pretty kludgey...
  private func resumeIfNeededForShowingWindow() {
    guard player.pendingResumeWhenShowingWindow else { return }
    player.pendingResumeWhenShowingWindow = false

    log.verbose("Resuming playback after window was shown")
    player.mpv.setFlag(MPVOption.PlaybackControl.pause, false)
  }

  /// Do not use the offical `NSWindowDelegate` method. This method will be called by the global window listener.
  func doPriorToWindowWillClose(_ window: NSWindow) {
    log.verbose("Window will close")
    defer {
      player.events.emit(.windowWillClose)
    }

    removeAllObservers()

    if currentLayout.isInPiP {
      // Close PiP. This should update currentLayout synchronously, though it may not completely finish until after we return.
      exitPIP()
    }

    if currentLayout.isFullScreen {
      updatePresentationOptions(windowIsFS: false)
    }

    // Stop playing. This will save state if configured to do so:
    player.stop()

    guard !AppDelegate.shared.isTerminating else { return }

    hideOSD(immediately: true)

    // Reset state to prepare window for reuse
    undoHelper.clearUndoes()
    removeTrackingAreas()
    window.displaysWhenScreenProfileChanges = false
    isWindowMiniturized = false
    player.overrideAutoMusicMode = false
    let wasSessionFinishedOpening = sessionState.hasOpenSession
    sessionState = .closedSession  // Reset this in preparation for repoen

    /// Use value of `sessionState.hasOpenSession` to prevent from saving when there was an error loading video
    if wasSessionFinishedOpening {
      /// Prepare window for possible reuse: restore default geometry, close sidebars, etc.
      /// Need to use `force` to bypass the normal checks for player state, etc, because we're closing.
      /// Setting these vars is especially important for copying to windowedModeGeoLastClosed, etc, below.
      geo = buildGeoSet(forceWinFrameUpdate: true)

      // Reset layout & its state (or at least the big stuff) for reopen: close sidebars, disable OSC
      let currentLayout = currentLayout
      let newLayoutState = currentLayout.clone(leadingSidebar: currentLayout.leadingSidebar.clone(visibility: .closed),
                                               trailingSidebar: currentLayout.trailingSidebar.clone(visibility: .closed),
                                               isInPiP: false,
                                               enableOSC: false)
      let resetTransition = buildLayoutTransition(named: "ResetWindowOnClose", from: currentLayout, to: newLayoutState)
      let tasks = buildTasks(for: resetTransition, totalStartingDuration: 0, totalEndingDuration: 0)

      // Do all the layout instantly. Need to run each in its own transaction however, to avoid intractable constraint errors
      var cleanupTasks = tasks.map { IINAAnimation.Task.instantTask($0.runFunc) }
      cleanupTasks.append(.instantTask { [self] in
        pendingVideoGeoUpdateTasks = []
        // The user may expect both to be updated.
        // Make sure to set these *after* running the above layout tasks, to ensure correct geometry.
        PlayerWindowController.windowedModeGeoLastClosed = windowedModeGeo
        PlayerWindowController.musicModeGeoLastClosed = musicModeGeo

        log.trace("Done: windowWillClose cleanup on main DQ")
      })

      log.trace("Resetting window geometry for close")
      animationPipeline.submit(cleanupTasks)
    }

    player.mpv.queue.async { [self] in
      // May not have finishing restoring when user closes. Make sure to clean up here
      if case .restoring = sessionState {
        log.debug("Discarding unfinished restore of window")
      }

      player.info.currentPlayback = nil
      osd.clearQueuedOSDs()
      log.trace("Done: windowWillClose cleanup on mpv DQ")
    }
  }

  // MARK: - Full Screen

  var isWindowInNativeFullScreen: Bool { NSApp.presentationOptions.contains(.fullScreen) }

  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    log.verbose("WndWillEnterFullScreen")
  }

  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
    animateEntryIntoFullScreen(withDuration: Constants.AnimationDuration.nativeFullScreenTransition, isLegacy: false)
  }

  // Animation: Enter FullScreen
  private func animateEntryIntoFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    let oldLayout = currentLayout

    let newMode: PlayerWindowMode = oldLayout.mode == .windowedInteractive ? .fullScreenInteractive : .fullScreenNormal
    log.verbose("Animating \(duration)s entry from \(oldLayout.mode) → \(isLegacy ? "legacy " : "native ")\(newMode)")
    // May be in interactive mode, with some panels hidden. Honor existing layout but change value of isFullScreen
    let fullscreenLayout = LayoutState.fromPrefs(andMode: newMode, isLegacyStyle: isLegacy, fillingInFrom: oldLayout)

    let transition = buildLayoutTransition(named: "Enter\(isLegacy ? "Legacy" : "Native")FullScreen", from: oldLayout, to: fullscreenLayout)
    buildTasks(for: transition, totalStartingDuration: 0, totalEndingDuration: duration, thenRun: true)
  }

  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    if !AccessibilityPreferences.motionReductionEnabled {  /// see note in `windowDidExitFullScreen()`
      animateExitFromFullScreen(withDuration: duration, isLegacy: false)
    }
  }

  /// Workaround for Apple quirk. When exiting fullscreen, MacOS uses a relatively slow animation to open the Dock and fade in other windows.
  /// It appears we cannot call `setFrame()` (or more precisely, we must make sure any `setFrame()` animation does not end) until after this
  /// animation completes, or the window size will be incorrectly set to the same size of the screen.
  /// There does not appear to be any similar problem when entering fullscreen.
  func windowDidExitFullScreen(_ notification: Notification) {
    log.verbose("WndDidExitFullScreen")
    if AccessibilityPreferences.motionReductionEnabled {
      animateExitFromFullScreen(withDuration: Constants.AnimationDuration.fullScreenTransition, isLegacy: false)
    } else {
      animationPipeline.submitInstantTask { [self] in
        // Kludge/workaround for race condition when exiting native FS to native windowed mode
        updateTitle()
      }
    }
  }

  // Animation: Exit Full Screen
  private func animateExitFromFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    // If a window is closed while in full screen mode (control-w pressed) AppKit will still call
    // this method. Because windows are tied to player cores and cores are cached and reused some
    // processing must be performed to leave the window in a consistent state for reuse. However
    // the windowWillClose method will have initiated unloading of the file being played. That
    // operation is processed asynchronously by mpv. If the window is being closed due to IINA
    // quitting then mpv could be in the process of shutting down. Must not access mpv while it is
    // asynchronously processing stop and quit commands.
    guard !isClosing else { return }

    let oldLayout = currentLayout

    let nextMode: PlayerWindowMode
    if oldLayout.mode == .fullScreenInteractive {
      nextMode = .windowedInteractive
    } else {
      nextMode = .windowedNormal
    }
    let windowedLayoutState = LayoutState.fromPrefs(andMode: nextMode, fillingInFrom: oldLayout)

    log.verbose("Animating \(duration)s exit from \(isLegacy ? "legacy " : "")\(oldLayout.mode) → \(windowedLayoutState.mode)")
    assert(!windowedLayoutState.isFullScreen, "Cannot exit full screen into mode \(windowedLayoutState.mode)! Spec: \(windowedLayoutState)")
    /// Split the duration between `openNewPanels` animation and `fadeInNewViews` animation
    let exitFSTransition = buildLayoutTransition(named: "Exit\(isLegacy ? "Legacy" : "Native")FullScreen",
                                                 from: oldLayout, to: windowedLayoutState)
    let exitFSTasks = buildTasks(for: exitFSTransition, totalStartingDuration: 0, totalEndingDuration: duration)

    if modeToSetAfterExitingFullScreen == .musicMode {
      let geo = geo.clone(windowed: exitFSTransition.outputGeometry)
      let enterMusicModeTransitionTasks = buildTasksToEnterMusicMode(from: windowedLayoutState, geo)
      animationPipeline.submit(exitFSTasks + enterMusicModeTransitionTasks)
      modeToSetAfterExitingFullScreen = nil
    } else {
      animationPipeline.submit(exitFSTasks)
    }
  }

  func toggleWindowFullScreen() {
    log.verbose("ToggleWindowFullScreen")
    let layout = currentLayout

    switch layout.mode {
    case .windowedNormal, .windowedInteractive, .musicMode:
      enterFullScreen()
    case .fullScreenNormal, .fullScreenInteractive:
      exitFullScreen()
    }
  }

  func enterFullScreen(legacy: Bool? = nil) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    let isLegacy: Bool = legacy ?? Preference.bool(for: .useLegacyFullScreen)
    let isInNativeFullScreen = isWindowInNativeFullScreen
    log.verbose("EnterFullScreen called. Legacy=\(isLegacy.yn) isInNativeFSNow=\(isInNativeFullScreen.yn)")

    if isLegacy {
      animationPipeline.submitInstantTask({ [self] in
        animateEntryIntoFullScreen(withDuration: Constants.AnimationDuration.fullScreenTransition, isLegacy: true)
      })
    } else {
      /// `collectionBehavior` *must* be correct or else `toggleFullScreen` may do nothing!
      resetCollectionBehavior()
      window.toggleFullScreen(self)
    }
  }

  func exitFullScreen() {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }

    let isLegacyFS = currentLayout.isLegacyFullScreen

    if isLegacyFS {
      log.verbose("ExitFullScreen called, legacy=\(isLegacyFS.yn)")
      animationPipeline.submitInstantTask({ [self] in
        // If "legacy" pref was toggled while in fullscreen, still need to exit native FS
        animateExitFromFullScreen(withDuration: Constants.AnimationDuration.fullScreenTransition, isLegacy: true)
      })
    } else {
      let isActuallyNativeFullScreen = isWindowInNativeFullScreen
      log.verbose("ExitFullScreen called, legacy=\(isLegacyFS.yn), isNativeFullScreenNow=\(isActuallyNativeFullScreen.yn)")
      guard isActuallyNativeFullScreen else { return }
      window.toggleFullScreen(self)
    }
  }

  /// Hide menu bar & dock if current window is in full screen (either legacy or native).
  /// Show menu bar & dock if current window is not in full screen (either legacy or native).
  func updatePresentationOptions(windowIsFS: Bool) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard let window else { return }

    // Set to true if in legacy FS in any window
    let appIsFS = windowIsFS || window.isAnotherWindowInFullScreen

    guard !isWindowInNativeFullScreen else {
      log.error("Cannot add presentation options for legacy full screen: window is already in native full screen!")
      return
    }

    log.verbose("Updating presentationOptions: legacyFS=\(appIsFS.yn)")
    if appIsFS {
      // Unfortunately, the check for native FS can return false if the window is in full screen but not the active space.
      // Fall back to checking this one
      guard !NSApp.presentationOptions.contains(.hideMenuBar) else {
        log.error("Cannot add presentation options for legacy full screen: option .hideMenuBar already present! Will try to avoid crashing")
        return
      }
      NSApp.presentationOptions.insert(.autoHideMenuBar)
      if !NSApp.presentationOptions.contains(.autoHideDock) {
        NSApp.presentationOptions.insert(.autoHideDock)
      }
    } else {
      if NSApp.presentationOptions.contains(.autoHideMenuBar) {
        NSApp.presentationOptions.remove(.autoHideMenuBar)
      }
      if NSApp.presentationOptions.contains(.autoHideDock) {
        NSApp.presentationOptions.remove(.autoHideDock)
      }
    }
  }

  func updateUseLegacyFullScreen() {
    animationPipeline.submitInstantTask { [self] in
      let oldLayout = currentLayout
      if !oldLayout.isFullScreen {
        animationPipeline.submitInstantTask { [self] in
          resetCollectionBehavior()
        }
      }
      // Exit from legacy FS only. Native FS will fail if not the active space
      guard oldLayout.isLegacyFullScreen else { return }
      let outputLayoutState = LayoutState.fromPrefs(fillingInFrom: oldLayout)
      if oldLayout.isLegacyStyle != outputLayoutState.isLegacyStyle {
        animationPipeline.submitInstantTask { [self] in
          log.verbose("User toggled legacy FS pref to \(outputLayoutState.isLegacyStyle.yesno) while in FS. Will try to exit FS")
          exitFullScreen()
        }
      }
    }
  }

  func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
    // TODO: support window tiling in FS! This will likely involve saving the size given here somewhere.
    log.verbose("Full screen content size proposed=\(proposedSize), returning=\(proposedSize)")
    return proposedSize
  }

  // MARK: - Window Delegate: window move, screen changes

  /// This does not appear to be called anymore in MacOS 14.5...
  /// Make sure to duplicate its functionality in `windowDidChangeScreenParameters`
  func windowDidChangeBackingProperties(_ notification: Notification) {
    log.verbose("WindowDidChangeBackingProperties received")
    videoView.refreshContentsScale()
    restartWindowResizeDenialPeriod("WindowDidChangeBackingProperties")
  }

  func windowDidChangeScreenProfile(_ notification: Notification) {
    log.verbose("WindowDidChangeScreenProfile received")
    videoView.refreshContentsScale()
    restartWindowResizeDenialPeriod("WindowDidChangeScreenProfile")
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    log.verbose("WndDidChangeOcclusionState received")
    assert(DispatchQueue.isExecutingIn(.main))
    // In case OpenGL buffer was emptied while window was hidden:
    videoView.forceDraw()
  }

  func colorSpaceDidChange(_ notification: Notification) {
    log.verbose("ColorSpaceDidChange received")
    player.refreshEdrMode()
  }

  // Note: this gets triggered by many unnecessary situations, e.g. several times each time full screen is toggled.
  func windowDidChangeScreen(_ notification: Notification) {
    guard let window = window, let screen = window.screen else { return }
    let displayId = screen.displayId
    guard videoView.currentDisplay != displayId else {
      log.trace("WndDidChangeScreen: no need to update display state; currentDisplayID \(displayId) is unchanged")
      return
    }

    log.trace("WndDidChangeScreen received: \(videoView.currentDisplay?.description ?? "nil") → \(screen.displayId)")
    if videoView.currentDisplay != nil {  // Don't need for first update
      restartWindowResizeDenialPeriod("windowDidChangeScreen")
      pendingResizeForScreenChange = true
    }

    // MacOS Sonoma sometimes blasts tons of these for unknown reasons. Attempt to prevent slowdown by debouncing
    screenChangedDebouncer.run { [self] in
      guard !isClosing else { return }
      guard videoView.currentDisplay != displayId else {
        log.trace("WndDidChangeScreen: no need to update display state; currentDisplayID \(displayId) is unchanged")
        return
      }

      animationPipeline.submitInstantTask({ [self] in
        log.verbose("WndDidChangeScreen wNum=\(window.windowNumber): frame=\(window.frame) screenID=\(screen.screenID.quoted) screenFrame=\(screen.frame)")
        applyThemeMaterial(window, screen)  // scaleFactor may have changed
        videoView.refreshAllVideoDisplayState()
        player.events.emit(.windowScreenChanged)
      })

      let blackWindows = self.blackWindows
      if isFullScreen && Preference.bool(for: .blackOutMonitor) && blackWindows.compactMap({$0.screen?.displayId}).contains(displayId) {
        log.verbose("WndDidChangeScreen: black windows contains window's displayId \(displayId); removing & regenerating black windows")
        // Window changed screen: adjust black windows accordingly
        removeBlackWindows()
        blackOutOtherMonitors()
      }

      guard !sessionState.isRestoring, !isAnimatingLayoutTransition else { return }

      animationPipeline.submitTask(timing: .linear, { [self] in
        adjustWindowFrameForScreenUpdate(nameForLog: "WndDidChangeScreen")
      })
    }
  }

  /// Can be:
  /// • A Screen was connected or disconnected
  /// • Dock visiblity was toggled
  /// • Menu bar visibility toggled
  /// • Adding or removing window style mask `.titled`
  /// • Sometimes called hundreds(!) of times while window is closing
  func windowDidChangeScreenParameters() {
    // MacOS Sonoma sometimes blasts tons of these for unknown reasons. Attempt to prevent slowdown by de-duplicating
    screenParamsChangedDebouncer.run { [self] in

      guard !sessionState.isRestoring, !isAnimatingLayoutTransition else { return }

      // In normal full screen mode AppKit will automatically adjust the window frame if the window
      // is moved to a new screen such as when the window is on an external display and that display
      // is disconnected. In legacy full screen mode IINA is responsible for adjusting the window's
      // frame.
      // Use very short duration. This usually gets triggered at the end when entering fullscreen, when the dock and/or menu bar are hidden.
      animationPipeline.submitTask(duration: Constants.AnimationDuration.videoReconfig, { [self] in
        guard !isClosing else { return }
        if UIState.shared.isSaveEnabled {
          UIState.shared.updateCachedScreens()
        }
        log.verbose("WndDidChangeScreenParams: Rebuilt cached screen meta: \(UIState.shared.cachedScreens.values)")
        // Put this inside a Task. It will cause hiccups in other animations if run outside
        videoView.refreshAllVideoDisplayState()

        adjustWindowFrameForScreenUpdate(nameForLog: "WndDidChangeScreenParams")
      })
    }
  }

  func windowDidMove(_ notification: Notification) {
    guard let window = window else { return }
    guard !window.inLiveResize, !isAnimatingLayoutTransition, !isMagnifying, !sessionState.isRestoring else { return }
    guard !isAnimating else { return }

    // Do not allow scrolling if window recently moved! By default, multi-touch gestures can trigger scrolling
    // either before or after the gesture if not all fingers are down/up at precisely the same time.
    windowScrollWheel.delegate?.endScrollSessionIfExists()
    restartWindowScrollDenialPeriod()

    // We can get here if external calls from accessibility APIs change the window location.
    // Inserting a small delay seems to help to avoid race conditions as the window seems to need time to "settle"
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.TimeInterval.windowDidMoveProcessingDelay) { [self] in
      animationPipeline.submitInstantTask({ [self] in

        let layout = currentLayout
        if layout.isLegacyFullScreen {
          // MacOS (as of 14.0 Sonoma) sometimes moves the window around when there are multiple screens
          // and the user is changing focus between windows or apps. This can also happen if the user is using a third-party
          // window management app such as Amethyst. If this happens, move the window back to its proper place:
          log.verbose("WindowDidMove: Updating legacy full screen window in response to unexpected windowDidMove to frame=\(window.frame), screen=\(bestScreen.screenID.quoted)")
          let fsGeo = fullScreenGeo()
          applyPWinGeometry(fsGeo)
        } else {
          player.saveState()
          player.events.emit(.windowMoved, data: window.frame)
        }
      })
    }
  }

  /// Used for possibly updating the window size and/or origin after receiving one of:
  /// `windowDidChangeScreen`
  /// `windowDidChangeScreenParameters`
  private func adjustWindowFrameForScreenUpdate(nameForLog: String) {
    guard let window = window, let screen = window.screen else { return }
    let screenID = screen.screenID
    let currentLayout = currentLayout

    /// Need to recompute legacy FS's window size so it exactly fills the new screen.
    /// But looks like the OS will try to reposition the window on its own and can't be stopped...
    /// Just wait until after it does its thing before calling `setFrame()`.
    if currentLayout.isLegacyFullScreen {
      guard currentLayout.isLegacyFullScreen else { return }  // check again now that we are inside animation
      log.verbose("\(nameForLog): Updating legacy FS window")
      let fsGeo = fullScreenGeo()
      applyPWinGeometry(fsGeo, submitUpdate: true)
      return
    }

    // If user is dragging with mouse, it feels more jarring to change the window frame, so try to avoid that.
    guard !isLeftMouseButtonDown else { return }
    guard NSScreen.forScreenID(screenID) != nil else { return }

    let newWindowFrame = window.frame
    // Don't resize the window unless it's too big to fit on screen.
    //      let needsSizeChange = !newWindowFrame.size.canFitInside(screenFrame.size)
    let newGeo: PWinGeometry
    if currentLayout.mode.isWindowed && windowedModeGeo.screenFit.shouldMoveWindowToKeepInContainer {
      /// In certain corner cases (e.g., exiting legacy full screen after changing screens while in full screen),
      /// the screen's `visibleFrame` can change after `transition.outputGeometry` was generated and won't be known until the end.
      /// By calling `refitted()` here, we can make sure the window is constrained to the up-to-date `visibleFrame`.
      newGeo = windowedModeGeo.clone(windowFrame: newWindowFrame, screenID: screenID).refitted()
    } else if currentLayout.mode == .musicMode && musicModeGeo.screenFit.shouldMoveWindowToKeepInContainer {
      newGeo = musicModeGeo.clone(windowFrame: newWindowFrame, screenID: screenID).refitted()
    } else {
      return
    }

    log.verbose("\(nameForLog): Updating windowFrame to fit screen: \(newWindowFrame) → \(newGeo.windowFrame)")
    applyPWinGeometry(newGeo, submitUpdate: true)
  }

  // MARK: - Window delegate: Active status

  func windowDidBecomeKey(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      guard !isClosing else { return }

      if Preference.bool(for: .pauseWhenInactive) && isPausedDueToInactive {
        log.verbose("Window is key & isPausedDueToInactive=Y. Resuming playback")
        player.resume()
        isPausedDueToInactive = false
      }

      refreshKeyWindowStatus()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      // keyWindow is nil: The whole app is inactive
      // keyWindow is another PlayerWindow: Switched to another video window
      let otherAppWindow = NSApp.keyWindow
      let wholeAppIsInactive = otherAppWindow == nil
      let otherPlayerWindow = otherAppWindow?.windowController as? PlayerWindowController
      let anotherPlayerWindowIsActive = otherPlayerWindow != nil
      if wholeAppIsInactive || anotherPlayerWindowIsActive {
        if Preference.bool(for: .pauseWhenInactive), player.info.isPlaying {
          log.verbose("WindowDidResignKey: pausing cuz either wholeAppIsInactive (\(wholeAppIsInactive.yn)) or anotherPlayerWindowIsActive (\(anotherPlayerWindowIsActive.yn))")
          player.pause()
          isPausedDueToInactive = true
        }
      }
      
      refreshKeyWindowStatus()
    }
  }

  func updateColorsForKeyWindowStatus(isKey: Bool) {
    if customTitleBar != nil {
      updateTitle()
    } else {
      /// Duplicate some of the logic in `customTitleBar.refreshTitle()`
      let alphaValue = isKey ? 1.0 : 0.4
      for view in [leadingSidebarToggleButton, trailingSidebarToggleButton, onTopButton] {
        // Skip buttons which are not visible
        guard view.alphaValue > 0.0 else { continue }
        view.alphaValue = alphaValue
      }
    }
  }

  /// Should be run inside an animation task!
  func refreshKeyWindowStatus() {
    guard let window else { return }
    guard !isClosing else { return }

    let isKey = window.isKeyWindow
    lastKeyWindowStatus = isKey
    log.trace("Window isKey=\(isKey.yesno)")
    updateColorsForKeyWindowStatus(isKey: isKey)

    if isKey {
      PlayerManager.shared.lastActivePlayer = player
      MediaPlayerIntegration.shared.update()
      AppDelegate.shared.menuController?.updatePluginMenu()

      if isFullScreen && Preference.bool(for: .blackOutMonitor) {
        blackOutOtherMonitors()
      }

      if currentLayout.isLegacyFullScreen && window.level != .iinaFloating {
        log.verbose("Window is key: resuming legacy FS window level")
        window.level = .iinaFloating
      }

      if player.needsInputConfFileReload {
        player.needsInputConfFileReload = false
        player.mpv.loadSelectedInputConf()
      }

      // If focus changed from a different window, need to recalculate the current bindings
      // so that this window's input sections are included and the other window's are not:
      if AppInputConfig.current.associatedPlayerLabel != player.label {
        if DebugConfig.logBindingsRebuild {
          AppInputConfig.log.verbose("Need to rebuild AppInputConfig.current: active player changed to \(player.label)")
        }
        AppInputConfig.rebuildForLastActivePlayer()
      }

    } else {
      /// Always restore window level from `floating` to `normal`, so other windows aren't blocked & cause confusion
      if currentLayout.isLegacyFullScreen && window.level != .normal {
        log.verbose("Window is not key: restoring legacy FS window level to normal")
        window.level = .normal
      }

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }
    }
  }

  // Don't really care if window is main in IINA Advance; we care only if window is key,
  // because the key window is the active window in AppKit.
  // Fire events anyway to keep compatibility with upstream IINA.
  func windowDidBecomeMain(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      player.events.emit(.windowMainStatusChanged, data: true)
      NotificationCenter.default.post(name: .iinaPlayerWindowChanged, object: true)
    }
  }

  func windowDidResignMain(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      player.events.emit(.windowMainStatusChanged, data: false)
      NotificationCenter.default.post(name: .iinaPlayerWindowChanged, object: false)
    }
  }

  func windowWillMiniaturize(_ notification: Notification) {
    if Preference.bool(for: .pauseWhenMinimized), player.info.isPlaying {
      isPausedDueToMiniaturization = true
      player.pause()
    }
  }

  func windowDidMiniaturize(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      log.verbose("PWin Did Miniaturize")
      isWindowMiniturized = true
      if Preference.bool(for: .togglePipByMinimizingWindow) &&
          (!Preference.bool(for: .togglePipByMinimizingWindowForVideoOnly) ||  player.info.currentMediaAudioStatus == .notAudio)
          && !isWindowMiniaturizedDueToPip {
        enterPIP()
      }
      player.events.emit(.windowMiniaturized)
    }
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    animationPipeline.submitInstantTask { [self] in
      log.verbose("PWin Did Deminiaturize")
      isWindowMiniturized = false
      if Preference.bool(for: .pauseWhenMinimized) && isPausedDueToMiniaturization {
        player.resume()
        isPausedDueToMiniaturization = false
      }
      if Preference.bool(for: .togglePipByMinimizingWindow) &&
          (!Preference.bool(for: .togglePipByMinimizingWindowForVideoOnly) ||  player.info.currentMediaAudioStatus == .notAudio) {
        exitPIP()
      }
      player.events.emit(.windowDeminiaturized)
    }
  }

  func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool {
    log.verbose("PWin ShouldPopUpDocumentPathMenu")
    guard let currentPlayback = player.info.currentPlayback else { return false }
    return !currentPlayback.isNetworkResource
  }

  // MARK: - UI: Title

  @objc
  func updateTitle() {
    player.mpv.queue.async { [self] in
      guard player.isActive else { return }
      guard let currentPlayback = player.info.currentPlayback else {
        log.trace("Cannot update window title: currentPlayback is nil")
        return
      }

      // Update metadata in cache (also send update if something changed)
      let (mediaTitle, mediaAlbum, mediaArtist) = player.getMusicMetadata()

      DispatchQueue.main.async { [self] in
        guard let window else { return }

        if isInMiniPlayer {
          // Update title in music mode control bar
          setWindowTitle(mediaTitle, isFilename: false)
          miniPlayer.loadIfNeeded()
          miniPlayer.updateTitle(mediaTitle: mediaTitle, mediaAlbum: mediaAlbum, mediaArtist: mediaArtist)

        } else if currentPlayback.isNetworkResource {
          // Streaming media: title can change unpredictably
          window.representedURL = nil
          setWindowTitle(mediaTitle, isFilename: false)

        } else {
          let currentURL = currentPlayback.url
          // Workaround for issue #3543, IINA crashes reporting:
          // NSInvalidArgumentException [NSNextStepFrame _displayName]: unrecognized selector
          // When running on an M1 under Big Sur and using legacy full screen.
          //
          // Changes in Big Sur broke the legacy full screen feature. The PlayerWindowController method
          // legacyAnimateToFullscreen had to be changed to get this feature working again. Under Big
          // Sur that method now calls "window.styleMask.remove(.titled)". Removing titled from the
          // style mask causes the AppKit method NSWindow.setTitleWithRepresentedFilename to trigger the
          // exception listed above. This appears to be a defect in the Cocoa framework. The window's
          // title can still be set directly without triggering the exception. The problem seems to be
          // isolated to the setTitleWithRepresentedFilename method, possibly only when running on an
          // Apple Silicon based Mac. Based on the Apple documentation setTitleWithRepresentedFilename
          // appears to be a convenience method. As a workaround for the issue directly set the window
          // title.
          //
          // This problem has been reported to Apple as:
          // "setTitleWithRepresentedFilename throws NSInvalidArgumentException: NSNextStepFrame _displayName"
          // Feedback number FB9789129
          let title = currentURL.lastPathComponent
          // Local file: facilitate document icon
          window.representedURL = currentURL
          setWindowTitle(title, isFilename: false)
          window.setTitleWithRepresentedFilename(currentURL.path)
        }
      }  // end DispatchQueue.main work item
    }
  }

  private func setWindowTitle(_ titleText: String, isFilename: Bool) {
    guard let window else { return }

    // Interesting. The Swift preprocessor will not see this variable inside the DEBUG block if it is also named "isFilename".
    var filename = isFilename
#if DEBUG
    // Include player ID in window (example: "[1234c0] MyVideo.mp4")
    let debugTitle = "[\(player.label)] \(titleText)"
    log.trace("Updating window title to: \(debugTitle.pii.quoted)")
    window.title = debugTitle
    filename = false
    customTitleBar?.updateTitle(to: debugTitle)
#else
    window.title = titleText
    customTitleBar?.updateTitle(to: titleText)
#endif

    /// This call is needed when using custom window style, otherwise the window won't get added to the Window menu or the Dock.
    /// Oddly, there are 2 separate functions for adding and changing the item, but `addWindowsItem` has no effect if called more than once,
    /// while `changeWindowsItem` needs to be called if `addWindowsItem` was already called. To be safe, just call both.
    NSApplication.shared.addWindowsItem(window, title: titleText, filename: filename)
    NSApplication.shared.changeWindowsItem(window, title: titleText, filename: filename)
  }

  func showContextMenu() {
    // TODO
  }


  // MARK: - UI: Interactive Mode

  func enterInteractiveMode(_ mode: InteractiveMode) {
    // Can't work with PiP. For now just exit it and don't wait. The animation could be better but it's better
    // than entering a buggy state.
    animationPipeline.submitInstantTask{ [self] in
      exitPIP()
    }

    let videoTF: GeometryTransform.VideoGeometryTF = { [self] inputVidGeo, ctx -> VideoGeometry? in
      log.verbose("Entering interactive mode: \(mode)")

      if inputVidGeo.streamRotation != 0 {
        log.warn("FIXME: Video codec rotation is not yet supported in interactive mode! Any selection chosen will be completely wrong!")
      }

      if mode == .crop, let cropFilter = inputVidGeo.cropFilter {
        log.debug("Crop mode requested. Will remove existing crop filter: \(cropFilter.stringFormat.quoted)")
        let uncroppedVidGeo = inputVidGeo.removingCrop()

        // A crop is already set. Need to temporarily remove it so that the whole video can be seen again,
        // so that a new crop can be chosen. But keep info from the old filter in case the user cancels.
        // Change this pre-emptively so that removeVideoFilter doesn't trigger a window geometry change
        player.info.videoFiltersDisabled[cropFilter.label!] = cropFilter
        if !player.removeVideoFilter(cropFilter) {
          log.error("Failed to remove prev crop filter: (\(cropFilter.stringFormat.quoted)) for some reason. Will ignore and try to proceed anyway")
        }

        return uncroppedVidGeo
      } else {
        return inputVidGeo
      }
    }

    let buildPWinGeoTransformTasks: (GeometryTransform.ContextStage3) -> [IINAAnimation.Task] = { [self] ctx -> [IINAAnimation.Task] in

      guard ctx.inputLayout.canEnterInteractiveMode else {
        log.debug("Aborting entry into interactive mode as it is not possible for this input layout")
        return []
      }

      // FIXME: need to un-rotate while in interactive mode
      if ctx.inputVidGeo.streamRotation != 0 {
        log.warn("FIXME: Video codec rotation is not yet supported in interactive mode! Any selection chosen will be completely wrong!")
      }
      // TODO: use key binding interceptor to support ESC and ENTER keys for interactive mode
      let isInFullScreen = ctx.inputLayout.mode.isFullScreen

      // Build entry animation
      let newMode: PlayerWindowMode = isInFullScreen ? .fullScreenInteractive : .windowedInteractive
      let interactiveModeLayout = ctx.inputLayout.clone(mode: newMode, interactiveMode: mode)
      let startDuration = isInFullScreen ? 0.0 : Constants.AnimationDuration.cropAnimation * 0.5
      let endDuration = startDuration
      let entryTransition = buildLayoutTransition(named: "EnterInteractiveMode_\(mode)",
                                                  from: ctx.inputLayout, to: interactiveModeLayout, ctx.inputGeoSet)
      return buildTasks(for: entryTransition, totalStartingDuration: startDuration, totalEndingDuration: endDuration)
    }

    let gtf = GeometryTransform("EnterInteractiveMode", player,
                                syncVideoParams: false,  // already done by videoTF
                                video: videoTF,
                                buildPWinGeoTransformTasks: buildPWinGeoTransformTasks)
    gtf.submit()
  }

  /// Use `immediately: true` to exit without animation.
  /// • If there is to be an active crop, `newVidGeo` must be present and must contain it. Otherwise crop of "None" will be applied.
  /// • This method can be run safely even if not in interactive mode.
  func exitInteractiveMode(immediately: Bool = false, newVidGeo: VideoGeometry? = nil, then doAfter: (() -> Void)? = nil) {

    guard currentLayout.isInteractiveMode else {
      if let doAfter {
        animationPipeline.submitInstantTask{
          doAfter()
        }
      }
      return
    }

    let videoTF: GeometryTransform.VideoGeometryTF = { [self] inputVidGeo, ctx -> VideoGeometry? in
      assert(DispatchQueue.isExecutingIn(player.mpv.queue))

      let vidGeoToSyncFrom: VideoGeometry
      if let newVidGeo, let newCropFilter = newVidGeo.cropFilter {
        // If newVidGeo contains a crop, we must apply it
        log.verbose("Cropping video from videoSizeRaw=\(inputVidGeo.videoSizeRaw) cropRect=\(newVidGeo.cropRect?.description ?? "nil")")

        /// Set the filter. This will result in `transformGeometry` getting called, which will trigger an exit from interactive mode.
        /// But that task can only happen once we return and relinquish the main queue.
        _ = player.addVideoFilter(newCropFilter)
        // May need to re-enable mpv's keepaspect-window prematurely for a nicer animation
        ctx.player.setMpvKeepaspectWindow(to: PlayerWindowMode.windowedNormal.needsMpvKeepaspectWindow)

        vidGeoToSyncFrom = newVidGeo
      } else {
        // If no crop, remove any existing crop filter
        log.verbose("Start exiting interactive mode: crop changing to none; removing crop filter")
        if !player.removeCrop() {
          // Still may need to bring UI up to date
          player.setQuickSettingsViewNeedsUpdate()
        }
        vidGeoToSyncFrom = inputVidGeo
      }
      let outputVidGeo = ctx.syncVideoParamsFromMpv(startingWith: vidGeoToSyncFrom)
      // Zap videoSizeDisplayOverride because it will probably be wrong at this stage due to mpv race condition
      return outputVidGeo?.clone(videoSizeDisplayOverride: nil)
    }

    let buildPWinGeoTransformTasks: (GeometryTransform.ContextStage3) -> [IINAAnimation.Task] = { [self] ctx -> [IINAAnimation.Task] in
      var tasks: [IINAAnimation.Task] = []

      // Build exit animation tasks
      if ctx.inputLayout.isInteractiveMode, let cropController = cropSettingsView {
        let newMode: PlayerWindowMode = ctx.inputLayout.isFullScreen ? .fullScreenNormal : .windowedNormal
        log.verbose("Exiting interactive mode, newMode=\(newMode)")

        let lastLayout: LayoutState
        let geoSet: GeometrySet
        var startDuration: CGFloat = 0
        var endDuration: CGFloat = 0

        if newMode == .fullScreenNormal {
          // Can derive last layout from lastWindowedLayoutState
          lastLayout = LayoutState.fromPrefs(andMode: newMode, fillingInFrom: lastWindowedLayoutState)

          // TODO: support animation in full screen once again

          geoSet = ctx.inputGeoSet.clone(video: ctx.outputVidGeo)

        } else {  // Windowed mode
          lastLayout = lastWindowedLayoutState

          if !immediately {
            startDuration = Constants.AnimationDuration.cropAnimation * 0.75
            endDuration = Constants.AnimationDuration.cropAnimation * 0.25
          }


          let currentWindowedIMGeo = windowedGeoForCurrentFrame()
          let croppedIMGeo = currentWindowedIMGeo.cropVideo(using: ctx.outputVidGeo)

          let croppedIMGeoWithNoViewportMargins = croppedIMGeo.scalingViewport(toSimilarSizeAs: currentWindowedIMGeo)
          geoSet = buildGeoSet(windowed: croppedIMGeoWithNoViewportMargins, video: ctx.outputVidGeo, layoutMode: ctx.inputLayout.mode)

          // Animate the crop to highlight the piece being cut out.
          let cropAnimationDuration = 0.0
          tasks.append(.init(duration: cropAnimationDuration) { [self] in
            log.verbose("Start exiting interactive mode: animating crop using: \(croppedIMGeo)")
            // #InteractiveModeAnimationKludge
            applyPWinGeometry(croppedIMGeo, .cropBeforeExitingInteractiveMode)

            // Fade out cropBox selection rect
            cropController.cropBoxView.isHidden = true
            cropController.cropBoxView.alphaValue = 0
          })
        }

        let newLayoutState = LayoutState.fromPrefs(andMode: newMode, fillingInFrom: lastLayout)
        let transition = buildLayoutTransition(named: "ExitInteractiveMode", from: ctx.inputLayout, to: newLayoutState, geoSet)
        let transitionTasks = buildTasks(for: transition, totalStartingDuration: startDuration, totalEndingDuration: endDuration)
        tasks.append(contentsOf: transitionTasks)
      }

      // Build doAfter task
      if let doAfter {
        tasks.append(.instantTask({
          doAfter()
        }))
      }

      return tasks
    }

    let gtf = GeometryTransform("ExitInteractiveMode", player, syncVideoParams: false,
                                video: videoTF, buildPWinGeoTransformTasks: buildPWinGeoTransformTasks)
    gtf.submit()
  }


  // MARK: - UI: Music Mode

  /// Calls `buildTransitionToEnterMusicMode`, but first exits existing FS or interactive mode.
  func enterMusicMode(automatically: Bool = false, from oldLayout: LayoutState? = nil, _ geo: GeometrySet? = nil) {
    exitInteractiveMode(then: { [self] in
      /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
      /// We can do this by creating a `LayoutState`, then using it to build a `LayoutTransition` and executing its animation.
      let oldLayout = oldLayout ?? currentLayout
      if oldLayout.isFullScreen {
        // Use exit FS as main animation and piggypack on that.
        // Need to do some gymnastics to parameterize exit from native full screen
        modeToSetAfterExitingFullScreen = .musicMode
        exitFullScreen()
      } else {
        let transitionTasks = buildTasksToEnterMusicMode(automatically: automatically, from: oldLayout, geo)
        animationPipeline.submit(transitionTasks)
      }
    })
  }

  /// `automatically` == via auto-switch to music mode
  func buildTasksToEnterMusicMode(automatically: Bool = false,
                                  from oldLayout: LayoutState, _ geo: GeometrySet? = nil) -> [IINAAnimation.Task] {
    let miniPlayerLayout = oldLayout.clone(mode: .musicMode)
    let transition = buildLayoutTransition(named: "EnterMusicMode", from: oldLayout, to: miniPlayerLayout, geo)
    var transitionTasks = buildTasks(for: transition)

    transitionTasks.append(.instantTask { [self] in
      if !automatically {
        // Toggle manual override
        player.overrideAutoMusicMode = !player.overrideAutoMusicMode
        log.verbose("Changed overrideAutoMusicMode to \(player.overrideAutoMusicMode.yesno)")
      }

      player.events.emit(.musicModeChanged, data: true)
    })
    return transitionTasks
  }

  func exitMusicMode(automatically: Bool = false, from oldLayout: LayoutState? = nil, _ geo: GeometrySet? = nil) {
    animationPipeline.submitInstantTask { [self] in
      let oldLayout = oldLayout ?? currentLayout

      // If not showing video, then enable video first & wait for it to return before exiting
      if oldLayout.isMusicMode && !(geo ?? self.geo).musicMode.isViewportShown {
        player.setVideoTrackEnabled(thenDoAction: .exitMusicMode)
        return
      }

      var tasks = buildTasksToExitMusicMode(automatically: automatically, from: oldLayout, geo)
      tasks.append(.instantTask { [self] in
        updateTitle()
        player.events.emit(.musicModeChanged, data: false)
      })

      animationPipeline.submit(tasks)
    }
  }

  func buildTasksToExitMusicMode(automatically: Bool = false,
                                 from oldLayout: LayoutState, _ geo: GeometrySet? = nil) -> [IINAAnimation.Task] {
    let windowedLayout = LayoutState.fromPrefs(andMode: .windowedNormal, fillingInFrom: lastWindowedLayoutState)
    let transition = buildLayoutTransition(named: "ExitMusicMode", from: oldLayout, to: windowedLayout, geo)
    var transitionTasks = buildTasks(for: transition)
    if !automatically {
      transitionTasks.append(.instantTask { [self] in
        if !automatically {
          player.overrideAutoMusicMode = !player.overrideAutoMusicMode
          log.verbose("Changed overrideAutoMusicMode to \(player.overrideAutoMusicMode.yesno)")
        }
      })
    }
    return transitionTasks
  }

  // MARK: - Misc window stuff

  func blackOutOtherMonitors() {
    removeBlackWindows()

    let screens = NSScreen.screens.filter { $0 != window?.screen }
    var blackWindows: [NSWindow] = []

    for screen in screens {
      var screenRect = screen.frame
      screenRect.origin = CGPoint(x: 0, y: 0)
      let blackWindow = NSWindow(contentRect: screenRect, styleMask: [], backing: .buffered, defer: false, screen: screen)
      blackWindow.backgroundColor = .black
      blackWindow.level = .iinaBlackScreen

      blackWindows.append(blackWindow)
      blackWindow.orderFront(nil)
    }
    self.blackWindows = blackWindows
    log.verbose("Added black windows for screens \((blackWindows.compactMap({$0.screen?.displayId}).map{String($0)}))")
  }

  func removeBlackWindows() {
    let blackWindows = self.blackWindows
    self.blackWindows = []
    guard !blackWindows.isEmpty else { return }
    for window in blackWindows {
      window.orderOut(self)
    }
    log.verbose("Removed black windows for screens \(blackWindows.compactMap({$0.screen?.displayId}).map{String($0)})")
  }

  func setWindowFloatingOnTop(_ onTop: Bool, from layout: LayoutState, updateOnTopStatus: Bool = true) {
    guard !layout.isFullScreen else {
      log.verbose("Ignoring request to set onTop=\(onTop.yn): currently in full screen")
      return
    }
    log.verbose("Setting window onTop ≔ \(onTop.yn), updateStatus=\(updateOnTopStatus.yn)")

    window?.level = onTop ? .iinaFloating : .normal
    if updateOnTopStatus {
      self.isOnTop = onTop
      player.mpv.queue.async { [self] in
        guard !player.isStopping else { return }
        // TODO: does this hang if videoView is not in window?
        player.mpv.setFlag(MPVOption.Window.ontop, onTop)
        DispatchQueue.main.async { [self] in
          updateOnTopButton(from: layout, showIfFadeable: true)
          player.saveState()
        }
      }
    }
    resetCollectionBehavior()
  }

  // MARK: - Sync UI with playback

  func isUITimerNeeded() -> Bool {
    //    log.verbose("Checking if UITimer needed. hasPermanentControlBar:\(currentLayout.hasPermanentControlBar.yn) fadeableViews:\(fadeableViewsAnimationState) topBar: \(fadeableTopBarAnimationState) OSD:\(osd.animationState)")
    if currentLayout.hasPermanentControlBar {
      return true
    }
    let showingFadeableViews = fadeableViews.animationState == .shown || fadeableViews.animationState == .willShow
    let showingFadeableTopBar = fadeableViews.topBarAnimationState == .shown || fadeableViews.topBarAnimationState == .willShow
    let showingOSD = osd.animationState == .shown || osd.animationState == .willShow
    return showingFadeableViews || showingFadeableTopBar || showingOSD
  }

  /// Updates all UI controls
  func updateUI(pullUpdatesFromMpv: Bool = false) {
    assert(DispatchQueue.isExecutingIn(.main))
    // This method is often run outside of the animation queue, which can be dangerous.
    // Just don't update in this case
    guard !isAnimatingLayoutTransition else { return }
    guard loaded else { return }
    guard player.state.isNotYet(.shuttingDown) else { return }

    // scroll wheel will set newer value; do not overwrite it until it is done
    if pullUpdatesFromMpv && !isScrollingOrDraggingPlaySlider {
      player.updatePlaybackTimeInfo()
    }

    /// Make sure window is done being sized before displaying, or else OSD text can be incorrectly stretched horizontally.
    /// Make sure file is completely loaded, or else the "watch-later" message may appear separately from the `fileStart` msg.
    if player.info.isFileLoadedAndSized {
      // Run all tasks in the OSD queue until it is depleted
      osd.queueLock.withLock {
        while let taskFunc = osd.queue.removeFirst() {
          taskFunc()
        }
      }
    } else {
      // Do not refresh syncUITimer. It will cause an infinite loop
      hideOSD(immediately: true, refreshSyncUITimer: false)
    }

    updatePlayButtonAndSpeedUI()
    updatePlaybackTimeUI()
    if additionalInfoView.superview != nil {
      updateAdditionalInfoContent()
    }

    if isInMiniPlayer {
      miniPlayer.updateScrollingLabels()
    }
    if player.info.isNetworkResource {
      updateNetworkState()
    }
    // Need to also sync volume slider here, because this is called in response to repeated key presses
    updateVolumeUI()
  }

  private func updatePlaybackTimeUI() {
    assert(DispatchQueue.isExecutingIn(.main))
    // IINA listens for changes to mpv properties such as chapter that can occur during file loading
    // resulting in this function being called before mpv has set its position and duration
    // properties. Confirm the window and file have been loaded.

    guard loaded, player.info.isFileLoaded || player.isRestoring else { return }
    // The mpv documentation for the duration property indicates mpv is not always able to determine
    // the video duration in which case the property is not available.
    guard let duration = player.info.playbackDurationSec,
          let position = player.info.playbackPositionSec,
          let remaining = player.info.playbackRemainingSec else { return }

    // If the OSD is visible and is showing playback position, keep its displayed time up to date:
    updateOSDViews(updateSize: false)

    // Update playback position slider in OSC:
    for label in [leftTimeLabel, rightTimeLabel] {
      label.updateText(with: duration, given: position, and: remaining)
    }
    let percentage = (position / duration) * 100
    playSlider.doubleValue = percentage

    // Touch bar
    player.touchBarSupport.touchBarPlaySlider?.setDoubleValueSafely(percentage)
    player.touchBarSupport.touchBarPosLabels.forEach { $0.updateText(with: duration, given: position, and: remaining) }
  }

  func updateVolumeUI() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard loaded, !isClosing else { return }
    guard player.info.isFileLoaded || player.isRestoring else { return }

    let volume = player.info.volume
    let isMuted = player.info.isMuted
    /// `info.aid` contains the current audio track selection, or `0` if none selected.
    /// Before `fileLoaded` it may change to `0` while the track info is still being processed, but this is unhelpful
    /// because it can mislead us into thinking that the user has deselected the audio track.
    let hasAudio = player.info.isAudioTrackSelected

    volumeSlider.isHidden = !hasAudio
    volumeSlider.maxValue = Double(Preference.integer(for: .maxVolume))
    volumeSlider.doubleValue = volume
    muteButton.isHidden = !hasAudio

    let volumeImage = volumeIcon(volume: volume, isMuted: isMuted)
    if let volumeImage, volumeImage != muteButton.image {
      let task = IINAAnimation.Task(duration: Constants.AnimationDuration.btnLayoutChange, { [self] in
        volumeIconAspectConstraint.isActive = false
        volumeIconAspectConstraint = muteButton.widthAnchor.constraint(equalTo: muteButton.heightAnchor, multiplier: volumeImage.aspect)
        volumeIconAspectConstraint.isActive = true
      })
      IINAAnimation.runAsync(task, then: { [self] in
        muteButton.image = volumeImage
      })
    }

    // Avoid race conditions between music mode & regular mode by just setting both sets of controls at the same time.
    // Also load music mode views ahead of time so that there are no delays when transitioning to/from it.
    if isInMiniPlayer {
      miniPlayer.updatePopupVolumeUI(volume: volume, volumeImage)
    }
  }

  func volumeIcon(volume: Double, isMuted: Bool) -> NSImage? {
    if isMuted {
      return Images.mute
    }
    switch Int(volume) {
    case 0:
      return Images.volume0
    case 1...33:
      return Images.volume1
    case 34...66:
      return Images.volume2
    case 67...1000:
      return Images.volume3
    default:
      log.error("Volume level \(volume) is invalid")
      return nil
    }
  }

  func updatePlayButtonAndSpeedUI() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard loaded else { return }

    let isPaused = player.info.isPaused
    let playPauseImage: NSImage
    if isPaused {
      if player.shouldShowRestartFromEOFIcon() {
        playPauseImage = Images.replay
      } else {
        playPauseImage = Images.play
      }
    } else {
      playPauseImage = Images.pause
    }

    let oscGeo = currentLayout.controlBarGeo
    let playSpeed = player.info.playSpeed
    let showSpeedLabel = player.info.shouldShowSpeedLabel && oscGeo.barHeight >= (oscGeo.isTwoRowBarOSC ? Constants.minTwoRowOSCBarHeightForSpeedLabel : Constants.minSingleRowOSCBarHeightForSpeedLabel)

    let hasPlayButtonChange = playButton.image != playPauseImage
    let hasSpeedLayoutChange = speedLabel.isHidden == !showSpeedLabel

    // Update status in menu bar menu (if enabled)
    MediaPlayerIntegration.shared.update()

    let duration = (hasSpeedLayoutChange || hasPlayButtonChange) ? Constants.AnimationDuration.btnLayoutChange * 4 : 0.0
    IINAAnimation.runAsync(.init(duration: duration) { [self] in
      // Avoid race conditions between music mode & regular mode by just setting both sets of controls at the same time.
      // Also load music mode views ahead of time so that there are no delays when transitioning to/from it.
      var effect: SymButton.ReplacementEffect = .downUp
      if playButton.image == Images.replay, playPauseImage != Images.replay {
        // looks less bad
        effect = .offUp
      }
      playButton.replaceSymbolImage(with: playPauseImage, effect: effect)

      speedLabelBtmConstraint.isActive = showSpeedLabel
      speedLabel.isHidden = !showSpeedLabel

      if showSpeedLabel {
        speedLabel.stringValue = "\(playSpeed.stringTrunc3f)x"
      }
      player.touchBarSupport.updateTouchBarPlayBtn()
    })
  }

  func showBufferIndicator(animate: Bool, progressLabel: String, detailLabel: String) {
    guard loaded else { return }

    if bufferIndicatorView.superview == nil {
      viewportView.addSubview(bufferIndicatorView)
      sortViewportViewSubviews()

      // Center in viewport
      bufferIndicatorView.centerXAnchor.constraint(equalTo: viewportView.centerXAnchor).isActive = true
      bufferIndicatorView.centerYAnchor.constraint(equalTo: viewportView.centerYAnchor).isActive = true
    }

    bufferIndicatorView.bufferSpin.startAnimation(self)
    bufferIndicatorView.bufferProgressLabel.stringValue = progressLabel
    bufferIndicatorView.bufferDetailLabel.stringValue = detailLabel
  }

  func hideBufferIndicator() {
    guard loaded else { return }
    bufferIndicatorView.removeFromSuperview()
    bufferIndicatorView.bufferSpin.stopAnimation(self)
  }

  func updateNetworkState() {
    let isNotYetLoaded = (player.info.currentPlayback?.state.isNotYet(.loaded) ?? false)
    // Indicator should only be shown for network resources (AKA streaming media).
    // When media is not yet loaded, mpv does not indicate it is paused for cache. Assume it is.
    let showIndicator = player.info.isNetworkResource &&
    (player.info.pausedForCache || isNotYetLoaded) && Preference.bool(for: .showBufferingThrobber) ||
    (player.info.isSeeking && Preference.bool(for: .showSeekingThrobber))

    // Hide videoView so that prev media (if any) is not seen while loading current media
    videoView.isHidden = showIndicator && isNotYetLoaded

    if showIndicator {
      let usedStr = FloatingPointByteCountFormatter.string(fromByteCount: player.info.cacheUsed, prefixedBy: .ki)
      let speedStr = FloatingPointByteCountFormatter.string(fromByteCount: player.info.cacheSpeed)
      let bufferingState = player.info.bufferingState
      // mpv usually hangs at 0% the entire time. Do not show any progress if we do not have progress to show.
      let showNumbers = bufferingState > 0
      let bufStateString = showNumbers ? "\(bufferingState)%" : ""
      log.trace("Showing bufferIndicatorView (\(bufferingState)%, \(usedStr)B, \(speedStr)/s)")
      let progressLabel = String(format: NSLocalizedString("main.buffering_indicator", comment:"Buffering... %@"), bufStateString)
      let detailLabel = showNumbers ? "\(usedStr)B (\(speedStr)/s)" : ""
      let animate = !(!isNotYetLoaded && player.info.cacheSpeed == 0)
      showBufferIndicator(animate: animate, progressLabel: progressLabel, detailLabel: detailLabel)
    } else {
      hideBufferIndicator()
    }
  }

  /// In music mode, there is different styling depending on whether viewport is visible.
  /// Need to adjust layout of buttons depending on layout.
  func updateMusicModeButtonOffsets(using targetGeo: PWinGeometry) {
    miniPlayer.loadIfNeeded()
    if targetGeo.mode == .musicMode {
      let isViewportShown = targetGeo.isViewportShown
      // Push the volume button to the right if the buttons on at the same vertical position
      miniPlayer.volumeButtonLeadingConstraint.animateToConstant(isViewportShown ? 12 : 70)
      miniPlayer.volumeButtonLeadingConstraint.priority = .required
    } else {
      miniPlayer.volumeButtonLeadingConstraint.priority = .minimum
    }
  }

  func refreshHidesOnDeactivateStatus() {
    guard let window else { return }
    let hideOnDeactivate = currentLayout.isWindowed && Preference.bool(for: .hideWindowsWhenInactive)
    if window.hidesOnDeactivate != hideOnDeactivate {
      window.hidesOnDeactivate = hideOnDeactivate
    }
  }

  /// All args are optional overrides
  func updateWindowBorderAndOpacity(using layout: LayoutState? = nil, windowOpacity newOpacity: Float? = nil) {
    // Do not use "required" priority for at least 1 constraint in each dimension (avoids constraint errors if an animation
    // reduces the window size to 0px).
    let priority = NSLayoutConstraint.Priority.defaultHigh
    let layout = layout ?? currentLayout
    /// The title bar of the native `titled` style doesn't support translucency. So do not allow it for native modes:
    let newOpacity: Float = layout.isFullScreen || !layout.isLegacyStyle ? 1.0 : newOpacity ?? (Preference.isAdvancedEnabled ? Preference.float(for: .playerWindowOpacity) : 1.0)
    // Native window removes the border if winodw background is transparent.
    // Try to match this behavior for legacy window
    var wantsBorderShown = false
    if #unavailable(macOS 26) {  // Border is drawn on all window styles starting with MacOS 26
      wantsBorderShown = layout.isLegacyStyle && !layout.isFullScreen && newOpacity == 1.0
    }
    if wantsBorderShown {
      let contentView = window!.contentView!
      if customWindowBorderBox.superview == nil {
        contentView.addSubview(customWindowBorderBox, positioned: .above, relativeTo: contentView.containsSubview(topBarView) ? topBarView : viewportView)
        // Deviate from the native look slightly by reducing trailing & bottom by 0.5pt. Just looks too distracting otherwise
        customWindowBorderBox.addConstraintsToFillSuperview(top: 0, .required, bottom: -0.5, priority,
                                                            leading: 0, .required, trailing: -0.5, priority)
        customWindowBorderBox.isHidden = false
        contentView.needsLayout = true
      }

      if customWindowBorderTopHighlightBox.superview == nil {
        contentView.addSubview(customWindowBorderTopHighlightBox, positioned: .above, relativeTo: customWindowBorderBox)
        // No highlight at all on the bottom & trailing: hide those sides outside superview bounds
        customWindowBorderTopHighlightBox.addConstraintsToFillSuperview(bottom: -1.0, trailing: -1.0)
        let hlBoxTop = customWindowBorderTopHighlightBox.topAnchor.constraint(equalTo: customWindowBorderBox.topAnchor, constant: 0)
        hlBoxTop.priority = priority
        hlBoxTop.isActive = true
        let hlBoxLeading = customWindowBorderTopHighlightBox.leadingAnchor.constraint(equalTo: customWindowBorderBox.leadingAnchor, constant: 0)
        hlBoxLeading.priority = priority
        hlBoxLeading.isActive = true
        customWindowBorderTopHighlightBox.isHidden = false
        contentView.needsLayout = true
      }
    } else {
      // Hide border
      customWindowBorderBox.removeFromSuperview()
      customWindowBorderTopHighlightBox.removeFromSuperview()
    }

    // Update window opacity *after* showing the views above. Apparently their alpha values will not get updated if shown afterwards.
    guard let window else { return }
    let existingOpacity = window.contentView?.layer?.opacity ?? -1
    guard existingOpacity != newOpacity else { return }
    log.debug("Changing window opacity: \(existingOpacity) → \(newOpacity)")
    window.backgroundColor = newOpacity < 1.0 ? .clear : .black
    window.contentView?.layer?.opacity = newOpacity
  }

  // MARK: - IBActions

  @objc func menuSwitchToMiniPlayer(_ sender: NSMenuItem) {
    animationPipeline.submitInstantTask{ [self] in
      if isInMiniPlayer {
        player.exitMusicMode()
      } else {
        player.enterMusicMode()
      }
    }
  }

  @objc func volumeSliderAction(_ slider: ScrollableSlider) {
    // show volume popover when volume seek begins and hide on end
    if isInMiniPlayer {
      miniPlayer.showVolumePopover()
    }
    let value = slider.doubleValue
    log.verbose("VolumeSlider: changing volume to \(value)")
    if Preference.double(for: .maxVolume) > 100, value > 100 && value < 101 {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
    player.setVolume(value)
  }

  @objc func backBtnAction(_ sender: NSButton) {
    player.exitMusicMode()
  }

  @objc func playButtonAction(_ sender: AnyObject) {
    player.togglePause()
  }

  @objc func muteButtonAction(_ sender: AnyObject) {
    player.toggleMute()
  }

  @objc func leftArrowButtonAction(_ sender: NSControl) {
    let clickPressure: Int = (sender as? SymButton)?.pressureStage ?? sender.integerValue
    arrowButtonAction(left: true, clickPressure: clickPressure)
  }

  @objc func rightArrowButtonAction(_ sender: NSControl) {
    let clickPressure: Int = (sender as? SymButton)?.pressureStage ?? sender.integerValue
    arrowButtonAction(left: false, clickPressure: clickPressure)
  }

  /** handle action of either left or right arrow button */
  func arrowButtonAction(left: Bool, clickPressure: Int) {
    let didRelease = clickPressure == 0
    log.verbose("ArrowButton \(left ? "left" : "right"): \(didRelease ? "released" : "pressed, clickPressure=\(clickPressure)")")

    let arrowBtnFunction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
    switch arrowBtnFunction {
    case .unused:
      return
    case .playlist:
      guard didRelease else { return }
      player.navigateInPlaylist(nextMedia: !left)

    case .seek:
      guard didRelease else { return }
      player.seek(relativeSecond: left ? -10 : 10, option: .defaultValue)

    case .speed:
      let indexSpeed1x = AppData.availableSpeedValues.count / 2
      let directionUnit: Int = (left ? -1 : 1)
      let currentSpeedIndex = findClosestCurrentSpeedIndex()
      let newSpeedIndex: Int

      if Preference.bool(for: .useForceTouchForSpeedArrows) {
        if didRelease { // Released

          // Discard redundant release events
          guard maxPressure > 0 else { return }

          if maxPressure == 1 &&
              ((left ? currentSpeedIndex < indexSpeed1x - 1 : currentSpeedIndex > indexSpeed1x + 1) ||
               Date().timeIntervalSince(lastForceTouchClick) < Constants.TimeInterval.minimumPressDuration) { // Single click ended
            newSpeedIndex = oldSpeedValueIndex + directionUnit
          } else { // Force Touch or long press ended
            newSpeedIndex = indexSpeed1x
          }
          maxPressure = 0
        } else {
          if clickPressure == 1 && maxPressure == 0 { // First press
            oldSpeedValueIndex = currentSpeedIndex
            newSpeedIndex = currentSpeedIndex + directionUnit
            lastForceTouchClick = Date()
          } else { // Force Touch
            newSpeedIndex = oldSpeedValueIndex + (clickPressure * directionUnit)
          }
          maxPressure = max(maxPressure, clickPressure)
        }
      } else {
        guard didRelease else { return }
        newSpeedIndex = currentSpeedIndex + directionUnit
      }
      let newSpeedIndexClamped = newSpeedIndex.clamped(to: 0..<AppData.availableSpeedValues.count)
      let newSpeed = AppData.availableSpeedValues[newSpeedIndexClamped]
      guard player.info.playSpeed != newSpeed else { return }
      player.setSpeed(newSpeed, forceResume: true) // always resume if paused
    }
  }

  private func findClosestCurrentSpeedIndex() -> Int {
    let currentSpeed = player.info.playSpeed
    for (speedIndex, speedValue) in AppData.availableSpeedValues.enumerated() {
      if currentSpeed <= speedValue {
        return speedIndex
      }
    }
    return AppData.availableSpeedValues.count - 1
  }

  @objc func toggleOnTop(_ sender: AnyObject) {
    let wasOnTop = isOnTop
    log.verbose("Toggling onTop: \(wasOnTop.yn) → \((!wasOnTop).yn)")
    if Preference.bool(for: .alwaysFloatOnTop) {
      let isPlaying = wasOnTop
      if isPlaying {
        // Assume window is only on top because media is playing. Pause the media to remove on-top.
        player.pause()
      }
    }
    setWindowFloatingOnTop(!wasOnTop, from: currentLayout)
  }

  /// Executes an absolute seek using `playSlider`'s current value.
  ///
  /// Called when `PlaySlider` changes value, either by:
  /// - clicking inside it
  /// - dragging inside it
  /// Scroll wheel seek should call `seekFromPlaySlider` directly.
  @objc func playSliderAction(_ slider: PlaySlider) {
    // Update player.info & UI proactively
    let playbackPositionAbsSec = player.info.playbackDurationSec! * slider.progressRatio
    let forceExactSeek = !Preference.bool(for: .followGlobalSeekTypeWhenAdjustSlider)
    seekFromPlaySlider(playbackPositionSec: playbackPositionAbsSec, forceExactSeek: forceExactSeek)
  }

  func seekFromPlaySlider(playbackPositionSec absoluteSecond: CGFloat, forceExactSeek: Bool) {
    guard !isInInteractiveMode else { return }

    // Update player.info & UI proactively
    player.info.playbackPositionSec = absoluteSecond
    updatePlaybackTimeUI()

    let knobWndCoordX = playSlider.centerOfKnobInWindowCoordX()
    log.trace("Seek from PlaySlider: knobWndCoordX=\(knobWndCoordX)")
    refreshSeekPreviewAsync(forWindowCoordX: knobWndCoordX)

    player.sliderSeekDebouncer.run { [self] in
      guard player.info.isFileLoaded else { return }

      let option: Preference.SeekOption = forceExactSeek ? .exact : Preference.enum(for: .useExactSeek)
      player.seek(absoluteSecond: absoluteSecond, option: option)
    }
  }

  @objc func toolBarButtonAction(_ sender: NSButton) {
    guard let buttonType = Preference.ToolBarButton(rawValue: sender.tag) else { return }
    switch buttonType {
    case .fullScreen:
      toggleWindowFullScreen()
    case .musicMode:
      player.enterMusicMode()
    case .pip:
      menuTogglePIP(sender)
    case .playlist:
      showSidebar(forTabGroup: .playlist)
    case .settings:
      showSidebar(forTabGroup: .settings)
    case .subTrack:
      quickSettingView.showSubChooseMenu(forView: sender, showLoadedSubs: true)
    case .screenshot:
      player.mpv.queue.async { [self] in
        player.screenshot()
      }
    case .plugins:
      showSidebar(forTabGroup: .plugins)
    }
  }

  // MARK: - Utility

  func setEmptySpaceColor(to newColor: CGColor) {
    guard let window else { return }
    window.contentView?.layer?.backgroundColor = newColor
    viewportView.layer?.backgroundColor = newColor
  }

  func resetCollectionBehavior() {
    guard AppDelegate.shared.isInteractiveLaunch else { return }

    guard let window else { return }
    let useLegacy = Preference.bool(for: .useLegacyFullScreen)
    log.verbose("Resetting collection behavior for full screen, legacy=\(useLegacy.yn)")
    if useLegacy {
      window.collectionBehavior.remove(.fullScreenPrimary)
      window.collectionBehavior.insert(.fullScreenAuxiliary)
    } else {
      window.collectionBehavior.remove(.fullScreenAuxiliary)
      window.collectionBehavior.insert(.fullScreenPrimary)
    }
  }

}
