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

    /// Player has started and is either idle (with no media loaded) or is active (with media loaded and/or playing).
    /// To determine idle state, check whether `info.currentPlayback` is `nil`.
    case started

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

  /// A DispatchQueue with `.background` QoS intended for longer-running tasks reqquiring disk IO:
  ///  - Auto Load
  ///  - MacOS bookmark generation
  ///  - External subtitle search
  ///
  ///  Tasks on this DQ are enqueued at the end of `fileLoaded`.
  static let postLoadBGQ = DispatchQueue.newDQ(label: "IINAA-Player-PostLoad-BG", qos: .background)
  /// A DispatchQueue with `.background` QoS for refreshing playlist item metadata (usually requiring disk or network IO)
  static let playlistMetaLoadDQ = DispatchQueue.newDQ(label: "IINAA-Player-BG", qos: .background)

  @MainActor
  static var mouseLocationAtLastOpen: NSPoint? = nil

  // MARK: - Instance Fields

  let log: any Logger.Subsystem
  var label: String
  let isDemoPlayer: Bool

  /// If a set of windows was opened at the same time, each is assigned an index, so they can be arranged slightly offset from each another.
  var openedWindowsSetIndex: Int = 0

  /// If `false`, has player functionality without use of a player window. Must be `true` to show a player window.
  var isInteractivePlayer = false

  @MainActor var isSaveEnabled: Bool { isInteractivePlayer && UIState.shared.isSaveEnabled }

  /// Time of the last player state save when called by `updatePlaybackInfo`.
  var lastStateSaveTime: TimeInterval = CFAbsoluteTimeGetCurrent()

  /// After mpvInit, contains both the user options in Settings > Advanced, + commandLineArgs
  var userOptions: [MPVOptPair]

  /// Should be the current build number, unless this player was restored from an older version's saved state
  var priorStateBuildNumber: Int

  // At launch, wait until all windows are open before resuming video
  var pendingResumeWhenShowingWindow: Bool = false
  /// If true, mpv needs to reload the current input config file because it has changed
  var needsInputConfFileReload: Bool = false

  @MainActor var undoHelper: PlayerWindowUndoHelper { pwc.undoHelper }

  private var subFileMonitor: FileMonitor? = nil
  let thumbnailsLoader = PlayerThumbnailsLoader()
  /// Use this to query for thumbnails.
  @MainActor var currentMediaThumbnails: SingleMediaThumbnailsLoader? = nil

  var windowAutosaveName: WindowAutosaveName { WindowAutosaveName.playerWindow(id: label) }

  // - Concurrency

  /// This ticket will be increased each time before a new task being submitted to `postLoadBGQ`.
  ///
  /// Each task holds a copy of ticket value at creation, so that a previous task will perceive & quit early if new tasks are awaiting.
  ///
  /// **See also**: `autoLoadFilesInCurrentFolder(ticket:)`
  @Atomic var postLoadBGQTicket = 0

  let saveUIStateDebouncer = Debouncer(delay: TimeConstants.playerStateSaveDelay, queue: PlayerSaveState.saveQueue)
  let sliderSeekDebouncer = Debouncer(delay: TimeConstants.sliderSeekThrottlingInterval)

  var uiTimeDebouncer: Debouncer!

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

  // - Playlist

  @MainActor
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
      if state == .started {
        Task { @MainActor in
          SleepPreventer.updateSleepPrevention()
        }
      }
    }
  }


  var isActive: Bool { state.isAtLeast(.started) && state.isNotYet(.stopping) }
  var isShuttingDown: Bool { state.isAtLeast(.shuttingDown) }
  var isShutDown: Bool { state.isAtLeast(.shutDown) }
  var isStopping: Bool { state.isAtLeast(.stopping) }
  /// An unused player is one which does not have a playback (`!hasPlayback`)
  var isIdleOrUnused: Bool { !hasPlayback && state.isNotYet(.stopping) }

  // - Window controller convenience

  var isRestoring: Bool { pwc.sessionState.isRestoring }
  var isFullScreen: Bool { pwc.isFullScreen }
  var isInInteractiveMode: Bool { pwc.isInInteractiveMode }

  // - Music mode

  /// For explicit request via command line
  var startInMusicModeRequested = false

  var isInMiniPlayer: Bool { pwc.isInMiniPlayer }

  fileprivate var pendingActionOnVidChange: PendingActionOnVidChange = .none
  fileprivate var isShowViewportPendingInMiniPlayer: Bool {
    pendingActionOnVidChange != .none
  }
  /// Calls `self.miniPlayerShowViewportTimerAction`
  let miniPlayerShowVideoTimer = TimeoutTimer(timeout: TimeConstants.musicModeChangeTrackTimeout)

  enum PendingActionOnVidChange {
    case none
    case showViewportInMusicMode
    case exitMusicMode
  }

  // Other state

  let info: PlaybackInfo

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
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    return isActive && (!info._isPaused || (info.playbackTime.positionSec ?? 0.0) > 0.0)
  }

  var canSkipForward: Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return false }
    guard let pos = info.playbackTime.positionSec, let dur = info.playbackTime.durationSec else { return true }
    return !info._isPaused || pos < dur
  }

  var canPlayPrevTrack: Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive, let currentPlayback = info.currentPlayback else { return false }
    return currentPlayback.playlistPos > 1
  }

  var canPlayNextTrack: Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
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
      info.abLoopA
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
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, max(TimeConstants.minLoopPointTime, newValue))
    }
  }

  /// The B loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopB: Double {
    /// Returns the value of the B loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    /// - Returns:value of the mpv option `ab-loop-b`
    get {
      info.abLoopB
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
      mpv.setDouble(MPVOption.PlaybackControl.abLoopB, max(TimeConstants.minLoopPointTime, newValue))
    }
  }

  /// Whether to only use the URL's filename when calculating the mpv
  /// [Watch Later](https://mpv.io/manual/stable/#watch-later) MD5 sum.
  ///
  /// This supports the mpv
  /// [ignore-path-in-watch-later-config](https://mpv.io/manual/stable/#options-ignore-path-in-watch-later-config)
  /// option. As this option is only used by advanced users there is intentionally no support in IINA's UI for this option. This is also an
  /// option that you would set and not change as changing it means existing watch later files will no longer be found. For this reason
  /// IINA does not support dynamic changes to this option. The value of this option is obtained and cached. Setting this option
  /// requires IINA to be restarted.
  lazy var ignorePathInWatchLaterConfig: Bool = {
    let ignorePath = mpv.getFlag(MPVOption.WatchLater.ignorePathInWatchLaterConfig)
    if ignorePath {
      log.debug("Will use filename instead of path when calculating watch later MD5 sum")
    }
    return ignorePath
  }()

  // MARK: - Init

  /// Base constructor (private).
  @MainActor
  private init(_ label: String, isDemoPlayer: Bool = false, priorStateBuildNumber: Int? = nil) {
    let log = Logger.subsystem(forPlayerID: label)
    log.debug("PlayerCore init: starting")
    self.label = label
    self.log = log
    self.info = PlaybackInfo(log: log)
    self.isDemoPlayer = isDemoPlayer
    self.playlistTableChangeNotificationName = .init("uiChangeForPlaylistTable-\(label)")
    self.userOptions = []
    self.priorStateBuildNumber = priorStateBuildNumber ?? InfoDictionary.shared.buildNumber

    super.init()
    self.videoView = VideoView(player: self)
    self.mpv = MPVController(playerCore: self)
    self.uiTimeDebouncer = Debouncer(delay: TimeConstants.uiTimeDebouncerDelay, queue: mpv.queue)
    self.keyBindingContext = PlayerInputContext(playerCore: self)
    self.touchBarSupport = TouchBarSupport(playerCore: self)

    miniPlayerShowVideoTimer.action = miniPlayerShowViewportTimerAction
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
    let priorStateBuildNumber = priorState.int(for: .buildNumber) ?? InfoDictionary.shared.buildNumber
    self.init(label, isDemoPlayer: false, priorStateBuildNumber: priorStateBuildNumber)
    self.userOptions = priorState.mpvUserOpts()

    pwc = PlayerWindowController(playerCore: self, geoSet: priorState.geoSet, initialLayout: priorState.layoutState)
    assert(pwc.sessionState.isNone, "Invalid sessionState for restore: \(pwc.sessionState)")
    pwc.sessionState = .restoring(playerState: priorState)
    log.verbose("PlayerCore init (restore): done")
  }

  /// Demo player has `pwc == nil`.
  @MainActor
  static func buildDemoPlayer() -> PlayerCore {
    let player = PlayerCore(StringConstants.demoPlayerIdentifier, isDemoPlayer: true)

    player.log.verbose("PlayerCore init (demo): done")
    return player
  }

  // MARK: - Additional mpv Options

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
        let shouldPause = opt.val.isEmpty || opt.val == StringConstants.mpvYes
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

    // All newly created sessions use the current build number
    priorStateBuildNumber = InfoDictionary.shared.buildNumber

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

    mpv.resetToDefault(MPVOption.Video.videoZoom)

    mpv.resetToDefault(MPVOption.Equalizer.brightness)
    mpv.resetToDefault(MPVOption.Equalizer.contrast)
    mpv.resetToDefault(MPVOption.Equalizer.saturation)
    mpv.resetToDefault(MPVOption.Equalizer.gamma)
    mpv.resetToDefault(MPVOption.Equalizer.hue)

    mpv.resetToDefault(MPVOption.Video.videoAspectOverride)
    mpv.resetToDefault(MPVOption.Video.videoRotate)

    mpv.resetToDefault(MPVOption.Subtitles.subVisibility)
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubVisibility)
    mpv.resetToDefault(MPVOption.Subtitles.subDelay)
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubDelay)
    mpv.resetToDefault(MPVOption.Subtitles.subPos)
    mpv.resetToDefault(MPVOption.Subtitles.secondarySubPos)
    mpv.resetToDefault(MPVOption.Subtitles.subScale)

    // PlaybackInfo cached values for these will be read in at window open:
    mpv.resetToDefault(MPVOption.PlaybackControl.loopPlaylist)
    mpv.resetToDefault(MPVOption.PlaybackControl.loopFile)

    mpv.resetToDefault(MPVOption.PlaybackControl.speed)

    mpv.resetToDefault(MPVOption.Audio.volume)
    mpv.resetToDefault(MPVOption.Audio.mute)
    mpv.resetToDefault(MPVOption.Audio.audioDelay)
    mpv.resetToDefault(MPVOption.PlaybackControl.abLoopA)
    mpv.resetToDefault(MPVOption.PlaybackControl.abLoopB)

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

  /// Update cached values in bulk (for use when opening player window.
  ///
  /// Some of the controls in Quick Settings, et al, may try to submit these values when their values are initially set.
  /// Pull all of these from mpv to ensure proper source of data sync.
  private func syncPlaybackInfoCacheFromMpv() {
    // Playback

    info.vid = mpv.getInt(MPVOption.TrackSelection.vid)
    info.aid = mpv.getInt(MPVOption.TrackSelection.aid)
    if info.vid == 0 && info.aid == 0 {
      log.warn("Looks like neither video nor audio track selected: media may fail to play!")
    }
    info.sid = mpv.getInt(MPVOption.TrackSelection.sid)
    info.secondSid = mpv.getInt(MPVOption.Subtitles.secondarySid)

    if let loopFile = mpv.getString(MPVOption.PlaybackControl.loopFile) {
      info.loopFile = loopFile
    }
    if let loopPlaylist = mpv.getString(MPVOption.PlaybackControl.loopPlaylist) {
      info.loopPlaylist = loopPlaylist
    }

    syncAbLoop()


    info.playSpeed = mpv.getDouble(MPVOption.PlaybackControl.speed)

    // Subtitles

    info.subScale = mpv.getDouble(MPVOption.Subtitles.subScale)
    info.subPos = mpv.getDouble(MPVOption.Subtitles.subPos)
    info.sub2Pos = mpv.getDouble(MPVOption.Subtitles.secondarySubPos)
    info.subDelay = mpv.getDouble(MPVOption.Subtitles.subDelay)
    info.sub2Delay = mpv.getDouble(MPVOption.Subtitles.secondarySubDelay)
    info.subFontSize = mpv.getInt(MPVOption.Subtitles.subFontSize)
    info.isSubVisible = mpv.getFlag(MPVOption.Subtitles.subVisibility)
    info.isSecondSubVisible = mpv.getFlag(MPVOption.Subtitles.secondarySubVisibility)

    // Video

    info.brightness = mpv.getInt(MPVOption.Equalizer.brightness)
    info.contrast = mpv.getInt(MPVOption.Equalizer.contrast)
    info.saturation = mpv.getInt(MPVOption.Equalizer.saturation)
    info.gamma = mpv.getInt(MPVOption.Equalizer.gamma)
    info.hue = mpv.getInt(MPVOption.Equalizer.hue)

    if let hwdec = mpv.getString(MPVOption.Video.hwdec) {
      info.hwdec = hwdec
    }
    info.deinterlace = mpv.getFlag(MPVOption.Video.deinterlace)

    // Audio

    info.volume = mpv.getDouble(MPVOption.Audio.volume)
    info.volumeMax = mpv.getInt(MPVOption.Audio.volumeMax)
    // `info.maxVolume` will be reset in `mpvSetInitialOptions`
    info.isMuted = mpv.getFlag(MPVOption.Audio.mute)
    info.audioDelay = mpv.getDouble(MPVOption.Audio.audioDelay)
  }
  // MARK: - Opening Media

  @MainActor
  @discardableResult
  func openURL(_ url: URL) -> Int? {
    return openURLs([url])
  }

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

    PlayerCore.mouseLocationAtLastOpen = NSEvent.mouseLocation
    openedWindowsSetIndex = 0  // reset

    let urls = Utility.resolveURLs(urls)
    let ids = urls.map{ MediaMetaCache.shared.getBestPlaybackID(forURL: $0) }
    return openPlaybackIDs(ids)
  }

  /// Returns number of playable URLs opened. If `0`, no player window was opened.
  @MainActor
  @discardableResult
  func openURLString(_ str: String) -> Int {
    if let id = PlaybackID(path: str) {
      return openPlaybackIDs([id])
    }
    return 0
  }

  @MainActor
  @discardableResult
  func openPlaybackIDs(_ ids: [PlaybackID]) -> Int {
    log.debug("OpenPlaybackIDs: \(ids.map{$0.path.pii})")

    // Handle folder URL (to support mpv shuffle, etc), BD folders and m3u / m3u8 files first.
    // For these cases, mpv will load/build the playlist and notify IINA when it can be retrieved.
    if ids.count == 1,
       ids[0].isStdin
        || isBDFolder(ids[0].staticURL)
        || Utility.playlistFileExt.contains(ids[0].staticURL.absoluteString.lowercasedPathExtension) {

      info.shouldAutoLoadFiles = false
      openPlayerWindow(ids)
      return 1
    }
    // Else open multiple URL args...

    // Filter URL args for playable files (video/audio), because mpv will "play" image files, text files (anything?)
    let playableFiles = getPlayableFiles(in: ids, organizeList: true)

    log.verbose("Found \(playableFiles.count) playable files for \(ids.count) requested URLs")
    // check playable files count
    guard playableFiles.count > 0 else {
      return 0
    }

    // If pwc is nil, it is not restoring
    info.shouldAutoLoadFiles = AppDelegate.shared.isInteractiveLaunch && playableFiles.count == 1
    &&  (pwc == nil || !pwc.sessionState.isRestoring)

    // open the first file
    openPlayerWindow(ids)
    return playableFiles.count
  }

  /// Loads the first URL into the player, and adds any remaining URLs to playlist.
  /// The caller must ensure that `urls` is *never* empty!
  @MainActor
  private func openPlayerWindow(_ ids: [PlaybackID]) {
    guard !isDemoPlayer else { log.fatalError("Cannot open player window for demo player!") }
    guard ids.count > 0 else { log.fatalError("Cannot open player window: empty url list!") }

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
    let playback = Playback(ids[0], playlistPos: 0)

    if playback.isNetworkResource, isInteractivePlayer {
      AppDelegate.shared.openURLWindow.showLoadingScreen(playerCore: self)
    }
    if isIdleOrUnused {
      // Set info.currentPlayback immediately to ensure it is non-nil. This is a workaround for the case of opening
      // multiple player windows at once, which will repeatedly call PlayerManager's getIdleOrCreateNew(). By
      // synchronously setting currentPlayback before the next iteration in the loop, we ensure that we don't
      // end up returning the same player multiple times.
      info.currentPlayback = playback
    }
    __openPlayerWindow(ids, playback, isInteractivePlayer: isInteractivePlayer)
  }

  private func __openPlayerWindow(_ ids: [PlaybackID], _ playback: Playback, isInteractivePlayer: Bool) {
    /// Put work on top of mpv queue so that prev use of mpv core can finish stopping / drain queue
    mpv.queue.async { [self] in
      let path = playback.path
      info.currentPlayback = playback
      log.debug("Opening player (window=\(isInteractivePlayer.yesno)) for \(path.pii.quoted), playerState=\(state), sessionState=\(pwc.sessionState)")

      if state == .stopping {
        // Player was previously started, but closed & is now being reopened
        state = .started
      }

      info.hdrEnabled = Preference.bool(for: .enableHdrSupport)

      DispatchQueue.main.async { [self] in
        let sessionState = pwc.sessionState

        switch sessionState {
        case .restoring, .creatingCLI:
          break
        default:
          if isInteractivePlayer {
            pwc.osd.queue.clear()
          }
          pwc.sessionState = sessionState.newSession()
        }

        if isInteractivePlayer {
          pwc.openWindow(nil)
        }

        let volRemountURLs: [String: Bool]
        if case .restoring = sessionState,
           let playerToRestore = AppDelegate.shared.startupHandler.playersToRestore.removeValue(forKey: WindowAutosaveName(window.savedStateName)!) {
          // This is the last bit of work for this player which requires volume remount info
          volRemountURLs = playerToRestore.volRemountsProcessed
        } else {
          volRemountURLs = [:]
        }

        mpv.queue.async { [self] in
          guard !isStopping else { return }

          switch sessionState {
          case .restoring, .creatingCLI:
            break
          default:
            resetOptionsForNewSession(reuseExistingWindow: sessionState.hasOpenSession)
          }

          // If this mpv core is being reused icc-profile-auto may have been left set to true. This option
          // MUST be reset to false to avoid a crash that occurs if the mpv OSD is being used. Another way
          // to fix this would be to add this option to the mpv reset-on-next-file option. However the
          // user might override IINA and set that option themselves and not include icc-profile-auto.
          // Better to directly reset icc-profile-auto. See issue #5727 for details.
          mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)

          // Send load file command
          mpv.command(.loadfile, args: [path])

          let playlistPlaybackIDs: [PlaybackID]
          let playlistPos: Int?

          if case .restoring(let priorState) = sessionState {

            priorState.restoreMpvProperties(to: self)

            /// Player was already paused in `PlayerSaveState.restoreTo()`.
            if Preference.bool(for: .alwaysPauseMediaWhenRestoringAtLaunch) {
              pendingResumeWhenShowingWindow = false
            } else if let wasPaused = priorState.bool(for: .paused) {
              pendingResumeWhenShowingWindow = !wasPaused
            } else {
              pendingResumeWhenShowingWindow = !shouldPauseOnFileOpen()
              log.warn("Could not determine pause state to restore; falling back using prefs: willResume=\(pendingResumeWhenShowingWindow.yn)")
            }

            playlistPlaybackIDs = priorState.restorePlaylistIDs(volRemounts: volRemountURLs)
            playlistPos = priorState.int(for: .playlistPos)

          } else {  // Not restoring

            playlistPlaybackIDs = ids
            playlistPos = 0

            if isInteractivePlayer {
              // Pause until window opens, to avoid blips or other loading unpleasantness.
              mpv.setFlag(MPVOption.PlaybackControl.pause, true)

              let shouldStayPaused = shouldPauseOnFileOpen()
              pendingResumeWhenShowingWindow = !shouldStayPaused
              log.debug("Paused playback until window is done opening; will resume when shown=\(pendingResumeWhenShowingWindow.yn)")
            } else {
              log.verbose("Player is non-interactive; skipping playback pause prior to window open")
              pendingResumeWhenShowingWindow = false
            }

            if Preference.bool(for: .autoRepeat) {
              let loopMode = Preference.DefaultRepeatMode(rawValue: Preference.integer(for: .defaultRepeatMode))
              setLoopMode(loopMode == .file ? .file : .playlist)
            }

          }

          if playlistPlaybackIDs.count > 1 {
            log.verbose("Adding \(playlistPlaybackIDs.count - 1) files to playlist. PlaylistPos="
                        + String(describing: playlistPos) + " Autoload=\(info.shouldAutoLoadFiles.yn)")
            addAllToPlaylist(playbackIDsIncludingCurrent: playlistPlaybackIDs, indexOfCurrentItem: playlistPos)
          } else {
            // Only one entry in playlist, but still need to pull it from mpv
            log.verbose("Only 1 entry in playlist & not restoring; doing initial reload of playlist")
            _reloadPlaylist()
          }

          syncPlaybackInfoCacheFromMpv()
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
#endif

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

    // Start mpv
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
  func shutdown() {
    mpv.queue.async { [self] in
      _shutdown()
    }
  }

  func _shutdown() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
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
  func mpvHasShutdown() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    let isMPVInitiated = state.isAtLeast(.started) && state.isNotYet(.shuttingDown)
    let suffix = isMPVInitiated ? " (initiated by mpv)" : ""
    log.debug("Player has shut down\(suffix)")
    state = .shuttingDown
    // If mpv shutdown was initiated by mpv then the player state has not been saved.
    if isMPVInitiated {
      if !isDemoPlayer {
        savePlaybackMetaBeforePlayerWillStop() // Save state to mpv watch-later (if enabled)
      }
      mpv.removeObservers()
    }
    state = .shutDown

    DispatchQueue.main.async { [self] in
      videoView.uninit()       // Shut down DisplayLink. Has its own lock.
      mpv.mpvDestroy()
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

  func shouldPauseOnFileOpen() -> Bool {
    getPauseFromUserOptions() ?? Preference.bool(for: .pauseWhenOpen)
  }

  func togglePause() {
    mpv.queue.async { [self] in
      _togglePause()
    }
  }

  func _togglePause() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    info._isPaused ? _resume() : _pause()
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
      pwc.updatePlayButtonAndSpeedUI(isPaused: true)
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
      videoView.displayActive()  // pre-empt for faster responsiveness
      pwc.updatePlayButtonAndSpeedUI(isPaused: false)
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

    guard Preference.bool(for: .resumeFromEndRestartsPlayback) && info.playbackTime.isAtEOF else {
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

      // If the user immediately closes the player window it is possible the background task may still
      // be working to load subtitles. Invalidate the ticket to get that task to abandon the work.
      $postLoadBGQTicket.withLock { $0 += 1 }
      shutDownPlayerThumbnails()

      // Reset playback state
      info.playbackTime = .nullTime
      info.playlist = []

      info.$matchedSubs.withLock { $0.removeAll() }

      if let pwc, pwc.loaded {
        pwc.playlistView.clearBackgroundQueue()

        // Do not enqueue after window is closed (and info.currentPlayback is nil)
        sendOSD(.stop)
        DispatchQueue.main.async { [self] in
          displayedPlaylist = []  // reset to match info.playlist
          videoView.stopDisplayLink()
        }
      }

      if !mpv.getFlag(MPVOption.PlaybackControl.pause) {
        log.debug("Pausing playback before sending stop command")
        mpv.setFlag(MPVOption.PlaybackControl.pause, true, level: .verbose)
      }

      // Do not send a stop command to mpv if it is already stopped. This happens when quitting is
      // initiated directly through mpv.
      log.debug("Stopping playback")

      mpv.command(.stop)
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
      if let duration = info.playbackTime.durationSec,
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
    case .relative:
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

  @MainActor
  func frameStep(backwards: Bool) {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // It must be running when stepping to avoid slowdowns caused by mpv waiting for IINA to call
    // mpv_render_report_swap.
    videoView.displayActive()
    __frameStep(backwards: backwards)
  }

  /// Standalone func to avoid Xcode isolation warning
  private func __frameStep(backwards: Bool) {
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
      guard let pwc else { return }
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

  func screenshotRawCallback(_ screenshotImage: NSImage) {
    DispatchQueue.main.async { [self] in
      let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
      if saveToClipboard {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([screenshotImage])
      }

      let saveToFile = Preference.bool(for: .screenshotSaveToFile)
      if saveToFile {
        // FIXME: implement save to file
      }

      guard Preference.bool(for: .screenshotShowPreview) else {
        sendOSD(.screenshot)
        return
      }

      guard let pwc else { return }
      let screenshotViewController = ScreenshootOSDView()
      // Shrink to some fraction of the currently displayed video
      let relativeSize = pwc.videoView.frame.size * 0.3
      let previewImageSize = screenshotImage.size.shrink(toSize: relativeSize)
      screenshotViewController.setImage(screenshotImage,
                                        size: previewImageSize,
                                        fileURL: nil)

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
    guard isInteractivePlayer, isActive else { return }

    // Obtain the values of the ab-loop-a and ab-loop-b options representing the A & B loop points.
    let a = mpv.getDouble(MPVOption.PlaybackControl.abLoopA)
    let b = mpv.getDouble(MPVOption.PlaybackControl.abLoopB)
    let loopCount = mpv.getString(MPVOption.PlaybackControl.abLoopCount)
    let didChange = (info.abLoopA != a) || (info.abLoopB != b)
    info.abLoopA = a
    info.abLoopB = b
    info.abLoopCount = loopCount ?? "0"

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
      pwc.playSliderCell.syncABLoop(info, a: a, b: b)
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
    return info.loopMode
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
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    log.verbose("Setting speed to \(speed)")
    mpv.setDouble(MPVOption.PlaybackControl.speed, speed)

    /// If `resetSpeedWhenPaused` is enabled, then speed is reset to 1x when pausing.
    /// This will create a subconscious link in the user's mind between "pause" -> "unset speed".
    /// Try to stay consistent by linking the contrapositive together: "set speed" -> "play".
    /// The intuition should be most apparent when using the speed slider in Quick Settings.
    if info._isPaused {
      if forceResume == true {
        _resume()
      } else if forceResume == nil && Preference.bool(for: .resetSpeedWhenPaused) {
        _resume()
      }
    }
  }

  /// Called with `MPVOption.PlaybackControl.pause` changed
  func pausedStateDidChange(to paused: Bool) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    let didChange = info.isPausedRemotely != paused
    info.isPausedRemotely = paused
    info.isPausedLocally = nil
    guard didChange else { return }

    if !paused {
      if state == .stopping {
        state = .started
      }
    }

    guard let pwc, pwc.loaded else { return }
    // Avoid race condition in moments between playback & pause state changes
    let hasPlayback = info.currentPlayback != nil
    DispatchQueue.main.async { [self] in
      pwc.updatePlayButtonAndSpeedUI(isPaused: paused)
      if paused || !hasPlayback {
        videoView.displayIdle()
      } else {  // resume
        videoView.displayActive()
      }
      if let pos = info.playbackTime.positionSec, let dur = info.playbackTime.durationSec {
        let osdMsg: OSDMessage = paused ? .pause(posSec: pos, durSec: dur) :
          .resume(posSec: pos, durSec: dur)
        sendOSD(osdMsg)
      }
      saveState()  // record the pause state
      if pwc.currentLayout.isInPiP {
        pwc.pip.controller?.playing = !paused
      }

      if pwc.loaded, Preference.bool(for: .alwaysFloatOnTop) {
        pwc.setWindowFloatingOnTop(!paused, from: pwc.currentLayout)
      }
    }
  }

  func speedDidChange(to speed: CGFloat) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    info.playSpeed = speed
    guard isInteractivePlayer else { return }
    sendOSD(.speed(speed))
    saveState()  // record the new speed
    let paused = info._isPaused
    DispatchQueue.main.async { [self] in
      pwc.updatePlayButtonAndSpeedUI(isPaused: paused)
    }
  }

  /// Called when `MPVOption.Video.videoRotate` changed
  func userRotationDidChange(to userRotation: Int) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded else { return }

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
  @MainActor
  func setVideoAspectOverride(_ aspectString: String) {
    guard !isRestoring else { return }
    guard let pwc else { return }

    let aspectLabel: String = Aspect.bestLabelFor(aspectString)
    guard pwc.geo.video.userAspectLabel != aspectLabel else { return }
    sendVideoAspectOverrideToMpv(aspectLabel: aspectLabel)
  }

  func sendVideoAspectOverrideToMpv(aspectLabel: String) {
    mpv.queue.async { [self] in
      _sendVideoAspectOverrideToMpv(aspectLabel: aspectLabel)
    }
  }

  func _sendVideoAspectOverrideToMpv(aspectLabel: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    var mpvValue = Aspect.mpvVideoAspectOverride(fromAspectLabel: aspectLabel)
    if mpvValue == StringConstants.mpvNo {
      /// mpv doc says that `-1` means: `strictly prefer the container aspect ratio`.
      // Note that the mpv doc says this value is deprecated, and that "no" should be used instead,
      // but that does not work properly for some videos.
      mpvValue = "-1.0"
    }
    log.verbose("Setting mpv video-aspect-override ≔ \(mpvValue.quoted)")
    mpv.setString(MPVOption.Video.videoAspectOverride, mpvValue)
  }

  @MainActor
  var shouldAlwaysHideCursor: Bool {
    if info.cursorAutoHideFullScreenOnly && !isFullScreen {
      return false
    }
    return info.cursorAutoHideTimeoutMs == 0
  }

  @MainActor
  var canHideCursor: Bool {
    if info.cursorAutoHideFullScreenOnly && !isFullScreen {
      return false
    }
    return info.enableCursorAutoHide
  }

  func updateCursorAutohideState() {
    let cursorAutoHideFullScreenOnly = mpv.getFlag(MPVOption.Window.cursorAutohideFsOnly)
    guard let autoHide = mpv.getString(MPVOption.Window.cursorAutohide) else { return }
    DispatchQueue.main.async { [self] in
      if autoHide == "always" {
        info.cursorAutoHideTimeoutMs = 0
      } else if autoHide == "no" {
        info.cursorAutoHideTimeoutMs = -1000
      } else if let autoHideMs = Int(autoHide) {
        info.cursorAutoHideTimeoutMs = autoHideMs
      }

      info.cursorAutoHideFullScreenOnly = cursorAutoHideFullScreenOnly
    }
  }

  func syncVideoParamsFromMpv() {
    guard let pwc, pwc.loaded else { return }
    guard !isRestoring else {
      log.trace("Ignoring SyncVidGeo request: isRestoring=Y")
      return
    }

    pwc.animationPipeline.enqueueVideoSyncTaskIfNeeded(self)
  }

  func setVideoRotate(_ userRotation: Int) {
    mpv.queue.async { [self] in
      guard Constants.rotations.firstIndex(of: userRotation)! >= 0 else {
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
    let value = String(describing: Preference.enum(for: .hardwareDecoder) as
                       Preference.HardwareDecoderOption)
    mpv.queue.async { [self] in
      guard isActive else { return }
      mpv.setString(MPVOption.Video.hwdec, enable ? value : "no")
    }
  }

  func getVideoZoom() -> Double {
    let logZoom = mpv.getDouble(MPVOption.Video.videoZoom)
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
          Utility.showAlert("unsupported_video")
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

  @MainActor @discardableResult
  func playChapter(_ pos: Int) -> MPVChapter? {
    log.verbose("Seeking to chapter \(pos)")
    let chapters = info.chapters
    guard pos < chapters.count else {
      return nil
    }
    let chapter = chapters[pos]
    __playChapterAsync(chapter)
    return chapter
  }

  /// Separate method to avoid compiler isolation warning
  private func __playChapterAsync(_ chapter: MPVChapter) {
    mpv.queue.async { [self] in
      // Update playbackPositionSec preemptively, so UI doesn't flash
      // to prev chapter and back
      info.playbackTime = info.playbackTime.clone(positionSec: chapter.startTime)
      guard isActive else { return }
      mpv.command(.seek, args: ["\(chapter.startTime)", "absolute"])
      _resume()
    }
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
    HistoryController.shared.savePlaybackMetaBeforeFileWillClose(id, duration: info.playbackTime.durationSec, position: info.playbackTime.positionSec)
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

    // TODO: do something with this
    let parentPlaylist = mpv.getString(MPVProperty.playlistPath) ?? ""

    guard let playbackFromPath = Playback(urlPath: path, playlistPos: playlistPos, parentPlaylist: parentPlaylist, state: .started) else {
      log.error("FileStarted: failed to create media from path \(path.pii.quoted)")
      return
    }

    log.verbose("FileStarted: playbackPath=\(path.pii.quoted), PL#=\(String(playbackFromPath.playlistPos))")
    info.currentPlayback = playbackFromPath

    MemoryUsage.shared.logUsage("after file started")

    // Stop watchers from prev media (if any)
    stopWatchingSubFile()

    if let pwc, pwc.loaded {
      DispatchQueue.main.async {
        // Check this inside main DispatchQueue
        // TableView whole table reload is very expensive. No need to reload entire playlist; just the two changed rows:
        pwc.playlistView.refreshNowPlayingIndex(thenScrollToVisible: true)

        MediaPlayerIntegration.shared.update()
      }
    }

    // set "date last opened" attribute
    if let url = info.currentURL, url.isFileURL, !info.isMediaOnRemoteDrive {
      let time = CFAbsoluteTimeGetCurrent()
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

    sendOSD(.fileStart(playbackFromPath.displayName, ""))

    log.verbose("FileStarted: done")
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

    if self.isDemoPlayer {
      log.verbose("DEMO PLAYER LOADED")
    }

    if let pwc, pwc.loaded {
      // mpv will play when loaded by default. But if we are opening a new window or starting a new session in an existing window,
      // we will have told mpv to pause the playback, and we should not unpause the playback until we are ready to show the window.
      if pwc.sessionState.isRestoring {
        // If restoring, playback was already paused, & will not be unpaused until window is ready to show (see `showWindow`)
        // Finally call this to update info.vid & related video track state in VideoView:
        updateVidStateFromMpv()
      } else if pwc.sessionState.hasOpenSession {
        // Note: we only need to handle existing session here.
        // New session or reuse of existing will be handled in openWindow().
        // Traditionally IINA will un-pause when starting a new file, unless it is configured to do otherwise.
        // So we should also be setting this value one way or another.
        let shouldPause = getPauseFromUserOptions() ?? Preference.bool(for: .pauseWhenOpen)
        log.verbose("FileLoaded: in existing session: setting pause=\(shouldPause.yn)")
        mpv.setFlag(MPVOption.PlaybackControl.pause, shouldPause)
      }

      DispatchQueue.main.async {
        pwc.videoView.displayActive()
      }
    }

    log.verbose("FileLoaded: getting playback time info")
    info.playbackTime = mpv.getPlaybackTimeInfo()

    triedUsingExactSeekForCurrentFile = false
    // Playback will move directly from stopped to loading when transitioning to the next file in
    // the playlist.
    if state == .stopping {
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

    log.verbose("FileLoaded: reloading track info")
    if !reloadTrackInfo() {
      // TODO: can this ever happen here?! May need to terminate player if so
      log.error("FileLoaded: no tracks returned by mpv! Returning early…")
      return
    }

    // Kick off thumbnails load/gen - it can happen in background
    reloadThumbnails()

    checkUnsyncedWindowOptions()

    // Cache these vars to keep them constant for background tasks
    let priorStateIfRestoring = pwc?.priorStateIfRestoring
    let isRestoring = priorStateIfRestoring != nil

    // Sync tracks
    if let priorStateIfRestoring, priorStateIfRestoring.string(for: .playPosition) != nil {
      /// Need to manually clear this, because mpv will try to seek to this time when any item in playlist
      /// is started. Run this on the mpv queue to ensure proper ordering.
      log.verbose("Clearing mpv 'start' option now that restore is complete")
      mpv.setString(MPVOption.PlaybackControl.start, StringConstants.mpvArgNone)

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
    let currentTicket = $postLoadBGQTicket.withLock { latestTicket in
      latestTicket += 1
      return latestTicket
    }
    let currentPlaylist = info.playlist
    PlayerCore.postLoadBGQ.asyncAfter(deadline: DispatchTime.now() + TimeConstants.autoLoadDelay) { [self] in
      fileLoaded_doPostLoadBGQWork(for: currentPlayback, currentPlaylist: currentPlaylist,
                                   currentTicket: currentTicket,
                                   shouldAutoLoadFiles: shouldAutoLoadFiles,
                                   priorStateIfRestoring: priorStateIfRestoring)
    }

    // History thread: update history given new playback URL. If restoring a prev playback, do not add again
    if let playbackID = info.currentPlayback?.id, !isRestoring {
      let mediaTitle = mpv.getString(MPVProperty.mediaTitle)
      let ignorePathForMD5 = mpv.getFlag(MPVOption.WatchLater.ignorePathInWatchLaterConfig)
      // Pass nil as positionSec for now, to reflect mpv watch-later state. The watch-later info is deleted when a file is
      // opened. Later if we implement our own position tracking, we can do something more intuitive.
      HistoryController.shared.savePlaybackMetaAfterFileDidLoad(for: playbackID,
                                                                durationSec: info.playbackTime.durationSec ?? 0.0,
                                                                positionSec: nil,
                                                                title: mediaTitle,
                                                                ignorePathForMD5)
    }
  }

  /// If `dueToStopCommand` is true, it can be assumed that no error has occurred (and thus `errorDetail` is unused).
  func fileEnded(dueToStopCommand: Bool, errorDetail: String) {
    // if receive end-file when loading file, might be error
    // wait for idle
    if info.isFileLoaded {
      // Unsure why this line exists. Cancel autoload(?)
      info.shouldAutoLoadFiles = false
    } else {
      if !dueToStopCommand {
        errorWhileLoading = errorDetail
      }
    }
    if dueToStopCommand {
      // Can indicate changing current playback (e.g. via playlist navigation), or if player is quitting
      DispatchQueue.main.async { [self] in
        postNotification(.iinaPlayerStopped)
      }
    }
    MemoryUsage.shared.logUsage("after file ended")
  }

  /// The mpv [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list)
  /// property changed.
  /// - Important: The mpv [audio-device](https://mpv.io/manual/stable/#command-interface-audio-device)
  ///     property value is not guaranteed to reflect the audio device that is actually in use. When a selected device is removed the
  ///     value of this property continues to reflect the device that is no longer present even though `libmpv` has switched to
  ///     another audio device. This will cause the IINA `Audio Device` menu to malfunction. To handle the problematic behavior
  ///     of the `audio-device` property, whenever the device list changes this method checks if the device returned by
  ///     `audio-device` is present in the new list of audio devices. If the audio device cannot be found the `audio-device`
  ///     property is set to `auto` so that both IINA and mpv are in agreement on the selected audio device. For more information
  ///     see issue [#6034](https://github.com/iina/iina/issues/6034).
  func audioDeviceListChanged() {
    guard isActive else { return }
    let devices = getAudioDevices()
    let device = mpv.getString(MPVProperty.audioDevice)
    guard !devices.contains(where: {$0.name == device}) else { return }
    log.debug("Selected audio device is no longer present, setting selected device to auto")
    setAudioDevice("auto")
  }

  func chapterChanged() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard isActive else { return }
    let chapter = Int(mpv.getInt(MPVProperty.chapter))
    DispatchQueue.main.async { [self] in
      log.verbose("Δ mpv prop: 'chapter' = \(chapter)")
      info.chapter = chapter
    }
    syncUIChapterList()
    mediaTitleChanged()
  }

  func idleActiveChanged() {
    let isFileLoaded = info.isFileLoaded
    let errorMsg = errorWhileLoading
    log.verbose("Got mpv 'idle-active': isFileLoaded=\(isFileLoaded.yn) error=\(errorMsg?.quoted ?? "nil") playerState=\(state)")
    /// Make sure to check that `info.currentPlayback != nil` before outputting error
    if let errorMsg, let playback = info.currentPlayback, !isFileLoaded {
      log.error("Received 'file-ended' + 'idle-active' from mpv while loading \(playback.path.pii.quoted)!"
                + " Will stop player\(isInteractivePlayer ? " & close window" : "")")
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
      DispatchQueue.main.async { [self] in
        videoView.displayIdle()
      }
    }
  }

  func mediaTitleChanged() {
    guard isActive else { return }
    DispatchQueue.main.async { [self] in
      guard let pwc, pwc.isOpen else { return }
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

  /// First (1) gets the latest playback time & cache info, then (2) updates the UI controls with these values.
  ///
  /// There will be some delay before the final UI update due to the use of queues, and the use
  /// of `uiTimeDebouncer` will throttle the frequency of updates.
  func syncTimeAndCacheUI() {
    uiTimeDebouncer.run { [self] in
      assert(DispatchQueue.isExecutingIn(mpv.queue))
      guard let (timeInfo, cacheState, rangesDidChange) = updatePlaybackInfo() else { return }
      let isPaused = info._isPaused

      DispatchQueue.main.async { [self] in
        pwc.updateUIControls(timeInfo, cacheState, rangesDidChange: rangesDidChange, isPaused: isPaused)
      }
    }
  }

  func playbackRestarted() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    log.debug("Playback restarted")

    // Important to synchronize the time as mpv may slightly alter the playback position during a
    // restart even while paused. See issue #5337.
    syncTimeAndCacheUI()
    saveState()
    let isPaused = info._isPaused

    DispatchQueue.main.async { [self] in
      info.isSeeking = false

      // When playback is paused the display link may be shutdown in order to not waste energy.
      // The display link will be restarted while seeking. If playback is paused shut it down again.
      if isPaused {
        videoView.displayIdle()
      }

      // End of seeking? Set short timer to hide seek time & thumbnail
      pwc?.seekPreview.restartHideTimer()
    }
  }

  func refreshEdrMode() {
#if !USE_GPU_NEXT
    guard let pwc, pwc.loaded else { return }
    pwc.animationPipeline.submitInstantTask { [self] in
      videoView.refreshEdrMode()
    }
#endif
  }

  /// *Enqueues*
  func setQuickSettingsViewNeedsUpdate() {
    guard let pwc, pwc.loaded else { return }
    pwc.animationPipeline.doAfterGTFs{ [self] in
      // Bit of a kludge: often we are called in response to video settings changes (e.g. sub-scale changed),
      // which may need to do a forced draw if paused to show the changes. But since `displayActive` needs
      // to be called via the main actor, just call it here instead of trying to add a separate animation task
      // to every case, which clutters the code and has higher risk of bugs from missing something.
      pwc.videoView.displayActive()
      reloadQuickSettingsViewNow()
    }
  }

  @MainActor
  func reloadQuickSettingsViewNow() {
    guard !isStopping else { return }
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

    if let pos = info.playbackTime.positionSec, let dur = info.playbackTime.durationSec {
      sendOSD(.seek(posSec: pos, durSec: dur))
    }
  }

  // MARK: - Background work

  /// Auto load via background queue
  private func fileLoaded_doPostLoadBGQWork(for currentPlayback: Playback,
                                            currentPlaylist: [PlaybackID],
                                            currentTicket: Int,
                                            shouldAutoLoadFiles: Bool,
                                            priorStateIfRestoring: PlayerSaveState?) {
    assert(DispatchQueue.isExecutingIn(PlayerCore.postLoadBGQ))
    let isRestoring = priorStateIfRestoring != nil

    guard currentTicket == postLoadBGQTicket else { return }

    loadBookmark(forCurrentPlayback: currentPlayback)

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
        guard currentTicket == postLoadBGQTicket else { return }
        loadExternalSubFile(sub)
      }
      if !isRestoring {
        // set sub to the first one
        // TODO: why?
        log.debug("Setting subtitle track to because an external sub was found")
        guard currentTicket == postLoadBGQTicket, mpv.mpv != nil else { return }
        setTrack(1, forType: .sub)
      }
    }

    // Search for online subtitles, auto-load if found
    if Preference.bool(for: .autoSearchOnlineSub) &&
        !info.isNetworkResource &&
        info.subTracks.isEmpty &&
        (info.playbackTime.durationSec ?? 0.0) >= Preference.double(for: .autoSearchThreshold) * 60 {
      pwc.menuFindOnlineSub(pwc)
    }

    guard currentTicket == postLoadBGQTicket, mpv.mpv != nil else { return }

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

    // Create bookmarks for playlist items (if not already done).
    // This can be expensive - perhaps ~1sec per item!
    let swGenBMs = Utility.Stopwatch()
    let playlisttItemsMissingBookmarks = currentPlaylist.filter{ !$0.isNetworkResource && $0.bookmark == nil }
    var progress = 0
    for item in playlisttItemsMissingBookmarks {
      guard currentTicket == postLoadBGQTicket else { return }
      if MediaMetaCache.shared.addBookmarkIfMissingOrStale(fromURL: item.url) {
        progress += 1
      }
    }
    log.verbose("Filled in \(progress) / \(playlisttItemsMissingBookmarks.count) missing bookmarks for playlist (\(currentPlaylist.count) total) in "
                + swGenBMs.secElapsedString)

    mpv.queue.async { [self] in
      // Attach bookmarks to playlist items (relatively inexpensive operations)
      let swAttachBMs = Utility.Stopwatch()
      guard currentTicket == postLoadBGQTicket else { return }
      let playlist = info.playlist
      log.verbose("Updating \(playlist.count) playlist items with bookmark(s)")
      var updatedPlaylist: [PlaybackID] = []
      for item in playlist {
        guard currentTicket == postLoadBGQTicket else { return }
        let itemUpdated = MediaMetaCache.shared.getPlaybackIDWithBookmark(forID: item)
        updatedPlaylist.append(itemUpdated)
      }
      info.playlist = updatedPlaylist
      log.verbose("Done updating playlist items with bookmarks in \(swAttachBMs.secElapsedString)")
    }
  }

  /**
   Add files in the same folder to playlist.
   It basically follows the following steps:
   - Get all files in current folder. Group and sort videos and audios, and add them to playlist.
   - Scan subtitles from search paths, combined with subs got in previous step.
   - Try match videos and subs by series and filename.
   - For unmatched videos and subs, perform fuzzy (but slow, O(n^2)) match for them.

   **Remark**:

   This method is expected to be executed in `postLoadBGQ` (see `postLoadBGQTicket`).
   Therefore accesses to `self.info` and mpv playlist must be guarded.
   */
  private func autoLoadFilesInCurrentFolder(ticket: Int) {
    AutoFileMatcher(player: self, ticket: ticket).startMatching()
  }

  /// Returns a MacOS bookmark for the given playback, if possible.
  /// If a cached bookmark is found, returns that. Otherwise a new bookmark will attempt to be generated. If successful, it will be cached and returned.
  @discardableResult
  func loadBookmark(forCurrentPlayback currentPlayback: Playback) -> Data? {
    if let bookmark = currentPlayback.id.bookmark {
      return bookmark
    }
    guard currentPlayback.id.needsBookmark else { return nil }
    guard let bookmarkData = MediaMetaCache.shared.getOrCreateBookmark(fromURL: currentPlayback.url) else {
      log.verbose("Failed to create bookmark for playback: \(currentPlayback.path.pii.quoted)")
      return nil
    }
    // Update cached PlaybackID with bookmark
    let idWithBookmark = PlaybackID(currentPlayback.id.url, bookmark: bookmarkData)
    mpv.queue.async { [self] in
      guard isActive else { return }
      guard let currentPlayback = info.currentPlayback, currentPlayback.id.url == idWithBookmark.url else { return }
      log.verbose("Adding bookmark data to currentPlayback")
      info.currentPlayback = currentPlayback.clone(id: idWithBookmark)
    }
    return bookmarkData
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
            if let result {
              setSubFont(result)
            }
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
      mpv.command(.subAdd, args: [urlPath], checkError: false, level: .verbose) { [self] code in
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
    guard let pwc, pwc.loaded else { return }
    guard encoding != info.subEncoding else { return }
    log.verbose("Δ mpv prop: `sub-codepage` = \(encoding)")
    info.subEncoding = encoding
    reloadAllSubs()
  }

  func sidChanged(to sid: Int? = nil, silent: Bool = false, reloadTracksIfNotFound: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded, !pwc.sessionState.isRestoring, !isStopping else { return }
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
    guard let pwc, pwc.loaded, !isRestoring, !isStopping else { return }
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

  // MARK: - Sync UI with Playback State

  /// Checks unsynchronized window options, such as those set via mpv before window loaded.
  ///
  /// These options currently include fullscreen and ontop.
  private func checkUnsyncedWindowOptions() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded, isActive else { return }

    syncFullScreenState()
    syncOntopState()
  }

  func syncOntopState() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded, isActive else { return }

    let ontop = mpv.getFlag(MPVOption.Window.ontop)
    if ontop != pwc.isOnTop {
      log.verbose("IINA OnTop state (\(pwc.isOnTop.yn)) does not match mpv (\(ontop.yn)); will change to match mpv state")
      DispatchQueue.main.async {
        pwc.setWindowFloatingOnTop(ontop, from: pwc.currentLayout, updateOnTopStatus: false)
      }
    }
  }

  func syncFullScreenState() {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded else { return }

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
        DispatchQueue.main.async {
          if mpvFS {
            pwc.enterFullScreen()
          } else {
            pwc.exitFullScreen()
          }
        }
      }
    }
  }

  func updatePlaybackInfo() -> (playbackTime: PlaybackTimeInfo, cacheState: CacheState?, rangesDidChange: Bool)? {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    guard !isStopping else {
      log.trace("SyncUI: not syncing: player not active")
      return nil
    }

    // Apparently adding this check fixes an issue at startup where `mpv.getFlag(MPVProperty.eofReached)`(below) can deadlock
    guard let currentPlayback = info.currentPlayback else {
      log.verbose("SyncUI: not syncing: current playback is nil")
      return nil
    }

    let timeInfo = mpv.getPlaybackTimeInfo()

    let cacheState: CacheState?
    let rangesDidChange: Bool
    if currentPlayback.isNetworkResource || Preference.bool(for: .showCachedRangesInSlider) {
      let cacheStateOld = info.cacheState
      let cacheStateNew = mpv.getCacheState()
      cacheState = cacheStateNew

      if cacheStateOld.isBufferUnderrun && !cacheStateNew.isBufferUnderrun {
        log.verbose("SyncUI: demuxer buffer underrun cleared")
      } else if !cacheStateOld.isBufferUnderrun && cacheStateNew.isBufferUnderrun {
        log.verbose("SyncUI: demuxer buffer underrun started")
      }

      rangesDidChange = cacheStateOld.cachedRanges.count != cacheStateNew.cachedRanges.count
      || zip(cacheStateNew.cachedRanges, cacheStateOld.cachedRanges).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 })
    } else {
      cacheState = nil
      rangesDidChange = false
    }

    saveStatePeriodicallyForPlayback()
    
    return (timeInfo, cacheState, rangesDidChange)
  }

  func syncUIChapterList() {
    // if window not loaded, ignore
    guard let pwc, pwc.loaded else { return }
    log.verbose("Syncing UI chapter list")

    DispatchQueue.main.async { [self] in
      // this should avoid sending reload when table view is not ready
      if isInMiniPlayer {
        guard pwc.miniPlayer.playlistShown else { return }
        pwc.miniPlayer.loadIfNeeded()
      } else {
        guard pwc.isOpen(sidebarTab: .chapters) else { return }
      }

      guard pwc.playlistView.isViewLoaded else { return }
      pwc.playlistView.chapterTableView.reloadData()
    }
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
  }

  @MainActor
  func makeTouchBar() -> NSTouchBar {
    log.debug("Activating Touch Bar")
    needsTouchBar = true
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
    syncUIChapterList()
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
    DispatchQueue.main.async { [self] in
      log.trace("Chapters: \(chapters)")
      // Instead of modifying existing list, overwrite reference to prev list.
      // This will avoid concurrent modification crashes
      info.chapters = chapters
    }

    syncUIChapterList()
  }

  // MARK: - Notifications

  func postNotification(_ name: Notification.Name) {
    log.verbose("Posting notification: \(name.rawValue)")
    NotificationCenter.default.post(Notification(name: name, object: self))
  }

  // MARK: - Track Meta

  func getMediaTitle(withExtension: Bool = true) -> String {
    if let mediaTitle = mpv.getString(MPVProperty.mediaTitle) {
      if !mediaTitle.isEmpty, let path = mpv.getString(MPVProperty.path), let id = PlaybackID(path: path) {
        MediaMetaCache.shared.updateCachedMeta(id, mpvTitle: mediaTitle,
                                               watchLaterMD5: nil, pullFromFfmpeg: false)
      }
      return mediaTitle
    }
    if let url = info.currentURL {
      return withExtension ? url.path : url.deletingPathExtension().path
    }
    return ""
  }

  func getMusicMetadata() -> (title: String, album: String, artist: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
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
        MediaMetaCache.shared.updateCachedMeta(id, mpvTitle: meta.0, mpvAlbum: meta.1, mpvArtist: meta.2,
                                               watchLaterMD5: nil, pullFromFfmpeg: false)
      }
      return meta
    }
  }

  // MARK: - Tracks

  func reloadTrackInfo() -> Bool {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    // No need to process track list changes if playback is being stopped. Must not process track
    // list changes if mpv is terminating as accessing mpv once shutdown has been initiated can
    // trigger a crash.
    guard !isStopping else {
      log.verbose("Aborting tracklist reload: player not ready (state=\(state))")
      return false
    }
    if Constants.requireFileLoadedForTrackReload {
      guard let currentPlayback = info.currentPlayback else {
        log.verbose("Aborting tracklist reload: currentPlayback is nil")
        return false
      }
      guard currentPlayback.state.isAtLeast(.loaded) else {
        log.verbose("Aborting tracklist reload: currentPlayback not yet loaded (state=\(currentPlayback.state.description))")
        return false
      }
    }

    log.verbose("Reloading tracklist from mpv")

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
    log.debug("Reloaded tracklist from mpv: \(videoTracks.count) vid, \(audioTracks.count) aud, \(subTracks.count) sub")

    // Need to reload these explicitly. Sometimes when mpv sends `track-list`, it omits `vid`, `aid`, etc.
    vidChanged()
    aidChanged()
    sidChanged()
    secondarySidChanged()

    log.verbose("Posting iinaTracklistChanged vid=\(String(info.vid)) aid=\(String(info.aid)) " +
                "sid=\(String(info.sid)) ssid=\(String(info.secondSid))")
    postNotification(.iinaTracklistChanged)
    return true
  }

  func aidChanged(to aid: Int? = nil, silent: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded, !isRestoring, !isStopping else { return }
    let aid = aid ?? Int(mpv.getInt(MPVOption.TrackSelection.aid))
    guard aid != info.aid else { return }
    if Constants.requireFileLoadedForTrackReload {
      guard info.isFileLoaded else {
        log.verbose("Audio track changed to \(aid) but file is not loaded; ignoring")
        return
      }
    }
    info.aid = aid

    log.verbose("Audio track changed to: \(aid)")
    pwc.updateVolumeUI()
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
    let didChange = vid != info.vid
    let trackIsAlbumArt = (vid > 0) && (mpv.getString(MPVProperty.trackListNAlbumart(vid)) == "yes")
    videoView.isVidAlbumArt = trackIsAlbumArt
    info.vid = vid
    log.verbose("Updated video state: vid=\(vid) isAlbumArt=\(trackIsAlbumArt.yn) ready=\(true.yn)")
    return (vid, didChange)
  }

  func vidChanged(silent: Bool = false) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard let pwc, pwc.loaded, !isRestoring, !isStopping else { return }
    if Constants.requireFileLoadedForTrackReload {
      guard info.isFileLoaded else {
        log.verbose("Video track changed but file not loaded; skipping")
        return
      }
    }

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
      log.verbose("[GTF:\(ctx.name)] Changing sessionState for vid change, vidNew=\(ctx.vidTrackID) " +
                  "pendingAction=\(pendingAction): \(prevSessionState) → \(returnValue?.description ?? "nil")")
      return returnValue
    }

    let videoGeoTF: GeometryTransform.VideoGeometryTF = { [self] inputVidGeo, ctx -> VideoGeometry? in
      guard ctx.currentPlayback.state.isAtLeast(.loaded) else {
        log.verbose("[GTF:\(ctx.name)] vid changed to \(vid) but file is not loaded")
        return nil
      }

      var outputVidGeo = ctx.syncVideoParamsFromMpv(startingWith: inputVidGeo)
      if outputVidGeo == nil && hasPendingAction {
        log.verbose("[GTF:\(ctx.name)] syncVideoParams returned nil but pending miniplayer show video. " +
                    "Assuming no video tracks; will show defaultAlbumArt")
        outputVidGeo = inputVidGeo
        // (kludge): ideally we'd want to include this in window transform, but need refactor to get there from here.
        // This should work ok.
        pwc.animationPipeline.submitInstantTask {
          pwc.updateDefaultArtVisibility(to: true)
        }
      }

      // Show OSD in music mode (if configured) when changing tracks, but not while toggling videoView visibility
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
      log.verbose("Enabling video track: changing vid from \(vidNow) → \(vidToSet) " +
                  "vidTrackCount=\(vidTrackCount) pnedingAction=\(action)")
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
        pwc.animationPipeline.submitInstantTask{ [self] in
          // Do not show if in music mode & video is hidden.
          guard !pwc.currentLayout.isMusicMode || pwc.musicModeGeo.isViewportShown else { return }
          pwc.updateDefaultArtVisibility(to: true)
        }
      }
    case .sub:
      name = MPVOption.TrackSelection.sid
    case .secondSub:
      name = MPVOption.Subtitles.secondarySid
    }
    mpv.setInt(name, index)
  }

}
