//
//  PlayerSaveState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let embeddedSeparator: Character = "|"

/// Added "1" in v1.2
fileprivate let videoGeometryPrefStringVersion1 = "1"
/// Upgraded to "2" in v1.3
fileprivate let videoGeometryPrefStringVersion2 = "2"

fileprivate let specPrefStringVersion1 = "1"
/// Upgraded to "2" in v1.3
fileprivate let specPrefStringVersion2 = "2"
/// Updated to "2" in v1.2
fileprivate let windowGeometryPrefStringVersion = "2"
/// Updated to "2" in v1.2
fileprivate let musicModeGeoPrefStringVersion = "2"
fileprivate let playlistVideosCSVVersion = "1"

fileprivate typealias PropName = PlayerSaveState.PropName

/// Data structure for saving to prefs / restoring from prefs the UI state of a single player window
struct PlayerSaveState: CustomStringConvertible {
  enum PropName: String {
    case buildNumber = "buildNum"       /// Added in v1.2
    case launchID = "launchID"

    case playlistPos = "playlistPos"    /// `MPVProperty.playlistPos`. Added in v1.4
    case playlistPaths = "playlistPaths"

    case playlistVideos = "playlistVideos"
    case playlistSubtitles = "playlistSubs"
    case matchedSubtitles = "matchedSubs"

    case intendedViewportSize = "intendedViewportSize"  // No longer used in v1.4
    case layoutState = "layoutSpec"     /// Class `LayoutSpec` was merged into `LayoutState` in v1.4
    case videoGeo = "videoGeo"          /// Added in v1.2
    case windowedModeGeo = "windowedModeGeo"
    case musicModeGeo = "musicModeGeo"
    case screens = "screens"
    case miscWindowBools = "miscWindowBools"
    case overrideAutoMusicMode = "overrideAutoMusicMode"
    case isOnTop = "onTop"

    case url = "url"
    case playPosition = "playPosition"  /// `MPVOption.PlaybackControl.start`
    case playDuration = "playDuration"  /// `MPVProperty.duration`
    case paused = "paused"              /// `MPVOption.PlaybackControl.pause`

    case vid = "vid"                    /// `MPVOption.TrackSelection.vid`
    case vidDisabled = "vidDisabled"    /// IINA `info.vidDisabled`
    case aid = "aid"                    /// `MPVOption.TrackSelection.aid`
    case sid = "sid"                    /// `MPVOption.TrackSelection.sid`
    case s2id = "sid2"                  /// `MPVOption.Subtitles.secondarySid`

    case hwdec = "hwdec"                /// `MPVOption.Video.hwdec`
    case deinterlace = "deinterlace"    /// `MPVOption.Video.deinterlace`
    case hdrEnabled = "hdrEnabled"      /// IINA setting

    case brightness = "brightness"      /// `MPVOption.Equalizer.brightness`
    case contrast = "contrast"          /// `MPVOption.Equalizer.contrast`
    case saturation = "saturation"      /// `MPVOption.Equalizer.saturation`
    case gamma = "gamma"                /// `MPVOption.Equalizer.gamma`
    case hue = "hue"                    /// `MPVOption.Equalizer.hue`

    // Added in v1.4
    case videoZoom = "videoZoom"        /// `MPVOption.Video.videoZoom`
    case videoPanX = "videoPanX"        /// `MPVOption.Video.videoPanX`
    case videoPanY = "videoPanY"        /// `MPVOption.Video.videoPanY`

    case videoFilters = "vf"            /// `MPVProperty.vf`
    case audioFilters = "af"            /// `MPVProperty.af`
    case videoFiltersDisabled = "vfDisabled"/// IINA-only

    case playSpeed = "playSpeed"        /// `MPVOption.PlaybackControl.speed`
    case volume = "volume"              /// `MPVOption.Audio.volume`
    case isMuted = "muted"              /// `MPVOption.Audio.mute`
    case maxVolume = "maxVolume"        /// `MPVOption.Audio.volumeMax`
    case audioDelay = "audioDelay"      /// `MPVOption.Audio.audioDelay`
    case abLoopA = "abLoopA"            /// `MPVOption.PlaybackControl.abLoopA`
    case abLoopB = "abLoopB"            /// `MPVOption.PlaybackControl.abLoopB`

    /// Deprecated props, last used in v1.2.2 (replaced by single prop: `.videoGeo`)
    case videoRawWidth = "vidRawW"      /// `MPVProperty.width`
    case videoRawHeight = "vidRawH"     /// `MPVProperty.height`
    case videoAspectLabel = "aspect"    /// Converted into `MPVOption.Video.videoAspectOverride`
    case cropLabel = "cropLabel"        /// Converted into crop filter
    case videoRotation = "videoRotate"  /// `MPVOption.Video.videoRotate`
    case totalRotation = "totalRotation"/// `MPVProperty.videoParamsRotate`

    case isSubVisible = "subVisible"    /// `MPVOption.Subtitles.subVisibility`
    case isSub2Visible = "sub2Visible"  /// `MPVOption.Subtitles.secondarySubVisibility`
    case subDelay = "subDelay"          /// `MPVOption.Subtitles.subDelay`
    case sub2Delay = "sub2Delay"        /// `MPVOption.Subtitles.secondarySubDelay`
    case subPos = "subPos"              /// `MPVOption.Subtitles.subPos`
    case sub2Pos = "sub2Pos"            /// `MPVOption.Subtitles.secondarySubPos`
    case subScale = "subScale"          /// `MPVOption.Subtitles.subScale`

    // More sub properties added in v1.4
    case subFont = "subFont"               /// `MPVOption.Subtitles.subFont`
    case subFontSize = "subFontSize"       /// `MPVOption.Subtitles.subFontSize`
    case subColor = "subColor"             /// `MPVOption.Subtitles.subColor`
    case subBgColor = "subBgColor"         /// `MPVOption.Subtitles.subBackColor`
    case subBorderColor = "subBorderColor" /// `MPVOption.Subtitles.subBorderColor`
    case subBorderSize = "subBorderSize"   /// `MPVOption.Subtitles.subBorderSize`

    case loopPlaylist = "loopPlaylist"  /// `MPVOption.PlaybackControl.loopPlaylist`
    case loopFile = "loopFile"          /// `MPVOption.PlaybackControl.loopFile`

    /// Dictionary of mpv options & properties, as set in Settings > Advanced > Addtional mpv options
    /// at the time of the player's initial creation.
    /// Any options specified in this will supercede other saved `PropName`s.
    ///
    /// Added in v1.4.
    case mpvOpts = "mpvOpts"
  }

  static let saveQueue = DispatchQueue(label: "com.iina_advance.PlayerSaveQueue", qos: .background)

  /// IINA general log
  static let log = Logger.log

  static let urlProp: String = PropName.url.rawValue

  /// The player's log
  let log: any Logger.Subsystem

  let properties: [String: Any]

  /// Cached values parsed from `properties`

  /// Describes the current layout configuration of the player window.
  /// See `buildWindowInitialLayoutTasks()` in `PlayerWindowLayout.swift`.
  let layoutState: LayoutState?

  let geoSet: GeometrySet
  let screens: [ScreenMeta]

  let needsNativeFullScreen: Bool

  @MainActor
  init(_ props: [String: Any], playerID: String) {
    self.properties = props
    self.log = Logger.subsystem(forPlayerID: playerID)

    let layoutStateCSV = PlayerSaveState.string(for: .layoutState, props)

    // A bit clunky in v1.4 now that PiP status was moved into LayoutState
    let isWindowInPiP: Bool
    if let (_, _, isInPip,  _, _, _) = PlayerSaveState.parseMiscWindowBools(props) {
      isWindowInPiP = isInPip
    } else {
      Logger.log.error("Failed to restore property \(PropName.miscWindowBools.rawValue.quoted); will assume window is not in PiP")
      isWindowInPiP = false
    }
    self.screens = (props[PropName.screens.rawValue] as? [String] ?? []).compactMap({ScreenMeta.from($0)})

    // Layout + GeometrySet
    let priorLayoutState = LayoutState.fromCSV(layoutStateCSV, isInPiP: isWindowInPiP)
    let priorGeoSet = PlayerSaveState.geoSet(from: props, log)

    let modeToRestore: PlayerWindowMode
    let initialLayout: LayoutState
    var needsNativeFullScreen = false
    if let priorLayoutState {
      if priorLayoutState.isNativeFullScreen {
        // Special handling for native fullscreen. Rely on mpv to put us in FS when it is ready
        initialLayout = priorLayoutState.clone(mode: .windowedNormal)
        needsNativeFullScreen = true
      } else {
        initialLayout = priorLayoutState
      }
      modeToRestore = initialLayout.mode
    } else {
      log.error("Failed to read LayoutState object for restore! Will try to assemble window from prefs instead")
      modeToRestore = .windowedNormal
      initialLayout = LayoutState.fromPrefs(andMode: modeToRestore)
    }

    self.needsNativeFullScreen = needsNativeFullScreen
    (self.geoSet, self.layoutState) = PlayerSaveState.fixingErrorsInSavedGeoSet(priorGeoSet, log,
                                                                                initialLayout: initialLayout,
                                                                                modeToRestore: modeToRestore)
  }

  /// Looks for inconsistencies in `priorState.geoSet` (actually just its `.windowed` property so far), and tries to fix what it finds.
  /// May also make changes to `ctx.outputLayout` if needed.
  @MainActor
  private static func fixingErrorsInSavedGeoSet(_ savedGeoSet: GeometrySet, _ log: any Logger.Subsystem,
                                         initialLayout: LayoutState,
                                         modeToRestore: PlayerWindowMode) -> (GeometrySet, LayoutState) {

    var adjustedLayout = initialLayout
    let adjustedGeoSet: GeometrySet
    switch modeToRestore {

    case .windowedNormal, .windowedInteractive:
      let savedWindowedGeo = savedGeoSet.windowed
      if !savedWindowedGeo.mode.isWindowed || savedWindowedGeo.screenFit.isFullScreen {
        log.error("Initial layout: windowedModeGeo from prior state has invalid mode (\(savedWindowedGeo.mode)) or screenFit (\(savedWindowedGeo.screenFit)). Will generate a fresh windowedModeGeo from saved layoutState and last closed window instead")

        let lastClosedGeo = PlayerWindowController.windowedModeGeoLastClosed
        let windowed: PWinGeometry
        if lastClosedGeo.mode.isWindowed && !lastClosedGeo.screenFit.isFullScreen {
          windowed = initialLayout.convertWindowedModeGeometry(from: lastClosedGeo, video: savedGeoSet.video,
                                                                  pinWidthOrHeightIfAtMax: false, log)
        } else {
          let bestScreen = NSScreen.forScreenID(lastClosedGeo.screenID) ?? NSScreen.main ?? NSScreen.screens.first!
          windowed = initialLayout.buildDefaultInitialGeometry(screen: bestScreen, video: savedGeoSet.video)
        }
        adjustedGeoSet = savedGeoSet.clone(windowed: windowed)

      } else if savedWindowedGeo.outsideBars.totalWidth + savedWindowedGeo.insideBars.totalWidth > savedWindowedGeo.windowFrame.width {
        log.error("Initial layout: windowedModeGeo from prior state has window size (\(savedWindowedGeo.windowFrame.size)) which is too small to accomodate bars (outside=\(savedWindowedGeo.outsideBars), inside=\(savedWindowedGeo.insideBars)). Will close sidebars.")

        /// Overwrite `outputLayout` with fixed version
        adjustedLayout = initialLayout.withSidebarsHidden()
        let outsideNew = savedWindowedGeo.outsideBars.clone(trailing: 0, leading: 0)
        let insideNew = savedWindowedGeo.insideBars.clone(trailing: 0, leading: 0)
        let windowed = savedWindowedGeo.clone(outsideBars: outsideNew, insideBars: insideNew)

        adjustedGeoSet = savedGeoSet.clone(windowed: windowed)
      } else {
        // Valid (as far as we've checked anyway)
        adjustedGeoSet = savedGeoSet
      }

    case .musicMode,
        .fullScreenNormal, .fullScreenInteractive:
      // No validation at present
      adjustedGeoSet = savedGeoSet
    }

    return (adjustedGeoSet, adjustedLayout)
  }

  var description: String {
    guard let url else {
      return "PlayerSaveState(url=<ERROR>)"
    }

    let urlPath: String
    if #available(macOS 13.0, *) {
      urlPath = url.path(percentEncoded: false)
    } else {
      urlPath = url.path
    }

    let filteredProps = properties.filter({ prop in
      switch prop.key {
      case PropName.url.rawValue,
        // these are too long and contain PII
        PropName.playlistPaths.rawValue,
        PropName.playlistVideos.rawValue,
        PropName.playlistSubtitles.rawValue,
        PropName.matchedSubtitles.rawValue:
        return false
      default:
        return true
      }
    })

    let propsJSON = json(from: filteredProps) ?? "<ERROR>"

    return "PlayerSaveState{url=\(urlPath.pii.quoted) props=\(propsJSON))"
  }

  func json(from object:Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
      return nil
    }
    return String(data: data, encoding: String.Encoding.utf8)
  }

  var url: URL? {
    url(for: .url)
  }

  var buildNumber: Int? {
    int(for: .buildNumber)
  }

  // MARK: - Save State / Serialize to prefs strings

  func getPlaylistPathList() -> [String] {
    guard let playlistPathList = properties[PropName.playlistPaths.rawValue] as? [String] else {
      return []
    }

    return playlistPathList
    // TODO: resolve bookmarks
/*
    guard let playlistBookmarks = properties[PropName.playlistBookmarks.rawValue] as? [NSData?] else {
      return playlistPathList
    }

    guard playlistPathList.count == playlistBookmarks.count else {
      log.error("Cannot use bookmarks for restore: found \(playlistBookmarks.count) bookmarks but \(playlistPathList.count) paths! Returning paths as-is")
      return playlistPathList
    }

    var restoredPlaylistPaths: [String] = []
    var resolvedCount = 0
    for (bookmark, storedPath) in zip(playlistBookmarks, playlistPathList) {
      if let bookmarkData = bookmark as? Data, let url = PlaybackID.url(fromBookmark: bookmarkData, log) {
        let resolvedPath = PlaybackID.path(from: url)
        restoredPlaylistPaths.append(resolvedPath)
        resolvedCount += 1
        if resolvedPath != storedPath {
          log.debug("Playlist item from bookmark resolved to a new path than previously stored: \(resolvedPath.pii.quoted) vs. \(storedPath.pii.quoted)")
        }
      } else {
        restoredPlaylistPaths.append(storedPath)
      }
    }
    log.debug("Resolved \(resolvedCount)/\(playlistPathList.count) playlist items from bookmarks")
    return restoredPlaylistPaths
*/
  }

  // MARK: - Restore State / Deserialize from prefs

  func string(for name: PropName) -> String? {
    return PlayerSaveState.string(for: name, properties)
  }

  /// Relies on `Bool` being serialized to `String` with value `Y` or `N`
  func bool(for name: PropName) -> Bool? {
    return PlayerSaveState.bool(for: name, properties)
  }

  func int(for name: PropName) -> Int? {
    return PlayerSaveState.int(for: name, properties)
  }

  /// Relies on `Double` being serialized to `String`
  func double(for name: PropName) -> Double? {
    return PlayerSaveState.double(for: name, properties)
  }

  /// Expects to parse CSV `String` with two tokens
  func nsSize(for name: PropName) -> NSSize? {
    if let csv = string(for: name) {
      let tokens = csv.split(separator: ",")
      if tokens.count == 2, let width = Double(tokens[0]), let height = Double(tokens[1]) {
        return NSSize(width: width, height: height)
      }
      log.debug("Failed to parse property as NSSize: \(name.rawValue.quoted)")
    }
    return nil
  }

  fileprivate func url(for name: PropName) -> URL? {
    if let string = string(for: name) {
      return URL(string: string)
    }
    return nil
  }

  func mpvUserOpts() -> [MPVOptPair] {
    guard let propsString = string(for: .mpvOpts) else { return [] }
    return MPVOptPair.parseLines(from: propsString)
  }

  fileprivate func mpvFilterList(for name: PropName) -> [MPVFilter]? {
    guard let filterListCSV = string(for: name) else { return nil }
    return filterListCSV.split(separator: ",").compactMap({MPVFilter(rawString: String($0))})
  }

  static func parseMiscWindowBools(_ properties: [String: Any]) -> (isMiniaturized: Bool, isHidden: Bool, isInPip: Bool,
                                                                    isWindowMiniaturizedDueToPip: Bool,
                                                                    isPausedPriorToInteractiveMode: Bool,
                                                                    isZoomedViaGesture: Bool)? {
    guard let stateString = PlayerSaveState.string(for: .miscWindowBools, properties) else {
      log.error("Failed to restore from miscWindowBools: pref not found!")
      return nil
    }


    let splitted: [String] = stateString.split(separator: ",").map{String($0)}
    guard splitted.count >= 5,
          let isMiniaturized = Bool.yn(splitted[0]),
          let isHidden = Bool.yn(splitted[1]),
          let isInPip = Bool.yn(splitted[2]),
          let isWindowMiniaturizedDueToPip = Bool.yn(splitted[3]),
          let isPausedPriorToInteractiveMode = Bool.yn(splitted[4]) else {
      log.error("Failed to restore property \(PropName.miscWindowBools.rawValue.quoted): could not parse \(stateString.quoted)!")
      return nil
    }

    // This field was added in v1.4
    let isZoomedViaGesture: Bool
    if splitted.count >= 6 {
      guard let val = Bool.yn(splitted[5]) else {
        log.error("Failed to restore property \(PropName.miscWindowBools.rawValue.quoted): could not parse isZoomedViaGesture as bool!")
        return nil
      }
      isZoomedViaGesture = val
    } else {
      isZoomedViaGesture = false
    }

    return (isMiniaturized, isHidden, isInPip, isWindowMiniaturizedDueToPip, isPausedPriorToInteractiveMode, isZoomedViaGesture)
  }

  static private func string(for name: PropName, _ properties: [String: Any]) -> String? {
    return properties[name.rawValue] as? String
  }

  static private func bool(for name: PropName, _ properties: [String: Any]) -> Bool? {
    return Bool.yn(string(for: name, properties))
  }

  static private func int(for name: PropName, _ properties: [String: Any]) -> Int? {
    if let intString = string(for: name, properties) {
      return Int(intString)
    }
    return nil
  }

  /// Relies on `Double` being serialized to `String`
  static private func double(for name: PropName, _ properties: [String: Any]) -> Double? {
    if let doubleString = string(for: name, properties) {
      return Double(doubleString)
    }
    return nil
  }

  static fileprivate func toCSV(mpvFilters: any Collection<MPVFilter> ) -> String {
    mpvFilters.map({$0.stringFormat}).joined(separator: ",")
  }

  /// Returns IINA-Advance build number associated with stored player's properties (param).
  ///
  /// `2`: default for v1.0 & v1.1, because `buildNumber` property was not added until v1.2.
  /// See: `Constants.BuildNumber`
  static private func buildNumber(from properties: [String: Any]) -> Int {
    return int(for: .buildNumber, properties) ?? Constants.BuildNumber.V1_1
  }

  @MainActor
  static private func geoSet(from props: [String: Any], _ log: any Logger.Subsystem) -> GeometrySet {
    // VideoGeometry is needed to quickly calculate & restore video dimensions instead of waiting for mpv to provide it
    let buildNumber = buildNumber(from: props)
    let videoGeo: VideoGeometry
    if let parsedVideoGeo = VideoGeometry.fromCSV(PlayerSaveState.string(for: .videoGeo, props), log) {
      videoGeo = parsedVideoGeo
    } else {
      if buildNumber < Constants.BuildNumber.V1_2 {
        // Older than IINA 1.2
        log.debug("Failed to restore VideoGeometry from CSV (build \(buildNumber) properties). Will attempt to build it from legacy properties instead")
      } else {
        log.errorDebugAlert("Failed to restore VideoGeometry from CSV (build \(buildNumber) properties)! Possible tampering occurred with the prefs, or a backwards-incompatible version of of IINA Advance was run. Will attempt to build VideoGeometry from legacy properties instead...")
      }
      let defaultGeo = VideoGeometry.defaultGeometry(log)
      let totalRotation = PlayerSaveState.int(for: .totalRotation, props)
      let userRotation = PlayerSaveState.int(for: .videoRotation, props)
      let streamRotation = (totalRotation ?? 0) - (userRotation ?? 0)
      let selectedCropLabel = PlayerSaveState.string(for: .cropLabel, props)
      videoGeo = defaultGeo.clone(rawWidth: PlayerSaveState.int(for: .videoRawWidth, props),
                                  rawHeight: PlayerSaveState.int(for: .videoRawHeight, props),
                                  userAspectLabel: PlayerSaveState.string(for: .videoAspectLabel, props),
                                  streamRotation: streamRotation,
                                  userRotation: userRotation,
                                  selectedCropLabel: selectedCropLabel,
                                  videoSizeDisplayOverride: nil)
    }

    let screenMetas = (props[PropName.screens.rawValue] as? [String] ?? []).compactMap({ScreenMeta.from($0)})

    let windowedCSV = PlayerSaveState.string(for: .windowedModeGeo, props)
    let savedWindowedGeo = PWinGeometry.fromCSV(windowedCSV, videoGeoFallback: videoGeo, log)
    var windowedGeo: PWinGeometry
    if let savedWindowedGeo {
      windowedGeo = savedWindowedGeo
    } else {
      log.errorDebugAlert("Failed to restore PWinGeometry from CSV! Will fall back to last closed geometry")
      windowedGeo = PlayerWindowController.windowedModeGeoLastClosed
    }

    let defaultScreen = NSScreen.main ?? NSScreen.screens[0]
    let defaultScreenID = defaultScreen.screenID

    // Need to replace `,` with `;` to avoid breaking CSV (ugly kludge)
    let windowedFrameScreenID = NSScreen.getOwnerOrDefaultScreenID(forViewRect: windowedGeo.windowFrame, fallbackScreenID: defaultScreenID).replacingOccurrences(of: ",", with: ";")
    let windowedGeoScreenID = windowedGeo.screenID.replacingOccurrences(of: ",", with: ";")
    if windowedFrameScreenID != windowedGeoScreenID {
      // The previous window origin is not in the previous screen, or possibly any screen.
      // Could be an external screen is no longer connected or the arrangement of the screens has changed.
      log.warn("Windowed geometry's frame is invalid for screen \(windowedGeoScreenID.quoted). Will use default screen instead (\(defaultScreen.screenID.quoted))")
      if let screenMeta = screenMetas.first(where: {$0.screenID == windowedGeoScreenID}), screenMeta.visibleFrame.contains(windowedGeo.windowFrame.origin) {
        // TODO: preserve relative window frame inside new screen
      } else {
      }
      windowedGeo = windowedGeo.clone(screenID: defaultScreenID).refitted(using: .stayInside)
    }

    let musicModeCSV = PlayerSaveState.string(for: .musicModeGeo, props)

    var musicModeGeo: PWinGeometry
    if let savedMusicModeGeo = PWinGeometry.fromCSV(musicModeCSV, videoGeoFallback: videoGeo, log) {
      musicModeGeo = savedMusicModeGeo
    } else if let savedLegacyMusicModeGeo = PWinGeometry.fromMusicModeCSV(musicModeCSV, videoGeoFallback: videoGeo, log) {
      // v1.3 and earlier
      musicModeGeo = savedLegacyMusicModeGeo
    } else {
      log.errorDebugAlert("Failed to restore music mode PWinGeometry from CSV! Will fall back to last closed geometry")
      musicModeGeo = PlayerWindowController.musicModeGeoLastClosed
    }

    // Need to replace `,` with `;` to avoid breaking CSV (ugly kludge)
    let musicModeFrameScreenID = NSScreen.getOwnerOrDefaultScreenID(forViewRect: musicModeGeo.windowFrame, fallbackScreenID: defaultScreenID).replacingOccurrences(of: ",", with: ";")
    let musicModeGeoScreenID = musicModeGeo.screenID.replacingOccurrences(of: ",", with: ";")
    if musicModeFrameScreenID != musicModeGeoScreenID {
      // The previous window origin is not in the previous screen, or possibly any screen.
      // Could be an external screen is no longer connected or the arrangement of the screens has changed.
      log.warn("Invalid windowFrame for music mode PWinGeometry for screen \(musicModeGeoScreenID.quoted). Will use default screen instead (\(defaultScreen.screenID.quoted))")
      if let screenMeta = screenMetas.first(where: {$0.screenID == musicModeGeoScreenID}), screenMeta.visibleFrame.contains(musicModeGeo.windowFrame.origin) {
        // TODO: preserve relative window frame inside new screen
      } else {
      }
      musicModeGeo = musicModeGeo.clone(screenID: defaultScreenID).refitted()
    }

    return GeometrySet(windowed: windowedGeo, musicMode: musicModeGeo, video: videoGeo)
  }

  // Utility function for parsing complex object from CSV
  static fileprivate func parseCSV<T>(_ csv: String?, separator: Character = ",",
                                      expectedTokenCount: Int, expectedVersion: String,
                                      targetObjName: String,
                                      _ parseFunc: (String, inout IndexingIterator<[String]>) throws -> T?) rethrows -> T? {
    guard let csv else { return nil }
    log.verbose("Parsing CSV as \(targetObjName): \(csv.quoted)")
    let errPreamble = "Failed to parse \(targetObjName) CSV:"
    let tokens = csv.split(separator: separator).map{String($0)}
    // Check version first, for a cleaner error msg
    guard tokens.count > 0 else {
      log.error("\(errPreamble) could not parse any tokens from CSV for \(targetObjName)! (CSV: \(csv))")
      return nil
    }
    var iter = tokens.makeIterator()
    let version = iter.next()
    guard version == expectedVersion else {
      if let version, let vInt = Int(version), let evInt = Int(expectedVersion), vInt < evInt {
        // Not an error to encounter an old version
        log.verbose("\(errPreamble) version (\(version.quoted)) is older than expected (\(expectedVersion.quoted))")
      } else {
        log.error("\(errPreamble) version found (\(version?.quoted ?? "nil")) too new (expected \(expectedVersion.quoted))")
      }
      return nil
    }

    guard tokens.count == expectedTokenCount else {
      log.error("\(errPreamble) wrong token count (expected \(expectedTokenCount) but found \(tokens.count))")
      return nil
    }

    return try parseFunc(errPreamble, &iter)
  }

  static private func parsePlaylistVideos(from entryString: String) -> [FileInfo] {
    var videos: [FileInfo] = []

    // Each entry cannot contain spaces, so use that for the first delimiter:
    for csvString in entryString.split(separator: " ") {
      // Do not parse more than the first 2 tokens. The URL can contain commas
      let tokens = csvString.split(separator: ",", maxSplits: 2).map{String($0)}
      guard tokens.count == 3 else {
        log.error("Could not parse PlaylistVideoInfo: not enough tokens (expected 3 but found \(tokens.count))")
        continue
      }
      guard tokens[0] == playlistVideosCSVVersion else {
        log.error("Could not parse PlaylistVideoInfo: wrong version (expected \(playlistVideosCSVVersion) but found \(tokens[0].quoted))")
        continue
      }

      guard let prefixLength = Int(tokens[1]),
            let url = URL(string: tokens[2])
      else {
        log.error("Could not parse PlaylistVideoInfo url or prefixLength!")
        continue
      }

      let fileInfo = FileInfo(url)
      if prefixLength > 0 {
        var string = url.deletingPathExtension().lastPathComponent
        let suffixRange = string.index(string.startIndex, offsetBy: prefixLength)..<string.endIndex
        string.removeSubrange(suffixRange)
        fileInfo.prefix = string
      }
      videos.append(fileInfo)
    }
    return videos
  }

  /// Restore player state from prior launch
  @MainActor
  func restorePlayer(id: String) -> PlayerCore? {

    guard let urlString = string(for: .url), let url = URL(string: urlString) else {
      log.error("Could not restore player window: no value for property \(PropName.url.rawValue.quoted)")
      return nil
    }

    let player = PlayerManager.shared.createNewPlayerCore(withLabel: id, restoringFrom: self)
    let pwc = player.pwc!

    let log = player.log

      // Log properties
    log.verbose("Restoring from prior launch: \(self)")
    let info = player.info

    info.priorStateBuildNumber = int(for: .buildNumber) ?? info.priorStateBuildNumber

    log.verbose("Screens from prior launch: \(self.screens)")

    // TODO: map current geometry to prior screen. Deal with mismatch

    if let hdrEnabled = bool(for: .hdrEnabled) {
      info.hdrEnabled = hdrEnabled
    }

    // Set these here so that play position slider can be restored to prev position when the window is opened - not after
    if let playbackPositionSec = double(for: .playPosition) {
      info.playbackPositionSec = playbackPositionSec
    }
    if let playbackDurationSec = double(for: .playDuration) {
      info.playbackDurationSec = playbackDurationSec
    }
    if let paused = bool(for: .paused) {
      info.isPausedLocally = paused
    }

    if let videoURLListString = string(for: .playlistVideos) {
      let currentVideosInfo = PlayerSaveState.parsePlaylistVideos(from: videoURLListString)
      info.currentVideosInfo = currentVideosInfo
    }

    if let videoURLList = properties[PropName.playlistSubtitles.rawValue] as? [String] {
      info.currentSubsInfo = videoURLList.compactMap({URL(string: $0)}).compactMap({FileInfo($0)})
    }

    if let matchedSubs = properties[PropName.matchedSubtitles.rawValue] as? [String: [String]] {
      info.$matchedSubs.withLock {
        for (videoPath, subs) in matchedSubs {
          $0[videoPath] = subs.compactMap{urlString in URL(string: urlString)}
        }
      }
    }
    player.log.verbose("Restored playlist info for \(info.currentVideosInfo.count) videos, \(info.currentSubsInfo.count) subs")

    if let videoFiltersDisabled = mpvFilterList(for: .videoFiltersDisabled) {
      for filter in videoFiltersDisabled {
        if let label = filter.label {
          info.videoFiltersDisabled[label] = filter
        } else {
          player.log.error("Could not restore disabled video filter: missing label (\(filter.stringFormat.quoted))")
        }
      }
    }

    // We must have a non-nil track of each. The UI's selected track will be blank if not.
    let vid = int(for: .vid) ?? 0
    info.vid = vid
    let aid = int(for: .aid) ?? 0
    info.aid = aid
    let sid = int(for: .sid) ?? 0
    info.sid = sid
    let s2id = int(for: .s2id) ?? 0
    info.secondSid = s2id

    if let vidDisabled = int(for: .vidDisabled) {
      info.vidDisabled = vidDisabled >= 0 ? vidDisabled : nil
    }

    // Prevent "seek" OSD from appearing unncessarily after loading finishes
    pwc.osd.lastPlaybackPosition = info.playbackPositionSec
    pwc.osd.lastPlaybackDuration = info.playbackDurationSec

    // IINA restore supercedes mpv watch-later.
    // Need to delete the watch-later file before mpv loads it or else things get very buggy
    let mpvMD5 = Utility.mpvWatchLaterMd5(url.path)
    let watchLaterFileURL = Utility.watchLaterURL.appendingPathComponent(mpvMD5).path
    if FileManager.default.fileExists(atPath: watchLaterFileURL) {
      player.log.debug("Found mpv watch-later file. Deleting it because we are using IINA restore...")
      try? FileManager.default.removeItem(atPath: watchLaterFileURL)
    }

    if let overrideAutoMusicMode = bool(for: .overrideAutoMusicMode) {
      player.overrideAutoMusicMode = overrideAutoMusicMode
    }

    // Open the window!
    player.openURLs([url])
    return player
  }

  /// Restore mpv properties.
  /// Must wait until after mpv init, so that the lifetime of these options is limited to the current file.
  /// Otherwise the mpv core will keep the options for the lifetime of the player, which is often undesirable (for example,
  /// `MPVOption.PlaybackControl.start` will skip any files in the playlist which have durations shorter than its start time).
  func restoreMpvProperties(to player: PlayerCore) {
    let mpv: MPVController = player.mpv
    let log = player.log

    if let playbackPositionSec = string(for: .playPosition) {
      log.verbose("Restoring playback position: \(playbackPositionSec)")
      mpv.setString(MPVOption.PlaybackControl.start, playbackPositionSec)
    }

    // Better to always pause when starting, because there may be a slight delay before it can be enforced later
    // See also: `PlayerCore.pendingResumeWhenShowingWindow`
    mpv.setFlag(MPVOption.PlaybackControl.pause, true)

    if let priorLayout = layoutState, priorLayout.isLegacyFullScreen {
      // Go immediately into full screen mode for Legacy Full Screen.
      // (Native Full Screen requires us to start in windowed and enter FS using an animation)
      mpv.setFlag(MPVOption.Window.fullscreen, true)
    }

    if let hwdec = string(for: .hwdec) {
      mpv.setString(MPVOption.Video.hwdec, hwdec)
    }

    if let deinterlace = bool(for: .deinterlace) {
      mpv.setFlag(MPVOption.Video.deinterlace, deinterlace)
    }

    mpv.setInt(MPVOption.Video.videoRotate, self.geoSet.video.userRotation)

    let userAspectLabel = self.geoSet.video.userAspectLabel
    player.sendVideoAspectOverrideToMpv(aspectLabel: userAspectLabel)

    if let brightness = int(for: .brightness) {
      mpv.setInt(MPVOption.Equalizer.brightness, brightness)
    }
    if let contrast = int(for: .contrast) {
      mpv.setInt(MPVOption.Equalizer.contrast, contrast)
    }
    if let saturation = int(for: .saturation) {
      mpv.setInt(MPVOption.Equalizer.saturation, saturation)
    }
    if let gamma = int(for: .gamma) {
      mpv.setInt(MPVOption.Equalizer.gamma, gamma)
    }
    if let hue = int(for: .hue) {
      mpv.setInt(MPVOption.Equalizer.hue, hue)
    }

    if let videoZoom = double(for: .videoZoom) {
      mpv.setDouble(MPVOption.Video.videoZoom, videoZoom)
    }
    if let videoPanX = double(for: .videoPanX) {
      mpv.setDouble(MPVOption.Video.videoPanX, videoPanX)
    }
    if let videoPanY = double(for: .videoPanY) {
      mpv.setDouble(MPVOption.Video.videoPanY, videoPanY)
    }

    if let playSpeed = double(for: .playSpeed) {
      mpv.setDouble(MPVOption.PlaybackControl.speed, playSpeed)
    }
    if let volume = double(for: .volume) {
      player.info.volume = volume
      mpv.setDouble(MPVOption.Audio.volume, volume)
    }
    if let isMuted = bool(for: .isMuted) {
      player.info.isMuted = isMuted
      mpv.setFlag(MPVOption.Audio.mute, isMuted)
    }
    if let volumeMax = int(for: .maxVolume) {
      player.info.volumeMax = volumeMax
      mpv.setInt(MPVOption.Audio.volumeMax, volumeMax)
    }
    if let audioDelay = double(for: .audioDelay) {
      mpv.setDouble(MPVOption.Audio.audioDelay, audioDelay)
    }

    if let subDelay = double(for: .subDelay) {
      mpv.setDouble(MPVOption.Subtitles.subDelay, subDelay)
    }
    if let sub2Delay = double(for: .sub2Delay) {
      mpv.setDouble(MPVOption.Subtitles.secondarySubDelay, sub2Delay)
    }
    if let isSubVisible = bool(for: .isSubVisible) {
      mpv.setFlag(MPVOption.Subtitles.subVisibility, isSubVisible)
    }
    if let isSub2Visible = bool(for: .isSub2Visible) {
      mpv.setFlag(MPVOption.Subtitles.secondarySubVisibility, isSub2Visible)
    }
    if let subScale = double(for: .subScale) {
      mpv.setDouble(MPVOption.Subtitles.subScale, subScale)
    }
    if let subPos = double(for: .subPos) {
      mpv.setDouble(MPVOption.Subtitles.subPos, subPos)
    }
    if let sub2Pos = double(for: .sub2Pos) {
      mpv.setDouble(MPVOption.Subtitles.secondarySubPos, sub2Pos)
    }

    if let subFont = string(for: .subFont) {
      mpv.setString(MPVOption.Subtitles.subFont, subFont)
    }
    if let subFontSize = int(for: .subFontSize) {
      mpv.setInt(MPVOption.Subtitles.subFontSize, subFontSize)
    }
    if let subColor = string(for: .subColor) {
      mpv.setString(MPVOption.Subtitles.subColor, subColor)
    }
    if let subBgColor = string(for: .subBgColor) {
      mpv.setString(MPVOption.Subtitles.subBackColor, subBgColor)
    }
    if let subBorderColor = string(for: .subBorderColor) {
      mpv.setString(MPVOption.Subtitles.subBorderColor, subBorderColor)
    }
    if let subBorderSize = double(for: .subBorderSize) {
      mpv.setDouble(MPVOption.Subtitles.subBorderSize, subBorderSize)
    }

    if let loopPlaylist = string(for: .loopPlaylist) {
      player.info.loopPlaylist = loopPlaylist
      mpv.setString(MPVOption.PlaybackControl.loopPlaylist, loopPlaylist)
    }
    if let loopFile = string(for: .loopFile) {
      player.info.loopFile = loopFile
      mpv.setString(MPVOption.PlaybackControl.loopFile, loopFile)
    }
    if let abLoopA = double(for: .abLoopA), abLoopA > 0.0 {
      player.info.abLoopA = abLoopA
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, abLoopA)

      if let abLoopB = double(for: .abLoopB), abLoopB > 0.0 {
        player.info.abLoopB = abLoopB
        mpv.setDouble(MPVOption.PlaybackControl.abLoopB, abLoopB)
      }
    }

    // Need to restore a non-nil value. Use 0 (none) by default if something went wrong
    let vid = int(for: .vid) ?? 0
    mpv.setInt(MPVOption.TrackSelection.vid, vid)
    let aid = int(for: .aid) ?? 0
    mpv.setInt(MPVOption.TrackSelection.aid, aid)

    if let audioFilters = string(for: .audioFilters) {
      mpv.setString(MPVProperty.af, audioFilters)
    }
    if let videoFilters = string(for: .videoFilters) {
      // This includes crop
      mpv.setString(MPVProperty.vf, videoFilters)
    }
  }

}  /// end `struct PlayerSaveState`

struct ScreenMeta {
  static private let expectedCSVTokenCount = 15
  static private let csvVersion: Int = 2

  let displayID: UInt32
  let name: String
  let frame: NSRect
  /// NOTE: `visibleFrame` is highly volatile and will change when Dock or title bar is shown/hidden
  let visibleFrame: NSRect
  let nativeResolution: CGSize
  let cameraHousingHeight: CGFloat
  let backingScaleFactor: CGFloat

  func toCSV() -> String {
    let csv = [String(ScreenMeta.csvVersion), String(displayID), name,
               frame.origin.x.stringMaxFrac2, frame.origin.y.stringMaxFrac2,
               frame.size.width.stringMaxFrac2, frame.size.height.stringMaxFrac2,
               visibleFrame.origin.x.stringMaxFrac2, visibleFrame.origin.y.stringMaxFrac2,
               visibleFrame.size.width.stringMaxFrac2, visibleFrame.size.height.stringMaxFrac2,
               nativeResolution.width.stringMaxFrac2, nativeResolution.height.stringMaxFrac2,
               cameraHousingHeight.stringMaxFrac2,
               backingScaleFactor.stringMaxFrac2
    ].joined(separator: ",")
    assert(csv.split(separator: ",").count == ScreenMeta.expectedCSVTokenCount,
           "Invalid ScreenMeta CSV (expected \(ScreenMeta.expectedCSVTokenCount) tokens: \(csv.quoted)")
    return csv
  }

  var screenID: String {
    if #available(macOS 10.15, *) {
      return "\(displayID):\(name)"
    }
    return "\(displayID)"
  }

  func matches(_ otherScreen: NSScreen) -> Bool {
    guard name != "?" else { return false }
    let otherScreenID = otherScreen.screenID.replacingOccurrences(of: ",", with: ";")
    return screenID == otherScreenID
  }

  static func from(_ screen: NSScreen) -> ScreenMeta {
      // Can't store comma in CSV. Just convert to semicolon
    var name: String = screen.localizedName.replacingOccurrences(of: ",", with: ";")
    if name.isEmpty {
      name = "?"
    }
    return ScreenMeta(displayID: screen.displayId, name: name, frame: screen.frame,
                      visibleFrame: screen.visibleFrame,
                      nativeResolution: screen.nativeResolution ?? CGSizeZero,
                      cameraHousingHeight: screen.cameraHousingHeight ?? 0,
                      backingScaleFactor: screen.backingScaleFactor)
  }

  static func from(_ csv: String) -> ScreenMeta? {
    let tokens = csv.split(separator: ",").map{String($0)}
    var iter = tokens.makeIterator()

    guard let versionStr = iter.next(), let version = Int(versionStr) else {
      Logger.log.error("While parsing ScreenMeta from CSV: failed to parse version")
      return nil
    }
    guard version == csvVersion else {
      if version == 1 {
        Logger.log.error("Discarding ScreenMeta from CSV: format is obsolete (expected version \(csvVersion) but found \(version))")
      } else {
        Logger.log.error("While parsing ScreenMeta from CSV: bad version (expected \(csvVersion) but found \(version))")
      }
      return nil
    }
    // Check this after parsing version, for cleaner error messages
    guard tokens.count == expectedCSVTokenCount else {
      Logger.log.error("While parsing ScreenMeta from CSV: wrong token count (expected \(expectedCSVTokenCount) but found \(tokens.count))")
      return nil
    }

    guard let displayID = UInt32(iter.next()!),
          let name = iter.next(),
          let frameX = Double(iter.next()!),
          let frameY = Double(iter.next()!),
          let frameW = Double(iter.next()!),
          let frameH = Double(iter.next()!),
          let visibleFrameX = Double(iter.next()!),
          let visibleFrameY = Double(iter.next()!),
          let visibleFrameW = Double(iter.next()!),
          let visibleFrameH = Double(iter.next()!),
          let nativeResW = Double(iter.next()!),
          let nativeResH = Double(iter.next()!),
          let cameraHousingHeight = Double(iter.next()!),
          let backingScaleFactor = Double(iter.next()!) else {
      Logger.log.error("While parsing ScreenMeta from CSV: could not parse one or more tokens")
      return nil
    }

    let frame = NSRect(x: frameX, y: frameY, width: frameW, height: frameH)
    let visibleFrame = NSRect(x: visibleFrameX, y: visibleFrameY, width: visibleFrameW, height: visibleFrameH)
    let nativeResolution = NSSize(width: nativeResW, height: nativeResH)
    return ScreenMeta(displayID: displayID, name: name, frame: frame,
                      visibleFrame: visibleFrame, nativeResolution: nativeResolution,
                      cameraHousingHeight: cameraHousingHeight, backingScaleFactor: backingScaleFactor)
  }
}

extension VideoGeometry {
  /// `String`, `Logger.Subsystem` -> `VideoGeometry`
  /// Note to maintainers: if compiler is complaining with the message "nil is not compatible with closure result type VideoGeometry",
  /// check the arguments to the `VideoGeometry` constructor. For some reason the error lands in the wrong place.
  static func fromCSV(_ csv: String?, _ log: any Logger.Subsystem, separator: Character = ",") -> VideoGeometry? {
    guard let csv, !csv.isEmpty else {
      log.debug("CSV is empty; returning nil for VideoGeometry")
      return nil
    }
    if let vidGeoV2: VideoGeometry = PlayerSaveState.parseCSV(csv, separator: separator, expectedTokenCount: 8,
                                                              expectedVersion: videoGeometryPrefStringVersion2,
                                                              targetObjName: "VideoGeometry v2", { errPreamble, iter in

      guard let rawWidth = Int(iter.next()!),
            let rawHeight = Int(iter.next()!),
            let streamRotation = Int(iter.next()!),
            let userRotation = Int(iter.next()!),
            let decodedAspectLabel = iter.next(),
            let userAspectLabel = iter.next(),
            let selectedCropLabel = iter.next()
      else {
        /// NOTE: if Xcode shows the error `'nil' is not compatible with closure result type 'VideoGeometry'`
        /// here, it means that the wrong args are being supplied to the`VideoGeometry` constructor below.
        log.error("\(errPreamble) could not parse one or more tokens")
        return nil
      }

      return VideoGeometry(rawWidth: rawWidth, rawHeight: rawHeight,
                           decodedAspectLabel: decodedAspectLabel, userAspectLabel: userAspectLabel,
                           streamRotation: streamRotation, userRotation: userRotation,
                           selectedCropLabel: selectedCropLabel, videoSizeDisplayOverride: nil, log: log)
    }) {
      return vidGeoV2
    }

    log.debug("Failed to parse VideoGeometry v2; falling back to v1")
    return PlayerSaveState.parseCSV(csv, separator: separator, expectedTokenCount: 7,
                                    expectedVersion: videoGeometryPrefStringVersion1,
                                    targetObjName: "VideoGeometry v1") { errPreamble, iter in

      guard let rawWidth = Int(iter.next()!),
            let rawHeight = Int(iter.next()!),
            let streamRotation = Int(iter.next()!),
            let userRotation = Int(iter.next()!),
            let userAspectLabel = iter.next(),
            let selectedCropLabel = iter.next()
      else {
        /// NOTE: if Xcode shows the error `'nil' is not compatible with closure result type 'VideoGeometry'`
        /// here, it means that the wrong args are being supplied to the`VideoGeometry` constructor below.
        log.error("\(errPreamble) could not parse one or more tokens")
        return nil
      }

      let decodedAspectLabel = Aspect.bestLabelFor((Double(rawWidth) / Double(rawHeight)).mpvAspectString)

      return VideoGeometry(rawWidth: rawWidth, rawHeight: rawHeight,
                           decodedAspectLabel: decodedAspectLabel, userAspectLabel: userAspectLabel,
                           streamRotation: streamRotation, userRotation: userRotation,
                           selectedCropLabel: selectedCropLabel, videoSizeDisplayOverride: nil, log: log)
    }
  }

  /// `VideoGeometry` -> `String`
  func toCSV() -> String {
    "\(videoGeometryPrefStringVersion2),\(fieldStrings.joined(separator: ","))"
  }

  // MARK: Embedded CSV

  fileprivate var fieldStrings: [String] {
    [
      "\(rawWidth)",
      "\(rawHeight)",
      "\(streamRotation)",
      "\(userRotation)",
      "\(decodedAspectLabel)",
      "\(userAspectLabel)",
      "\(selectedCropLabel)"
    ]
  }

  /// `VideoGeometry` -> `String` (without version token)
  fileprivate func toEmbeddedCSV() -> String {
    fieldStrings.joined(separator: String(embeddedSeparator))
  }

  /// Assumes embedded CSV is current version (but will fall back & try to parse as prev version if that fails)
  static func fromEmbeddedCSV(_ csvEmbedded: String?, _ log: any Logger.Subsystem) -> VideoGeometry? {
    guard let csvEmbedded, !csvEmbedded.isEmpty else {
      log.debug("CSV is empty; returning nil for embedded VideoGeometry")
      return nil
    }
    let csv2 = "\(videoGeometryPrefStringVersion2)\(embeddedSeparator)\(csvEmbedded)"
    if let videoGeoV2 = fromCSV(csv2, log, separator: embeddedSeparator) {
      return videoGeoV2
    } else {
      log.debug("Could not parse embedded VideoGeometry v2; trying v1")
      let csv1 = "\(videoGeometryPrefStringVersion1)\(embeddedSeparator)\(csvEmbedded)"
      return fromCSV(csv1, log, separator: embeddedSeparator)
    }
  }
}

// TODO: this is old MusicModeGeometry stuff. Consolidate into PWinGeometry!
extension PWinGeometry {
  static let expectedMusicModeCSVTokenCount = 9

  /// (Deprecated in v1.4 - use `fromCSV()` instead)
  /// v2: `String` -> `MusicModeGeometry` (In v1.4+, now builds a `PWinGeometry` with mode: `.musicMode`).
  /// v1: (`String`, `VideoGeometry`) -> `MusicModeGeometry` (v1.4+: same note as above).
  /// Note to maintainers: if compiler is complaining with the message "nil is not compatible with closure result type PWinGeometry",
  /// check the arguments to the `PWinGeometry` constructor. For some reason the error lands in the wrong place.
  static func fromMusicModeCSV(_ csv: String?, videoGeoFallback: VideoGeometry? = nil, _ log: any Logger.Subsystem) -> PWinGeometry? {
    guard let csv, !csv.isEmpty else {
      log.debug("CSV is empty; returning nil for music mode PWinGeometry")
      return nil
    }

    // Try v2 first.
    let mmGeo: PWinGeometry? = PlayerSaveState.parseCSV(csv, expectedTokenCount: PWinGeometry.expectedMusicModeCSVTokenCount,
                                                        expectedVersion: musicModeGeoPrefStringVersion,
                                                        targetObjName: "PWinGeometry musicMode v2") { errPreamble, iter in

      guard let winOriginX = Double(iter.next()!),
            let winOriginY = Double(iter.next()!),
            let winWidth = Double(iter.next()!),
            let winHeight = Double(iter.next()!),
            let isViewportShown = Bool.yn(iter.next()!),
            let playlistShown = Bool.yn(iter.next()!),
            let screenID = iter.next(),
            let videoGeoEmbeddedCSV = iter.next()
      else {
        /// NOTE: if Xcode shows the error `'nil' is not compatible with closure result type 'PWinGeometry'`
        /// here, it means that the wrong args are being supplied to the `PWinGeometry.forMusicMode` function below.
        log.error("\(errPreamble) could not parse one or more tokens")
        return nil
      }

      guard let videoGeo = VideoGeometry.fromEmbeddedCSV(videoGeoEmbeddedCSV, log) else {
        Logger.log.error("\(errPreamble) could not parse VideoGeometry")
        return nil
      }

      let windowFrame = CGRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
      return PWinGeometry.forMusicMode(windowFrame: windowFrame, screenID: screenID, video: videoGeo,
                                       isViewportShown: isViewportShown, playlistShown: playlistShown)
    }

    if let mmGeo {
      return mmGeo
    }

    // Fall back to v1
    return PlayerSaveState.parseCSV(csv, expectedTokenCount: 10,
                                    expectedVersion: "1",
                                    targetObjName: "PWinGeometry musicMode v1") { errPreamble, iter in

      guard let winOriginX = Double(iter.next()!),
            let winOriginY = Double(iter.next()!),
            let winWidth = Double(iter.next()!),
            let winHeight = Double(iter.next()!),
            let _ = Double(iter.next()!),  /// was `playlistHeight` (defunct as of 1.1)
            let isViewportShown = Bool.yn(iter.next()!),
            let playlistShown = Bool.yn(iter.next()!),
            let _ = Double(iter.next()!),  /// was `videoAspect` (defunct as of 1.2)
            let screenID = iter.next()
      else {
        /// NOTE: if Xcode shows the error `'nil' is not compatible with closure result type 'PWinGeometry'`
        /// here, it means that the wrong args are being supplied to the `PWinGeometry.forMusicMode` function below.
        log.error("\(errPreamble) could not parse one or more tokens")
        return nil
      }

      let videoGeo: VideoGeometry
      if let videoGeoFallback {
        videoGeo = videoGeoFallback
      } else {
        log.warn("No VideoGeometry given for legacy v1 musicMode PWinGeometry! Falling back to default VideoGeometry")
        videoGeo = VideoGeometry.defaultGeometry()
      }

      let windowFrame = CGRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
      return PWinGeometry.forMusicMode(windowFrame: windowFrame, screenID: screenID, video: videoGeo,
                                       isViewportShown: isViewportShown, playlistShown: playlistShown)
    }
  }

  /// `MusicModeGeometry` -> `String`
  /// Deprecated: use `toCSV()`
  func toMusicModeCSV() -> String {
    precondition(mode == .musicMode, "PWinGeometry.toMusicModeCSV() called on non-musicMode geometry: \(self)")
    let csv = [musicModeGeoPrefStringVersion,
               self.windowFrame.origin.x.stringMaxFrac2,
               self.windowFrame.origin.y.stringMaxFrac2,
               self.windowFrame.width.stringMaxFrac2,
               self.windowFrame.height.stringMaxFrac2,
               self.isViewportShown.yn,
               self.isMusicModePlaylistShown.yn,
               self.screenID.replacingOccurrences(of: ",", with: ";"),  // ensure it's CSV-compatible
               self.video.toEmbeddedCSV()
    ].joined(separator: ",")
    assert(csv.split(separator: ",").count == PWinGeometry.expectedMusicModeCSVTokenCount,
           "Invalid musicMode PWinGeometry CSV (expected \(PWinGeometry.expectedMusicModeCSVTokenCount) tokens: \(csv)")
    return csv
  }
}

extension PWinGeometry {
  static let expectedCSVTokenCount = 22

  /// `PWinGeometry` -> `String`
  func toCSV() -> String {
    let csv = [windowGeometryPrefStringVersion,
               self.topMarginHeight.stringMaxFrac2,
               self.outsideBars.top.stringMaxFrac2,
               self.outsideBars.trailing.stringMaxFrac2,
               self.outsideBars.bottom.stringMaxFrac2,
               self.outsideBars.leading.stringMaxFrac2,
               self.insideBars.top.stringMaxFrac2,
               self.insideBars.trailing.stringMaxFrac2,
               self.insideBars.bottom.stringMaxFrac2,
               self.insideBars.leading.stringMaxFrac2,
               self.viewportMargins.top.stringMaxFrac2,
               self.viewportMargins.trailing.stringMaxFrac2,
               self.viewportMargins.bottom.stringMaxFrac2,
               self.viewportMargins.leading.stringMaxFrac2,
               self.windowFrame.origin.x.stringMaxFrac2,
               self.windowFrame.origin.y.stringMaxFrac2,
               self.windowFrame.width.stringMaxFrac2,
               self.windowFrame.height.stringMaxFrac2,
               String(self.screenFit.rawValue),
               self.screenID.replacingOccurrences(of: ",", with: ";"),  // ensure it's CSV-compatible
               String(self.mode.rawValue),
               self.video.toEmbeddedCSV()
    ].joined(separator: ",")
    assert(csv.split(separator: ",").count == PWinGeometry.expectedCSVTokenCount,
           "Invalid PWinGeometry CSV (expected \(PWinGeometry.expectedCSVTokenCount) tokens: \(csv.quoted)")
    return csv
  }

  /// (`String`, `VideoGeometry`) -> `PWinGeometry`
  /// `log` is needed to construct embedded `VideoGeometry`.
  /// `videoGeoFallback` is only used if CSV is legacy version
  static func fromCSV(_ csv: String?, videoGeoFallback: VideoGeometry? = nil, _ log: any Logger.Subsystem) -> PWinGeometry? {
    guard let csv, !csv.isEmpty else {
      log.debug("CSV is empty; returning nil for geometry")
      return nil
    }

    /// Try v2 first.
    /// Version 2 removes `videoAspect` field and adds 6 `videoGeometry` fields.
    let pwinGeo: PWinGeometry? = PlayerSaveState.parseCSV(csv, expectedTokenCount: PWinGeometry.expectedCSVTokenCount,
                                                          expectedVersion: windowGeometryPrefStringVersion,
                                                          targetObjName: "PWinGeometry v2") { errPreamble, iter ->  PWinGeometry? in

      guard let topMarginHeight = Double(iter.next()!),
            let outsideTopBarHeight = Double(iter.next()!),
            let outsideTrailingBarWidth = Double(iter.next()!),
            let outsideBottomBarHeight = Double(iter.next()!),
            let outsideLeadingBarWidth = Double(iter.next()!),
            let insideTopBarHeight = Double(iter.next()!),
            let insideTrailingBarWidth = Double(iter.next()!),
            let insideBottomBarHeight = Double(iter.next()!),
            let insideLeadingBarWidth = Double(iter.next()!),
            // Viewport margins are persisted but no longer used (v1.4+).
            // They can be derived from the other variables & it's safer to do that.
            let _ /* viewportMarginTop */ = Double(iter.next()!),
            let _ /* viewportMarginTrailing */ = Double(iter.next()!),
            let _ /* viewportMarginBottom */ = Double(iter.next()!),
            let _ /* viewportMarginLeading */ = Double(iter.next()!),
            let winOriginX = Double(iter.next()!),
            let winOriginY = Double(iter.next()!),
            let winWidth = Double(iter.next()!),
            let winHeight = Double(iter.next()!),
            let fitOptionRawValue = Int(iter.next()!),
            let screenID = iter.next(),
            let modeRawValue = Int(iter.next()!),
            let videoGeoEmbeddedCSV = iter.next()
      else {
        log.error("\(errPreamble) could not parse one or more tokens")
        /// NOTE: if Xcode shows a weird error here, it means that the wrong args are being supplied
        /// to the`PWinGeometry` constructor below, or the constructor of any object passed to it.
        return nil
      }

      guard let mode = PlayerWindowMode(rawValue: modeRawValue) else {
        log.error("\(errPreamble) unrecognized PlayerWindowMode: \(modeRawValue)")
        return nil
      }
      guard let screenFit = ScreenFit(rawValue: fitOptionRawValue) else {
        log.error("\(errPreamble) unrecognized ScreenFit: \(fitOptionRawValue)")
        return nil
      }
      let windowFrame = CGRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
      let outsideBars = MarginQuad(top: outsideTopBarHeight, trailing: outsideTrailingBarWidth,
                                   bottom: outsideBottomBarHeight, leading: outsideLeadingBarWidth)
      let insideBars = MarginQuad(top: insideTopBarHeight, trailing: insideTrailingBarWidth,
                                  bottom: insideBottomBarHeight, leading: insideLeadingBarWidth)

      guard let videoGeo = VideoGeometry.fromEmbeddedCSV(videoGeoEmbeddedCSV, log) else {
        log.error("\(errPreamble) could not parse VideoGeometry")
        return nil
      }

      return PWinGeometry(windowFrame: windowFrame, screenID: screenID, screenFit: screenFit, mode: mode,
                          topMarginHeight: topMarginHeight,
                          outsideBars: outsideBars, insideBars: insideBars,
                          viewportMargins: nil,
                          video: videoGeo,
                          videoZoom: 1.0)
    }
    if let pwinGeo {
      return pwinGeo
    }

    // Fall back to v1, which did not include embedded VideoGeometry CSV.
    return PlayerSaveState.parseCSV(csv, expectedTokenCount: 22,
                                    expectedVersion: "1",
                                    targetObjName: "PWinGeometry v1") { errPreamble, iter -> PWinGeometry? in

      guard let topMarginHeight = Double(iter.next()!),
            let outsideTopBarHeight = Double(iter.next()!),
            let outsideTrailingBarWidth = Double(iter.next()!),
            let outsideBottomBarHeight = Double(iter.next()!),
            let outsideLeadingBarWidth = Double(iter.next()!),
            let insideTopBarHeight = Double(iter.next()!),
            let insideTrailingBarWidth = Double(iter.next()!),
            let insideBottomBarHeight = Double(iter.next()!),
            let insideLeadingBarWidth = Double(iter.next()!),
            let viewportMarginTop = Double(iter.next()!),
            let viewportMarginTrailing = Double(iter.next()!),
            let viewportMarginBottom = Double(iter.next()!),
            let viewportMarginLeading = Double(iter.next()!),
            let _ = iter.next(),  /// was `videoAspect` (defunct as of 1.2)
            let winOriginX = Double(iter.next()!),
            let winOriginY = Double(iter.next()!),
            let winWidth = Double(iter.next()!),
            let winHeight = Double(iter.next()!),
            let fitOptionRawValue = Int(iter.next()!),
            let screenID = iter.next(),
            let modeRawValue = Int(iter.next()!)
      else {
        log.error("\(errPreamble) could not parse one or more tokens")
        /// NOTE: if Xcode shows a weird error here, it means that the wrong args are being supplied
        /// to the`PWinGeometry` constructor below, or the constructor of any object passed to it.
        return nil
      }

      guard let mode = PlayerWindowMode(rawValue: modeRawValue) else {
        log.error("\(errPreamble) unrecognized PlayerWindowMode: \(modeRawValue)")
        return nil
      }
      guard let screenFit = ScreenFit(rawValue: fitOptionRawValue) else {
        log.error("\(errPreamble) unrecognized ScreenFit: \(fitOptionRawValue)")
        return nil
      }
      let windowFrame = NSRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
      let viewportMargins = MarginQuad(top: viewportMarginTop, trailing: viewportMarginTrailing,
                                       bottom: viewportMarginBottom, leading: viewportMarginLeading)
      let outsideBars = MarginQuad(top: outsideTopBarHeight, trailing: outsideTrailingBarWidth,
                                   bottom: outsideBottomBarHeight, leading: outsideLeadingBarWidth)
      let insideBars = MarginQuad(top: insideTopBarHeight, trailing: insideTrailingBarWidth,
                                  bottom: insideBottomBarHeight, leading: insideLeadingBarWidth)

      let video: VideoGeometry
      if let videoGeoFallback {
        video = videoGeoFallback
      } else {
        // we will do our best but our best may not be good enough
        log.error("VideoGeometry for legacy PWinGeometry is nil! Will try to derive it")
        let viewportSize = GeoUtil.deriveViewportSize(from: windowFrame, topMarginHeight: topMarginHeight, outsideBars: outsideBars)
        let videoSize = viewportSize - viewportMargins.totalSize
        let defaultVideoGeo: VideoGeometry = VideoGeometry.defaultGeometry(log)
        video = defaultVideoGeo.clone(rawWidth: Int(videoSize.width), rawHeight: Int(videoSize.height), videoSizeDisplayOverride: nil)
      }

      let pwinGeo = PWinGeometry(windowFrame: windowFrame, screenID: screenID, screenFit: screenFit,
                                 mode: mode, topMarginHeight: topMarginHeight,
                                 outsideBars: outsideBars, insideBars: insideBars,
                                 viewportMargins: viewportMargins, video: video,
                                 videoZoom: 1.0)
      return pwinGeo
    }
  }

}

extension LayoutState {
  /// `LayoutState` -> `String`
  func toCSV(buildNumber: Int) -> String {
    let leadingSidebarTab: String = self.leadingSidebar.visibleTab?.name ?? "nil"
    let trailingSidebarTab: String = self.trailingSidebar.visibleTab?.name ?? "nil"
    var csvItems = [leadingSidebarTab,
                    trailingSidebarTab,
                    String(self.mode.rawValue),
                    self.isLegacyStyle.yn,
                    String(self.topBarPlacement.rawValue),
                    String(self.trailingSidebarPlacement.rawValue),
                    String(self.bottomBarPlacement.rawValue),
                    String(self.leadingSidebarPlacement.rawValue),
                    self.enableOSC.yn,
                    String(self.oscPosition.rawValue),
                    String(self.interactiveMode?.rawValue ?? 0)
    ]

    if buildNumber < Constants.BuildNumber.V1_3 {
      csvItems = [specPrefStringVersion1] + csvItems
    } else { // v1.3
      csvItems = [specPrefStringVersion2] + csvItems + [
        String(moreSidebarState.selectedSubSegment),
        String(moreSidebarState.playlistSidebarWidth),
        moreSidebarState.selectedPluginTabID
      ]
    }
    return csvItems.joined(separator: ",")
  }

  /// `String` -> `LayoutState`
  static func fromCSV(_ csv: String?, isInPiP: Bool) -> LayoutState? {
    guard let csv, !csv.isEmpty else {
      Logger.log.debug("CSV is empty; returning nil for LayoutState")
      return nil
    }
    let parsingFunc: (String, inout IndexingIterator<[String]>) throws -> LayoutState? = { errPreamble, iter -> LayoutState? in

      let leadingSidebarTab = Sidebar.Tab(name: iter.next())
      let traillingSidebarTab = Sidebar.Tab(name: iter.next())

      guard let modeInt = Int(iter.next()!), let mode = PlayerWindowMode(rawValue: modeInt),
            let isLegacyStyle = Bool.yn(iter.next()) else {
        Logger.log.error("\(errPreamble) could not parse mode or isLegacyStyle")
        return nil
      }

      guard let topBarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let trailingSidebarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let bottomBarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let leadingSidebarPlacement = Preference.PanelPlacement(Int(iter.next()!)) else {
        Logger.log.error("\(errPreamble) could not parse bar placements")
        return nil
      }

      guard let enableOSC = Bool.yn(iter.next()),
            let oscPositionInt = Int(iter.next()!),
            let oscPosition = Preference.OSCPosition(rawValue: oscPositionInt) else {
        Logger.log.error("\(errPreamble) could not parse enableOSC or oscPosition")
        return nil
      }

      let interactModeInt = Int(iter.next()!)
      let interactiveMode = InteractiveMode(rawValue: interactModeInt ?? 0) ?? nil  /// `0` === `nil` value

      var leadingTabGroups = Sidebar.TabGroup.fromPrefs(for: .leadingSidebar)
      let leadVis: Sidebar.Visibility = leadingSidebarTab == nil ? .closed : .open(tabToShow: leadingSidebarTab!)
      // If the tab groups prefs changed somehow since the last run, just add it for now so that the geometry can be restored.
      // Will correct this at the end of restore.
      if let visibleTab = leadVis.visibleTab, !leadingTabGroups.contains(visibleTab.group) {
        Logger.log.error("Restore state is invalid: leadingSidebar has visibleTab \(visibleTab.name) which is outside its configured tab groups")
        leadingTabGroups.insert(visibleTab.group)
      }
      let leadingSidebar = Sidebar(.leadingSidebar, tabGroups: leadingTabGroups, placement: leadingSidebarPlacement, visibility: leadVis)

      var trailingTabGroups = Sidebar.TabGroup.fromPrefs(for: .trailingSidebar)
      let trailVis: Sidebar.Visibility = traillingSidebarTab == nil ? .closed : .open(tabToShow: traillingSidebarTab!)
      // Account for invalid visible tab (see note above)
      if let visibleTab = trailVis.visibleTab, !trailingTabGroups.contains(visibleTab.group) {
        Logger.log.error("Restore state is invalid: trailingSidebar has visibleTab \(visibleTab.name) which is outside its configured tab groups")
        trailingTabGroups.insert(visibleTab.group)
      }
      let trailingSidebar = Sidebar(.trailingSidebar, tabGroups: trailingTabGroups, placement: trailingSidebarPlacement, visibility: trailVis)

      let moreSidebarState: Sidebar.SidebarMiscState

      if let selectedSubSegment = Int(iter.next() ?? ""),
         let playlistWidth = Int(iter.next() ?? "") {
        // Default to anyPlugin: it will just select first plugin tab found in PluginSidebar
        let selectedPluginTabID = iter.next() ?? Constants.Sidebar.anyPluginID
        moreSidebarState = Sidebar.SidebarMiscState(playlistSidebarWidth: playlistWidth,
                                                    selectedSubSegment: selectedSubSegment,
                                                    selectedPluginTabID: selectedPluginTabID)
      } else {
        // v1 of the CSV lacked this info. Fall back to default
        moreSidebarState = Sidebar.SidebarMiscState.fromDefaultPrefs()
      }
      let oscColorScheme = effectiveOSCColorSchemeFromPrefs


      return LayoutState(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar, mode: mode,
                         isInPiP: isInPiP,
                         isLegacyStyle: isLegacyStyle, topBarPlacement: topBarPlacement,
                         bottomBarPlacement: bottomBarPlacement, enableOSC: enableOSC, oscPosition: oscPosition,
                         oscColorScheme: oscColorScheme,
                         interactiveMode: interactiveMode, moreSidebarState: moreSidebarState)
    }

    do {
      if let specV2 = try PlayerSaveState.parseCSV(csv, expectedTokenCount: 15,
                                                   expectedVersion: specPrefStringVersion2,
                                                   targetObjName: "LayoutState v2", parsingFunc) {
        return specV2
      } else {
        let specV1 = try PlayerSaveState.parseCSV(csv, expectedTokenCount: 12,
                                                  expectedVersion: specPrefStringVersion1,
                                                  targetObjName: "LayoutState v1", parsingFunc)
        return specV1
      }
    } catch {
      Logger.log.error("Caught error while parsing LayoutState: \(error)")
      return nil
    }
  }

}

extension PlayerCore {

  /// Generates a Dictionary of properties for storage into a Preference entry
  fileprivate func generatePropDict(_ geo: GeometrySet) -> [String: Any] {
    var props: [String: Any] = [:]
    /// Must *not* access `window`: this is not the main thread
    let layout = pwc.currentLayout

    let buildNumber: Int = info.priorStateBuildNumber
    props[PropName.buildNumber.rawValue] = String(buildNumber)
    props[PropName.launchID.rawValue] = String(UIState.shared.currentLaunchID)

    // - Window Layout & Geometry

    /// `layoutSpec`
    props[PropName.layoutState.rawValue] = layout.toCSV(buildNumber: buildNumber)

    /// `windowedModeGeo`: use supplied GeometrySet for most up-to-date window frame
    props[PropName.windowedModeGeo.rawValue] = geo.windowed.toCSV()

    /// `musicModeGeo`: use supplied GeometrySet for most up-to-date window frame
    props[PropName.musicModeGeo.rawValue] = geo.musicMode.toCSV()

    /// `videoGeo`: use supplied GeometrySet for most up-to-date data (avoiding complex logic to derive it)
    props[PropName.videoGeo.rawValue] = geo.video.toCSV()

    let screenMetaCSVList: [String] = UIState.shared.cachedScreens.values.map{$0.toCSV()}
    props[PropName.screens.rawValue] = screenMetaCSVList

    if pwc.isOnTop {
      props[PropName.isOnTop.rawValue] = true.yn
    }

    // - Misc window state

    if Preference.bool(for: .autoSwitchToMusicMode) {
      var overrideAutoMusicMode = overrideAutoMusicMode
      let audioStatus = info.currentMediaAudioStatus
      if (audioStatus == .notAudio && isInMiniPlayer) || (audioStatus.isAudio && !isInMiniPlayer) {
        /// Need to set this so that when restoring, the player won't immediately overcorrect and auto-switch music mode.
        /// This can happen because the `iinaFileLoaded` event will be fired by mpv very soon after restore is done, which is where it switches.
        overrideAutoMusicMode = true
      }
      props[PropName.overrideAutoMusicMode.rawValue] = overrideAutoMusicMode.yn
    }

    props[PropName.miscWindowBools.rawValue] = [
      pwc.isWindowMiniturized.yn,
      pwc.isWindowHidden.yn,
      layout.isInPiP.yn,  // stored here for historical reasons. MOved into LayoutState in v1.4
      pwc.isWindowMiniaturizedDueToPip.yn,
      pwc.isPausedPriorToInteractiveMode.yn,
      pwc.isZoomedViaGesture.yn,
    ].joined(separator: ",")

    // - Playback State

    if let urlString = info.currentURL?.absoluteString ?? nil {
      props[PropName.url.rawValue] = urlString
    }

    let playlist = info.playlist
    let playlistPaths: [String] = playlist.compactMap{ PlaybackID.path(from: $0.url) }
    if !playlistPaths.isEmpty {
      props[PropName.playlistPaths.rawValue] = playlistPaths
    }
    if let playlistPos = info.currentPlayback?.playlistPos {
      props[PropName.playlistPos.rawValue] = String(playlistPos)
    }

    if let playbackPositionSec = info.playbackPositionSec {
      props[PropName.playPosition.rawValue] = playbackPositionSec.stringMaxFrac6
    }
    if let playbackDurationSec = info.playbackDurationSec {
      props[PropName.playDuration.rawValue] = playbackDurationSec.stringMaxFrac6
    }
    props[PropName.paused.rawValue] = info.isPaused.yn

    // - Video, Audio, Subtitles Settings

    props[PropName.playlistVideos.rawValue] = Array(info.currentVideosInfo.map({
      // Need to store the group prefix length (if any) to allow collapsing it in the playlist. Not easy to recompute
      "\(playlistVideosCSVVersion),\($0.prefix.count),\($0.url.absoluteString)"
    })).joined(separator: " ")
    props[PropName.playlistSubtitles.rawValue] = Array(info.currentSubsInfo.map({$0.url.absoluteString}))
    let matchedSubsArray = info.matchedSubs.map({key, value in (key, Array(value.map({$0.absoluteString})))})
    let matchedSubs: [String: [String]] = Dictionary(uniqueKeysWithValues: matchedSubsArray)
    props[PropName.matchedSubtitles.rawValue] = matchedSubs

    props[PropName.deinterlace.rawValue] = info.deinterlace.yn
    props[PropName.hwdec.rawValue] = info.hwdec
    props[PropName.hdrEnabled.rawValue] = info.hdrEnabled.yn

    // We must restore a non-nil value. Default to 0 (none) if not found
    let vid = info.vid ?? 0
    props[PropName.vid.rawValue] = String(vid)
    if let intVal = info.aid {
      props[PropName.aid.rawValue] = String(intVal)
    }
    if let intVal = info.sid {
      props[PropName.sid.rawValue] = String(intVal)
    }
    if let intVal = info.secondSid {
      props[PropName.s2id.rawValue] = String(intVal)
    }
    let vidDisabled = info.vidDisabled ?? -1
    props[PropName.vidDisabled.rawValue] = String(vidDisabled)
    props[PropName.brightness.rawValue] = String(info.brightness)
    props[PropName.contrast.rawValue] = String(info.contrast)
    props[PropName.saturation.rawValue] = String(info.saturation)
    props[PropName.gamma.rawValue] = String(info.gamma)
    props[PropName.hue.rawValue] = String(info.hue)
    props[PropName.videoZoom.rawValue] = String(info.videoZoom)
    props[PropName.videoPanX.rawValue] = String(info.videoPanX)
    props[PropName.videoPanY.rawValue] = String(info.videoPanY)

    props[PropName.playSpeed.rawValue] = info.playSpeed.stringMaxFrac6
    props[PropName.volume.rawValue] = info.volume.stringMaxFrac6
    props[PropName.isMuted.rawValue] = info.isMuted.yn
    props[PropName.audioDelay.rawValue] = info.audioDelay.stringMaxFrac6
    props[PropName.subDelay.rawValue] = info.subDelay.stringMaxFrac6
    props[PropName.sub2Delay.rawValue] = info.sub2Delay.stringMaxFrac6

    props[PropName.subScale.rawValue] = info.subScale.stringMaxFrac2
    props[PropName.subPos.rawValue] = info.subPos.stringMaxFrac2
    props[PropName.sub2Pos.rawValue] = info.sub2Pos.stringMaxFrac2

    props[PropName.isSubVisible.rawValue] = info.isSubVisible.yn
    props[PropName.isSub2Visible.rawValue] = info.isSecondSubVisible.yn

    props[PropName.subFont.rawValue] = info.subFont
    props[PropName.subFontSize.rawValue] = String(info.subFontSize)
    props[PropName.subColor.rawValue] = info.subColor
    props[PropName.subBgColor.rawValue] = info.subBgColor
    props[PropName.subBorderColor.rawValue] = info.subBorderColor
    props[PropName.subBorderSize.rawValue] = info.subBorderSize.stringMaxFrac2

    let abLoopA: Double = info.abLoopA
    if abLoopA != 0 {
      props[PropName.abLoopA.rawValue] = abLoopA.stringMaxFrac6
    }
    let abLoopB: Double = info.abLoopB
    if abLoopB != 0 {
      props[PropName.abLoopB.rawValue] = abLoopB.stringMaxFrac6
    }

    props[PropName.loopPlaylist.rawValue] = info.loopFile
    props[PropName.loopFile.rawValue] = info.loopPlaylist

    let volumeMax = info.volumeMax
    if volumeMax != 100 {
      props[PropName.maxVolume.rawValue] = String(volumeMax)
    }

    let videoFiltersCSV = PlayerSaveState.toCSV(mpvFilters: info.videoFilters)
    props[PropName.videoFilters.rawValue] = videoFiltersCSV
    let audioFiltersCSV = PlayerSaveState.toCSV(mpvFilters: info.audioFilters)
    props[PropName.audioFilters.rawValue] = audioFiltersCSV

    // Remember: mpv itself uses comma as delimiter between filters in a serialized string (see the mpv docs).
    let videoFiltersDisabled = PlayerSaveState.toCSV(mpvFilters: info.videoFiltersDisabled.values)
    props[PropName.videoFiltersDisabled.rawValue] = videoFiltersDisabled

    let mpvUserOptsString = MPVOptPair.toUndashedLinesString(userOptions)
    props[PropName.mpvOpts.rawValue] = mpvUserOptsString

    return props
  }

  // Saves this player's state asynchronously
  func saveState() {
    guard isSaveEnabled else { return }
    guard pwc.loaded else { return }
    guard !isRestoring else {
      log.trace("Skipping player state save: still restoring previous state")
      return
    }

    /// Runs asynchronously in background queue to avoid blocking UI.
    /// Cuts down on duplicate work via delay and ticket check.
    saveUIStateDebouncer.run { [self] in
      guard !isShuttingDown else {
        log.verbose("Skipping player state save: player is shutting down")
        return
      }
      guard !isStopping else {
        // mpv core is often still active even after closing, and will send events which
        // can trigger save. Need to make sure we check for this so that we don't un-delete state
        log.trace("Skipping player state save: window.isClosing is true")
        return
      }

      guard let pwc = self.pwc else { return }
      DispatchQueue.main.async {
        guard pwc.loaded else {
          pwc.log.trace("Skipping player state save: player window is not loaded")
          return
        }
        pwc.animationPipeline.submitInstantTask {
          guard !pwc.isAnimatingLayoutTransition else {
            /// The transition itself will call `save` when it is done. Just return
            return
          }
          // Retrieve appropriate geometry values, updating to latest window frame if needed:
          let geo = pwc.buildGeoSet(layoutMode: pwc.currentLayout.mode)

          let player = pwc.player
          guard !player.isShuttingDown else { return }

          PlayerSaveState.saveQueue.async {
            let properties = player.generatePropDict(geo)
            if Logger.isTraceEnabled, Preference.bool(for: .logPlayerSave) {
              player.log.trace("Saving player state: \(properties)")
            }
            UIState.shared.saveState(forPlayerID: player.label, properties: properties)
          }
        }
      }
    }
  }

  @MainActor
  func saveSynchronously() {
    guard isSaveEnabled else { return }
    let pwc = pwc!
    guard !pwc.sessionState.isRestoring else {
      log.debug("Skipping synchronous save of player state: player did not finish restoring")
      return
    }
    log.debug("Saving player state synchronously")

    // Retrieve appropriate geometry values, updating to latest window frame if needed:
    let geo: GeometrySet
    if pwc.isAnimatingLayoutTransition {
      geo = pwc.geo
    } else {
      geo = pwc.buildGeoSet(layoutMode: pwc.currentLayout.mode)
    }

    /// Using `sync` here should delay shutdown & makes sure any existing async saves aren't killed mid-write!
    PlayerSaveState.saveQueue.sync {
      let properties = generatePropDict(geo)
      log.trace("Saving player state: \(properties)")
      UIState.shared.saveState(forPlayerID: label, properties: properties)
      log.debug("Done saving player state synchronously")
    }
  }

  @MainActor
  func clearSavedState() {
    UIState.shared.clearPlayerSaveState(forPlayerID: label)
  }
}
