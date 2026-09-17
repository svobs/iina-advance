//
//  PlaybackInfo.swift
//  iina
//
//  Created by lhc on 21/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Foundation

/// Current state of player's mpv core. Reused between playbacks. For a single playback, see class `Playback`.
class PlaybackInfo {
  let log: any Logger.Subsystem

  @MainActor
  init(log: any Logger.Subsystem) {
    self.log = log
  }

  // MARK: - Current Playback

  /// Should only be updated in the `mpv` DispatchQueue
  var currentPlayback: Playback? = nil {
    didSet {
      let newValue = currentPlayback
      if let oldValue, let newValue, oldValue.id == newValue.id {
        if oldValue.state != newValue.state {
          log.verbose("Δ currentPlayback.lifecycleState: \(oldValue.state) → \(newValue.state)")
        }
      } else {
        log.verbose("Updated currentPlayback to \(newValue?.description ?? "nil")")
      }
    }
  }

  var nowPlayingIndex: Int? { currentPlayback?.playlistPos }
  var currentURL: URL? { currentPlayback?.url }
  var isNetworkResource: Bool { currentPlayback?.isNetworkResource ?? false }
  var isMediaOnRemoteDrive: Bool { currentPlayback?.isMediaOnRemoteDrive ?? false }

  var isFileLoaded: Bool { currentPlayback?.state.isAtLeast(.loaded) ?? false }
  var isFileLoadedAndSized: Bool {  currentPlayback?.state.isAtLeast(.loadedAndSized) ?? false }

  var shouldAutoLoadFiles: Bool = false
  var isMatchingSubtitles = false

  /// Returns the current pause state (if on the main queue!)
  @MainActor private(set) var isPaused: Bool = true
  /// Returns the current pause state (if on the mpv queue!)
  var _isPaused: Bool { isPausedLocally ?? isPausedRemotely }
  /// Set this while waiting for remote to respond
  var isPausedLocally: Bool? = nil {
    didSet {
      updatePauseState()
    }
  }

  var isPausedRemotely: Bool = true {
    didSet {
      updatePauseState()
    }
  }

  private func updatePauseState() {
    let paused = _isPaused
    DispatchQueue.main.async { [self] in
      let oldValue = isPaused
      if oldValue != paused {
        isPaused = paused
        log.verbose("Playback is \(isPaused ? "PAUSED" : "PLAYING")")
        SleepPreventer.updateSleepPrevention()
      }
    }
  }

  /// Should only be updated in `DispatchQueue.main`
  var isSeeking: Bool = false

  // MARK: - Filters & Equalizers

  var videoFilters: [MPVFilter] = []
  // Consider phasing these out...
  var flipFilter: MPVFilter?
  var mirrorFilter: MPVFilter?
  var audioEqFilter: MPVFilter?
  var delogoFilter: MPVFilter?

  var isFlippedVertical: Bool { flipFilter != nil }
  var isFlippedHorizontal: Bool { mirrorFilter != nil }

  /// `[filter.name -> filter]`. Should be used on main thread only
  var videoFiltersDisabled: [String: MPVFilter] = [:]

  var deinterlace: Bool = false
  var hwdec: String = "no"
  var hwdecEnabled: Bool { hwdec != "no" }
  var hdrAvailable: Bool = false
  var hdrEnabled: Bool = true

  var mpvKeepaspectWindow: Bool = true

  // video equalizer
  var brightness: Int = 0
  var contrast: Int = 0
  var saturation: Int = 0
  var gamma: Int = 0
  var hue: Int = 0

  var videoZoom: Double = 1.0
  var videoPanX: Double = 0.0
  var videoPanY: Double = 0.0

  var volume: Double = 50
  var volumeMax: Int = 50
  var isMuted: Bool = false

  var audioFilters: [MPVFilter] = []

  var audioDelay: Double = 0
  var subDelay: Double = 0
  var sub2Delay: Double = 0
  var subScale: Double = 1.0
  var subPos: Double = 100
  var sub2Pos: Double = 0
  var subEncoding: String?
  var subFont: String?
  var subFontSize: Int = 38
  var subColor: String? = nil
  var subBgColor: String? = nil
  var subBorderColor: String? = nil
  var subBorderSize: Double = 1.65

  var abLoopStatus: LoopStatus = .cleared
  var abLoopA: Double = 0
  var abLoopB: Double = 0
  var abLoopCount: String = "0"
  var isABLoopActive: Bool { abLoopA != 0 && abLoopB != 0 && abLoopCount != "0" }

  // mpv properties (cached here for easier use by PlayerSaveState)
  var loopFile: String = StringConstants.mpvNo
  var loopPlaylist: String = StringConstants.mpvNo
  var loopMode: LoopMode {
    let loopFileStatus = loopFile
    let loopPlaylistStatus = loopPlaylist
    guard loopFileStatus != "inf" else { return .file }
    if let count = Int(loopFileStatus), count != 0 {
      return .file
    }
    guard loopPlaylistStatus != "inf", loopPlaylistStatus != "force" else { return .playlist }
    guard let count = Int(loopPlaylistStatus) else {
      return .off
    }
    return count == 0 ? .off : .playlist
  }

  var playSpeed: Double = 1.0

  var playlist: [PlaybackID] = []

  /** Selected track IDs. Use these (instead of `isSelected` of a track) to check if selected */
  var vid: Int? {
    didSet {
      log.verbose("Track `vid` changed: \(oldValue?.description ?? "nil") → \(vid?.description ?? "nil")")
    }
  }
  var aid: Int? {
    didSet {
      log.verbose("Track `aid` changed: \(oldValue?.description ?? "nil") → \(aid?.description ?? "nil")")
    }
  }
  var sid: Int? {
    didSet {
      log.verbose("Track `sid` changed: \(oldValue?.description ?? "nil") → \(sid?.description ?? "nil")")
    }
  }
  var secondSid: Int? {
    didSet {
      log.verbose("Track `sid2` changed: \(oldValue?.description ?? "nil") → \(sid?.description ?? "nil")")
    }
  }

  var isAudioTrackSelected: Bool {
    if let aid {
      return aid != 0
    }
    return false
  }

  var isVideoTrackSelected: Bool {
    if let vid {
      return vid != 0
    }
    return false
  }

  /// Used to keep track of previously selected vid track if video track is disabled due to hiding videoView in music mode.
  var vidDisabled: Int? {
    didSet {
      log.verbose("vidDisabled changed: \(String(oldValue)) → \(String(vidDisabled))")
    }
  }

  var isSubVisible = true
  var isSecondSubVisible = true

  /// If it return `nil`, it means do not change visibility from existing value
  var shouldShowDefaultArt: Bool? {
    if let currentPlayback {
      // Don't show art if currently loading
      log.verbose("shouldShowDefaultArt: loaded=\(currentPlayback.state.isAtLeast(.loaded).yn) vidSelected=\(isVideoTrackSelected.yn) vid=\(vid?.description ?? "nil")")
      if currentPlayback.state.isAtLeast(.loaded) {
        if vid == 0 {
          return true
        }
        let audioStatus = currentMediaAudioStatus
        let hasSubtitles = (isSubVisible && sid != 0) || (isSecondSubVisible && secondSid != 0)
        return audioStatus.isAudio && (audioStatus != .isAudioWithArtShown) && !hasSubtitles
      }
    }
    return nil
  }

  // -- PERSISTENT PROPERTIES END --

  enum MediaAudioStatus {
    case unknown
    case isAudioWithoutArt
    case isAudioWithArtHidden
    case isAudioWithArtShown
    case notAudio

    var isAudio: Bool {
      switch self {
      case .isAudioWithoutArt, .isAudioWithArtHidden, .isAudioWithArtShown:
        return true
      default:
        return false
      }
    }
  }

  var currentMediaAudioStatus: MediaAudioStatus {
    guard !isNetworkResource else { return .notAudio }
    let noVideoTrack = videoTracks.isEmpty
    let noAudioTrack = audioTracks.isEmpty
    if noVideoTrack && noAudioTrack {
      return .unknown
    }
    if noVideoTrack {
      return .isAudioWithoutArt
    }
    let hasRealVideoTrack = videoTracks.contains { !$0.isAlbumart }
    if !hasRealVideoTrack {
      if isVideoTrackSelected {
        return .isAudioWithArtShown
      } else {
        return .isAudioWithArtHidden
      }
    }
    return .notAudio
  }

  private let infoLock = Lock()

  @MainActor var chapter = 0
  @MainActor var chapters: [MPVChapter] = []
  @MainActor var currentChapter: MPVChapter? { chapters[at: chapter] }
  @MainActor func chapter(forPlaybackTime playbackPosSec: Double) -> MPVChapter? {
    let pos = VideoTime(playbackPosSec)
    for (index, chapter) in chapters.enumerated() {
      if let nextChapterStart = chapters[at: index+1]?.startTime, pos.between(chapter.startTime, nextChapterStart) {
        return chapter
      }
    }
    return nil
  }

  private var _audioTracks: [MPVTrack] = []
  private var _videoTracks: [MPVTrack] = []
  private var _subTracks: [MPVTrack] = []
  var audioTracks: [MPVTrack] {
    get {
      infoLock.withLock { _audioTracks }
    }
    set {
      infoLock.withLock { _audioTracks = newValue }
    }
  }
  var videoTracks: [MPVTrack] {
    get {
      infoLock.withLock { _videoTracks }
    }
    set {
      infoLock.withLock { _videoTracks = newValue }
    }
  }
  var subTracks: [MPVTrack] {
    get {
      infoLock.withLock { _subTracks }
    }
    set {
      infoLock.withLock { _subTracks = newValue }
    }
  }

  var selectedSub: MPVTrack? {
    let subTracksCached = subTracks
    let selected = subTracksCached.filter { $0.id == sid }
    if selected.count > 0 {
      return selected[0]
    }
    return nil
  }

  func findExternalSubTrack(withURL url: URL) -> MPVTrack? {
    let subTracksCached = subTracks
    return subTracksCached.first(where: { $0.externalFilename == url.path })
  }

  func replaceTracks(audio: [MPVTrack], video: [MPVTrack], sub: [MPVTrack]) {
    infoLock.withLock {
      _audioTracks = audio
      _videoTracks = video
      _subTracks = sub
    }
  }

  func trackList(_ type: MPVTrack.TrackType) -> [MPVTrack] {
    switch type {
    case .video: return videoTracks
    case .audio: return audioTracks
    case .sub, .secondSub: return subTracks
    }
  }

  func trackId(_ type: MPVTrack.TrackType) -> Int? {
    switch type {
    case .video: return vid
    case .audio: return aid
    case .sub: return sid
    case .secondSub: return secondSid
    }
  }

  func currentTrack(_ type: MPVTrack.TrackType) -> MPVTrack? {
    track(type, id: nil)
  }

  /// `id` is the index into the tracklist for the given type.
  /// Or if `id: nil` is supplied, will look up the current track for the given type.
  func track(_ type: MPVTrack.TrackType, id idGiven: Int?) -> MPVTrack? {
    let id: Int?, list: [MPVTrack]
    switch type {
    case .video:
      id = idGiven ?? vid
      list = videoTracks
    case .audio:
      id = idGiven ?? aid
      list = audioTracks
    case .sub:
      id = idGiven ?? sid
      list = subTracks
    case .secondSub:
      id = idGiven ?? secondSid
      list = subTracks
    }
    if let id {
      return list.first { $0.id == id }
    } else {
      return nil
    }
  }

  // Playlist metadata:
  @Atomic var currentVideosInfo: [FileInfo] = []
  @Atomic var currentSubsInfo: [FileInfo] = []
  /// Map: { video `path` for each `info` of `currentVideosInfo` -> `url` for each of `info.relatedSubs` }
  @Atomic var matchedSubs: [String: [URL]] = [:]

  func getMatchedSubs(_ file: String) -> [URL]? { $matchedSubs.withLock { $0[file] } }

  /// * If `0`, corresoponds to mpv's `cursor-autohide=always`.
  /// * If `> 0`, corresoponds to mpv's `cursor-autohide={number}`.
  /// * If `< 0`, corresoponds to mpv's `cursor-autohide=never`.
  ///
  /// ```
  /// --cursor-autohide=<number|no|always>
  /// Make mouse cursor automatically hide after given number of milliseconds (default: 1000 ms).
  /// no will disable cursor autohide. always means the cursor will stay hidden.
  /// ```
  @MainActor var cursorAutoHideTimeoutMs: Int = 0
  /// If true, corresoponds to mpv's `cursor-autohide-fs-only=yes`.
  ///
  /// ```
  /// --cursor-autohide-fs-only:
  /// If this option is given, the cursor is always visible in windowed mode. In fullscreen mode, the cursor is shown
  /// or hidden according to --cursor-autohide.
  /// ```
  @MainActor var cursorAutoHideFullScreenOnly: Bool = false
  /// Use these instead: `player.canHideCursor`, `player.shouldAlwaysHideCursor`
  @MainActor var enableCursorAutoHide: Bool { cursorAutoHideTimeoutMs >= 0 }

  var playbackTime = PlaybackTimeInfo.nullTime
  var cacheState: CacheState = CacheState(pausedForCache: false, cacheUsed: 0, cacheSpeed: 0, bufferingState: 0, isBufferUnderrun: false, cachedRanges: [])

}

struct PlaybackTimeInfo {
  static let nullTime = PlaybackTimeInfo(positionSec: nil, durationSec: nil, remainingSec: nil)

  let positionSec: Double?
  let durationSec: Double?
  /// Remaining playback time.
  ///
  /// This will or will not reflect the speed at which playback is occurring depending upon whether the `scaleRemainingTime` setting is enabled or not.
  let remainingSec: Double?
  var isAtEOF: Bool {
    if let positionSec, let durationSec, positionSec == durationSec {
      return true
    }
    return false
  }

  init(positionSec: Double?, durationSec: Double?, remainingSec: Double?) {
    let pos: Double?
    if let positionSec {
      if let durationSec, positionSec > durationSec {
        pos = max(0.0, durationSec)
      } else {
        pos = max(0.0, positionSec.roundedTo6())
      }
    } else {
      pos = nil
    }
    self.positionSec = pos
    self.durationSec = durationSec
    self.remainingSec = remainingSec
  }

  func clone(positionSec: Double? = nil) -> Self {
    .init(positionSec: positionSec ?? self.positionSec, durationSec: self.durationSec, remainingSec: self.remainingSec)
  }

  var percentage: Double {
    if let positionSec, let durationSec, durationSec > 0.0 {
      return (positionSec / durationSec) * 100
    }
    return 0.0
  }

  /// Returns the percent of the total duration of the video the given position in seconds represents.
  ///
  /// The percentage returned must be considered an estimate that could change. The duration of the video is obtained from the
  /// [mpv](https://mpv.io/manual/stable/) `duration` property. The documentation for this property cautions that mpv
  /// is not always able to determine the duration and when it does return a duration it may be an estimate. If the duration is unknown
  /// this method will fallback to using the current playback position, if that is known. Otherwise this method will return zero.
  /// - Parameter seconds: Position in the video as seconds from start.
  /// - Returns: The percent of the video the given position represents.
  func secondsToPercent(_ seconds: Double) -> Double {
    if let duration = durationSec {
      return duration == 0 ? 0 : seconds / duration * 100
    } else if let position = positionSec {
      return position == 0 ? 0 : seconds / position * 100
    } else {
      return 0
    }
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
    if let duration = durationSec {
      return duration * percent / 100
    } else if let position = positionSec {
      return position * percent / 100
    } else {
      return 0
    }
  }
}

struct CacheState {
  let pausedForCache: Bool
  let cacheUsed: Int
  let cacheSpeed: Int
  let bufferingState: Int
  let isBufferUnderrun: Bool
  let cachedRanges: [(Double, Double)]

  func clone(cachedRanges: [(Double, Double)]? = nil) -> CacheState {
    .init(
      pausedForCache: pausedForCache,
      cacheUsed: cacheUsed,
      cacheSpeed: cacheSpeed,
      bufferingState: bufferingState,
      isBufferUnderrun: isBufferUnderrun,
      cachedRanges: cachedRanges ?? self.cachedRanges)
  }
}
