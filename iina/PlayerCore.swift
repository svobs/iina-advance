//
//  PlayerCore.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

final class PlayerCore: NSObject {

  /// Should always be updated in mpv DQ
  enum LifecycleState: Int, StateEnum {
    case notYetStarted = 1

    // TODO: evaluate combining `started` + `idle` states
    case started

    // TODO: add states for playing, paused

    /// Playback has stopped and the media has been unloaded.
    ///
    /// This is the initial state of a player. The player returns to this state when a
    /// [MPV_EVENT_PROPERTY_CHANGE](https://mpv.io/manual/stable/#command-interface-mpv-event-property-change)
    /// for the `idle-active` property is received with a value of `true`.
    case idle

    /// Whether stopping of this player has been initiated.
    case stopping

    /// Whether shutdown of this player has been initiated.
    case shuttingDown

    /// Whether shutdown of this player has completed (mpv has shut down).
    case shutDown

    func isAtLeast(_ minState: LifecycleState) -> Bool { rawValue >= minState.rawValue }
    func isNotYet(_ state: LifecycleState) -> Bool { rawValue < state.rawValue }
  }

  // MARK: - Singleton Fields

  @MainActor
  static var mouseLocationAtLastOpen: NSPoint? = nil

  /// A DispatchQueue for longer-running tasks reqquiring disk IO:
  ///  auto load, playlist length prefetch, external subtitle search
  static let backgroundQueue = DispatchQueue.newDQ(label: "IINAA-Player-BG", qos: .background)

  // MARK: - Instance Fields

  let log: any Logger.Subsystem
  var subsystem: any Logger.Subsystem { self.log }
  var label: String
  let isDemoPlayer: Bool

  /// If `false`, has player functionality without use of a player window. Must be `true` to show a player window.
  var isInteractivePlayer = false

  /// After mpvInit, contains both the user options in Settings > Advanced, + commandLineArgs
  var userOptions: [MPVOptPair]

  // At launch, wait until all windows are open before resuming video
  var pendingResumeWhenShowingWindow: Bool = false
  /// If true, mpv needs to reload the current input config file because it has changed
  var needsInputConfFileReload: Bool = false
  /// If a set of windows was opened at the same time, each is assigned an index, so they can be arranged slightly offset from each another.
  var openedWindowsSetIndex: Int = 0

  var isSaveEnabled: Bool { isInteractivePlayer && UIState.shared.isSaveEnabled }

  /// Time of the last player state save when called by `updatePlaybackTimeInfo`.
  private var lastStateSaveTime = Date().timeIntervalSince1970

  @MainActor
  var undoHelper: PlayerWindowUndoHelper { pwc.undoHelper }

  private var subFileMonitor: FileMonitor? = nil

  // - Concurrency

  /// This ticket will be increased each time before a new task being submitted to `backgroundQueue`.
  ///
  /// Each task holds a copy of ticket value at creation, so that a previous task will perceive & quit early if new tasks are awaiting.
  ///
  /// **See also**: `autoLoadFilesInCurrentFolder(ticket:)`
  @Atomic var backgroundQueueTicket = 0
  @Atomic var thumbnailQueueTicket = 0

  let saveUIStateDebouncer = Debouncer(delay: Constants.TimeInterval.playerStateSaveDelay, queue: PlayerSaveState.saveQueue)
  let sliderSeekDebouncer = Debouncer(delay: Constants.TimeInterval.sliderSeekThrottlingInterval)
  let thumbReloadDebouncer = Debouncer(delay: Constants.TimeInterval.thumbnailRegenerationDelay, queue: ThumbnailCache.shared.thumbnailQueue)

  // - Plugins

  var isManagedByPlugin = false
  var userLabel: String?
  var disableUI = false
  var disableWindowAnimation = false

  var plugins: [JavascriptPluginInstance] = []
  private var pluginMap: [String: JavascriptPluginInstance] = [:]
  var events = EventController()

  // - Touch Bar

  var touchBarSupport: TouchBarSupport!

  /// `true` if this Mac is _known to_ have a  [Touch Bar](https://support.apple.com/guide/mac-help/use-the-touch-bar-mchlbfd5b039/mac).
  ///
  /// In order to adhere to energy efficiency best practices IINA should stop the timer that synchronizes the UI when it is not needed.
  /// As one job of the timer is to update the Touch Bar on Macs that have one, IINA needs information such as:
  /// - Does this host have a Touch Bar?
  /// - Is the Touch Bar configured to show app controls?
  /// - Is the Touch Bar awake?
  /// - Is the host being operated in closed clamshell mode?
  ///
  /// This is the kind of information needed to avoid running the timer and updating controls that are not visible. Unfortunately in the
  /// documentation for [NSTouchBar](https://developer.apple.com/documentation/appkit/nstouchbar) Apple
  /// indicates "There’s no need, and no API, for your app to know whether or not there’s a Touch Bar available". So this property is
  /// set based off whether `AppKit` has requested that a `NSTouchBar` object be created by calling
  /// [MakeTouchBar](https://developer.apple.com/documentation/appkit/nsresponder/2544690-maketouchbar).
  /// This property is used to avoid running the timer on Macs that do not have a Touch Bar. It also may avoid running the timer when a
  /// MacBook with a Touch Bar is being operated in closed clamshell mode as `AppKit` will not call `MakeTouchBar` when the
  /// Touch Bar is asleep.
  var needsTouchBar = false

  // Window & views

  var pwc: PlayerWindowController!
  @MainActor
  var window: PlayerWindow { pwc.window as! PlayerWindow }

  var mpv: MPVController!
  var videoView: VideoView!

  var keyBindingContext: PlayerInputContext!

  var syncUITimer: Timer?

  // - Playlist

  var displayedPlaylist: [PlaybackID] {
    get { pwc.playlistView.displayedPlaylist }
    set { pwc.playlistView.displayedPlaylist = newValue }
  }

  let playlistTableSelectNextRowAfterDelete = false
  let playlistTableChangeNotificationName: NSNotification.Name

  var playlistShown: Bool {
    isInMiniPlayer ? pwc.miniPlayer.playlistShown : pwc.isOpen(sidebarTab: .playlist)
  }

  // - Player lifecycle state

  var state: LifecycleState = .notYetStarted {
    didSet {
      log.verbose("Δ lifecycleState ≔ \(state)")
      if state == .idle {
        SleepPreventer.updateSleepPrevention()
      }
    }
  }


  var isActive: Bool { state.isAtLeast(.started) && state.isNotYet(.stopping) }
  var isShuttingDown: Bool { state.isAtLeast(.shuttingDown) }
  var isShutDown: Bool { state.isAtLeast(.shutDown) }
  var isStopping: Bool { state.isAtLeast(.stopping) }
  /// An unused player is one which does not have a playback (`!hasPlayback`)
  var isIdleOrUnused: Bool { state == .idle || (state == .notYetStarted && !hasPlayback) }

  // - Window controller convenience

  var isRestoring: Bool { pwc.sessionState.isRestoring }
  var isFullScreen: Bool { pwc.isFullScreen }
  var isInInteractiveMode: Bool { pwc.isInInteractiveMode }

  /// Exists to avoid refactoring legacy code
  var videoGeo: VideoGeometry { pwc.geo.video }

  // - Music mode

  /// For explicit request via command line
  var startInMusicModeRequested = false

  var isInMiniPlayer: Bool { pwc.isInMiniPlayer }

  fileprivate var pendingActionOnVidChange: PendingActionOnVidChange = .none
  fileprivate var isShowViewportPendingInMiniPlayer: Bool {
    pendingActionOnVidChange != .none
  }
  /// Calls `self.miniPlayerShowViewportTimerAction`
  let miniPlayerShowVideoTimer = TimeoutTimer(timeout: Constants.TimeInterval.musicModeChangeTrackTimeout)

  enum PendingActionOnVidChange {
    case none
    case showViewportInMusicMode
    case exitMusicMode
  }

  // Other state

  var info: PlaybackInfo

  var isUsingMpvOSD = false {
    didSet { log.verbose("Δ isUsingMpvOSD ≔ \(isUsingMpvOSD.yn)") }
  }

  var errorWhileLoading: String? = nil

  /// Set this to `true` if user changes "music mode" status manually. This disables `autoSwitchToMusicMode`
  /// functionality for the duration of this player even if the preference is `true`. But if they manually change the
  /// "music mode" status again, change this to `false` so that the preference is honored again.
  var overrideAutoMusicMode = false

  /// Need this when reusing the window, so that we know that if in full screen, it was set by a previous window session,
  /// and not by a user cmd (although that would be a better way to detect it - should investigate tracking mpv args)
  var didEnterFullScreenViaUserToggle = false

  var isSearchingOnlineSubtitle = false

  /// For supporting mpv `--shuffle` arg, to shuffle playlist when launching from command line
  @Atomic private var shufflePending = false

  // test seeking
  var triedUsingExactSeekForCurrentFile: Bool = false
  var useExactSeekForCurrentFile: Bool = true

  var hasPlayback: Bool { info.currentPlayback != nil }

  var canSkipBackward: Bool {
    isActive && (info.isPlaying || (info.playbackPositionSec ?? 0.0) > 0.0)
  }

  var canSkipForward: Bool {
    guard isActive else { return false }
    guard let pos = info.playbackPositionSec, let dur = info.playbackDurationSec else { return true }
    return !info.isPaused || pos < dur
  }

  var canPlayPrevTrack: Bool {
    guard isActive, let currentPlayback = info.currentPlayback else { return false }
    return currentPlayback.playlistPos > 1
  }

  var canPlayNextTrack: Bool {
    guard isActive, let currentPlayback = info.currentPlayback, currentPlayback.state.isAtLeast(.loaded) else { return false }
    let playlistCount = info.playlist.count
    return currentPlayback.playlistPos < playlistCount - 1
  }

  /// The A loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopA: Double {
    /// Returns the value of the A loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    /// - Returns:value of the mpv option `ab-loop-a`
    get {
      mpv.getDouble(MPVOption.PlaybackControl.abLoopA)
    }
    /// Sets the value of the A loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the A loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The A loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    set {
      guard info.abLoopStatus == .aSet || info.abLoopStatus == .bSet else { return }
      guard !isStopping else { return }
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, max(Constants.TimeInterval.minLoopPointTime, newValue))
    }
  }

  /// The B loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopB: Double {
    /// Returns the value of the B loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    /// - Returns:value of the mpv option `ab-loop-b`
    get {
      mpv.getDouble(MPVOption.PlaybackControl.abLoopB)
    }
    /// Sets the value of the B loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the B loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The B loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    set {
      guard info.abLoopStatus == .bSet else { return }
      guard !isStopping else { return }
      mpv.setDouble(MPVOption.PlaybackControl.abLoopB, max(Constants.TimeInterval.minLoopPointTime, newValue))
    }
  }

  var isABLoopActive: Bool {
    abLoopA != 0 && abLoopB != 0 && mpv.getString(MPVOption.PlaybackControl.abLoopCount) != "0"
  }

  @MainActor
  private init(_ label: String, isDemoPlayer: Bool = false) {
    let log = Logger.subsystem(forPlayerID: label)
    log.debug("PlayerCore init: starting")
    self.label = label
    self.log = log
    self.info = PlaybackInfo(log: log)
    self.isDemoPlayer = isDemoPlayer
    self.playlistTableChangeNotificationName = .init("uiChangeForPlaylistTable-\(label)")
    self.userOptions = []
    super.init()
    self.videoView = VideoView(player: self)
    self.mpv = MPVController(playerCore: self)
    self.keyBindingContext = PlayerInputContext(playerCore: self)
    self.touchBarSupport = TouchBarSupport(playerCore: self)

    miniPlayerShowVideoTimer.action = miniPlayerShowViewportTimerAction
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModeFnModes)
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModeGlobal)
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModePerApp)
  }

  @MainActor
  convenience init(_ label: String, userOptions: [MPVOptPair]) {
    self.init(label, isDemoPlayer: false)
    self.userOptions = userOptions
    pwc = PlayerWindowController(playerCore: self)
    log.verbose("PlayerCore init (new): done")
  }

  @MainActor
  convenience init(_ label: String, restoringFrom priorState: PlayerSaveState) {
    self.init(label, isDemoPlayer: false)
    self.userOptions = priorState.mpvUserOpts()

    pwc = PlayerWindowController(playerCore: self, geoSet: priorState.geoSet, initialLayout: priorState.layoutState)
    assert(pwc.sessionState.isNone, "Invalid sessionState for restore: \(pwc.sessionState)")
    pwc.sessionState = .restoring(playerState: priorState)
    log.verbose("PlayerCore init (restore): done")
  }

  /// Demo player has `pwc == nil`.
  @MainActor
  static func buildDemoPlayer() -> PlayerCore {
    let player = PlayerCore(Constants.String.demoPlayerLabel, isDemoPlayer: true)
    player.log.verbose("PlayerCore init (demo): done")
    return player
  }

  /// If the user has enabled Advanced Settings and has added entries to the "Addtional mpv options" table,
  /// this returns them in a list.
  static func getMpvAdditionalOptionsFromPrefs(_ log: any Logger.Subsystem) -> [MPVOptPair] {
    guard Preference.bool(for: .enableAdvancedSettings) else {
      log.verbose("Using empty user options ∵ enableAdvancedSettings pref is disabled")
      return []
    }

    guard let opts = MPVOptPair.readFromPrefs() else {
      // `Utility.showAlert` will deadlock if not called async because we are already running on the main thread
      DispatchQueue.main.async {
        Utility.showAlert("extra_option.cannot_read")
      }
      log.error("Using empty user options ∵ failed to deserialize userOptions pref entry")
      return []
    }
    return opts
  }

  /// Search mpv user options list for `pause` command; return last (i.e. the active) value. Useful when opening window and/or file.
  func getPauseFromUserOptions() -> Bool? {
    for opt in userOptions.reversed() {
      if opt.key == MPVOption.PlaybackControl.pause {
        // User option or cmd line option, if provided, takes priority over pauseOnOpen pref
        let shouldPause = opt.val.isEmpty || opt.val == Constants.String.mpvYes
        log.debug("Found in user options: pause=\(shouldPause.yesno)")
        return shouldPause
      }
    }
    return nil
  }

  /// Searches the list of user configured `mpv` options and returns `true` if the given option is present.
  /// - Parameter option: Option to look for.
  /// - Returns: `true` if the `mpv` option is found, `false` otherwise.
  func isPresentInUserOptions(_ optionName: String) -> Bool {
    let userOptions = userOptions
    for op in userOptions {
      if op.optionName == optionName {
        return true
      }
    }
    return false
  }

  private func resetOptionsForNewSession(reuseExistingWindow: Bool) {
    // Need to remove these: `mpvSetInitialOptions` will add new ones
    mpv.removeOptionObservers()

    log.verbose("Resetting user options to defaults: reusingWnd=\(reuseExistingWindow.yn)")

    // First reset any previously set options to their default values
    for option in userOptions {
      mpv.resetToDefault(option.optionName)
    }

    // Reset window vars to their defaults too:
    pwc.isLiveResizingWidth = nil
    pwc.isMagnifying = false
    pwc.isZoomedViaGesture = false
    pwc.isWindowHidden = false
    pwc.isWindowMiniturized = false
    pwc.isWindowMiniaturizedDueToPip = false
    pwc.isWindowPipDueToInactiveSpace = false
    pwc.isDragging = false
    pwc.currentDragObject = nil
    pwc.isPausedDueToInactive = false
    pwc.isPausedDueToMiniaturization = false
    pwc.isPausedPriorToInteractiveMode = false

    log.verbose("Resetting mpv options to defaults")

    if !reuseExistingWindow {
      pwc.isOnTop = false
      mpv.setFlag(MPVOption.Window.ontop, false)
    }
    info.vid = nil
    info.vidDisabled = nil
    mpv.setString(MPVOption.TrackSelection.vid, "auto")
    info.aid = nil
    mpv.setString(MPVOption.TrackSelection.aid, "auto")
    info.sid = nil
    mpv.setString(MPVOption.TrackSelection.sid, "auto")
    info.secondSid = nil
    mpv.setString(MPVOption.Subtitles.secondarySid, "auto")
    // `hwdec` is handled in `mpvSetInitialOptions`
    mpv.resetToDefault(MPVOption.Video.deinterlace)
    info.deinterlace = mpv.getFlag(MPVOption.Video.deinterlace)

    mpv.resetToDefault(MPVOption.Video.videoZoom)

    mpv.resetToDefault(MPVOption.Equalizer.brightness)
    info.brightness = mpv.getInt(MPVOption.Equalizer.brightness)
    mpv.resetToDefault(MPVOption.Equalizer.contrast)
    info.contrast = mpv.getInt(MPVOption.Equalizer.contrast)
    mpv.resetToDefault(MPVOption.Equalizer.saturation)
    info.saturation = mpv.getInt(MPVOption.Equalizer.saturation)
    mpv.resetToDefault(MPVOption.Equalizer.gamma)
    info.gamma = mpv.getInt(MPVOption.Equalizer.gamma)
    mpv.resetToDefault(MPVOption.Equalizer.hue)
    info.hue = mpv.getInt(MPVOption.Equalizer.hue)

    mpv.resetToDefault(MPVOption.Video.videoAspectOverride)
    mpv.resetToDefault(MPVOption.Video.videoRotate)

    info.isSubVisible = true
    mpv.resetToDefault(MPVOption.Subtitles.subVisibility)
    info.isSecondSubVisible = true
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubVisibility)
    info.subDelay = 0
    mpv.resetToDefault(MPVOption.Subtitles.subDelay)
    info.sub2Delay = 0
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubDelay)
    info.subPos = 0
    mpv.resetToDefault(MPVOption.Subtitles.subPos)
    info.sub2Pos = 0
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubPos)
    info.subScale = 0
    mpv.resetToDefault(MPVOption.Subtitles.subScale)

    // PlaybackInfo cached values for these will be read in at window open:
    mpv.resetToDefault(MPVOption.PlaybackControl.loopPlaylist)
    mpv.resetToDefault(MPVOption.PlaybackControl.loopFile)

    info.playSpeed = 1.0
    mpv.resetToDefault(MPVOption.PlaybackControl.speed)

    mpv.resetToDefault(MPVOption.Audio.volume)
    info.volume = mpv.getDouble(MPVOption.Audio.volume)
    // `info.maxVolume` will be reset in `mpvSetInitialOptions`
    mpv.resetToDefault(MPVOption.Audio.mute)
    info.isMuted = mpv.getFlag(MPVOption.Audio.mute)
    mpv.resetToDefault(MPVOption.Audio.audioDelay)
    info.audioDelay = mpv.getDouble(MPVOption.Audio.audioDelay)
    mpv.resetToDefault(MPVOption.PlaybackControl.abLoopA)
    info.abLoopA = mpv.getDouble(MPVOption.PlaybackControl.abLoopA)
    mpv.resetToDefault(MPVOption.PlaybackControl.abLoopB)
    info.abLoopB = mpv.getDouble(MPVOption.PlaybackControl.abLoopB)

    info.videoFiltersDisabled = [:]
    removeAllVideoFilters(notify: false)
    removeAllAudioFilters(notify: false)

    // Now load in the most recent options from Prefs > Advanced, if any, and set remaining options
    // as we would during the initial window load:
    userOptions = PlayerCore.getMpvAdditionalOptionsFromPrefs(log)
    log.verbose("Found \(userOptions.count) additional mpv options to set")
    
    mpv.mpvSetOptionsFromPrefs()
    mpv.mpvSetOptions(from: userOptions)
  }

  // MARK: - Opening Media

  /**
   Open a list of urls. If there are more than one urls, add the remaining ones to
   playlist and disable auto loading.

   - Returns: `nil` if no further action is needed, like opened a BD Folder; otherwise the count of playable files.
     `0` if no playable files were found & the player window was not opened.
   */
  @MainActor
  @discardableResult
  func openURLs(_ urls: [URL]) -> Int {
    guard !urls.isEmpty else { return 0 }
    log.debug("OpenURLs: \(urls.map{PlaybackID.path(from: $0).pii})")
    // Reset:
    openedWindowsSetIndex = 0

    PlayerCore.mouseLocationAtLastOpen = NSEvent.mouseLocation

    let urls = Utility.resolveURLs(urls)

    // Handle folder URL (to support mpv shuffle, etc), BD folders and m3u / m3u8 files first.
    // For these cases, mpv will load/build the playlist and notify IINA when it can be retrieved.
    if urls.count == 1,
       isBDFolder(urls[0])
        || Utility.playlistFileExt.contains(urls[0].absoluteString.lowercasedPathExtension) {

      info.shouldAutoLoadFiles = false
      openPlayerWindow(urls)
      return 1
    }
    // Else open multiple URL args...

    // Filter URL args for playable files (video/audio), because mpv will "play" image files, text files (anything?)
    let playableFiles = getPlayableFiles(in: urls, organizeList: true)

    log.verbose("Found \(playableFiles.count) playable files for \(urls.count) requested URLs")
    // check playable files count
    guard playableFiles.count > 0 else {
      return 0
    }

    // If pwc is nil, it is not restoring
    info.shouldAutoLoadFiles = AppDelegate.shared.isInteractiveLaunch && (pwc == nil || !pwc.sessionState.isRestoring) && playableFiles.count == 1

    // open the first file
    openPlayerWindow(playableFiles)
    return playableFiles.count
  }

  @MainActor
  @discardableResult
  func openURL(_ url: URL) -> Int? {
    return openURLs([url])
  }

  /// Returns number of playable URLs opened. If `0`, no player window was opened.
  @MainActor
  @discardableResult
  func openURLString(_ str: String) -> Int? {
    if str == "-" {
      info.shouldAutoLoadFiles = false  // reset
      openPlayerWindow([URL(string: "stdin")!])
      return 1
    }
    if str.first == "/" {
      return openURL(URL(fileURLWithPath: str))
    } else {
      // For apps built with Xcode 15 or later the behavior of the URL initializer has changed when
      // running under macOS Sonoma or later. The behavior now matches URLComponents and will
      // automatically percent encode characters. Must not apply percent encoding to the string
      // passed to the URL initializer if the new new behavior is active.
      var performPercentEncoding = true
#if compiler(>=5.9)
      if #available(macOS 14, *) {
        performPercentEncoding = false
      }
#endif
      var pstr = str
      if performPercentEncoding {
        guard let encoded = str.addingPercentEncoding(withAllowedCharacters: .urlAllowed) else {
          log.error("Cannot add percent encoding for \(str)")
          return 0
        }
        pstr = encoded
      }
      guard let url = URL(string: pstr) else {
        log.error("Cannot parse url for \(pstr)")
        return 0
      }
      return openURL(url)
    }
  }

  /// Loads the first URL into the player, and adds any remaining URLs to playlist.
  /// The caller must ensure that `urls` is *never* empty!
  @MainActor
  private func openPlayerWindow(_ urls: [URL]) {
    guard !isDemoPlayer else { log.fatalError("Cannot open player window for demo player!") }
    guard urls.count > 0 else { log.fatalError("Cannot open player window: empty url list!") }

    guard state.isAtLeast(.started) else {
      log.error("Cannot open player window: player not started! Ignoring request")
      return
    }
    guard !isShuttingDown else {
      // Prevent possible (though very unlikely) deadlock if called while shutting down
      log.debug("Aborting open player window: already shutting down")
      return
    }

    let isInteractivePlayer = self.isInteractivePlayer
    let playback = Playback(url: urls[0], playlistPos: 0)

    if playback.isNetworkResource, isInteractivePlayer {
      AppDelegate.shared.openURLWindow.showLoadingScreen(playerCore: self)
    }

    /// Need to use `sync` so that:
    /// 1. Prev use of mpv core can finish stopping / drain queue
    /// 2. `currentPlayback` is guaranteed to update before returning, so that `PlayerCore.activeOrNew` does not return same player
    mpv.queue.sync { [self] in
      let path = playback.path
      info.currentPlayback = playback
      log.debug("Opening player (window=\(isInteractivePlayer.yesno)) for \(path.pii.quoted), playerState=\(state), sessionState=\(pwc.sessionState)")

      if state == .stopping || state == .idle {
        // Player was previously started, but closed & is now being reopened
        state = .started
      }

      switch pwc.sessionState {
      case .restoring, .creatingCLI:
        break
      default:
        resetOptionsForNewSession(reuseExistingWindow: pwc.sessionState.hasOpenSession)
      }

      info.hdrEnabled = Preference.bool(for: .enableHdrSupport)

      DispatchQueue.main.async { [self] in
        if !pwc.sessionState.isRestoring {
          if isInteractivePlayer {
            pwc.osd.clearQueuedOSDs()
          }
          pwc.sessionState = pwc.sessionState.newSession()
        }
        let sessionState = pwc.sessionState

        if isInteractivePlayer {
          pwc.openWindow(nil)
        }

        mpv.queue.async { [self] in
          guard !isStopping else { return }

          // If this mpv core is being reused icc-profile-auto may have been left set to true. This option
          // MUST be reset to false to avoid a crash that occurs if the mpv OSD is being used. Another way
          // to fix this would be to add this option to the mpv reset-on-next-file option. However the
          // user might override IINA and set that option themselves and not include icc-profile-auto.
          // Better to directly reset icc-profile-auto. See issue #5727 for details.
          mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)

          // Send load file command
          mpv.command(.loadfile, args: [path])

          if case .restoring(let priorState) = sessionState {
            priorState.restoreMpvProperties(to: self)

            /// Player was already paused in `PlayerSaveState.restoreTo()`.
            if Preference.bool(for: .alwaysPauseMediaWhenRestoringAtLaunch) {
              pendingResumeWhenShowingWindow = false
            } else if let wasPaused = priorState.bool(for: .paused) {
              pendingResumeWhenShowingWindow = !wasPaused
            } else {
              pendingResumeWhenShowingWindow = !Preference.bool(for: .pauseWhenOpen)
            }

            return

          } else if isInteractivePlayer {
            log.debug("Pausing playback until window is done opening")
            // Pause until window opens, to avoid blips or other loading unpleasantness.
            mpv.setFlag(MPVOption.PlaybackControl.pause, true)

            let shouldStayPaused = getPauseFromUserOptions() ?? Preference.bool(for: .pauseWhenOpen)
            log.debug("Setting pendingResumeWhenShowingWindow = \(pendingResumeWhenShowingWindow.yn)")
            pendingResumeWhenShowingWindow = !shouldStayPaused

          } else {
            log.verbose("Player is non-interactive; skipping playback pause prior to window open")
            pendingResumeWhenShowingWindow = false
          }

          // Not restoring

          if urls.count > 1 {
            log.verbose("Adding \(urls.count - 1) files to playlist. Autoload=\(info.shouldAutoLoadFiles.yn)")
            let urls = urls.map({PlaybackID.path(from: $0)})
            _addAllToPlaylist(pathListIncludingCurrent: urls, indexOfCurrentItem: 0)
          } else {
            // Only one entry in playlist, but still need to pull it from mpv
            _reloadPlaylist()
          }

          // TODO: move this stuff into mpv init

          if Preference.bool(for: .enablePlaylistLoop) {
            mpv.setString(MPVOption.PlaybackControl.loopPlaylist, "inf")
          }
          if Preference.bool(for: .enableFileLoop) {
            mpv.setString(MPVOption.PlaybackControl.loopFile, "inf")
          }

          if Preference.bool(for: .autoRepeat) {
            let loopMode = Preference.DefaultRepeatMode(rawValue: Preference.integer(for: .defaultRepeatMode))
            setLoopMode(loopMode == .file ? .file : .playlist)
          }

          if let loopFile = mpv.getString(MPVOption.PlaybackControl.loopFile) {
            info.loopFile = loopFile
          }
          if let loopPlaylist = mpv.getString(MPVOption.PlaybackControl.loopPlaylist) {
            info.loopPlaylist = loopPlaylist
          }
        }
      }
    }
  }

  // MARK: - Startup / Shutdown

  /// Starts mpv & create the `PlayerWindowController` (`pwc`) if it wasn't created already.
  /// This will apply all the mpv user options as well.
  /// Does nothing if already started.
  @MainActor
  func startPlayer() {
    guard state == .notYetStarted else { return }
    let isInteractivePlayer = !isDemoPlayer && AppDelegate.shared.isInteractiveLaunch
    self.isInteractivePlayer = isInteractivePlayer
    log.verbose("Player start: interactive=\(isInteractivePlayer.yn)")

    if isInteractivePlayer, let pwc {
      // `windowDidLoad` is a legacy method, a leftover from when XIB was used.
      // Need to call this explicitly now. Maybe we can refactor at some point.
      // For non-interactive players, we still have too many dependencies on PlayerWindowController to avoid the need to
      // instantiate it, but we can at least leave it "unloaded" and not suffer too much waste because much of the code
      // already checks whether `!pwc.loaded` and gracefully handles it.
      pwc.finishLoading()
    }
    
#if USE_GPU_NEXT
    if isInteractivePlayer {
      videoView.initVideoLayer()
    }
    startMPV()
#else
    startMPV()
    if isInteractivePlayer {
      videoView.initVideoLayer()
    }
#endif

    if state == .notYetStarted {
      state = .started
    }
  }

  @MainActor
  private func startMPV() {
    // set path for youtube-dl
    let oldPath = String(cString: getenv("PATH")!)
    var path = Utility.exeDirURL.path + ":" + oldPath
    if let customYtdlPath = Preference.string(for: .ytdlSearchPath), !customYtdlPath.isEmpty {
      path = customYtdlPath + ":" + path
    }
    setenv("PATH", path, 1)
    log.debug("Set env path to \(path.pii)")

    // set http proxy
    if let proxy = Preference.string(for: .httpProxy), !proxy.isEmpty {
      setenv("http_proxy", "http://" + proxy, 1)
      log.debug("Set env http_proxy to \(proxy.pii)")
    }

    mpv.mpvInit()
    events.emit(.mpvInitialized)

    let audioDevice = Preference.string(for: .audioDevice)!
    if !getAudioDevices().contains(where: { $0.name == audioDevice }) {
      log.debug("Audio device configured in settings not found, will default to auto:\n  \(audioDevice)")
      setAudioDevice("auto")
    }
  }

  /// Initiate shutdown of this player.
  ///
  /// This method is intended to only be used during application termination. Once shutdown has been initiated player methods
  /// **must not** be called.
  /// - Important: As a part of shutting down the player this method sends a quit command to mpv. Even though the command is
  ///     sent to mpv using the synchronous API mpv executes the quit command asynchronously. The player is not fully shutdown
  ///     until mpv finishes executing the quit command and shuts down.
  /// - Note: If the user clicks on `Quit` right after starting to play a video then the background task may still be running and
  ///     loading files into the playlist and adding subtitles. If that is the case then the background task **must be** stopped before
  ///     sending a `quit` command to mpv. If the background task is allowed to access mpv after a `quit` command has been
  ///     sent mpv could crash. The `stop` method takes care of instructing the background task to stop and will wait for it to stop
  ///     before sending a `stop` command to mpv. _However_ mpv will stop on its own if the end of the video is reached. When
  ///     that happens while IINA is quitting then this method may be called with the background task still running. If the background
  ///     task is still running this method only changes the player state. When the background task ends it will notice that shutting
  ///     down was in progress and will call this method again to continue the process of shutting down..
  @MainActor
  func shutdown() {
    guard state.isNotYet(.shuttingDown) else {
      log.verbose("Player is already shutting down")
      return
    }
    guard state.isAtLeast(.started) else {
      log.debug("Player was never started")
      mpvHasShutdown()
      return
    }
    log.debug("Shutting down player")
    state = .shuttingDown
    if !isDemoPlayer {
      savePlaybackMetaBeforePlayerWillStop() // Save state to mpv watch-later (if enabled)
      refreshSyncUITimer()   // Shut down timer
    }
    mpv.mpvQuit()
  }

  /// Respond to the mpv core shutting down.
  /// - Important: Normally shutdown of the mpv core occurs after IINA has sent a `quit` command to the mpv core and that
  ///     asynchronous command completes. _However_ this can also occur when the user uses mpv's IPC interface to send a quit
  ///     command directly to mpv. Accessing a mpv core after it has shutdown is not permitted by mpv and can trigger a crash.
  ///     When IINA is in control of the termination sequence it is able to prevent access to the mpv core. For example, observers are
  ///     removed before sending the `quit` command. But when shutdown is initiated by mpv the actions IINA takes before
  ///     shutting down mpv are bypassed. This means a mpv initiated shutdown can't be made fully deterministic as there are inherit
  ///     windows of vulnerability that can not be fully closed. IINA has no choice but to support a mpv initiated shutdown as best it
  ///     can.
  @MainActor
  func mpvHasShutdown() {
    let isMPVInitiated = state.isAtLeast(.started) && state.isNotYet(.shuttingDown)
    let suffix = isMPVInitiated ? " (initiated by mpv)" : ""
    log.debug("Player has shut down\(suffix)")
    // If mpv shutdown was initiated by mpv then the player state has not been saved.
    if isMPVInitiated {
      state = .shuttingDown  // Make sure to indicate shutdown before calling `refreshSyncUITimer`
      if !isDemoPlayer {
        savePlaybackMetaBeforePlayerWillStop() // Save state to mpv watch-later (if enabled)
        refreshSyncUITimer()   // Shut down timer
      }
      mpv.removeObservers()
    }
    videoView.uninit()       // Shut down DisplayLink. Has its own lock.

    mpv.queue.sync { [self] in  // run in queue to avoid race condition when handling events in queue, which checks mpv!=nil
      mpv.mpvDestroy()
    }
    state = .shutDown
    PlayerManager.shared.removePlayer(withLabel: label)
    postNotification(.iinaPlayerShutdown)
    if isMPVInitiated {
      // Initiate application termination. AppKit requires this be done from the main thread,
      // however the main dispatch queue must not be used to avoid blocking the queue as per
      // instructions from Apple.
      Task { @MainActor in
        NSApp.terminate(nil)
      }
    }
  }

  func enterMusicMode(automatically: Bool = false, withNewVidGeo newVidGeo: VideoGeometry? =  nil) {
    log.debug("Switch to music mode, automatically=\(automatically.yesno)")
    pwc.enterMusicMode(automatically: automatically)
  }

  func exitMusicMode(automatically: Bool = false, withNewVidGeo newVidGeo: VideoGeometry? =  nil) {
    log.debug("Switch to normal window from music mode, automatically=\(automatically.yesno)")
    pwc.exitMusicMode(automatically: automatically)
  }

  // MARK: - Plugins

  @MainActor
  static func reloadPluginForAll(_ plugin: JavascriptPlugin, forced: Bool = false) {
    PlayerManager.shared.playerCores.forEach { $0.reloadPlugin(plugin, forced: forced) }
    AppDelegate.shared.menuController?.updatePluginMenu()
  }

  func clearPlugins() {
    log.verbose("Clearing plugins")
    pluginMap.removeAll()
    plugins.removeAll()

    pwc.pluginView.updatePluginTabs()
  }

  @MainActor
  func loadPlugins() {
    guard AppDelegate.iinaPluginSystemEnabled else {
      log.verbose("Plugin system disabled; skipping load of plugins")
      return
    }
    log.verbose("Loading plugins")
    pluginMap.removeAll()
    plugins = JavascriptPlugin.plugins.compactMap { plugin in
      guard plugin.enabled else { return nil }
      let instance = JavascriptPluginInstance(player: self, plugin: plugin)
      pluginMap[plugin.identifier] = instance
      return instance
    }

    pwc.pluginView.updatePluginTabs()
  }

  @MainActor
  func reloadPlugin(_ plugin: JavascriptPlugin, forced: Bool = false) {
    guard AppDelegate.iinaPluginSystemEnabled else { return }

    let id = plugin.identifier
    log.verbose("Reloading plugin: \(id.quoted)")
    if let _ = pluginMap[id] {
      if plugin.enabled {
        // no need to reload, unless forced
        guard forced else { return }
        pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
      } else {
        pluginMap.removeValue(forKey: id)
      }
    } else {
      guard plugin.enabled else { return }
      pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
    }

    plugins = JavascriptPlugin.plugins.compactMap { pluginMap[$0.identifier] }
    pwc.pluginView.updatePluginTabs()
  }

  // MARK: - MPV commands

  /// __CAUTION:__ this call can cause a momentary hiccup while animating, so we don't want to run it `async` in mpv queue.
  /// This should be run by using `mpv.queue.sync()` (and very carefully).
  func setMpvKeepaspectWindow(to enable: Bool) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    guard DebugConfig.useMpvKeepaspectWindow else { return }
    guard info.mpvKeepaspectWindow != enable else { return }
    mpv.setFlag(MPVOption.Window.keepaspectWindow, enable, level: .verbose)
  }

  /// __CAUTION:__ this call uses `sync` to mpv queue.
  @MainActor
  func updateMpvKeepaspectWindowSynchronously() {
    guard DebugConfig.useMpvKeepaspectWindow else { return }
    log.verbose("Updating mpv keepaspect-window synchronously")
    mpv.queue.sync {
      setMpvKeepaspectWindow(to: pwc.currentLayout.mode.needsMpvKeepaspectWindow)
    }
    log.verbose("Updating mpv keepaspect-window synchronously: done")
  }

  func updateMpvKeepaspectWindowAsync() {
    guard DebugConfig.useMpvKeepaspectWindow else { return }
    log.verbose("Updating mpv keepaspect-window async")
    mpv.queue.async { [self] in
      setMpvKeepaspectWindow(to: pwc.currentLayout.mode.needsMpvKeepaspectWindow)
    }
    log.verbose("Updating mpv keepaspect-window synchronously: done")
  }

  func togglePause() {
    mpv.queue.async { [self] in
      _togglePause()
    }
  }

  func _togglePause() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    info.isPaused ? _resume() : _pause()
  }

  /// Pause playback.
  ///
  /// - Important: Setting the `pause` property will cause `mpv` to emit a `MPV_EVENT_PROPERTY_CHANGE` event. The
  ///     event will still be emitted even if the `mpv` core is idle. If the setting `Pause when machine goes to sleep` is
  ///     enabled then `PlayerWindowController` will call this method in response to a
  ///     `NSWorkspace.willSleepNotification`. That happens even if the window is closed and the player is idle. In
  ///     response the event handler in `MPVController` will call `VideoView.displayIdle`. The suspicion is that calling this
  ///     method results in a call to `CVDisplayLinkCreateWithActiveCGDisplays` which fails because the display is
  ///     asleep. Thus `setFlag` **must not** be called if the `mpv` core is idle or stopping. See issue
  ///     [#4520](https://github.com/iina/iina/issues/4520)
  func pause() {
    mpv.queue.async { [self] in
      _pause()
    }
  }

  func _pause() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    /// Set this so that callbacks will fire even though `info.isPaused` was already set
    info.isPausedLocally = true
    mpv.setFlag(MPVOption.PlaybackControl.pause, true)
    let isNormalSpeed = info.playSpeed == 1
    if !isNormalSpeed && Preference.bool(for: .resetSpeedWhenPaused) {
      _setSpeed(1.0, forceResume: false)
    }

    DispatchQueue.main.async { [self] in
      pwc.updatePlayButtonAndSpeedUI()
    }
  }

  func _resume() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    /// Set this so that callbacks will fire even though `info.isPaused` was already set
    info.isPausedLocally = false
    if shouldRestartFromEOF() {
      _seek(0, absolute: true, option: .exact)
    }
    mpv.setFlag(MPVOption.PlaybackControl.pause, false)
    DispatchQueue.main.async { [self] in
      pwc.updatePlayButtonAndSpeedUI()
    }
  }

  /// Restart playback if at EOF & feature is enabled.
  /// If auto-play next track in playlist is enabled, must be last track to restart.
  private func shouldRestartFromEOF() -> Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    guard mpv.getFlag(MPVProperty.eofReached) && Preference.bool(for: .resumeFromEndRestartsPlayback) else {
      return false
    }
    if Preference.bool(for: .playlistAutoPlayNext) {
      let playlistPos = mpv.getInt(MPVProperty.playlistPos)
      let playlistCount = mpv.getInt(MPVProperty.playlistCount)
      return playlistPos == playlistCount - 1
    }
    return true
  }

  /// Same idea as `shouldRestartFromEOF()` but uses cached values so it can be called from main queue
  func shouldShowRestartFromEOFIcon() -> Bool {
    assert(DispatchQueue.isExecutingIn(.main))

    guard Preference.bool(for: .resumeFromEndRestartsPlayback) && info.isAtEOF else {
      return false
    }

    if Preference.bool(for: .playlistAutoPlayNext) {
      if let currentPlayback = info.currentPlayback, currentPlayback.playlistPos == info.playlist.count - 1 {
        return true
      } else {
        return false
      }
    }
    return true
  }

  func resume() {
    mpv.queue.async { [self] in
      _resume()
    }
  }

  /// Stop playback and unload the media.
  ///
  /// This method is called when a window closes. The player may be:
  /// - In one of the "active" states
  /// - In the `idle` state
  /// - In the `shutdown` state
  func stop() {
    assert(DispatchQueue.isExecutingIn(.main))

    mpv.queue.async { [self] in
      guard state.isNotYet(.stopping) else {
        log.verbose("Ignoring redundant stop call: player state is already \(state)")
        return
      }

      log.verbose("Stop called")

      /// call this BEFORE setting state to `.stopping`
      savePlaybackMetaBeforePlayerWillStop() // Save state to mpv watch-later (if enabled)

      state = .stopping

      stopWatchingSubFile()

      thumbReloadDebouncer.invalidate()
      // If the user immediately closes the player window it is possible the background task may still
      // be working to load subtitles. Invalidate the ticket to get that task to abandon the work.
      $backgroundQueueTicket.withLock { $0 += 1 }
      $thumbnailQueueTicket.withLock { $0 += 1 }

      // Reset playback state
      info.playbackPositionSec = nil
      info.playbackDurationSec = nil
      info.playlist = []

      info.$matchedSubs.withLock { $0.removeAll() }

      // Do not enqueue after window is closed (and info.currentPlayback is nil)
      sendOSD(.stop)
      DispatchQueue.main.async { [self] in
        refreshSyncUITimer()
        videoView.stopDisplayLink()
      }

      // Do not send a stop command to mpv if it is already stopped. This happens when quitting is
      // initiated directly through mpv.
      guard state != .idle else { return }
      log.debug("Stopping playback")

      mpv.command(.stop)
    }
  }

  /// Playback has stopped and the media has been unloaded.
  ///
  /// This method is called by `MPVController` when mpv emits an event indicating the asynchronous mpv `stop` command
  /// has completed executing.
  private func playbackStopped() {
    log.debug("Playback has stopped")
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    /// Do not set player's state = `stopped` here. This method seems to get called when it shouldn't
    /// (e.g., when changing current pos in playlist)

    DispatchQueue.main.async { [self] in
      postNotification(.iinaPlayerStopped)
    }
  }

  func toggleMute(_ set: Bool? = nil) {
    log.debug("Toggling mute (set=\(set?.yn ?? "nil"))")
    mpv.queue.async { [self] in
      let newState = set ?? !mpv.getFlag(MPVOption.Audio.mute)
      mpv.setFlag(MPVOption.Audio.mute, newState)
    }
  }

  // Seek %
  func seek(percent: Double, forceExact: Bool = false) {
    mpv.queue.async { [self] in
      var percent = percent
      // mpv will play next file automatically when seek to EOF.
      // We clamp to a Range to ensure that we don't try to seek to 100%.
      // however, it still won't work for videos with large keyframe interval.
      if let duration = info.playbackDurationSec,
         duration > 0 {
        percent = percent.clamped(to: 0..<100)
      }
      let useExact = forceExact ? true : Preference.bool(for: .useExactSeek)
      let seekMode = useExact ? "absolute-percent+exact" : "absolute-percent"
      mpv.command(.seek, args: ["\(percent)", seekMode], checkError: false)
    }
  }

  // Seek Relative
  func seek(relativeSecond: Double, option: Preference.SeekOption) {
    seek(relativeSecond, absolute: false, option: option)
  }

  private func seek(_ time: Double, absolute: Bool, option: Preference.SeekOption) {
    mpv.queue.async { [self] in
      _seek(time, absolute: absolute, option: option)
    }
  }

  private func _seek(_ time: Double, absolute: Bool, option: Preference.SeekOption) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    let kind = absolute ? "absolute" : "relative"

    switch option {
    case .keyframes:
      mpv.command(.seek, args: ["\(time)", "\(kind)+keyframes"], checkError: false)

    case .exact:
      mpv.command(.seek, args: ["\(time)", "\(kind)+exact"], checkError: false)

    case .auto:
      // for each file , try use exact and record interval first
      if !triedUsingExactSeekForCurrentFile {
        mpv.recordedSeekTimeListener = { [unowned self] interval in
          // if seek time < 0.05, then can use exact
          self.useExactSeekForCurrentFile = interval < 0.05
        }
        mpv.needRecordSeekTime = true
        triedUsingExactSeekForCurrentFile = true
      }
      let seekMode = useExactSeekForCurrentFile ? "\(kind)+exact" : kind
      mpv.command(.seek, args: ["\(time)", seekMode], checkError: false)
    }
  }

  // Seek Absolute
  func seek(absoluteSecond: Double, forceExact: Bool = true) {
    let useExact = forceExact ? true : Preference.bool(for: .useExactSeek)
    seek(absoluteSecond, absolute: true, option: useExact ? .exact : .defaultValue)
  }

  func seek(absoluteSecond: Double, option: Preference.SeekOption) {
    seek(absoluteSecond, absolute: true, option: option)
  }

  func frameStep(backwards: Bool) {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // It must be running when stepping to avoid slowdowns caused by mpv waiting for IINA to call
    // mpv_render_report_swap.
    videoView.displayActive()
    mpv.queue.async { [self] in
      if backwards {
        mpv.command(.frameBackStep)
      } else {
        mpv.command(.frameStep)
      }
    }
  }

  /// Takes a screenshot, attempting to augment mpv's `screenshot` command with additional functionality & control, for example
  /// the ability to save to clipboard instead of or in addition to file, and displaying the screenshot's thumbnail via the OSD.
  /// Returns `true` if a command was sent to mpv; `false` if no command was sent.
  ///
  /// If the prefs for `Preference.Key.screenshotSaveToFile` and `Preference.Key.screenshotCopyToClipboard` are both `false`,
  /// this function does nothing and returns `false`.
  ///
  /// ## Determining screenshot flags
  /// If `keyBinding` is present, it should contain an mpv `screenshot` command. If its action includes any flags, they will be
  /// used. If `keyBinding` is not present or its command has no flags, the value for `Preference.Key.screenshotIncludeSubtitle` will
  /// be used to determine the flags:
  /// - If `true`, the command `screenshot subtitles` will be sent to mpv.
  /// - If `false`, the command `screenshot video` will be sent to mpv.
  ///
  /// Note: IINA overrides mpv's behavior in some ways:
  /// 1. As noted above, if the stored values for `Preference.Key.screenshotSaveToFile` and `Preference.Key.screenshotCopyToClipboard` are
  /// set to false, all screenshot commands will be ignored.
  /// 2. When no flags are given with `screenshot`: instead of defaulting to `subtitles` as mpv does, IINA will use the value for
  /// `Preference.Key.screenshotIncludeSubtitle` to decide between `subtitles` or `video`.
  @discardableResult
  func screenshot(fromKeyBinding keyBinding: KeyMapping? = nil) -> Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return false }

    /// `screenshot-raw`? (i.e. not `screenshot`)
    var isRaw: Bool = false
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else {
      log.debug("Ignoring screenshot request: all forms of screenshots are disabled in prefs")
      return false
    }

    guard let vid = info.vid, vid > 0 else {
      log.debug("Ignoring screenshot request: no video stream is being played")
      return false
    }

    log.debug("Screenshot requested by user\(keyBinding == nil ? "" : " (rawAction: \(keyBinding!.rawAction?.quoted ?? "nil"))")")

    var commandFlags: [String] = []

    if let keyBinding {
      var canUseIINAScreenshot = true

      guard let rawAction = keyBinding.rawAction, let action = keyBinding.action,
            let commandName = keyBinding.action?.first,
            (commandName == MPVCommand.screenshotRaw.rawValue || commandName == MPVCommand.screenshot.rawValue) else {
        log.error("Cannot take screenshot: unexpected first token in key binding action: \(keyBinding.rawAction?.quoted ?? "nil")")
        return false
      }
      isRaw = commandName == MPVCommand.screenshotRaw.rawValue
      if isRaw {
        // Cannot yet support screenshot-raw
        canUseIINAScreenshot = false
      }
      if action.count > 1 {
        commandFlags = action[1].split(separator: "+").map{String($0)}

        for flag in commandFlags {
          switch flag {
          case "window", "subtitles", "video":
            // These are supported
            break
          case "each-frame":
            // Option is not currently supported by IINA's screenshot command
            canUseIINAScreenshot = false
          default:
            // Unexpected flag. Let mpv decide how to handle
            log.warn("Taking screenshot: Unrecognized flag for mpv '\(commandName)' command: '\(flag)'")
            canUseIINAScreenshot = false
          }
        }
      }

      if !canUseIINAScreenshot {
        let returnValue = mpv.command(rawString: rawAction)
        return returnValue == 0
      }
    }

    if commandFlags.isEmpty {
      let includeSubtitles = Preference.bool(for: .screenshotIncludeSubtitle)
      commandFlags.append(includeSubtitles ? "subtitles" : "video")
    }

    if isRaw {
      mpv.asyncCommand(.screenshotRaw, args: commandFlags, replyUserdata: MPVController.UserData.screenshotRaw)
    } else {
      mpv.asyncCommand(.screenshot, args: commandFlags, replyUserdata: MPVController.UserData.screenshot)
    }
    return true
  }

  /// Initializes and returns an image object with the contents of the specified URL.
  ///
  /// At this time, the normal [NSImage](https://developer.apple.com/documentation/appkit/nsimage/1519907-init)
  /// initializer will fail to create an image object if the image file was encoded in [JPEG XL](https://jpeg.org/jpegxl/) format.
  /// In older versions of macOS this will also occur if the image file was encoded in [WebP](https://en.wikipedia.org/wiki/WebP/)
  /// format. As these are supported formats for screenshots this method will fall back to using FFmpeg to create the `NSImage` if
  /// the normal initializer fails to return an object.
  /// - Parameter url: The URL identifying the image.
  /// - Returns: An initialized `NSImage` object or `nil` if the method cannot create an image representation from the contents
  ///       of the specified URL.
  private func createImage(_ url: URL) -> NSImage? {
    if let image = NSImage(contentsOf: url) {
      return image
    }
    // The following internal property was added to provide a way to disable the FFmpeg image
    // decoder should a problem be discovered by users running old versions of macOS.
    guard Preference.bool(for: .enableFFmpegImageDecoder) else { return nil }
    log.debug("Using FFmpeg to decode screenshot: \(url)")
    return FFmpegController.createNSImage(withContentsOf: url)
  }

  func screenshotCallback() {
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else { return }
    log.verbose("Screenshot done: saveToFile=\(saveToFile), saveToClipboard=\(saveToClipboard)")

    guard let imageFolder = mpv.getString(MPVOption.Screenshot.screenshotDir) else { return }
    guard let lastScreenshotURL = Utility.getLatestScreenshot(from: imageFolder) else { return }

    defer {
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
    }

    guard let screenshotImage = createImage(lastScreenshotURL) else {
      self.sendOSD(.screenshot)
      return
    }

    if saveToClipboard {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([screenshotImage])
    }
    guard Preference.bool(for: .screenshotShowPreview) else {
      sendOSD(.screenshot)
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
      return
    }

    DispatchQueue.main.async { [self] in
      let screenshotViewController = ScreenshootOSDView()
      // Shrink to some fraction of the currently displayed video
      let relativeSize = pwc.videoView.frame.size * 0.3
      let previewImageSize = screenshotImage.size.shrink(toSize: relativeSize)
      screenshotViewController.setImage(screenshotImage,
                                        size: previewImageSize,
                                        fileURL: saveToFile ? lastScreenshotURL : nil)

      sendOSD(.screenshot, accessoryViewController: screenshotViewController)
    }
  }

  /// Invoke the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  ///
  /// The A-B loop command cycles mpv through these states:
  /// - Cleared (looping disabled)
  /// - A loop point set
  /// - B loop point set (looping enabled)
  ///
  /// When the command is first invoked it sets the A loop point to the timestamp of the current frame. When the command is invoked
  /// a second time it sets the B loop point to the timestamp of the current frame, activating looping and causing mpv to seek back to
  /// the A loop point. When the command is invoked again both loop points are cleared (set to zero) and looping stops.
  func abLoop() {
    mpv.queue.async { [self] in
      // may subject to change
      mpv.command(.abLoop)
    }
  }

  /// Synchronize IINA with the state of the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  func syncAbLoop() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }

    // Obtain the values of the ab-loop-a and ab-loop-b options representing the A & B loop points.
    let a = mpv.getDouble(MPVOption.PlaybackControl.abLoopA)
    let b = mpv.getDouble(MPVOption.PlaybackControl.abLoopB)
    let didChange = (info.abLoopA != a) || (info.abLoopB != b)
    info.abLoopA = a
    info.abLoopB = b

    if a == 0 {
      if b == 0 {
        // Neither point is set, the feature is disabled.
        info.abLoopStatus = .cleared
      } else {
        // The B loop point is set without the A loop point having been set. This is allowed by mpv
        // but IINA is not supposed to allow mpv to get into this state, so something has gone
        // wrong. This is an internal error. Log it and pretend that just the A loop point is set.
        log.error("Unexpected A-B loop state, ab-loop-a is \(a) ab-loop-b is \(b)")
        info.abLoopStatus = .aSet
      }
    } else {
      // A loop point has been set. B loop point must be set as well to activate looping.
      info.abLoopStatus = b == 0 ? .aSet : .bSet
    }

    // The play slider has knobs representing the loop points, make insure the slider is in sync.
    log.verbose("Synchronized info.abLoopStatus=\(info.abLoopStatus) (changed=\(didChange.yn))")

    if didChange {
      sendOSD(.abLoop(info.abLoopStatus))
    }

    DispatchQueue.main.async { [self] in
      log.verbose("Syncing player slider AB loop: a=\(a), b=\(b)")
      pwc.playSlider.syncABLoop(info, a: a, b: b)
    }
  }

  func togglePlaylistLoop() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let loopMode = getLoopMode()
      if loopMode == .playlist {
        setLoopMode(.off)
      } else {
        setLoopMode(.playlist)
      }
    }
  }

  func toggleFileLoop() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let loopMode = getLoopMode()
      if loopMode == .file {
        setLoopMode(.off)
      } else {
        setLoopMode(.file)
      }
    }
  }

  func getLoopMode() -> LoopMode {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    let loopFileStatus = mpv.getString(MPVOption.PlaybackControl.loopFile)
    let loopPlaylistStatus = mpv.getString(MPVOption.PlaybackControl.loopPlaylist)
    if let loopFileStatus {
      info.loopFile = loopFileStatus
    }
    if let loopPlaylistStatus {
      info.loopPlaylist = loopPlaylistStatus
    }

    guard loopFileStatus != "inf" else { return .file }
    if let loopFileStatus = loopFileStatus, let count = Int(loopFileStatus), count != 0 {
      return .file
    }
    guard loopPlaylistStatus != "inf", loopPlaylistStatus != "force" else { return .playlist }
    guard let loopPlaylistStatus = loopPlaylistStatus, let count = Int(loopPlaylistStatus) else {
      return .off
    }
    return count == 0 ? .off : .playlist
  }

  private func setLoopMode(_ newMode: LoopMode) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    switch newMode {
    case .playlist:
      mpv.setString(MPVOption.PlaybackControl.loopPlaylist, "inf")
      mpv.setString(MPVOption.PlaybackControl.loopFile, "no")
    case .file:
      mpv.setString(MPVOption.PlaybackControl.loopFile, "inf")
    case .off:
      mpv.setString(MPVOption.PlaybackControl.loopPlaylist, "no")
      mpv.setString(MPVOption.PlaybackControl.loopFile, "no")
    }
  }

  func nextLoopMode() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      setLoopMode(getLoopMode().next())
    }
  }

  func toggleShuffle() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.command(.playlistShuffle)
      _reloadPlaylist()
    }
  }

  func setVolume(_ volume: Double) {
    mpv.queue.async { [self] in
      let constrainedVolume = volume.clamped(to: 0...Preference.double(for: .maxVolume))
      info.volume = constrainedVolume
      // Always show OSD to acknowledge input, even if volume did not change:
      sendOSD(.volume(constrainedVolume))
      mpv.setDouble(MPVOption.Audio.volume, constrainedVolume)
      // Save default for future players:
      Preference.set(constrainedVolume, for: .softVolume)
    }
  }

  /// Set playback speed.
  /// If `forceResume` is `true`, then always resume if paused; if `false`, never resume if paused;
  /// if `nil`, then resume if paused based on pref setting.
  func setSpeed(_ speed: Double, forceResume: Bool? = nil) {
    let speedRounded = speed.roundedTo6()
    info.playSpeed = speedRounded  // set preemptively to keep UI in sync
    mpv.queue.async { [self] in
      _setSpeed(speedRounded, forceResume: forceResume)
    }
  }

  func _setSpeed(_ speed: Double, forceResume: Bool? = nil) {
    guard isActive else { return }
    log.verbose("Setting speed to \(speed)")
    mpv.setDouble(MPVOption.PlaybackControl.speed, speed)

    /// If `resetSpeedWhenPaused` is enabled, then speed is reset to 1x when pausing.
    /// This will create a subconscious link in the user's mind between "pause" -> "unset speed".
    /// Try to stay consistent by linking the contrapositive together: "set speed" -> "play".
    /// The intuition should be most apparent when using the speed slider in Quick Settings.
    if info.isPaused {
      if forceResume == true {
        _resume()
      } else if forceResume == nil && Preference.bool(for: .resetSpeedWhenPaused) {
        _resume()
      }
    }
  }

  /// Called with `MPVOption.PlaybackControl.pause` changed
  func pausedStateDidChange(to paused: Bool) {
    let didChange = info.isPausedRemotely != paused
    info.isPausedRemotely = paused
    info.isPausedLocally = nil
    guard didChange else { return }

    DispatchQueue.main.async { [self] in
      if !paused {
        if state == .stopping || state == .idle {
          state = .started
        }
      }
      pwc.updatePlayButtonAndSpeedUI()
      refreshSyncUITimer() // needed to get latest playback position
      if let pos = info.playbackPositionSec, let dur = info.playbackDurationSec {
        let osdMsg: OSDMessage = paused ? .pause(posSec: pos, durSec: dur) :
          .resume(posSec: pos, durSec: dur)
        sendOSD(osdMsg)
      }
      saveState()  // record the pause state
      if paused {
        videoView.displayIdle()
      } else {  // resume
        videoView.displayActive()
      }
      if pwc.currentLayout.isInPiP {
        pwc.pip.controller?.playing = !paused
      }

      if pwc.loaded, Preference.bool(for: .alwaysFloatOnTop) {
        pwc.setWindowFloatingOnTop(!paused, from: pwc.currentLayout)
      }
    }
  }

  func speedDidChange(to speed: CGFloat) {
    info.playSpeed = speed
    sendOSD(.speed(speed))
    saveState()  // record the new speed
    DispatchQueue.main.async { [self] in
      pwc.updatePlayButtonAndSpeedUI()
    }
  }

  /// Called when `MPVOption.Video.videoRotate` changed
  func userRotationDidChange(to userRotation: Int) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    let gtf = GeometryTransform("UserRotation", self)
    gtf.submit()
  }

  /// Set video's aspect ratio override. The `aspect` param is a string which may be one of the following formats:
  /// 1. Target aspect ratio. This came from user input, either from a button, menu, or text entry.
  /// This can be either in colon notation (e.g., "16:10") or decimal ("2.333333").
  /// 2. Actual aspect ratio as could be parsed as `Double` value.
  /// After the target aspect is applied to the raw video dimensions, the resulting dimensions must be rounded to their nearest
  /// integer values (because of reasons). So when the aspect is recalculated from the new dimensions, the result may be slightly
  /// different.
  ///
  /// This method ensures that the following components are synced to the given aspect ratio:
  /// 1. mpv `video-aspect-override` property
  /// 2. Player window geometry / displayed video size
  /// 3. Quick Settings controls & menu item checkmarks
  ///
  /// To hopefully avoid precision problems, `mpvAspectString` is used for comparisons across data sources.
  func setVideoAspectOverride(_ aspectString: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isRestoring else { return }

    let aspectLabel: String = Aspect.bestLabelFor(aspectString)
    guard videoGeo.userAspectLabel != aspectLabel else { return }

    sendVideoAspectOverrideToMpv(aspectLabel: aspectLabel)
  }

  func sendVideoAspectOverrideToMpv(aspectLabel: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    var mpvValue = Aspect.mpvVideoAspectOverride(fromAspectLabel: aspectLabel)
    if mpvValue == Constants.String.mpvNo {
      /// mpv doc says that `-1` means: `strictly prefer the container aspect ratio`.
      // Note that the mpv doc says this value is deprecated, and that "no" should be used instead,
      // but that does not work properly for some videos.
      mpvValue = "-1.0"
    }
    log.verbose("Setting mpv video-aspect-override ≔ \(mpvValue.quoted)")
    mpv.setString(MPVOption.Video.videoAspectOverride, mpvValue)
  }

  var shouldAlwaysHideCursor: Bool {
    if info.cursorAutoHideFullScreenOnly && !isFullScreen {
      return false
    }
    return info.cursorAutoHideTimeoutMs == 0
  }

  var canHideCursor: Bool {
    if info.cursorAutoHideFullScreenOnly && !isFullScreen {
      return false
    }
    return info.enableCursorAutoHide
  }

  func updateCursorAutohideState() {
    if let autoHide = mpv.getString(MPVOption.Window.cursorAutohide) {
      if autoHide == "always" {
        info.cursorAutoHideTimeoutMs = 0
      } else if autoHide == "no" {
        info.cursorAutoHideTimeoutMs = -1000
      } else if let autoHideMs = Int(autoHide) {
        info.cursorAutoHideTimeoutMs = autoHideMs
      }
    }
    info.cursorAutoHideFullScreenOnly = mpv.getFlag(MPVOption.Window.cursorAutohideFsOnly)
  }

  func syncVideoParamsFromMpv() {
    guard pwc.loaded else { return }
    guard !isRestoring else {
      log.trace("Ignoring SyncVidGeo request: isRestoring=Y")
      return
    }

    pwc.animationPipeline.enqueueVideoSyncTaskIfNeeded(self)
  }

  func setVideoRotate(_ userRotation: Int) {
    mpv.queue.async { [self] in
      guard AppData.rotations.firstIndex(of: userRotation)! >= 0 else {
        log.error("Invalid value for videoRotate, ignoring: \(userRotation)")
        return
      }

      guard isActive else { return }
      log.verbose("Setting videoRotate to: \(userRotation)°")
      mpv.setInt(MPVOption.Video.videoRotate, userRotation)
    }
  }

  /// Vertical flip
  func setFlip(_ enable: Bool) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      log.verbose("Setting flip to: \(enable)°")
      if enable {
        guard info.flipFilter == nil else {
          log.error("Cannot enable flip: there is already a filter present")
          return
        }
        let vf = MPVFilter.flip()
        let _ = addVideoFilter(vf)
      } else {
        guard let vf = info.flipFilter else {
          log.error("Cannot disable flip: no filter is present")
          return
        }
        let _ = removeVideoFilter(vf)
      }
    }
  }

  /// Horizontal flip
  func setMirror(_ enable: Bool) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      log.verbose("Setting mirror to: \(enable)°")
      if enable {
        guard info.mirrorFilter == nil else {
          log.error("Cannot enable mirror: there is already a mirror filter present")
          return
        }
        let vf = MPVFilter.mirror()
        let _ = addVideoFilter(vf)
      } else {
        guard let vf = info.mirrorFilter else {
          log.error("Cannot disable mirror: no mirror filter is present")
          return
        }
        let _ = removeVideoFilter(vf)
      }
    }
  }

  func toggleDeinterlace(_ enable: Bool) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setFlag(MPVOption.Video.deinterlace, enable)
    }
  }

  func toggleHardwareDecoding(_ enable: Bool) {
    let value = Preference.HardwareDecoderOption(rawValue: Preference.integer(for: .hardwareDecoder))?.mpvString ?? "auto"
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString(MPVOption.Video.hwdec, enable ? value : "no")
    }
  }

  func getVideoZoom() -> Double {
    let logZoom = pwc.player.mpv.getDouble(MPVOption.Video.videoZoom)
    // mpv uses a logrithmic scale. Convert to linear scale:
    let linearZoom = pow(2.0, logZoom)
    return linearZoom
  }

  func setVideoZoom(to zoom: Double) {
    let logZoom = log2(zoom)
    pwc.player.mpv.setDouble(MPVOption.Video.videoZoom, logZoom, level: .verbose)
  }

  private func mpvScale(fromZoom zoom: Double) -> Double {
    return pow(2.0, zoom)
  }

  private func mpvZoom(fromScale scale: Double) -> Double {
    return log2(scale)
  }


  enum VideoEqualizerType {
    case brightness, contrast, saturation, gamma, hue
  }

  func setVideoEqualizer(forOption option: VideoEqualizerType, value: Int) {
    let optionName: String
    switch option {
    case .brightness:
      optionName = MPVOption.Equalizer.brightness
    case .contrast:
      optionName = MPVOption.Equalizer.contrast
    case .saturation:
      optionName = MPVOption.Equalizer.saturation
    case .gamma:
      optionName = MPVOption.Equalizer.gamma
    case .hue:
      optionName = MPVOption.Equalizer.hue
    }
    mpv.queue.async { [self] in
      mpv.command(.set, args: [optionName, value.description])
    }
  }

  func loadExternalVideoFile(_ url: URL) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let urlPath = PlaybackID.path(from: url)
      mpv.command(.videoAdd, args: [urlPath], checkError: false) { [self] code in
        if code >= 0 { return }
        log.error("Unsupported video: \(url.path)")
        DispatchQueue.main.async {
          // FIXME: need to add text for `unsupported_video` (or delete this)
          Utility.showAlert("unsupported_audio")
        }
      }
    }
  }

  func loadExternalAudioFile(_ url: URL) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let urlPath = PlaybackID.path(from: url)
      mpv.command(.audioAdd, args: [urlPath], checkError: false) { [self] code in
        if code >= 0 { return }
        log.error("Unsupported audio: \(urlPath)")
        DispatchQueue.main.async {
          Utility.showAlert("unsupported_audio")
        }
      }
    }
  }

  func setAudioDelay(_ delay: Double) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setDouble(MPVOption.Audio.audioDelay, delay)
    }
  }

  @discardableResult
  func playChapter(_ pos: Int) -> MPVChapter? {
    log.verbose("Seeking to chapter \(pos)")
    let chapters = info.chapters
    guard pos < chapters.count else {
      return nil
    }
    let chapter = chapters[pos]
    mpv.queue.async { [self] in
      // Update playbackPositionSec preemptively, so UI doesn't flash
      // to prev chapter and back
      info.playbackPositionSec = chapter.startTime
      guard isActive else { return }
      mpv.command(.seek, args: ["\(chapter.startTime)", "absolute"])
      _resume()
    }
    return chapter
  }

  // MARK: - Other mpv Operations

  /// Return the list of audio devices.
  ///
  /// This function obtains the list of audio devices from mpv using the
  /// [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list) property. It then
  /// filters out audio devices that are not applicable based on the current IINA audio output driver setting
  /// (`audioDriverEnableAVFoundation`) and returns the results as a list of `MPVAudioDevice` objects.
  ///
  /// A mpv audio device is tied to a specific audio output driver (with the exception of the `auto` pseudo device). Thus an individual
  /// audio device appears twice in the list, once for the `coreaudio` driver and once for the `avfoundation` driver. This allows
  /// you to select both an audio device and a driver at the same time when setting the
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) mpv option. The documentation for
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) contains this caution:
  /// ```
  /// However, the --ao option will strictly force a specific AO. To avoid confusion, don't use --ao
  /// and --audio-device together.
  /// ```
  /// What the manual means by confusion is that if [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao)
  /// has been set to a specific audio output driver and
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) is then set to an audio device for a
  /// driver that is not contained in the list of drivers specified by
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) then mpv will not be able to use that audio
  /// device and will fall back to the default audio device.
  ///
  /// IINA sets [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) to either `coreaudio` or
  /// `avfoundation` based on the IINA `audioDriverEnableAVFoundation` setting. This is intentional as the
  /// `avfoundation` driver is experimental and has some problems that still need to be resolved. We want the user to explicitly
  /// choose to use the `avfoundation` driver, not accidentally choose it when selecting an audio output device.
  ///
  /// The [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list) property
  /// returns the full list of audio devices regardless of the
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) setting. Thus IINA must filter the list and
  /// remove audio devices tied to an audio output device that is not configured in
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao).
  /// - Returns: An array of `MPVAudioDevice` objects  that identify the available audio devices.
  func getAudioDevices() -> [MPVAudioDevice] {
    let raw = mpv.getNode(MPVProperty.audioDeviceList)
    guard let list = raw as? [[String: String]] else { return [] }
    let ignore = Preference.bool(for: .audioDriverEnableAVFoundation) ? "coreaudio" : "avfoundation"
    var result: [MPVAudioDevice] = []
    for dict in list {
      let device = MPVAudioDevice(dict)
      guard device.driver != ignore else {
        log.verbose("Ignored audio device due to audio driver setting:\n \(device)")
        continue
      }
      result.append(device)
    }
    return result
  }

  func setAudioDevice(_ name: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString(MPVProperty.audioDevice, name)
    }
  }

  /// mpv `watch-later` + `saveToLastPlayedFile()` (above)
  func savePlaybackMetaBeforePlayerWillStop() {
    guard !isDemoPlayer else { return }
    guard mpv.getFlag(MPVOption.WatchLater.savePositionOnQuit) else { return }

    // The player must be active to be able to save the watch later configuration.
    if isActive {
      log.debug("Write watch later config")
      mpv.command(.writeWatchLaterConfig, level: .verbose)
    }

    guard let id = info.currentPlayback?.id else {
      log.warn("Cannot save playback meta: currentPlayback is nil")
      return
    }
    HistoryController.shared.savePlaybackMetaBeforeFileWillClose(id, duration: info.playbackDurationSec, position: info.playbackPositionSec)
  }

  func getMPVGeometry() -> MPVGeometryDef? {
    /// Cannot rely on mpv instance to have `MPVOption.Window.geometry` set. If configured to only set when opening manually, it doesn't
    /// make sense to keep it set. Just load the pref value directly.
    let geometryString = Preference.string(for: .initialWindowSizePosition) ?? ""
    if let mpvGeometry = MPVGeometryDef.parse(geometryString) {
      log.verbose("Parsed mpv geometry from prefs: \(mpvGeometry)")
      return mpvGeometry
    } else {
      log.verbose("Got nil for mpv geometry from prefs!")
      return nil
    }
  }

  /// Uses an mpv `on_before_start_file` hook to honor mpv's `shuffle` command via IINA CLI.
  ///
  /// There is currently no way to remove an mpv hook once it has been added, so to minimize potential impact and/or side effects
  /// when not in use:
  /// 1. Only add the mpv hook if `--mpv-shuffle` (or equivalent) is specified. Because this decision only happens at launch,
  /// there is no risk of adding the hook more than once per player.
  /// 2. Use `shufflePending` to decide if it needs to run again. Set to `false` after use, and check its value as early as possible.
  func addShufflePlaylistHook() {
    $shufflePending.withLock{ $0 = true }

    func callback(next: @escaping Callback) {
      var mustShuffle = false
      $shufflePending.withLock{ shufflePending in
        if shufflePending {
          mustShuffle = true
          shufflePending = false
        }
      }

      guard mustShuffle else {
        log.verbose("Triggered on_before_start_file hook, but no shuffle needed")
        next()
        return
      }

      DispatchQueue.main.async { [self] in
        log.debug("Running on_before_start_file hook: shuffling playlist")
        mpv.command(.playlistShuffle)
        /// will cancel this file load sequence (so `fileLoaded` will not be called), then will start loading item at index 0
        mpv.command(.playlistPlayIndex, args: ["0"])
        next()
      }
    }

    mpv.addHook(MPVHook.onBeforeStartFile, hook: MPVHookValue(withBlock: callback))
  }

  // MARK: - mpv Event Callbacks

  /// A [MPV_EVENT_START_FILE](https://mpv.io/manual/stable/#command-interface-mpv-event-start-file) was received.
  func fileStarted(path: String, playlistPos: Int) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isStopping else { return }

    if isIdleOrUnused {
      state = .started
    }

    // TODO: do something with this
    let parentPlaylist = mpv.getString(MPVProperty.playlistPath) ?? ""

    guard let playbackFromPath = Playback(urlPath: path, playlistPos: playlistPos, parentPlaylist: parentPlaylist, state: .started) else {
      log.error("FileStarted: failed to create media from path \(path.pii.quoted)")
      return
    }
    if let existingPlayback = info.currentPlayback, existingPlayback.url == playbackFromPath.url {
      guard existingPlayback.state.isNotYet(.started) else {
        log.warn("FileStarted: found existing playback for \(existingPlayback.url.absoluteString.pii.quoted), but state is unexpected; aborting (expected: 'notYetStarted', found: \(existingPlayback.state.rawValue))")
        return
      }
    }

    log.verbose("FileStarted: playbackPath=\(path.pii.quoted), PL#=\(String(playbackFromPath.playlistPos))")
    info.currentPlayback = playbackFromPath

    // Stop watchers from prev media (if any)
    stopWatchingSubFile()

    DispatchQueue.main.async { [self] in
      // Check this inside main DispatchQueue
      if playlistShown {
        // TableView whole table reload is very expensive. No need to reload entire playlist; just the two changed rows:
        pwc.playlistView.refreshNowPlayingIndex(setNewIndexTo: playlistPos, thenScrollToVisible: true)
      }

      MediaPlayerIntegration.shared.update()
    }

    // set "date last opened" attribute
    if let url = info.currentURL, url.isFileURL, !info.isMediaOnRemoteDrive {
      let time = Date().timeIntervalSince1970
      var ts = timespec()
      ts.tv_sec = Int(time)
      ts.tv_nsec = Int(time.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
      let data = Data(bytesOf: ts)
      // set the attribute; the key is undocumented
      let name = "com.apple.lastuseddate#PS"
      url.withUnsafeFileSystemRepresentation { fileSystemPath in
        let _ = data.withUnsafeBytes {
          setxattr(fileSystemPath, name, $0.baseAddress, data.count, 0, 0)
        }
      }
    }

    // Cannot restore playlist until after fileStarted event & mpv has a position for current item
    if let priorState = pwc.priorStateIfRestoring {
      let playlistPathList = priorState.getPlaylistPathList()
      if !playlistPathList.isEmpty {
        let playlistPos: Int? = priorState.int(for: .playlistPos)
        log.debug("Restoring \(playlistPathList.count) items into playlist, indexOfCurrentItem=\(playlistPos?.description ?? "nil")")
        _addAllToPlaylist(pathListIncludingCurrent: playlistPathList, indexOfCurrentItem: playlistPos)
      }
    }

    sendOSD(.fileStart(playbackFromPath.displayName, ""))

    events.emit(.fileStarted)
  }


  /// When [MPV_EVENT_FILE_LOADED](https://mpv.io/manual/stable/#command-interface-mpv-event-file-loaded) was received.
  ///
  /// This function is called right after file loaded, triggered by mpv `fileLoaded` notification.
  /// We should now be able to get track info from mpv and can start rendering the video in the final size.
  func fileLoaded() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    // note: player may be "stopped" here
    guard !isStopping else { return }

    log.verbose("FileLoaded path=\(info.currentPlayback?.path.pii.quoted ?? "nil")")

    // mpv will play when loaded by default. But if we are opening a new window or starting a new session in an existing window,
    // we will have told mpv to pause the playback, and we should not unpause the playback until we are ready to show the window.
    if isRestoring {
      // If restoring, playback was already paused, & will not be unpaused until window is ready to show (see `showWindow`)
      // Finally call this to update info.vid & related video track state in VideoView:
      updateVidStateFromMpv()
    } else if pwc.loaded, pwc.sessionState.hasOpenSession {
      // Note: we only need to handle existing session here.
      // New session or reuse of existing will be handled in openWindow().
      // Traditionally IINA will un-pause when starting a new file, unless it is configured to do otherwise.
      // So we should also be setting this value one way or another.
      let shouldPause = getPauseFromUserOptions() ?? Preference.bool(for: .pauseWhenOpen)
      log.verbose("FileLoaded: in existing session: setting pause=\(shouldPause.yn)")
      mpv.setFlag(MPVOption.PlaybackControl.pause, shouldPause)

      if !shouldPause {
        // Normally the display link is started when finishLoading() calls initVideo.
        // However if this player is being reused then the window will have already been loaded and
        // windowDidLoad will not be called. If playback is not paused make sure the display link is
        // active.
        DispatchQueue.main.async { [self] in
          pwc.videoView.displayActive()
        }
      }
    }

    let duration = mpv.getDouble(MPVProperty.duration)
    info.playbackDurationSec = duration
    if let path = mpv.getString(MPVProperty.path) {
      if let id = PlaybackID(path: path) {
        MediaMetaCache.shared.updateCacheEntry(id, newDuration: duration)
      } else {
        log.error("MediaMetaCache: could not create URL for path, skipping: \(path)")
      }
    }
    let playbackPosition = mpv.getDouble(MPVProperty.timePos)
    info.playbackPositionSec = playbackPosition

    if Preference.bool(for: .scaleRemainingTime) {
      info.playbackRemainingSec = mpv.getDouble(MPVProperty.playtimeRemainingFull)
    } else {
      info.playbackRemainingSec = mpv.getDouble(MPVProperty.timeRemainingFull)
    }

    triedUsingExactSeekForCurrentFile = false
    // Playback will move directly from stopped to loading when transitioning to the next file in
    // the playlist.
    if state == .stopping || state == .idle {
      state = .started
    }

    guard let currentPlayback = info.currentPlayback else {
      log.debug("FileLoaded: aborting: currentPlayback was nil")
      return
    }

    guard !mpv.isStale() else {
      log.debug("FileLoaded: aborting: mpv is stale")
      return
    }

    guard currentPlayback.state.isNotYet(.loaded) else {
      log.warn("FileLoaded: aborting - state of \(currentPlayback.path.pii.quoted) is \(currentPlayback.state.description.quoted)")
      return
    }

    info.currentPlayback = currentPlayback.changingState(to: .loaded)

    if currentPlayback.isNetworkResource, isInteractivePlayer {
      DispatchQueue.main.async {
        let openURLWindow = IINA_Advance.AppDelegate.shared.openURLWindow
        if openURLWindow.playerCore == self {
          openURLWindow.closeAfterSuccess()
        }
      }
    }

    // Kick off thumbnails load/gen - it can happen in background
    reloadThumbnails()

    checkUnsyncedWindowOptions()
    if !reloadTrackInfo() {
      // TODO: can this ever happen here?! May need to terminate player if so
      log.error("FileLoaded: no tracks returned by mpv! Returning early…")
      return
    }

    // Cache these vars to keep them constant for background tasks
    let priorStateIfRestoring = pwc.priorStateIfRestoring
    let isRestoring = priorStateIfRestoring != nil

    // Sync tracks
    if let priorStateIfRestoring, priorStateIfRestoring.string(for: .playPosition) != nil {
      /// Need to manually clear this, because mpv will try to seek to this time when any item in playlist
      /// is started. Run this on the mpv queue to ensure proper ordering.
      log.verbose("Clearing mpv 'start' option now that restore is complete")
      mpv.setString(MPVOption.PlaybackControl.start, Constants.String.mpvArgNone)

      /// Will complete restore when `transformGeometry` is done
    }
    let currentPlaybackButLoadedNeedsSizing = currentPlayback.changingState(to: .loadedButNeedsSizing)

    _reloadPlaylist()  // Need to do this when opening a playlist!
    _reloadChapters()
    syncAbLoop()
    // Done syncing tracks

    let gtf = GeometryTransform("FileLoaded", self,
                                currentPlayback: currentPlaybackButLoadedNeedsSizing,
                                sessionState: { [self] prevSessionState, ctx in
      switch prevSessionState {
      case .existingSession_continuing:
        return .existingSession_startingNewPlayback
      default:
        if prevSessionState.isStartingNewPlayback {
          return prevSessionState
        } else {
          log.verbose("[GTF:\(ctx.name)] Not the right sessionState (\(prevSessionState)); will let another handler take this")
          return nil
        }
      }
    })
    gtf.submit()

    // Launch auto-load tasks on background thread
    let shouldAutoLoadFiles = info.shouldAutoLoadFiles
    let currentTicket = $backgroundQueueTicket.withLock { latestTicket in
      latestTicket += 1
      return latestTicket
    }
    PlayerCore.backgroundQueue.asyncAfter(deadline: DispatchTime.now() + Constants.TimeInterval.autoLoadDelay) { [self] in
      fileLoaded_backgroundQueueWork(for: currentPlayback, currentTicket: currentTicket,
                                     shouldAutoLoadFiles: shouldAutoLoadFiles,
                                     priorStateIfRestoring: priorStateIfRestoring)
    }

    // History thread: update history given new playback URL. If restoring a prev playback, do not add again
    if let playbackID = info.currentPlayback?.id, !isRestoring {
      // Pass nil as positionSec for now, to reflect mpv watch-later state. The watch-later info is deleted when a file is
      // opened. Later if we implement our own position tracking, we can do something more intuitive.
      HistoryController.shared.savePlaybackMetaAfterFileDidLoad(for: playbackID,
                                                                durationSec: info.playbackDurationSec ?? 0.0,
                                                                positionSec: nil)
    }
  }

  /// Auto load via background queue
  private func fileLoaded_backgroundQueueWork(for currentPlayback: Playback,
                                              currentTicket: Int,
                                              shouldAutoLoadFiles: Bool,
                                              priorStateIfRestoring: PlayerSaveState?) {
    assert(DispatchQueue.isExecutingIn(PlayerCore.backgroundQueue))
    let isRestoring = priorStateIfRestoring != nil

    // Auto-load: add files in same folder to playlist (if configured)
    if shouldAutoLoadFiles {
      assert(!isRestoring, "shouldAutoLoadFiles should not be true when restoring!")
      log.debug("Started auto load of files in current folder")
      autoLoadFilesInCurrentFolder(ticket: currentTicket)
    }

    // Search for external subtitles on disk, auto-load if found
    if let matchedSubs = info.getMatchedSubs(currentPlayback.path) {
      log.debug("Found \(matchedSubs.count) external subs for current file")
      var loadedSubs = Set<URL>()
      for sub in matchedSubs {
        // filter duplicated matched subtitles, see https://github.com/iina/iina/issues/5399
        guard !loadedSubs.contains(sub) else { continue }
        loadedSubs.insert(sub)
        guard currentTicket == backgroundQueueTicket else { return }
        loadExternalSubFile(sub)
      }
      if !isRestoring {
        // set sub to the first one
        // TODO: why?
        log.debug("Setting subtitle track to because an external sub was found")
        guard currentTicket == backgroundQueueTicket, mpv.mpv != nil else { return }
        setTrack(1, forType: .sub)
      }
    }

    // Search for online subtitles, auto-load if found
    if Preference.bool(for: .autoSearchOnlineSub) &&
        !info.isNetworkResource &&
        info.subTracks.isEmpty &&
        (info.playbackDurationSec ?? 0.0) >= Preference.double(for: .autoSearchThreshold) * 60 {
      pwc.menuFindOnlineSub(pwc)
    }

    guard currentTicket == backgroundQueueTicket, mpv.mpv != nil else { return }

    // Set SID & S2ID now that all subs are available
    if let priorState = priorStateIfRestoring {
      if let priorSID = priorState.int(for: .sid) {
        setTrack(priorSID, forType: .sub, silent: true)
      }
      if let priorS2ID = priorState.int(for: .s2id) {
        setTrack(priorS2ID, forType: .secondSub, silent: true)
      }
    }
    log.debug("Auto load done")
  }

  func fileEnded(dueToStopCommand: Bool, detail: String) {
    // if receive end-file when loading file, might be error
    // wait for idle
    if info.isFileLoaded {
      info.shouldAutoLoadFiles = false
    } else {
      if !dueToStopCommand {
        errorWhileLoading = detail
      }
    }
    if dueToStopCommand {
      playbackStopped()
    }
  }

  func chapterChanged() {
    guard isActive else { return }
    let chapter = Int(mpv.getInt(MPVProperty.chapter))
    info.chapter = chapter
    log.verbose("Δ mpv prop: 'chapter' = \(info.chapter)")
    syncUI(.chapterList)
    mediaTitleChanged()
  }

  func fullscreenChanged() {
    guard pwc.loaded, !isStopping else { return }
    let fs = mpv.getFlag(MPVOption.Window.fullscreen)
    if fs != isFullScreen {
      pwc.toggleWindowFullScreen()
    }
  }

  func idleActiveChanged() {
    let isFileLoaded = info.isFileLoaded
    let errorMsg = errorWhileLoading
    log.verbose("Got mpv 'idle-active': isFileLoaded=\(isFileLoaded.yn) error=\(errorMsg?.quoted ?? "nil") playerState=\(state)")
    /// Make sure to check that `info.currentPlayback != nil` before outputting error
    if let errorMsg, let playback = info.currentPlayback, playback.state.isNotYet(.loaded) {
      log.error("Received fileEnded + 'idle-active' from mpv while loading \(playback.path.pii.quoted)! Will stop player\(isInteractivePlayer ? " & close window" : "")")
      DispatchQueue.main.async { [self] in
        let errorDetail = errorMsg.isEmpty ? "" : "\n\n\(errorMsg)"
        Utility.showAlert("error_open_name", arguments: ["\(playback.path.quoted)\(errorDetail)"])
        let openURLWindow = AppDelegate.shared.openURLWindow
        if openURLWindow.playerCore == self, openURLWindow.window?.isOpen == true {
          openURLWindow.failedToLoadURL()
        }
        _closeWindow()
      }
    } else if isFileLoaded || state.isAtLeast(.stopping) {
      // Check for stopping status also. Sometimes libmpv doesn't post stop message.
      closeWindow()
    }
    errorWhileLoading = nil
    // Make sure current playback is taken into account before changing state to `idle`.
    // Idle player is one which is closed or never used but can be reused. Do not set to idle when changing media or other small intervals
    if state.isNotYet(.shuttingDown), (errorMsg != nil) || (info.currentPlayback == nil) {
      state = .idle
      DispatchQueue.main.async { [self] in
        videoView.displayIdle()
      }
    }
  }

  func mediaTitleChanged() {
    guard isActive else { return }
    DispatchQueue.main.async { [self] in
      guard pwc.isOpen else { return }
      MediaPlayerIntegration.shared.update()
      postNotification(.iinaMediaTitleChanged)
    }
  }

  /// The mpv [current-ao](https://mpv.io/manual/stable/#command-interface-current-ao) property changed.
  ///
  /// When the audio output driver changes it may cause the currently selected audio device to be invalid because a mpv audio device
  /// is tied to a specific audio output driver. Attempt to find and configure the same audio device with the current audio output driver.
  func currentAoChanged() {
    guard let currentAo = mpv.getString(MPVProperty.currentAo),
          let audioDevice = mpv.getString(MPVProperty.audioDevice) else { return }
    let device = MPVAudioDevice(desc: "", name: audioDevice)
    let invalid = currentAo == "coreaudio" ? "avfoundation" : "coreaudio"
    guard device.driver == invalid else { return }
    let replacement = MPVAudioDevice(device, currentAo)
    let audioDevices = getAudioDevices()
    // Make certain the replacement device is in the list of audio devices.
    let found = audioDevices.contains { $0.name == replacement.name }
    guard found else {
      // Should not occur.
      log.error("Failed to find replacement audio device \(replacement.name) in:\n  \(audioDevices)")
      return
    }
    log.debug("""
        Audio output driver changed to \(currentAo), changing audio device
          from \(audioDevice)
          to \(replacement.name)
        """)
    mpv.setString(MPVProperty.audioDevice, replacement.name)
  }

  /// *Enqueues*
  func setQuickSettingsViewNeedsUpdate() {
    pwc.animationPipeline.doAfterGTFs{ [self] in
      reloadQuickSettingsViewNow()
    }
  }

  func reloadQuickSettingsViewNow() {
    guard pwc.loaded else { return }
    guard !isStopping else { return }
    log.verbose("Reloading QuickSettigsView")

    pwc.quickSettingView.reloadCurrentTab()
  }

  func seeking() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    log.trace("Seeking")

    DispatchQueue.main.async { [self] in
      info.isSeeking = true
      // When playback is paused the display link may be shutdown in order to not waste energy.
      // It must be running when seeking to avoid slowdowns caused by mpv waiting for IINA to call
      // mpv_render_report_swap.
      videoView.displayActive()
    }

    if let pos = info.playbackPositionSec, let dur = info.playbackDurationSec {
      sendOSD(.seek(posSec: pos, durSec: dur))
    }
  }

  func playbackRestarted() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    log.debug("Playback restarted")

    DispatchQueue.main.async { [self] in
      info.isSeeking = false
      // Important to synchronize the time as mpv may slightly alter the playback position during a
      // restart even while paused. See issue #5337.
      updatePlaybackTimeInfo()  // prepare for updateUI()
      pwc.updateUI()

      // When playback is paused the display link may be shutdown in order to not waste energy.
      // The display link will be restarted while seeking. If playback is paused shut it down again.
      if info.isPaused {
        videoView.displayIdle()
      }

      // End of seeking? Set short timer to hide seek time & thumbnail
      pwc.seekPreview.restartHideTimer()

      saveState()
    }
  }

  func refreshEdrMode() {
    pwc.animationPipeline.submitInstantTask { [self] in
      guard isActive else { return }
      guard pwc.loaded else { return }
      videoView.refreshEdrMode()
    }
  }

  // MARK: - Subtitles

  /// Shows the Font Chooser window to select a new font for the player
  func chooseSubFont() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let subFont = mpv.getString(MPVOption.Subtitles.subFont)
      DispatchQueue.main.async { [self] in
        Utility.quickFontPickerWindow(selecting: subFont) { [self] result in
          Task { @MainActor in
            setSubFont(result)
          }
        }
      }
    }
  }

  func toggleSubVisibility(_ set: Bool? = nil) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let newState = set ?? !info.isSubVisible
      mpv.setFlag(MPVOption.Subtitles.subVisibility, newState)
    }
  }

  func toggleSecondSubVisibility(_ set: Bool? = nil) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let newState = set ?? !info.isSecondSubVisible
      mpv.setFlag(MPVOption.Subtitles.secondarySubVisibility, newState)
    }
  }

  func loadExternalSubFile(_ url: URL, delay: Bool = false) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      log.verbose("Trying to load external sub file: \(url.path.pii.quoted)")
      if let track = info.findExternalSubTrack(withURL: url) {
        log.verbose("External sub file already loaded (track \(track.id))")
        mpv.command(.subReload, args: [String(track.id)], checkError: false)
        return
      }

      /// Use `auto` flag to override the default:
      /// ```<select>  Select the subtitle immediately (default).
      ///    <auto>    Don't select the subtitle. (Or in some special situations, let the default stream
      ///              selection mechanism decide.)```
      let urlPath = PlaybackID.path(from: url)
      log.verbose("Loading external sub file: \(urlPath.pii.quoted)")
      mpv.command(.subAdd, args: [urlPath], checkError: false, level: .verbose) { code in
        if code >= 0 { return }
        let errorDesc = mpv.errorString(code)
        log.error("Failed to load sub (error \(code): \(errorDesc)) \(urlPath.pii.quoted)")
        // if another modal panel is shown, popping up an alert now will cause some infinite loop.
        if delay {
          DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5) {
            Utility.showAlert("unsupported_sub")
          }
        } else {
          DispatchQueue.main.async {
            Utility.showAlert("unsupported_sub")
          }
        }
      }
    }
  }

  func reloadAllSubs() {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let currentSubName = info.currentTrack(.sub)?.externalFilename
      for subTrack in info.subTracks {
        mpv.command(.subReload, args: ["\(subTrack.id)"], checkError: false)
      }
      guard reloadTrackInfo() else { return }
      if let currentSub = info.subTracks.first(where: {$0.externalFilename == currentSubName}) {
        setTrack(currentSub.id, forType: .sub)
      }

      setQuickSettingsViewNeedsUpdate()
    }
  }

  func setSubDelay(_ delay: Double, forPrimary: Bool = true) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let option = forPrimary ? MPVOption.Subtitles.subDelay : MPVOption.Subtitles.secondarySubDelay
      mpv.setDouble(option, delay)
    }
  }

  /** Scale is a double value in (0, 100] */
  func setSubScale(_ scale: Double) {
    assert(scale > 0.0, "Invalid sub scale: \(scale)")
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setDouble(MPVOption.Subtitles.subScale, scale)
    }
  }

  func setSubPos(_ pos: Int, forPrimary: Bool = true) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      let option = forPrimary ? MPVOption.Subtitles.subPos : MPVOption.Subtitles.secondarySubPos
      mpv.setInt(option, pos)
    }
  }

  func setSubTextColor(_ colorString: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString("options/" + MPVOption.Subtitles.subColor, colorString)
    }
  }

  func setSubFont(_ font: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString(MPVOption.Subtitles.subFont, font)
    }
  }

  func setSubTextSize(_ fontSize: Double) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setDouble("options/" + MPVOption.Subtitles.subFontSize, fontSize)
    }
  }

  func setSubTextBold(_ isBold: Bool) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setFlag("options/" + MPVOption.Subtitles.subBold, isBold)
    }
  }

  func setSubTextBorderColor(_ colorString: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString("options/" + MPVOption.Subtitles.subBorderColor, colorString)
    }
  }

  func setSubTextBorderSize(_ size: Double) {
    mpv.queue.async { [self] in
      mpv.setDouble("options/" + MPVOption.Subtitles.subBorderSize, size)
    }
  }

  func setSubTextBgColor(_ colorString: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString("options/" + MPVOption.Subtitles.subBackColor, colorString)
    }
  }

  func setSubEncoding(_ encoding: String) {
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString(MPVOption.Subtitles.subCodepage, encoding)
    }
  }

  func subCodepageDidChange(to encoding: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard encoding != info.subEncoding else { return }
    log.verbose("Δ mpv prop: `sub-codepage` = \(encoding)")
    info.subEncoding = encoding
    reloadAllSubs()
  }

  func sidChanged(to sid: Int? = nil, silent: Bool = false, reloadTracksIfNotFound: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !pwc.sessionState.isRestoring, !isStopping else { return }
    let sid = sid ?? Int(mpv.getInt(MPVOption.TrackSelection.sid))
    guard info.isFileLoaded else {
      log.verbose("SID changed to \(sid) but file is not loaded; ignoring")
      return
    }
    guard sid != info.sid else { return }
    if reloadTracksIfNotFound, sid != 0, info.track(.sub, id: sid) == nil {
      // This can happen after loading an external sub. Try (only once) to get its track info
      log.verbose("Track not found for sid \(sid); will reload tracks")
      // This will call back to this function afterwards
      _ = reloadTrackInfo()
      return
    }
    log.verbose("Δ mpv prop: `sid`=\(sid)")
    info.sid = sid

    if !silent {
      sendOSD(.track(info.currentTrack(.sub) ?? .noneSubTrack))
    }
    startWatchingSubFile()
    postNotification(.iinaSIDChanged)
    saveState()
  }

  func secondarySidChanged(to ssid: Int? =  nil, silent: Bool = false, reloadTracksIfNotFound: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isRestoring, !isStopping else { return }
    let ssid = ssid ?? Int(mpv.getInt(MPVOption.Subtitles.secondarySid))
    guard info.isFileLoaded else {
      log.verbose("SSID changed to \(ssid) but file is not loaded; ignoring")
      return
    }
    guard ssid != info.secondSid else { return }
    if reloadTracksIfNotFound, ssid != 0, info.track(.secondSub, id: ssid) == nil {
      // This can happen after loading an external sub. Try (only once) to get its track info
      log.verbose("Track not found for ssid \(ssid); will reload tracks")
      // This will call back to this function afterwards
      _ = reloadTrackInfo()
      return
    }
    log.verbose("Δ mpv prop: `ssid` = \(ssid)")
    info.secondSid = ssid

    if !silent {
      sendOSD(.track(info.currentTrack(.secondSub) ?? .noneSecondSubTrack))
    }
    postNotification(.iinaSSIDChanged)
    saveState()
    setQuickSettingsViewNeedsUpdate()
  }

  func subScaleChanged(_ subScale: Double) {
    info.subScale = subScale
    let displayValue = subScale >= 1 ? subScale : -1/subScale
    sendOSD(.subScale(displayValue.roundedTo2()))
    saveState()
    setQuickSettingsViewNeedsUpdate()
  }

  func subVisibilityChanged(_ visible: Bool) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard info.isSubVisible != visible else { return }
    info.isSubVisible = visible
    sendOSD(visible ? .subVisible : .subHidden)
    saveState()
    postNotification(.iinaSubVisibilityChanged)
  }

  func secondSubVisibilityChanged(_ visible: Bool) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard info.isSecondSubVisible != visible else { return }
    info.isSecondSubVisible = visible
    sendOSD(visible ? .secondSubVisible : .secondSubHidden)
    saveState()
    postNotification(.iinaSecondSubVisibilityChanged)
  }

  func subDelayChanged(_ delay: Double) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    if info.subDelay != delay {
      log.verbose("Δ mpv prop: `sub-delay` = \(delay)")
      info.subDelay = delay
      sendOSD(.subDelay(delay))
      saveState()
    }
    setQuickSettingsViewNeedsUpdate()
  }

  func secondarySubDelayChanged(_ delay: Double) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    if info.sub2Delay != delay {
      log.verbose("Δ mpv prop: `secondary-sub-delay` = \(delay)")
      info.sub2Delay = delay
      sendOSD(.secondSubDelay(delay))
      saveState()
    }
    setQuickSettingsViewNeedsUpdate()
  }

  func subPosChanged(_ position: Double) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    info.subPos = position
    sendOSD(.subPos(position))
    saveState()
    setQuickSettingsViewNeedsUpdate()
  }

  func secondarySubPosChanged(_ position: Double) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    info.sub2Pos = position
    sendOSD(.secondSubPos(position))
    saveState()
    setQuickSettingsViewNeedsUpdate()
  }

  private func startWatchingSubFile() {
    guard let currentSubTrack = info.currentTrack(.sub) else { return }
    guard let externalFilename = currentSubTrack.externalFilename else {
      log.verbose("Sub \(currentSubTrack.id) is not an external file")
      return
    }

    // Stop previous watch (if any)
    stopWatchingSubFile()

    let subURL = URL(fileURLWithPath: externalFilename)
    let fileMonitor = FileMonitor(url: subURL)
    fileMonitor.fileDidChange = { [self] in
      mpv.command(.subReload, args: [String(currentSubTrack.id)], checkError: false) { [self] code in
        if code >= 0 { return }
        log.error("Failed reloading sub track \(currentSubTrack.id): error code \(code)")
      }
    }
    subFileMonitor = fileMonitor
    log.verbose("Starting FS watch of sub file \(subURL.path.pii.quoted)")
    fileMonitor.startMonitoring()
  }

  private func stopWatchingSubFile() {
    guard let subFileMonitor else { return }

    log.verbose("Stopping FS watch of sub file \(PlaybackID.path(from: subFileMonitor.url).pii.quoted)")
    subFileMonitor.stopMonitoring()
    self.subFileMonitor = nil
  }

  /**
   Add files in the same folder to playlist.
   It basically follows the following steps:
   - Get all files in current folder. Group and sort videos and audios, and add them to playlist.
   - Scan subtitles from search paths, combined with subs got in previous step.
   - Try match videos and subs by series and filename.
   - For unmatched videos and subs, perform fuzzy (but slow, O(n^2)) match for them.

   **Remark**:

   This method is expected to be executed in `backgroundQueue` (see `backgroundQueueTicket`).
   Therefore accesses to `self.info` and mpv playlist must be guarded.
   */
  private func autoLoadFilesInCurrentFolder(ticket: Int) {
    AutoFileMatcher(player: self, ticket: ticket).startMatching()
  }

  // MARK: - Sync UI with Playback State

  /// Checks unsynchronized window options, such as those set via mpv before window loaded.
  ///
  /// These options currently include fullscreen and ontop.
  private func checkUnsyncedWindowOptions() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard pwc.loaded, isActive else { return }

    syncFullScreenState()
    syncOntopState()
  }

  func syncOntopState() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard pwc.loaded, isActive else { return }

    let ontop = mpv.getFlag(MPVOption.Window.ontop)
    if ontop != pwc.isOnTop {
      log.verbose("IINA OnTop state (\(pwc.isOnTop.yn)) does not match mpv (\(ontop.yn)); will change to match mpv state")
      DispatchQueue.main.async { [self] in
        pwc.setWindowFloatingOnTop(ontop, from: pwc.currentLayout, updateOnTopStatus: false)
      }
    }
  }

  func syncFullScreenState() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard pwc.loaded else { return }

    let mpvFS = mpv.getFlag(MPVOption.Window.fullscreen)
    DispatchQueue.main.async { [self] in
      let iinaFS = pwc.isFullScreen
      log.verbose("FullScreen state: IINA=\(iinaFS.yn) mpv=\(mpvFS.yn)")
      guard mpvFS != iinaFS else { return }

      if mpvFS && didEnterFullScreenViaUserToggle {
        log.verbose("Disabling mpv full screen to sync it with IINA's state")
        didEnterFullScreenViaUserToggle = false
        mpv.queue.async{ [self] in
          guard isActive else { return }
          mpv.setFlag(MPVOption.Window.fullscreen, false)
        }
      } else {
        log.debug("IINA full screen state does not match mpv (FS=\(mpvFS.yesno)); will change to match mpv state")
        DispatchQueue.main.async { [self] in
          if mpvFS {
            pwc.enterFullScreen()
          } else {
            pwc.exitFullScreen()
          }
        }
      }
    }
  }

  var lastTimerSummary = ""  // for reducing log volume

  /// Assess the need for the timer that synchronizes the UI and start or stop it as needed.
  ///
  /// Call this when `syncUITimer` may need to be started, stopped, or needs its interval changed. It will figure out the correct action.
  ///
  /// This method is required to adhere to the best practices in the [Energy Efficiency Guide for Mac Apps](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/UsingEfficientGraphics.html#//apple_ref/doc/uid/TP40013929-CH27-SW1)
  /// that call for an app to avoid needless energy use. [Minimizing Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html#//apple_ref/doc/uid/TP40013929-CH5-SW1) is one of the recommended best practices.
  /// - Important: Make sure that any state variables (e.g., `info.isPaused`, `isInMiniPlayer`,  etc.) are set *before*
  ///     calling this method, not after, so that it makes the correct decisions.
  @MainActor
  func refreshSyncUITimer(logMsg: String = "") {
    // Check if timer should start/restart

    let useTimer: Bool
    if state.isAtLeast(.stopping) {
      useTimer = false
    } else if info.currentPlayback == nil {
      useTimer = false
    } else if info.isPaused {
      // Follow energy efficiency best practices and ensure IINA is absolutely idle when the
      // video is paused to avoid wasting energy with needless processing. If paused shutdown
      // the timer that synchronizes the UI and the high priority display link thread.

      // If showing OSC for streaming media, even while paused the cache may still be filling,
      // which will change the duration continuously.
      useTimer = info.isNetworkResource && pwc.isUITimerNeeded()
    } else if needsTouchBar && TouchBarSettings.shared.showAppControls || isInMiniPlayer {
      // The timer can't be stopped if the mini player is being used as it always displays the OSC
      // or if the timer is updating the information being displayed in the Touch Bar.
      useTimer = true
    } else if info.isNetworkResource {
      // May need to show, hide, or update buffering indicator at any time.
      useTimer = true
    } else {
      useTimer = pwc.isUITimerNeeded()
    }

    let timerConfig = AppData.syncTimerConfig

    /// Invalidate existing timer:
    /// - if no longer needed
    /// - if still needed but need to change the `timeInterval`
    var wasTimerRunning = false
    var timerRestartNeeded = false
    if let existingTimer = self.syncUITimer, existingTimer.isValid {
      wasTimerRunning = true
      if useTimer {
        if timerConfig.interval == existingTimer.timeInterval {
          /// Don't restart the existing timer if not needed, because restarting will ignore any time it has
          /// already spent waiting, and could in theory result in a small visual jump (more so for long intervals).
        } else {
          timerRestartNeeded = true
        }
      }

      if !useTimer || timerRestartNeeded {
        log.verbose("Invalidating SyncUITimer")
        existingTimer.invalidate()
        self.syncUITimer = nil
      }
    }

    if Logger.isEnabled(.verbose) {
      var summary: String = ""
      if wasTimerRunning {
        if useTimer {
          summary = timerRestartNeeded ? "restarting" : "running"
        } else {
          summary = "didStop"
        }
      } else {  // timer was not running
        summary = useTimer ? "starting" : "notNeeded"
      }
      if summary != lastTimerSummary {
        lastTimerSummary = summary
        if useTimer {
          summary += ", every \(timerConfig.interval)s"
        }
        log.verbose({
          let logMsg = logMsg.isEmpty ? logMsg : "\(logMsg)- "
          return "\(logMsg)SyncUITimer \(summary), paused:\(info.isPaused.yn) net:\(info.isNetworkResource.yn) mini:\(isInMiniPlayer.yn) touchBar:\(needsTouchBar.yn) state:\(state)"
        }())
      }
    }

    // When fadeable views are hidden the time can get out of sync. This method will be called when
    // the view becomes visible to sync the time. If the timer was not running the view must be
    // updated now. Playback may be paused. If that is the case then the timer will not be started.
    if !wasTimerRunning {
      // Do not wait for first redraw
      pwc.updateUI(pullUpdatesFromMpv: true)
    }

    guard useTimer && (timerRestartNeeded || !wasTimerRunning) else {
      return
    }

    // Timer will start

    log.verbose("Scheduling SyncUITimer")
    syncUITimer = Timer.scheduledTimer(
      timeInterval: timerConfig.interval,
      target: self,
      selector: #selector(fireSyncUITimer),
      userInfo: nil,
      repeats: true
    )
    /// This defaults to 0 ("no tolerance"). But after profiling, it was found that granting a tolerance of `timeInterval * 0.1` (10%)
    /// resulted in an ~8% redunction in CPU time used by UI sync.
    syncUITimer?.tolerance = timerConfig.tolerance
  }

  @objc func fireSyncUITimer() {
    pwc.updateUI(pullUpdatesFromMpv: true)
  }

  func updatePlaybackTimeInfo() {
    guard state.isAtLeast(.started), state.isNotYet(.stopping) else {
      log.verbose("SyncUI: not syncing")
      return
    }

    let isNetworkStream = info.isNetworkResource
    if isNetworkStream {
      info.playbackDurationSec = mpv.getDouble(MPVProperty.duration)
    }
    // When the end of a video file is reached mpv does not update the value of the property
    // time-pos, leaving it reflecting the position of the last frame of the video. This is
    // especially noticeable if the onscreen controller time labels are configured to show
    // milliseconds. Adjust the position if the end of the file has been reached.
    let eofReached = mpv.getFlag(MPVProperty.eofReached)
    let playbackPositionSec: Double
    if eofReached, let duration = info.playbackDurationSec {
      playbackPositionSec = duration
    } else {
      playbackPositionSec = mpv.getDouble(MPVProperty.timePos)
    }
    info.playbackPositionSec = playbackPositionSec

    info.constrainVideoPosition()

    let remaining = Preference.bool(for: .scaleRemainingTime) ?
    mpv.getDouble(MPVProperty.playtimeRemainingFull) :
    mpv.getDouble(MPVProperty.timeRemainingFull)
    info.playbackRemainingSec = remaining

    if isNetworkStream || Preference.bool(for: .showCachedRangesInSlider) {
      updateCacheInfo()
    }
    // else: info.cachedRanges will be cleared by pref observer

    if isSaveEnabled {
      // Ensure user can resume playback by periodically saving
      let now = Date().timeIntervalSince1970
      let secSinceLastSave = now - lastStateSaveTime
      if secSinceLastSave >= Constants.TimeInterval.playTimeSaveStateFrequency {
        log.trace("SyncUI: another \(Constants.TimeInterval.playTimeSaveStateFrequency)s has passed: saving player state")
        saveState()
        lastStateSaveTime = now
      }
    }
  }

  /// - Important: The mpv
  ///     [cache-buffering-state](https://mpv.io/manual/stable/#command-interface-cache-buffering-state)
  ///     property is only valid when
  ///     [paused-for-cache](https://mpv.io/manual/stable/#command-interface-paused-for-cache) is `true`
  ///     and can not be used to provide an indication of progress when seeking.
  func updateCacheInfo() {
    var cachedRanges: [(Double, Double)] = []
    info.pausedForCache = mpv.getFlag(MPVProperty.pausedForCache)
    if let demuxerCacheState = mpv.getNode(MPVProperty.demuxerCacheState) as? [String: Any] {
      if let underrun = demuxerCacheState["underrun"] as? Bool, underrun {
        if !info.isBufferUnderrun {
          log.verbose("SyncUI: demuxer buffer underrun started")
          info.isBufferUnderrun = true
        }
      } else if info.isBufferUnderrun {
        log.verbose("SyncUI: demuxer buffer underrun cleared")
        info.isBufferUnderrun = false
      }
      if let seekableRanges = demuxerCacheState["seekable-ranges"] as? [[String: Any]] {
        for seekableRange in seekableRanges {
          if let rangeStart = seekableRange["start"] as? Double, let rangeEnd = seekableRange["end"] as? Double {
            cachedRanges.append((rangeStart, rangeEnd))
          }
        }
      }
      info.cacheUsed = Int(demuxerCacheState["fw-bytes"] as? Int64 ?? 0)
      // Not guaranteed to be sorted. Sort them
      cachedRanges = cachedRanges.sorted(by: { $0.0 < $1.0 })
      let oldRanges = info.cachedRanges
      let rangesDidChange = oldRanges.count != cachedRanges.count || zip(cachedRanges, oldRanges).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 })
      if rangesDidChange {
        //    NSLog("   *** CACHED RANGES: \(cachedRanges.count): \(cachedRanges)")
        info.cachedRanges = cachedRanges
        // Redraw PlaySlider to reflect change:
        if let osc = pwc.currentControlBar, !osc.isHidden {
          pwc.playSlider.needsDisplay = true
        }
      }
      info.cacheSpeed = Int(demuxerCacheState["raw-input-rate"] as? Int64 ?? 0)
    }
    info.bufferingState = mpv.getInt(MPVProperty.cacheBufferingState)
  }

  // difficult to use option set
  enum SyncUIOption {
    case volume
    case muteButton
    case chapterList
    case playlist
    case loop
  }

  func syncUI(_ option: SyncUIOption) {
    // if window not loaded, ignore
    guard pwc.loaded else { return }
    log.verbose("Syncing UI \(option)")

    switch option {

    case .volume, .muteButton:
      DispatchQueue.main.async { [self] in
        pwc.updateVolumeUI()
      }

    case .chapterList:
      DispatchQueue.main.async { [self] in
        // this should avoid sending reload when table view is not ready
        if isInMiniPlayer {
          guard pwc.miniPlayer.playlistShown else { return }
          pwc.miniPlayer.loadIfNeeded()
        } else {
          guard pwc.isOpen(sidebarTab: .chapters) else { return }
        }

        pwc.playlistView.chapterTableView.reloadData()
      }

    case .playlist:
      DispatchQueue.main.async {
        if self.playlistShown {
          self.pwc.playlistView.playlistTableView.reloadData()
        }
      }

    case .loop:
      DispatchQueue.main.async {
        self.pwc.playlistView.updateLoopBtnStatus()
      }
    }

    // All of the above reflect a state change. Save it:
    saveState()
  }

  func closeWindow() {
    DispatchQueue.main.async { [self] in
      _closeWindow()
    }
  }

  /// Closes the window & ensures its state is properly updated.
  ///
  /// After closing the window, calls `AppDelegate.shared.windowWillClose` explicitly (AppKit should always call
  /// it via` NotificationCenter`, but this will dispel all doubt).
  /// This function can safely be called more than once without danger of side effects.
  @MainActor
  private func _closeWindow() {
    stop()
    guard isInteractivePlayer else {
      log.verbose("Called stop, but no window to close (player is non-interactive)")
      return
    }
    pwc.postWindowMustCancelShow()
    log.verbose("Closing window")
    pwc.close()
    /// Some doubts about whether `windowWillClose` is always fired. Call manually to ensure things execute:
    AppDelegate.shared.windowWillClose(window)
  }

  func reloadThumbnails() {
    mpv.queue.asyncAfter(deadline: .now() + Constants.TimeInterval.thumbnailRegenerationDelay) { [self] in
      guard !isStopping else { return }
      guard isInteractivePlayer else {
        log.verbose("Thumbnails reload stopped: player is non-interactive")
        return
      }
      guard !Preference.bool(for: .integrateWithThumbfast) else {
        log.verbose("Thumbnails reload stopped: pref key `integrateWithThumbfast` is set")
        DispatchQueue.main.async { [self] in
          touchBarSupport.touchBarPlaySlider?.resetCachedThumbnails()
        }
        return
      }
      guard let currentPlayback = info.currentPlayback else {
        log.debug("Thumbnails reload stopped ∵ no current playback")
        DispatchQueue.main.async { [self] in
          touchBarSupport.touchBarPlaySlider?.resetCachedThumbnails()
        }
        return
      }
      let videoTrackID = info.vid
      guard let videoTrackID, videoTrackID > 0 else {
        log.debug("Thumbnails reload stopped: invalid/missing video track: \(String(videoTrackID))")
        clearExistingThumbnails(for: currentPlayback)
        return
      }
      guard !currentPlayback.isNetworkResource else {
        log.verbose("Thumbnails reload stopped: current media is network")
        clearExistingThumbnails(for: currentPlayback)
        return
      }
      guard Preference.bool(for: .enableThumbnailPreview) else {
        log.verbose("Thumbnails reload stopped ∵ thumbnails are disabled by user")
        clearExistingThumbnails(for: currentPlayback)
        return
      }
      if !Preference.bool(for: .enableThumbnailForRemoteFiles) && info.isMediaOnRemoteDrive {
        log.debug("Thumbnails reload stopped ∵ file is on a mounted remote drive")
        clearExistingThumbnails(for: currentPlayback)
        return
      }
      if isInMiniPlayer && !Preference.bool(for: .enableThumbnailForMusicMode) {
        log.verbose("Thumbnails reload stopped ∵ user has disabled for music mode")
        clearExistingThumbnails(for: currentPlayback)
        return
      }

      // Generate thumbnails using video's original dimensions, before aspect ratio correction.
      // We will adjust aspect ratio & rotation when we display the thumbnail, similar to how mpv works.
      let videoGeo = videoGeo
      let videoSizeRaw = videoGeo.videoSizeRaw

      let thumbnailWidth = SingleMediaThumbnailsLoader.determineWidthOfThumbnail(from: videoSizeRaw, log: log)

      if let oldThumbs = currentPlayback.thumbnails {
        if !oldThumbs.isCancelled, oldThumbs.mediaFilePath == currentPlayback.url.path,
           oldThumbs.videoTrackID == videoTrackID,
           thumbnailWidth == oldThumbs.thumbnailWidth {
          log.debug("Already loaded \(oldThumbs.thumbnails.count) thumbnails (\(oldThumbs.thumbnailsProgress * 100.0)%) for vid\(videoTrackID) @ \(thumbnailWidth)px; nothing to do")
          return
        } else {
          clearExistingThumbnails(for: currentPlayback)
        }
      }

      var queueTicket: Int = 0
      $thumbnailQueueTicket.withLock {
        $0 += 1  // this will cancel any previous thumbnail loads for this player
        queueTicket = $0
      }

      log.verbose("Creating new thumbnails loader")
      let newMediaThumbnailLoader = SingleMediaThumbnailsLoader(self, queueTicket: queueTicket, mediaFilePath: currentPlayback.url.path, mediaFilePathMD5: currentPlayback.mpvMD5,
                                                                videoTrackID: videoTrackID, thumbnailWidth: thumbnailWidth)
      info.currentPlayback = currentPlayback.clone(thumbnails: newMediaThumbnailLoader)
      // Run the following in the background (`thumbnailQueue`) at lower priority, so the UI is not slowed down.
      thumbReloadDebouncer.run { [self] in
        log.trace("Thumbnails reload requested")

        guard queueTicket == thumbnailQueueTicket else { return }
        newMediaThumbnailLoader.loadThumbnails()
      }
    }
  }

  private func clearExistingThumbnails(for currentPlayback: Playback) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    if currentPlayback.thumbnails != nil {
      info.currentPlayback = currentPlayback.clone(clearThumbnails: true)
    }
    DispatchQueue.main.async { [self] in
      touchBarSupport.touchBarPlaySlider?.resetCachedThumbnails()
    }
  }

  @MainActor
  func makeTouchBar() -> NSTouchBar {
    log.debug("Activating Touch Bar")
    needsTouchBar = true
    // The timer that synchronizes the UI is shutdown to conserve energy when the OSC is hidden.
    // However the timer can't be stopped if it is needed to update the information being displayed
    // in the touch bar. If currently playing make sure the timer is running.
    refreshSyncUITimer()
    return touchBarSupport.touchBar
  }

  func refreshTouchBarSlider() {
    DispatchQueue.main.async {
      self.touchBarSupport.touchBarPlaySlider?.needsDisplay = true
    }
  }

  func reloadChapters() {
    mpv.queue.async { [self] in
      _reloadChapters()
    }
    syncUI(.chapterList)
  }

  func _reloadChapters() {
    log.verbose("Reloading chapter list")
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    var chapters: [MPVChapter] = []
    let chapterCount = mpv.getInt(MPVProperty.chapterListCount)
    for index in 0..<chapterCount {
      let chapter = MPVChapter(title:     mpv.getString(MPVProperty.chapterListNTitle(index)),
                               startTime: mpv.getDouble(MPVProperty.chapterListNTime(index)),
                               index:     index)
      chapters.append(chapter)
    }
    log.trace("Chapters: \(chapters)")
    // Instead of modifying existing list, overwrite reference to prev list.
    // This will avoid concurrent modification crashes
    info.chapters = chapters

    syncUI(.chapterList)
  }

  // MARK: - Notifications

  func postNotification(_ name: Notification.Name) {
    log.verbose("Posting notification: \(name.rawValue)")
    NotificationCenter.default.post(Notification(name: name, object: self))
  }

  /// Observer for changes to the macOS Touch Bar settings.
  /// - Parameters:
  ///   - keyPath: The key path, relative to `object`, to the value that has changed.
  ///   - object: The source object of the key path `keyPath`.
  ///   - change: A dictionary that describes the changes that have been made to the value of the property at the key path
  ///             `keyPath` relative to object. Entries are described in `Change Dictionary Keys`.
  ///   - context: The value that was provided when the observer was registered to receive key-value observation notifications.
  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    // The following guards are sanity checks and should never report an error.
    guard let keyPath = keyPath else {
      log.error("Observed key path is missing")
      return
    }
    guard let key = TouchBarSettings.Key(rawValue: keyPath) else {
      log.error("Observed key path is not a touch bar setting: \(keyPath)")
      return
    }
    guard (key == .PresentationModeFnModes) || (key == .PresentationModeGlobal) || (key == .PresentationModePerApp) else {
      log.error("Observed key path is unrecognized: \(keyPath)")
      return
    }
    DispatchQueue.main.async { [self] in
      log.debug("Touch Bar \(key) setting has changed")
      // The macOS settings that control what the Touch Bar displays has changed. May need to start or
      // stop the timer that refreshes the UI.
      refreshSyncUITimer()
    }
  }

  // MARK: - Track Meta

  func getMediaTitle(withExtension: Bool = true) -> String {
    if let mediaTitle = mpv.getString(MPVProperty.mediaTitle) {
      if !mediaTitle.isEmpty, let path = mpv.getString(MPVProperty.path), let id = PlaybackID(path: path) {
        MediaMetaCache.shared.updateCachedMeta(id, reloadFromWatchLater: false, reloadFromFFmpeg: false,
                                               mpvTitle: mediaTitle)
      }
      return mediaTitle
    }
    if let url = info.currentURL {
      return withExtension ? url.path : url.deletingPathExtension().path
    }
    return ""
  }

  func getMusicMetadata() -> (title: String, album: String, artist: String) {
    if mpv.getInt(MPVProperty.chapters) > 0 {
      let chapter = mpv.getInt(MPVProperty.chapter)
      let chapterTitle = mpv.getString(MPVProperty.chapterListNTitle(chapter))
      return (
        chapterTitle ?? mpv.getString(MPVProperty.mediaTitle) ?? "",
        mpv.getString("metadata/by-key/album") ?? "",
        mpv.getString("chapter-metadata/by-key/performer") ?? mpv.getString("metadata/by-key/artist") ?? ""
      )
    } else {
      let meta = (
        mpv.getString(MPVProperty.mediaTitle) ?? "",
        mpv.getString("metadata/by-key/album") ?? "",
        mpv.getString("metadata/by-key/artist") ?? ""
      )
      if let path = mpv.getString(MPVProperty.path), let id = PlaybackID(path: path) {
        MediaMetaCache.shared.updateCachedMeta(id, reloadFromWatchLater: false, reloadFromFFmpeg: false,
                                               mpvTitle: meta.0, mpvAlbum: meta.1, mpvArtist: meta.2)
      }
      return meta
    }
  }

  // MARK: - Tracks

  func reloadTrackInfo() -> Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    log.verbose("Reloading tracklist from mpv")

    // No need to process track list changes if playback is being stopped. Must not process track
    // list changes if mpv is terminating as accessing mpv once shutdown has been initiated can
    // trigger a crash.
    guard !isStopping, info.isFileLoaded else {
      log.trace("Aborting tracklist reload: player or file not ready (player=\(state), file=\(info.currentPlayback?.state.description ?? "nil"))")
      return false
    }

    let raw = mpv.getNode(MPVProperty.trackList)
    guard let list = raw as? [[String: Any]] else {
      // Internal error, should not occur.
      log.error("Cast of mpv node failed: \(String(describing: raw))")
      return false
    }

    var audioTracks: [MPVTrack] = []
    var videoTracks: [MPVTrack] = []
    var subTracks: [MPVTrack] = []

    for dict in list {
      guard let type = dict["type"] as? String else { continue }
      guard let isDefault = dict["default"] as? Bool, let isForced = dict["forced"] as? Bool,
            let isImage = dict["image"] as? Bool, let isSelected = dict["selected"] as? Bool,
            let isExternal = dict["external"] as? Bool else {
        // Internal error, should not occur.
        log.error("Unable to construct MPVTrack from mpv node map: \(dict)")
        continue
      }
      let id = MPVController.nodeValueAsInt(dict["id"])
      let track = MPVTrack(id: id, type: MPVTrack.TrackType(rawValue: type)!,
                           srcId: MPVController.nodeValueAsInt(dict["src-id"]),
                           title: dict["title"] as? String,
                           lang: dict["lang"] as? String,
                           isDefault: isDefault, isForced: isForced, isImage: isImage,
                           isSelected: isSelected,
                           isExternal: isExternal,
                           externalFilename: dict["external-filename"] as? String,
                           codec: dict["codec"] as? String,
                           demuxW: MPVController.nodeValueAsInt(dict["demux-w"]),
                           demuxH: MPVController.nodeValueAsInt(dict["demux-h"]),
                           demuxChannelCount: MPVController.nodeValueAsInt(dict["demux-channel-count"]),
                           demuxChannels: dict["demux-channels"] as? String,
                           demuxSamplerate: MPVController.nodeValueAsInt(dict["demux-samplerate"]),
                           demuxFps: dict["demux-fps"] as? Double,
                           isAlbumart: dict["albumart"] as? Bool ?? false,
                           decoderDesc: dict["decoder-desc"] as? String,
      )

      // add to lists
      switch track.type {
      case .audio:
        audioTracks.append(track)
      case .video:
        videoTracks.append(track)
      case .sub:
        subTracks.append(track)
      default:
        break
      }
    }

    info.replaceTracks(audio: audioTracks, video: videoTracks, sub: subTracks)
    log.debug("Reloaded tracklist from mpv: \(videoTracks.count) video, \(audioTracks.count) audio, \(subTracks.count) subtitle")

    // Need to reload these explicitly. Sometimes when mpv sends `track-list`, it omits `vid`, `aid`, etc.
    vidChanged()
    aidChanged()
    sidChanged()
    secondarySidChanged()

    log.verbose("Posting iinaTracklistChanged vid=\(String(info.vid)) aid=\(String(info.aid)) sid=\(String(info.sid)) ssid=\(String(info.secondSid))")
    postNotification(.iinaTracklistChanged)
    return true
  }

  func aidChanged(to aid: Int? = nil, silent: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isRestoring, !isStopping else { return }
    let aid = aid ?? Int(mpv.getInt(MPVOption.TrackSelection.aid))
    guard aid != info.aid else { return }
    guard info.isFileLoaded else {
      log.verbose("Audio track changed to \(aid) but file is not loaded; ignoring")
      return
    }
    info.aid = aid

    log.verbose("Audio track changed to: \(aid)")
    syncUI(.volume)
    postNotification(.iinaAIDChanged)
    if !silent {
      if let audioTrack = info.currentTrack(.audio) {
        sendOSD(.audioTrack(audioTrack, info.volume))
      } else {
        // Do not show volume if no audio track:
        sendOSD(.track(.noneAudioTrack))
      }
    }
  }

  @discardableResult
  func updateVidStateFromMpv() -> (Int, Bool) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isStopping else { return (0, false) }

    let vid = Int(mpv.getInt(MPVOption.TrackSelection.vid))
    let isVidEnabled = vid != 0
    let trackIsAlbumArt = isVidEnabled && (mpv.getString(MPVProperty.trackListNAlbumart(vid)) == "yes")

    return videoView.$isUninited.withLock{ _ in
      let didChange = vid != info.vid
      videoView.isVidEnabled = isVidEnabled
      videoView.isVidAlbumArt = trackIsAlbumArt
      // Try to prevent crash when forcing draws. After changing vid from 0 to non-zero, do not allow forced drawing until after
      // the first render callback is triggered (unless track is album art).
      videoView.isReadyToRender = (isVidEnabled && trackIsAlbumArt) || isRestoring
      info.vid = vid
      log.verbose("Updated video state: vid=\(String(info.vid)) isAlbumArt=\(videoView.isVidAlbumArt.yn) ready=\(videoView.isReadyToRender.yn)")
      return (vid, didChange)
    }
  }

  func vidChanged(silent: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isRestoring, !isStopping else { return }

    /// Grab & reset `isShowViewportPendingInMiniPlayer` in mpv queue right away to avoid race
    let pendingAction = pendingActionOnVidChange
    pendingActionOnVidChange = .none

    let (vid, vidDidChange) = updateVidStateFromMpv()
    let hasPendingAction = pendingAction != .none
    log.verbose("VidDidChange=\(vidDidChange.yn) vid=\(String(info.vid)) hasPendingAction=\(hasPendingAction.yn)")
    guard vidDidChange || hasPendingAction else { return }

    let sessionStateTF: GeometryTransform.PWinSessionStateTF = { [self] prevSessionState, ctx -> PWinSessionState? in
      let returnValue: PWinSessionState?
      if case .existingSession_continuing = prevSessionState {
        if ctx.currentPlayback.state.isAtLeast(.loadedAndSized) {
          returnValue = .existingSession_videoTrackChangedForSamePlayback
        } else {
          returnValue = prevSessionState
        }
      } else if hasPendingAction {
        returnValue = prevSessionState
      } else {
        returnValue = nil  // abort
      }
      log.verbose("[GTF:\(ctx.name)] Changing sessionState for vid change, vidNew=\(ctx.vidTrackID) pendingAction=\(pendingAction): \(prevSessionState) → \(returnValue?.description ?? "nil")")
      return returnValue
    }

    let videoGeoTF: GeometryTransform.VideoGeometryTF = { [self] inputVidGeo, ctx -> VideoGeometry? in
      guard ctx.currentPlayback.state.isAtLeast(.loaded) else {
        log.verbose("[GTF:\(ctx.name)] vid changed to \(vid) but file is not loaded")
        return nil
      }

      var outputVidGeo = ctx.syncVideoParamsFromMpv(startingWith: inputVidGeo)
      if outputVidGeo == nil && hasPendingAction {
        log.verbose("[GTF:\(ctx.name)] syncVideoParams returned nil but pending miniplayer show video. Assuming no video tracks; will show default art")
        outputVidGeo = inputVidGeo
        // (kludge): ideally we'd want to include this in our window transform, but need refactor to get there from here. This should work ok.
        pwc.animationPipeline.submitInstantTask{ [self] in
          pwc.updateDefaultArtVisibility(to: true)
        }
      }

      // Show OSD in music mode (if configured) when actually changing tracks, but not while toggling videoView visibility
      if !silent, (!isInMiniPlayer || (pwc.miniPlayer.isViewportShown && !hasPendingAction)) {
        sendOSD(.track(info.track(.video, id: vid) ?? .noneVideoTrack))
      }
      if vid != 0, isActive, !isRestoring {
        reloadThumbnails()
      }
      postNotification(.iinaVIDChanged)
      return outputVidGeo
    }

    let gtf: GeometryTransform

    switch pendingAction {
    case .none:
      gtf = GeometryTransform("VidChange", self,
                              syncVideoParams: false,   // does the syncing itself
                              sessionState: sessionStateTF,
                              video: videoGeoTF)
      gtf.submit()

    case .showViewportInMusicMode:
      gtf = GeometryTransform("ShowViewportOnVidChange", self,
                              syncVideoParams: false,   // does the syncing itself
                              sessionState: sessionStateTF,
                              video: videoGeoTF,
                              windowed: { [self] ctx -> PWinGeometry? in
        guard ctx.outputLayout.isMusicMode else { return nil }
        let inputMusicModeGeo = ctx.inputGeoSet.musicMode
        log.verbose("[GTF:\(ctx.name)] Showing viewport in music mode (visibleNow=\(inputMusicModeGeo.isViewportShown.yesno))")
        miniPlayerShowVideoTimer.cancel()
        guard ctx.inputLayout.isMusicMode && !inputMusicModeGeo.isViewportShown else { return nil }
        let newGeo = inputMusicModeGeo.clone(video: ctx.outputVidGeo).withViewportVisible(true)
        return newGeo
      })

    case .exitMusicMode:
      gtf = GeometryTransform( "ExitMusicModeOnVidChange", self,
                               syncVideoParams: false,   // does the syncing itself
                               sessionState: sessionStateTF,
                               video: videoGeoTF,
                               buildPWinGeoTransformTasks: { [self] ctx -> [IINAAnimation.Task] in

        let inputMusicModeGeo = ctx.inputGeoSet.musicMode
        log.verbose("[GTF:\(ctx.name)] Showing viewport & exiting music mode (visibleNow=\(inputMusicModeGeo.isViewportShown.yesno))")
        miniPlayerShowVideoTimer.cancel()
        guard ctx.inputLayout.isMusicMode && !inputMusicModeGeo.isViewportShown else { return [] }

        let outputWindowed = ctx.inputGeoSet.windowed.clone(video: ctx.outputVidGeo).refitted()
        let outputGeoSet = ctx.inputGeoSet.clone(windowed: outputWindowed)
        let exitMusicModeTransitionTasks = ctx.pwc.buildTasksToExitMusicMode(from: ctx.inputLayout, outputGeoSet)
        return exitMusicModeTransitionTasks
      })
      gtf.submit()
    }

    gtf.submit()
  }

  /// In music mode, when toggling album art on, we wait for `vidChanged` to get called before showing the art.
  /// But it will not be called if there is no change (i.e. there are no video tracks at all).
  /// We can bridge the gap by setting a timer which will call `vidChanged`.
  private func miniPlayerShowViewportTimerAction() {
    mpv.queue.async { [self] in
      guard isShowViewportPendingInMiniPlayer else { return }
      log.verbose("Forcing vidChanged() to show videoView")
      vidChanged(silent: true)
    }
  }

  ///  Sets `vid=1` via mpv (if track exists), then if `showMiniPlayerVideo==true` and in music mode, shows `videoView`.
  ///  Does nothing if already in the target state (idempotent).
  ///
  ///  See also: `setVideoTrackDisabled`
  func setVideoTrackEnabled(thenDoAction action: PendingActionOnVidChange = .none) {
    mpv.queue.async { [self] in
      guard isActive else {
        log.verbose("Skipping enable video track: player is not active")
        return
      }

      guard reloadTrackInfo() else { return }
      let vidTrackCount = info.videoTracks.count
      let vidNow = Int(mpv.getInt(MPVOption.TrackSelection.vid))
      let vidToSet: Int
      if let vidPrevious = info.vidDisabled {
        info.vidDisabled = nil
        if vidPrevious < vidTrackCount {
          vidToSet = vidPrevious
        } else {
          // vidDisabled is invalid. Can happen if media changed while disabled.
          // Just fall back to 1:
          vidToSet = 1
        }
      } else {
        vidToSet = 1
      }
      let hasPendingAction = action != .none
      if hasPendingAction {
        pendingActionOnVidChange = action
        // In most cases, mpv will async'ly notify when the video track is done changing. But it is not guaranteed in all cases.
        // Give it a chance to load but use a timer as fallback to guarantee the videoView will open.
        log.verbose("Will show music mode video after enabling video track, timeout=\(miniPlayerShowVideoTimer.timeout)s")
        DispatchQueue.main.async { [self] in
          miniPlayerShowVideoTimer.restart()
        }
      }
      log.verbose("Enabling video track: changing vid from \(vidNow) → \(vidToSet) vidTrackCount=\(vidTrackCount) pnedingAction=\(action)")
      let hasVidTrack = vidTrackCount > 0
      guard hasVidTrack else {
        info.vidDisabled = nil  // clear saved track
        if hasPendingAction {
          // If no tracks, will not get a response from mpv if requesting to change tracks.
          // Or if a track is already selected, don't need to change tracks. But still need to show videoView.
          log.verbose("Enabling video track: skipping, but forcing call to vidChanged to show videoView")
          vidChanged(silent: true)
        }
        return
      }
      guard info.vid! != vidToSet else {
        log.verbose("Enabling video track: no change to vid (pendingAction=\(action))")
        if hasPendingAction {
          // Still need to call this to show videoView
          vidChanged(silent: true)
        }
        return
      }

      _setTrack(vidToSet, forType: .video, silent: true)
    }
  }

  ///  Sets `vid=0` via mpv. Does nothing if already in the target state (idempotent).
  ///
  ///  See also: `setVideoTrackEnabled`
  func setVideoTrackDisabled() {
    assert(DispatchQueue.isExecutingIn(.main))

    mpv.queue.async { [self] in
      guard isActive else { return }
      // Change video track to None
      let vidNow = Int(mpv.getInt(MPVOption.TrackSelection.vid))

      if info.vidDisabled == nil {
        log.verbose("Disabling video track: setting vidDisabled to \(vidNow) before setting vid=0")
        info.vidDisabled = vidNow
      }
      guard vidNow != 0 else {
        log.verbose("Disabling video track: vid=0 already, skipping")
        return
      }
      log.verbose("Disabling video: setting vid=0")
      _setTrack(0, forType: .video, silent: true)
    }
  }

  func setTrack(_ index: Int, forType: MPVTrack.TrackType, silent: Bool = false) {
    mpv.queue.async { [self] in
      _setTrack(index, forType: forType, silent: silent)
    }
  }

  func _setTrack(_ index: Int, forType trackType: MPVTrack.TrackType, silent: Bool = false) {
    log.verbose("Setting \(trackType) track to \(index)")
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }

    let name: String
    switch trackType {
    case .audio:
      name = MPVOption.TrackSelection.aid
    case .video:
      name = MPVOption.TrackSelection.vid

      if index == 0 {
        log.verbose("New track is 0: launching task to show defaultAlbumArt")
        // Show default art *before* waiting for mpv confirmation, to avoid a moment of empty black window.
        pwc.animationPipeline.submit(.instantTask{ [self] in
          // Do not show if in music mode & video is hidden.
          guard !pwc.currentLayout.isMusicMode || pwc.musicModeGeo.isViewportShown else { return }
          pwc.updateDefaultArtVisibility(to: true)
        })
      }
    case .sub:
      name = MPVOption.TrackSelection.sid
    case .secondSub:
      name = MPVOption.Subtitles.secondarySid
    }
    mpv.setInt(name, index)
  }

}
