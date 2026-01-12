//
//  Preference.swift
//  iina
//
//  Created by lhc on 17/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

protocol InitializingFromKey {

  static var defaultValue: Self { get }

  init?(key: Preference.Key)

}

struct Preference {

  static func quoted(_ key: Key) -> String {
    return key.rawValue.quoted
  }

  // MARK: - Keys

  // consider using RawRepresentable, but also need to extend UserDefaults
  struct Key: RawRepresentable, Hashable {

    typealias RawValue = String

    var rawValue: RawValue

    var hashValue: Int {
      return rawValue.hashValue
    }

    init(_ string: String) { self.rawValue = string }

    init?(rawValue: RawValue) { self.rawValue = rawValue }

    func isValid() -> Bool {
      // It is valid if it exists and has a default
      return Preference.defaultPreference[self] != nil
    }

    static let receiveBetaUpdate = Key("receiveBetaUpdate")

    static let actionAfterLaunch = Key("actionAfterLaunch")
    static let alwaysOpenInNewWindow = Key("alwaysOpenInNewWindow")
    /// • This setting only applies when `alwaysOpenInNewWindow` is `true`.
    /// • By default, when manually opening (e.g. double-clicking from the Finder, or dragging onto the IINA icon)
    ///   a file that's already loaded in an IINA window, IINA conforms the the standard MacOS behavior: a new window
    ///   is not opened, and instead the existing window which contains it is brought to the front. This setting, if
    ///   `true`, disables this behavior.
    static let allowDuplicatePlayers = Key("allowDuplicatePlayers")
    /// If set to `true`, makes the menu item `File` > `New Window` visible:
    static let enableCmdN = Key("enableCmdN")

    static let animationDurationDefault = Key("animationDurationDefault")
    static let animationDurationFullScreen = Key("animationDurationFullScreen")
    static let animationDurationOSD = Key("animationDurationOSD")
    static let animationDurationCrop = Key("animationDurationCrop")

    /** Record recent files */
    static let recordPlaybackHistory = Key("recordPlaybackHistory")
    static let recordRecentFiles = Key("recordRecentFiles")
    static let trackAllFilesInRecentOpenMenu = Key("trackAllFilesInRecentOpenMenu")

    /** Material for OSC and title bar (Theme(int)) */
    static let themeMaterial = Key("themeMaterial")
    static let playerWindowOpacity = Key("playerWindowOpacity")

    /** Soft volume (int, 0 - 100)*/
    static let softVolume = Key("softVolume")

    /** Pause at first (pause) (bool) */
    static let pauseWhenOpen = Key("pauseWhenOpen")

    /// If true, player windows will auto-hide when IINA is not the frontmost application, and show again when it
    /// is brought back into focus. Only applies to player windows in windowed mode
    static let hideWindowsWhenInactive = Key("hideWindowsWhenInactive")

    /** Enter fill screen when open (bool) */
    static let fullScreenWhenOpen = Key("fullScreenWhenOpen")

    /// Use window `styleMask` which does not include `.titled`. Has sharp corners, and no title bar
    static let useLegacyWindowedMode = Key("useLegacyWindowedMode")

    static let useLegacyFullScreen = Key("useLegacyFullScreen")

    /** Black out other monitors while fullscreen (bool) */
    static let blackOutMonitor = Key("blackOutMonitor")

    /// Quit when no open window (bool)
    static let quitWhenNoOpenedWindow = Key("quitWhenNoOpenedWindow")

    /// For windowed mode only.
    /// `true`: restrict viewport size (i.e. the window size minus any outside bars) to conform to video aspect ratio.
    /// `false`: allow user to resize window and show black bars.
    static let lockViewportToVideoSize = Key("lockViewportToVideoSize")

    /// For windowed mode only.
    /// `true`: when the window is resized, move it back inside the screen's visible rect if is not already
    /// `false`: do nothing if part of it is offscreen after the window is resized.
    static let moveWindowIntoVisibleScreenOnResize = Key("moveWindowIntoVisibleScreenOnResize")

    /// If enabled, in legacy full screen, video will fill entire screen including camera housing, showing a
    /// visible notch in the middle top
    static let allowVideoToOverlapCameraHousing = Key("allowVideoToOverlapCameraHousing")

    /** Keep player window open on end of file / playlist. (bool) */
    static let keepOpenOnFileEnd = Key("keepOpenOnFileEnd")

    /// Pressing pause/resume when stopped at EOF to restart playback
    static let resumeFromEndRestartsPlayback = Key("resumeFromEndRestartsPlayback")

    static let actionWhenNoOpenWindow = Key("actionWhenNoOpenWindow")

    /// Enable the use of mpv's Watch Later feature to save & resume playback position (+ other properties)
    static let resumeLastPosition = Key("resumeLastPosition")

    static let preventScreenSaver = Key("preventScreenSaver")
    static let allowScreenSaverForAudio = Key("allowScreenSaverForAudio")

    /// Always float on top while playing:
    static let alwaysFloatOnTop = Key("alwaysFloatOnTop")
    static let alwaysShowOnTopIcon = Key("alwaysShowOnTopIcon")

    static let pauseWhenMinimized = Key("pauseWhenMinimized")
    static let pauseWhenInactive = Key("pauseWhenInactive")
    static let playWhenEnteringFullScreen = Key("playWhenEnteringFullScreen")
    static let pauseWhenLeavingFullScreen = Key("pauseWhenLeavingFullScreen")
    static let pauseWhenGoesToSleep = Key("pauseWhenGoesToSleep")

    static let autoRepeat = Key("autoRepeat")
    static let defaultRepeatMode = Key("defaultRepeatMode")

    static let screenshotSaveToFile = Key("screenshotSaveToFile")
    static let screenshotCopyToClipboard = Key("screenshotCopyToClipboard")
    static let screenshotFolder = Key("screenShotFolder")
    static let screenshotIncludeSubtitle = Key("screenShotIncludeSubtitle")
    static let screenshotFormat = Key("screenShotFormat")
    static let screenshotTemplate = Key("screenShotTemplate")
    static let screenshotShowPreview = Key("screenshotShowPreview")

    static let playlistAutoAdd = Key("playlistAutoAdd")
    static let playlistAutoPlayNext = Key("playlistAutoPlayNext")
    /// "Show artist and track name for audio files when available"
    static let playlistShowMetadata = Key("playlistShowMetadata")
    /// Same as `playlistShowMetadata` but "only in music mode"
    static let playlistShowMetadataInMusicMode = Key("playlistShowMetadataInMusicMode")

    // MARK: - UI Keys

    // - Title bar & OSC

    static let titleBarBtnsGlow = Key("activeTitleBarBtnsGlow")
    static let showTopBarTrigger = Key("showTopBarTrigger")
    /// Inside or outside viewport?
    static let topBarPlacement = Key("topBarPlacement")
    static let bottomBarPlacement = Key("bottomBarPlacement")

    static let enableOSC = Key("enableOSC")
    /// Top, bottom, or floating
    static let oscPosition = Key("oscPosition")
    /// Blended gray, or clear-black gradient. Only applies to top & bottom OSCs which are `.insideViewport`
    static let oscColorScheme = Key("oscColorScheme")
    static let oscForceSingleRow = Key("oscForceSingleRow")
    static let oscTimeLabelsAlwaysWrapSlider = Key("oscTimeLabelsAlwaysWrapSlider")

    /// Which buttons to display in the OSC, stored as `Array` of `Integer`s
    static let controlBarToolbarButtons = Key("controlBarToolbarButtons")

    // - Top & Bottom OSCs

    /// Total height of the OSC container.
    static let oscBarHeight = Key("oscBarHeight")

    static let oscBarPlayIconSizeTicks = Key("oscBarPlayIconSizeTicks")
    static let oscBarPlayIconSpacingTicks = Key("oscBarPlayIconSpacingTicks")
    static let oscBarToolIconSizeTicks = Key("oscBarToolIconSizeTicks")
    static let oscBarToolIconSpacingTicks = Key("oscBarToolIconSpacingTicks")
    // These get calculated based on the number of ticks. Ideally they would be derived, but that would be tricky
    // because it could introduce race conditions when window preference observers try to detect & respond to multiple
    // simultaneous changes...
    static let oscBarPlayIconSize = Key("oscBarPlayIconSize")
    static let oscBarPlayIconSpacing = Key("oscBarPlayIconSpacing")
    /// Size of one side of a (square) OSC toolbar button
    static let oscBarToolIconSize = Key("oscBarToolIconSize")
    /// The space added around all the sides of each button
    static let oscBarToolIconSpacing = Key("oscBarToolIconSpacing")

    // - Floating OSC

    /// How close the floating OSC is allowed to get to the edges of its available space, in pixels
    static let floatingControlBarMargin = Key("floatingControlBarMargin")
    /// Horizontal position of floating control bar. (float, 0 - 1)
    static let controlBarPositionHorizontal = Key("controlBarPositionHorizontal")
    /// Horizontal position of floating control bar. In percentage from bottom. (float, 0 - 1)
    static let controlBarPositionVertical = Key("controlBarPositionVertical")
    static let floatingControlBarWidth = Key("floatingControlBarWidth")

    /// Whether floating OSC can snap to center when dragging close to it.
    static let controlBarStickToCenter = Key("controlBarStickToCenter")

    // - Play Slider & Volume Slider

    /// If true, highlight the part of the playback slider to the right of the knob
    /// which has already been loaded into the demuxer cache.
    ///
    /// Applies to remote files only. This is always enabled for streaming media.
    static let showCachedRangesInSlider = Key("showCachedRangesInSlider")
    static let roundSliderBarRects = Key("roundSliderBarRects")
    static let sliderBarDoneColor = Key("sliderBarDoneColor")
    static let useSliderFocusMagnifyEffect = Key("useSliderFocusMagnifyEffect")
    static let alwaysShowSliderKnob = Key("alwaysShowSliderKnob")
    // If true, break up the PlaySlider bar into chapter segments. (bool)
    static let showChapterPos = Key("showChapterPos")

    // - Fadeable ("Inside") Views

    /// Whether auto hiding `.insideViewport` views is enabled. (bool).
    static let enableControlBarAutoHide = Key("enableControlBarAutoHide")
    /// Timeout for auto hiding OSC (if it is `.insideViewport`) & other overlays (float).
    static let controlBarAutoHideTimeout = Key("controlBarAutoHideTimeout")
    static let hideFadeableViewsWhenOutsideWindow = Key("hideFadeableViewsWhenOutsideWindow")

    // - OSD

    /// Enable/disable OSD
    static let enableOSD = Key("enableOSD")
    /// Only valid if `enableOSD` is `true`.
    static let enableOSDInMusicMode = Key("enableOSDInMusicMode")

    static let osdPosition = Key("osdPosition")
    static let disableOSDFileStartMsg = Key("disableOSDFileStartMsg")
    static let disableOSDPauseResumeMsgs = Key("disableOSDPauseResumeMsgs")
    static let disableOSDSeekMsg = Key("disableOSDSeekMsg")
    static let disableOSDSpeedMsg = Key("disableOSDSpeedMsg")
    static let disableOSDVideoZoomMsg = Key("disableOSDVideoZoomMsg")

    static let osdAutoHideTimeout = Key("osdAutoHideTimeout")
    static let osdTextSize = Key("osdTextSize")

    // - Window Geometry

    static let usePhysicalResolution = Key("usePhysicalResolution")
    static let initialWindowSizePosition = Key("initialWindowSizePosition")
    static let resizeWindowScheme = Key("resizeWindowScheme")
    static let resizeWindowTiming = Key("resizeWindowTiming")
    static let resizeWindowOption = Key("resizeWindowOption")
    /// If `true` & `lockViewportToVideoSize==false` & there is extra space in viewport,
    /// adjust center of VideoView as much as possible to avoid overlapping inside bars.
    static let keepVideoAwayFromBars = Key("keepVideoAwayFromBars")

    // - Sidebars

    static let leadingSidebarPlacement = Key("leadingSidebarPlacement")
    static let trailingSidebarPlacement = Key("trailingSidebarPlacement")
    static let showLeadingSidebarToggleButton = Key("showLeadingSidebarToggleButton")
    static let showTrailingSidebarToggleButton = Key("showTrailingSidebarToggleButton")
    static let hideLeadingSidebarOnClick = Key("hideLeadingSidebarOnClick")
    static let hideTrailingSidebarOnClick = Key("hideTrailingSidebarOnClick")
    /// `Settings` tab group (leading or trailing)
    static let settingsTabGroupLocation = Key("settingsTabGroupLocation")
    /// `Playlist` tab group (leading or trailing)
    static let playlistTabGroupLocation = Key("playlistTabGroupLocation")
    /// `Plugin` tab group (leading or trailing)
    static let pluginsTabGroupLocation = Key("pluginsTabGroupLocation")
    /// Preferred height of playlist (excluding music mode)
    static let playlistWidth = Key("playlistWidth")
    static let prefetchPlaylistVideoDuration = Key("prefetchPlaylistVideoDuration")
    static let prefetchPlaylistVideoGeometry = Key("prefetchPlaylistVideoGeometry")

    // - Thumbnail

    static let enableThumbnailPreview = Key("enableThumbnailPreview")
    static let enableThumbnailForRemoteFiles = Key("enableThumbnailForRemoteFiles")
    static let enableThumbnailForMusicMode = Key("enableThumbnailForMusicMode")
    static let showThumbnailDuringSliderSeek = Key("showThumbnailDuringSliderSeek")
    static let thumbnailBorderStyle = Key("thumbnailBorderStyle")
    static let thumbnailSizeOption = Key("thumbnailSizeOption")
    /// Only for `ThumbnailSizeOption.fixed`. Length of the longer dimension of thumbnail in screen points.
    /// May be scaled down if needed to fit inside window.
    static let thumbnailFixedLength = Key("thumbnailFixedLength")
    /// Only for `ThumbnailSizeOption.scaleWithViewport`. Quality of generated thumbnail as % of raw video size, 1 - 100.
    /// Will be scaled up/down to satisfy `thumbnailDisplayedSizePercentage`; may be scaled down if needed to fit inside window.
    static let thumbnailRawSizePercentage = Key("thumbnailRawSizePercentage")
    /// Only for `ThumbnailSizeOption.scaleWithViewport`. Size of displayed thumbnail as % of displayed video, 1 - 100
    static let thumbnailDisplayedSizePercentage = Key("thumbnailDisplayedSizePercentage")
    static let maxThumbnailPreviewCacheSize = Key("maxThumbnailPreviewCacheSize")

    static let integrateWithThumbfast = Key("integrateWithThumbfast")

    // - Seek Preview

    static let seekPreviewHasTimeDelta = Key("seekPreviewHasTimeDelta")
    static let seekPreviewHasChapter = Key("seekPreviewHasChapter")
    static let seekPreviewShadow = Key("seekPreviewShadow")

    // - Music mode

    static let autoSwitchToMusicMode = Key("autoSwitchToMusicMode")
    static let musicModeShowPlaylist = Key("musicModeShowPlaylist")
    static let musicModeShowAlbumArt = Key("musicModeShowAlbumArt")
    static let musicModePlaylistHeight = Key("musicModePlaylistHeight")
    static let musicModeMaxWidth = Key("musicModeMaxWidth")

    static let displayTimeAndBatteryInFullScreen = Key("displayTimeAndBatteryInFullScreen")

    // - Picture-in-Picture (PiP)

    static let windowBehaviorWhenPip = Key("windowBehaviorWhenPip")
    static let pauseWhenPip = Key("pauseWhenPip")
    static let togglePipByMinimizingWindow = Key("togglePipByMinimizingWindow")
    static let togglePipWhenSwitchingSpaces = Key("togglePipWhenSwitchingSpaces")
    static let togglePipByMinimizingWindowForVideoOnly = Key("togglePipByMinimizingWindowForVideoOnly")

    static let disableAnimations = Key("disableAnimations")
    static let windowLaunchAnimation = Key("windowLaunchAnimation")
    static let playerWindowOpenCloseAnimation = Key("playerWindowOpenCloseAnimation")
    static let auxWindowOpenCloseAnimation = Key("auxWindowOpenCloseAnimation")

    // MARK: - Keys: Codec

    static let videoThreads = Key("videoThreads")
    static let hardwareDecoder = Key("hardwareDecoder")
    static let forceDedicatedGPU = Key("forceDedicatedGPU")
    static let loadIccProfile = Key("loadIccProfile")
    static let enableHdrSupport = Key("enableHdrSupport")
    static let enableToneMapping = Key("enableToneMapping")
    static let toneMappingTargetPeak = Key("toneMappingTargetPeak")
    static let toneMappingAlgorithm = Key("toneMappingAlgorithm")

    static let audioDriverEnableAVFoundation = Key("audioDriverEnableAVFoundation")
    static let audioThreads = Key("audioThreads")
    static let audioLanguage = Key("audioLanguage")
    static let maxVolume = Key("maxVolume")

    static let spdifAC3 = Key("spdifAC3")
    static let spdifDTS = Key("spdifDTS")
    static let spdifDTSHD = Key("spdifDTSHD")

    static let audioDevice = Key("audioDevice")
    static let audioDeviceDesc = Key("audioDeviceDesc")

    static let enableInitialVolume = Key("enableInitialVolume")
    static let initialVolume = Key("initialVolume")

    static let replayGain = Key("replayGain")
    static let replayGainPreamp = Key("replayGainPreamp")
    static let replayGainClip = Key("replayGainClip")
    static let replayGainFallback = Key("replayGainFallback")

    static let gaplessAudio = Key("gaplessAudio")

    static let userEQPresets = Key("userEQPresets")

    // MARK: - Keys: Subtitle

    static let subAutoLoadIINA = Key("subAutoLoadIINA")
    static let subAutoLoadPriorityString = Key("subAutoLoadPriorityString")
    static let subAutoLoadSearchPath = Key("subAutoLoadSearchPath")
    static let ignoreAssStyles = Key("ignoreAssStyles")
    static let subOverrideLevel = Key("subOverrideLevel")
    static let secondarySubOverrideLevel = Key("secondarySubOverrideLevel")
    static let subTextFont = Key("subTextFont")
    static let subTextSize = Key("subTextSize")
    static let subTextColorString = Key("subTextColorString")
    static let subBgColorString = Key("subBgColorString")
    static let subBold = Key("subBold")
    static let subItalic = Key("subItalic")
    static let subBlur = Key("subBlur")
    static let subSpacing = Key("subSpacing")
    static let subBorderSize = Key("subBorderSize")
    static let subBorderColorString = Key("subBorderColorString")
    static let subShadowSize = Key("subShadowSize")
    static let subShadowColorString = Key("subShadowColorString")
    static let subAlignX = Key("subAlignX")
    static let subAlignY = Key("subAlignY")
    static let subMarginX = Key("subMarginX")
    static let subMarginY = Key("subMarginY")
    static let subPos = Key("subPos")
    static let subScale = Key("subScale")
    static let subLang = Key("subLang")
    static let legacyOnlineSubSource = Key("onlineSubSource")
    static let onlineSubProvider = Key("onlineSubProvider")
    static let displayInLetterBox = Key("displayInLetterBox")
    static let subScaleWithWindow = Key("subScaleWithWindow")
    static let openSubUsername = Key("openSubUsername")
    static let assrtToken = Key("assrtToken")
    static let defaultEncoding = Key("defaultEncoding")
    static let autoSearchOnlineSub = Key("autoSearchOnlineSub")
    static let autoSearchThreshold = Key("autoSearchThreshold")

    // MARK: - Keys: Network

    static let enableCache = Key("enableCache")
    static let defaultCacheSize = Key("defaultCacheSize")
    static let cacheBufferSize = Key("cacheBufferSize")
    static let secPrefech = Key("secPrefech")
    static let showBufferingThrobber = Key("showBufferingThrobber")
    static let showSeekingThrobber = Key("showSeekingThrobber")
    static let userAgent = Key("userAgent")
    static let transportRTSPThrough = Key("transportRTSPThrough")
    static let ytdlEnabled = Key("ytdlEnabled")
    static let ytdlSearchPath = Key("ytdlSearchPath")
    static let ytdlRawOptions = Key("ytdlRawOptions")
    static let httpProxy = Key("httpProxy")

    // MARK: - Keys: Control

    /** Seek option */
    static let useExactSeek = Key("useExactSeek")

    /** Seek speed for non-exact relative seek (Int, 1~5) */
    static let relativeSeekAmount = Key("relativeSeekAmount")

    static let arrowButtonAction = Key("arrowBtnAction")
    /// If `true`, the playback speed will be reset to 1x whenever the media is paused
    static let resetSpeedWhenPaused = Key("resetSpeedWhenPaused")
    static let useForceTouchForSpeedArrows = Key("useForceTouchForSpeedArrows")
    /** (1~4) */
    static let volumeScrollAmount = Key("volumeScrollAmount")
    static let playbackSpeedScrollAmount = Key("playbackSpeedScrollAmount")
    static let verticalScrollAction = Key("verticalScrollAction")
    static let horizontalScrollAction = Key("horizontalScrollAction")
    /// If true, scrolling either vertically or horizontally while hovered over either the playback position or volume slider
    /// will adjust the value of that slider.
    static let enableScrollOverSliders = Key("enableScrollOverSliders")

    static let videoViewAcceptsFirstMouse = Key("videoViewAcceptsFirstMouse")
    static let singleClickAction = Key("singleClickAction")
    static let doubleClickAction = Key("doubleClickAction")
    static let rightClickAction = Key("rightClickAction")
    static let middleClickAction = Key("middleClickAction")
    static let pinchAction = Key("pinchAction")
    static let rotateAction = Key("rotateAction")
    static let forceTouchAction = Key("forceTouchAction")

    static let enablePinchToVideoZoom = Key("enablePinchToVideoZoom")
    static let pinchMaxZoom = Key("pinchMaxZoom")

    static let showRemainingTime = Key("showRemainingTime")
    static let scaleRemainingTime = Key("scaleRemainingTime")
    static let timeDisplayPrecision = Key("timeDisplayPrecision")
    static let touchbarShowRemainingTime = Key("touchbarShowRemainingTime")

    static let followGlobalSeekTypeWhenAdjustSlider = Key("followGlobalSeekTypeWhenAdjustSlider")

    static let enablePlaylistLoop = Key("enablePlaylistLoop")
    static let enableFileLoop = Key("enableFileLoop")

    /// If true, scan playlist filenames with identical starting strings.  replace them with `…` button
    static let shortenFileGroupsInPlaylist = Key("shortenFileGroupsInPlaylist")

    // MARK: Input / Key Bindings

    /// Whether to integrate with Media Center to enable use of media keys and also Now Playing (bool)
    static let useMediaKeys = Key("useMediaKeys")

    /// The file name (without the .conf suffix) of the currently active input configuration.
    static let currentInputConfigName = Key("currentInputConfigName")

    /// Saved value of checkbox in Key Bindings settings UI
    static let displayKeyBindingRawValues = Key("displayKeyBindingRawValues")

    /* Behavior when setting the name of a new configuration to the Settings > Key Bindings > Configuration table, when duplicating an
     existing file or adding a new file.
     If true, a new row will be created in the table and a field editor will be displayed in it to allow setting the name (more modern).
     If false, a dialog will pop up containing a prompt and text field for entering the name.
     */
    static let useInlineEditorInsteadOfDialogForNewInputConf = Key("useInlineEditorInsteadOfDialogForNewInputConf")

    /* [advanced] If true, a selection of raw text can be pasted, or dragged from an input config file and dropped as a list of
     input bindings wherever input bindings can be dropped. */
    static let acceptRawTextAsKeyBindings = Key("acceptRawTextAsKeyBindings")

    /* If true, when the Key Bindings table is completely reloaded (as when changing the selected conf file), the changes will be animated using
     a calculated diff of the new contents compared to the old. If false, the contents of the table will be changed without an animation. */
    static let animateKeyBindingTableReloadAll = Key("animateKeyBindingTableReloadAll")

    /* [advanced] If true, enables spreadsheet-like navigation for quickly editing the Key Bindings table.
     When this pref is `true`:
     * When editing the last column of a row, pressing TAB accepts changes and opens a new editor in the first column of the next row.
     * When editing the first column of a row, pressing SHIFT+TAB accepts changes and opens a new editor in the last column of the previous row.
     * When editing any column, pressing RETURN will accept changes and open an editor in the same column of the next row.
     When this pref is `false` (default), each of the above actions will accept changes but will not open a new editor.
     */
    static let tableEditKeyNavContinuesBetweenRows = Key("tableEditKeyNavContinuesBetweenRows")

    // MARK: - Keys: Advanced

    /// Enable advanced settings
    static let enableAdvancedSettings = Key("enableAdvancedSettings")

    /// Use mpv's OSD (bool)
    static let useMpvOsd = Key("useMpvOsd")

    // MARK: Logging

    /// If true, enable logging to file (only if `enableAdvancedSettings` is also true).
    static let enableLogging = Key("enableLogging")
    static let logLevel = Key("logLevel")
    /// Log level threshold for logging to stdout via print() statements.
    /// The value given in `logLevel` will be the maximum level which will be honored.
    static let stdoutLogLevel = Key("stdoutLogLevel")
    /// [advanced] Specifies the highest level of mpv logging to include in the IINA log. Only enabled if `enableLogging` is true.
    ///
    /// - This mechanism is mutually exclusive to any log files which mpv writes to. Each mpv core will have its own category name
    ///   in the IINA log with the format `mpv-{playerID}`.
    /// - The value contained in this pref should be a string which matches the name of an mpv log level. See `MPVLogLevel`.
    static let mpvEventLogLevel = Key("mpvEventLogLevel")

    static let enablePiiMaskingInLog = Key("enablePiiMaskingInLog")

    /// [debugging] If true, enables even more verbose logging so that input bindings computations can be more easily debugged.
    static let logKeyBindingsRebuild = Key("logKeyBindingsRebuild")

    /// If true, and trace-level logging is enabled, log the details of every save of player state.
    /// This is frequent and verbose and can clutter up even trace-level logs, which is why this setting is false by default.
    static let logPlayerSave = Key("logPlayerSave")

    /// Normally, all logging is disabled if using options `--o` or `--macos-app-activation-policy=accessory` (both of which
    /// are used by `thumbfast.lua`). Change this to true to log these launches like any other.
    static let logNonInteractiveLaunches = Key("logNonInteractiveLaunches")

    // MARK: - mpv Options

    /// User defined mpv options ([string, string])
    static let userOptions = Key("userOptions")

    /// Whether to use a user-defined mpv config directory (`PK.userDefinedConfDir`)
    static let useUserDefinedConfDir = Key("useUserDefinedConfDir")
    /// User-defined mpv config directory (e.g., `~/.config/mpv/`
    static let userDefinedConfDir = Key("userDefinedConfDir")

    /// Inspector window watch list
    static let watchProperties = Key("watchProperties")

    // MARK: - Other Saved User Data

    static let savedVideoFilters = Key("savedVideoFilters")
    static let savedAudioFilters = Key("savedAudioFilters")

    // These are apparently only used for display in the welcome window
    static let iinaLastPlayedFilePath = Key("iinaLastPlayedFilePath")
    static let iinaLastPlayedFilePosition = Key("iinaLastPlayedFilePosition")

    static let iinaEnablePluginSystem = Key("iinaEnablePluginSystem")

    /// Workaround for issue [#4688](https://github.com/iina/iina/issues/4688)
    /// - Note: This workaround can cause significant slowdown at startup if the list of recent documents contains files on a mounted
    ///         volume that is unreachable. For this reason the workaround is disabled by default and must be enabled by running the
    ///         following command in [Terminal](https://support.apple.com/guide/terminal/welcome/mac):
    ///         `defaults write com.colliderli.iina enableRecentDocumentsWorkaround true`
    static let enableRecentDocumentsWorkaround = Key("enableRecentDocumentsWorkaround")
    static let recentDocuments = Key("recentDocuments")

    static let aspectRatioPanelPresets = Key("aspectRatioPanelPresets")
    static let cropPanelPresets = Key("cropPanelPresets")

    // MARK: - Keys: Internal UI State

    /// When saving and restoring the UI state is enabled, we need to first check if other instances of IINA Advance are running so that they
    /// don't overwrite each other's data. To do that, we can have each instance listen for changes to this counter and respond
    /// appropriately.
    static let launchCount = Key("LaunchCount")

    /// If true:
    /// 1. Enables save of IINA's UI state as it changes
    /// 2. Enables restore of previous launches when app is relaunched.
    ///
    /// NOTE: Do not use this directly. Use `UIState.shared.isRestoreEnabled()` so that runtime overrides work.
    static let enableRestoreUIState = Key("enableRestoreUIState")

    static let alwaysAskBeforeRestoreAtLaunch = Key("alwaysAskBeforeRestoreAtLaunch")
    static let alwaysPauseMediaWhenRestoringAtLaunch = Key("alwaysPauseMediaWhenRestoringAtLaunch")
    /// If `enableRestoreUIStateForCmdLineLaunch==false`, then save & restore of UI state will be disabled
    /// for launches via the command line (as though `enableRestoreUIState==false`).
    static let enableRestoreUIStateForCmdLineLaunches = Key("enableRestoreUIStateForCmdLineLaunches")
    static let isRestoreInProgress = Key("isRestoreInProgress")

    static let uiPrefWindowSearchString = Key("uiPrefWindowSearchString")
    // Index of currently selected tab in Navigator table
    static let uiPrefWindowNavTableSelectionIndex = Key("uiPrefWindowNavTableSelectionIndex")
    static let uiPrefDetailViewScrollOffsetY = Key("uiPrefDetailViewScrollOffsetY")
    /// These must match the identifier of their respective CollapseView's button, except replacing the "Trigger" prefix with
    /// "uiCollapseView": `true` == open;  `false` == folded
    static let uiCollapseViewSuppressOSDMessages = Key("uiCollapseViewSuppressOSDMessages")
    static let uiCollapseViewSubAutoLoadAdvanced = Key("uiCollapseViewSubAutoLoadAdvanced")
    static let uiPrefBindingsTableSearchString = Key("uiPrefBindingsTableSearchString")
    static let showKeyBindingsFromAllSources = Key("showKeyBindingsFromAllSources")
    static let uiPrefBindingsTableScrollOffsetY = Key("uiPrefBindingsTableScrollOffsetY")

    static let uiInspectorWindowTabIndex = Key("uiInspectorWindowTabIndex")

    static let uiHistoryTableGroupBy = Key("uiHistoryTableGroupBy")
    static let uiHistoryTableSearchType = Key("uiHistoryTableSearchType")
    static let uiHistoryTableSearchString = Key("uiHistoryTableSearchString")

    static let uiLastClosedWindowedModeGeometry = Key("uiLastClosedWindowedModeGeometry")
    static let uiLastClosedMusicModeGeometry = Key("uiLastClosedMusicModeGeometry")

    // MARK: - Misc Flags

    /// In some cases (usually while debugging, but possibly others), instances of IINA which are launched in non-interactive mode
    /// (e.g., by Thumbfast) will keep running even after their parent process has died. These zombie processes use resources and can
    /// also interfere with a new interactive launch. For some reason these instances sometimes show a running status in the Dock, and
    /// receive the `applicationShouldHandleReopen` callback, but whether responding to it with Y or N, it seems to block a new instance
    /// from being launched in interactive mode. There now exists logic to kill any non-interactive mode instances when they receive
    /// `applicationShouldHandleReopen`, but this functionality can be disabled by setting this pref to `false`.
    static let killNonInteractiveLaunchesAtReopen = Key("killNonInteractiveLaunchesAtReopen")

    /// Janky substitute for an IPC message. Postted when an IINA client requests all clients to quit.
    static let killRequest = Key("killRequest")

    static let enableFFmpegImageDecoder = Key("enableFFmpegImageDecoder")

    /// The belief is that the workaround for issue #3844 that adds a tiny subview to the player window is no longer needed.
    /// To confirm this the workaround is being disabled by default using this preference. Should all go well this workaround will be
    /// removed in the future.
    static let enableHdrWorkaround = Key("enableHdrWorkaround")

    /// Internal setting to allow disabling the new feature that shows cover artwork in the Now Playing module in case a serious
    /// problem is encountered.
    static let enableNowPlayingArtwork = Key("enableNowPlayingArtwork")

    /// Internal setting to allow disabling the feature that detects when a display is idle and shuts down the display link to save energy
    /// in case a problem is found where the display link is shut down when it is needed.
    static let enableDisplayIdle = Key("enableDisplayIdle")
  }

  // MARK: - Enums

  enum ActionAfterLaunch: Int, InitializingFromKey {
    case welcomeWindow = 0
    case openPanel
    case none
    case historyWindow

    static let defaultValue = ActionAfterLaunch.welcomeWindow

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var description: String {
      switch self {
      case .welcomeWindow:
        return "Show welcome window"
      case .openPanel:
        return "Show open file panel"
      case .none:
        return "Do nothing"
      case .historyWindow:
        return "Show Playback History window"
      }
    }
  }

  enum ActionWhenNoOpenWindow: Int, InitializingFromKey {
    case sameActionAsLaunch = 0
    case quit
    case none

    static let defaultValue = ActionWhenNoOpenWindow.none

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum ArrowButtonAction: Int, InitializingFromKey, CustomStringConvertible {
    case speed = 0
    case playlist = 1
    case seek = 2
    case unused = 3

    static let defaultValue = ArrowButtonAction.speed

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var description: String {
      switch self {
      case .speed: return "Speed(\(rawValue))"
      case .playlist: return "Playlist(\(rawValue))"
      case .seek: return "Seek(\(rawValue))"
      case .unused: return "Unused(\(rawValue))"
      }
    }
  }

  enum WindowOpenCloseAnimation: Int, InitializingFromKey {
    case none = 0
    case useDefault = 1
    case zoomIn = 2

    static let defaultValue = WindowOpenCloseAnimation.useDefault

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }


  enum Theme: Int, InitializingFromKey {
    case dark = 0
    /// Obsolete
    case ultraDark // 1
    case light // 2
    /// Obsolete
    case mediumLight // 3
    case system // 4

    static let defaultValue = Theme.dark

    init?(key: Key) {
      let value = Preference.integer(for: key)
      if value == 1 || value == 3 {
        return nil
      }
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum Shadow: Int, InitializingFromKey {
    case none = 0
    case dark
    case glow

    static let defaultValue = Shadow.dark

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }


  enum ThumnailBorderStyle: Int, InitializingFromKey {
    case plain = 1
    case outlineSharpCorners = 3
    case outlineRoundedCorners
    case shadowSharpCorners
    case shadowRoundedCorners
    case outlinePlusShadowSharpCorners
    case outlinePlusShadowRoundedCorners

    static let defaultValue = ThumnailBorderStyle.shadowRoundedCorners

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var hasShadow: Bool {
      switch self {
      case .shadowSharpCorners, .shadowRoundedCorners,
          .outlinePlusShadowSharpCorners, .outlinePlusShadowRoundedCorners:
        return true
      default:
        return false
      }
    }
  }

  enum ThumbnailSizeOption: Int, InitializingFromKey {
    case fixedSize = 1
    /// Percentage of displayed video size
    case scaleWithViewport

    static let defaultValue = ThumbnailSizeOption.scaleWithViewport

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum OSDPosition: Int, InitializingFromKey {
    case topLeading = 1
    case topTrailing

    static let defaultValue = OSDPosition.topLeading

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum SidebarLocation: Int, InitializingFromKey, CustomStringConvertible {
    case leadingSidebar = 1
    case trailingSidebar

    static let defaultValue = SidebarLocation.trailingSidebar

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var description: String {
      self == .leadingSidebar ? "leadingSidebar" : "trailingSidebar"
    }

  }

  enum PanelPlacement: Int, InitializingFromKey, CustomStringConvertible {
    case insideViewport = 1
    case outsideViewport

    static let defaultValue = PanelPlacement.insideViewport

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    init?(_ intValue: Int?) {
      guard let intValue = intValue else {
        return nil
      }
      self.init(rawValue: intValue)
    }

    var description: String {
      self == .insideViewport ? "inside" : "outside"
    }
  }

  enum OSCColorScheme: Int, InitializingFromKey, CustomStringConvertible {
    /// Use Apple's `NSVisualEffectView`
    case visualEffectView = 1
    /// Use clear background with slight alpha gradient
    case clearGradient

    static let defaultValue = OSCColorScheme.clearGradient

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    init?(_ intValue: Int?) {
      guard let intValue = intValue else {
        return nil
      }
      self.init(rawValue: intValue)
    }

    var description: String {
      self == .visualEffectView ? "visualEffectView" : "clearGradient"
    }
  }

  enum ShowTopBarTrigger: Int, InitializingFromKey {
    case windowHover = 1
    case topBarHover

    static let defaultValue = ShowTopBarTrigger.windowHover

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum OSCPosition: Int, InitializingFromKey, CustomStringConvertible {
    case floating = 0
    case top
    case bottom

    static let defaultValue = OSCPosition.bottom

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var description: String {
      switch self {
      case .floating: return "floating(\(rawValue))"
      case .top: return "top(\(rawValue))"
      case .bottom: return "bottom(\(rawValue))"
      }
    }
  }

  enum SliderBarLeftColor: Int, InitializingFromKey {
    case controlAccentColor = 1
    case gray = 2

    static let defaultValue = SliderBarLeftColor.controlAccentColor

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum SeekOption: Int, InitializingFromKey {
    case keyframes = 0
    case exact
    case auto

    static let defaultValue = SeekOption.exact

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum MouseClickAction: Int, InitializingFromKey {
    case none = 0
    case fullscreen
    case pause
    case hideOSC
    case togglePIP
    case abLoop
    case resetSpeed
    case contextMenu

    static let defaultValue = MouseClickAction.none

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum ScrollAction: Int, InitializingFromKey {
    /// Ideally, `none` would be `0`, but we need to support legacy behavior
    case volume = 0
    case seek
    case none
    case passToMpv
    case playbackSpeed

    static let defaultValue = ScrollAction.volume

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum PinchAction: Int, InitializingFromKey {
    /// Ideally, `none` would be `0`, but we need to support legacy behavior
    case windowSize = 0
    case fullScreen
    case none
    case windowSizeOrFullScreen

    static let defaultValue = PinchAction.windowSize

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum RotateAction: Int, InitializingFromKey {
    case none = 0
    case rotateVideoByQuarters

    static let defaultValue = RotateAction.rotateVideoByQuarters

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum IINAAutoLoadAction: Int, InitializingFromKey {
    case disabled = 0
    case mpvFuzzy
    case iina

    static let defaultValue = IINAAutoLoadAction.iina

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    func shouldLoadSubsContainingVideoName() -> Bool {
      return self != .disabled
    }

    func shouldLoadSubsMatchedByIINA() -> Bool {
      return self == .iina
    }
  }

  enum AutoLoadAction: Int, InitializingFromKey {
    case no = 0
    case exact
    case fuzzy
    case all

    static let defaultValue = AutoLoadAction.fuzzy

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var string: String {
      get {
        switch self {
        case .no: return "no"
        case .exact: return "exact"
        case .fuzzy: return "fuzzy"
        case .all: return "all"
        }
      }
    }
  }

  /// Enum values for the IINA settings that correspond to the `mpv`
  /// [sub-ass-override](https://mpv.io/manual/stable/#options-sub-ass-override) and
  /// [secondary-sub-ass-override](https://mpv.io/manual/stable/#options-secondary-sub-ass-override) options.
  ///- Important: In order to preserve backward compatibility with enum values stored in user's settings `scale` and `no`were
  ///     added to the end of the enumeration. This is why the constants are not ordered from least impactful to most impactful.
  enum SubOverrideLevel: Int, InitializingFromKey {
    case yes = 0
    case force
    case strip
    case scale
    case no

    static let defaultValue = SubOverrideLevel.scale

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var string: String {
      get {
        switch self {
        case .yes: return "yes"
        case .force : return "force"
        case .strip: return "strip"
        case .scale: return "scale"
        case .no: return "no"
        }
      }
    }
  }

  enum SubAlign: Int, InitializingFromKey {
    case top = 0  // left
    case center
    case bottom  // right

    static let defaultValue = SubAlign.center

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var stringForX: String {
      get {
        switch self {
        case .top: return "left"
        case .center: return "center"
        case .bottom: return "right"
        }
      }
    }

    var stringForY: String {
      get {
        switch self {
        case .top: return "top"
        case .center: return "center"
        case .bottom: return "bottom"
        }
      }
    }
  }

  enum RTSPTransportation: Int, InitializingFromKey {
    case lavf = 0
    case tcp
    case udp
    case http

    static let defaultValue = RTSPTransportation.tcp

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var string: String {
      get {
        switch self {
        case .lavf: return "lavf"
        case .tcp: return "tcp"
        case .udp: return "udp"
        case .http: return "http"
        }
      }
    }
  }

  enum ScreenshotFormat: Int, InitializingFromKey {
    case png = 0
    case jpg
    case jpeg
    case webp
    case jxl

    static let defaultValue = ScreenshotFormat.png

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var string: String {
      get {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
        case .jpeg: return "jpeg"
        case .webp: return "webp"
        case .jxl: return "jxl"
        }
      }
    }
  }

  enum HardwareDecoderOption: Int, InitializingFromKey {
    case disabled = 0
    case auto
    case autoCopy

    static let defaultValue = HardwareDecoderOption.autoCopy

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var mpvString: String {
      switch self {
      case .disabled: return "no"
      case .auto: return "auto"
      case .autoCopy: return "auto-copy"
      }
    }

    var localizedDescription: String {
      return NSLocalizedString("hwdec." + mpvString, comment: mpvString)
    }
  }

  enum ToneMappingAlgorithmOption: Int, InitializingFromKey {
    case auto = 0
    case clip
    case mobius
    case reinhard
    case hable
    case bt_2390
    case gamma
    case linear

    static let defaultValue = ToneMappingAlgorithmOption.auto

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var mpvString: String {
      switch self {
      case .auto: return "auto"
      case .clip: return "clip"
      case .mobius: return "mobius"
      case .reinhard: return "reinhard"
      case .hable: return "hable"
      case .bt_2390: return "bt.2390"
      case .gamma: return "gamma"
      case .linear: return "linear"
      }
    }
  }

  enum ResizeWindowScheme: Int, InitializingFromKey {
    case simpleVideoSizeMultiple = 1
    case mpvGeometry

    static let defaultValue = ResizeWindowScheme.simpleVideoSizeMultiple

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum ResizeWindowTiming: Int, InitializingFromKey {
    case always = 0
    case onlyWhenOpen
    case never

    static let defaultValue = ResizeWindowTiming.onlyWhenOpen

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum ResizeWindowOption: Int, InitializingFromKey {
    case fitScreen = 0
    case videoSize05
    case videoSize10
    case videoSize15
    case videoSize20

    static let defaultValue = ResizeWindowOption.videoSize10

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var ratio: Double {
      switch self {
      case .fitScreen: return -1
      case .videoSize05: return 0.5
      case .videoSize10: return 1
      case .videoSize15: return 1.5
      case .videoSize20: return 2
      }
    }
  }

  enum WindowBehaviorWhenPip: Int, InitializingFromKey, CustomStringConvertible {
    case doNothing = 0
    case hide
    case minimize

    static let defaultValue = WindowBehaviorWhenPip.doNothing

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var description: String {
      switch self {
      case .doNothing:
        return "doNothing"
      case .hide:
        return "hide"
      case .minimize:
        return "minimize"
      }
    }
  }

  enum ToolBarButton: Int {
    case settings = 0
    case playlist
    case pip
    case fullScreen
    case musicMode
    case subTrack
    case screenshot
    case plugins

    func image() -> NSImage {
      func makeSymbol(_ names: [String], _ fallbackImage: NSImage.Name) -> NSImage {
        guard #available(macOS 14.0, *) else { return NSImage(named: fallbackImage)! }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage.findSFSymbol(names, withConfiguration: configuration)
      }
      switch self {
      case .settings: return makeSymbol(["gearshape"], NSImage.actionTemplateName)
      case .playlist: return makeSymbol(["list.bullet.rectangle", "list.bullet"], "playlist")
      case .pip: return makeSymbol(["pip.swap"], "pip")
      case .fullScreen: return makeSymbol(["arrow.up.backward.and.arrow.down.forward.rectangle", "arrow.up.left.and.arrow.down.right"], "fullscreen")
      case .musicMode: return makeSymbol(["music.microphone", "music.mic"], "toggle-album-art")
      case .subTrack: return makeSymbol(["captions.bubble.fill"], "sub-track")
      case .screenshot: return makeSymbol(["camera.shutter.button"], "screenshot")
      case .plugins: return makeSymbol(["puzzlepiece.extension"], "plugin")
      }
    }

    var keyString: String {
      let key: String
      switch self {
      case .settings: key = "settings"
      case .playlist: key = "playlist"
      case .pip: key = "pip"
      case .fullScreen: key = "full_screen"
      case .musicMode: key = "music_mode"
      case .subTrack: key = "sub_track"
      case .screenshot: key = "screenshot"
      case .plugins: key = "plugins"
      }

      return key
    }

    func description() -> String {
      let key: String = self.keyString
      return NSLocalizedString("osc_toolbar.\(key)", comment: key)
    }

    static let allButtonTypes: [Preference.ToolBarButton] = [
      .settings, .playlist, .pip, .fullScreen, .musicMode, .subTrack, .screenshot, .plugins
    ]
  }

  enum HistoryGroupBy: Int, InitializingFromKey {
    case lastPlayedDay = 0
    case parentFolder

    static let defaultValue = HistoryGroupBy.lastPlayedDay

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum HistorySearchType: Int, InitializingFromKey {
    case fullPath = 0
    case filename

    static let defaultValue = HistorySearchType.fullPath

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }
  }

  enum ReplayGainOption: Int, InitializingFromKey {
    case no = 0
    case track
    case album

    static let defaultValue = ReplayGainOption.no

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var mpvString: String {
      get {
        switch self {
        case .no: return "no"
        case .track : return "track"
        case .album: return "album"
        }
      }
    }
  }

  enum GaplessAudioOption: Int, InitializingFromKey {
    case disabled = 0
    case weak
    case strong

    static var defaultValue = GaplessAudioOption.weak

    init?(key: Key) {
      self.init(rawValue: Preference.integer(for: key))
    }

    var localizedDescription: String {
      return NSLocalizedString("gaplessAudio." + mpvString, comment: mpvString)
    }

    var mpvString: String {
      get {
        switch self {
        case .disabled: return "no"
        case .weak : return "weak"
        case .strong: return "yes"
        }
      }
    }
  }

  enum DefaultRepeatMode: Int {
    case playlist = 0
    case file
  }

  // MARK: - Defaults

  static let defaultPreference: [Preference.Key: Any & Sendable] = [
    .receiveBetaUpdate: false,
    .actionAfterLaunch: ActionAfterLaunch.welcomeWindow.rawValue,
    .alwaysOpenInNewWindow: true,
    .allowDuplicatePlayers: false,
    .enableCmdN: true,
    .animationDurationDefault: 0.25,
    // Native duration (as of MacOS 13.4) is 0.5s, which is quite sluggish. Speed it up a bit
    .animationDurationFullScreen: 0.25,
    .animationDurationOSD: 0.5,
    .animationDurationCrop: 1.5,
    .recordPlaybackHistory: true,
    .recordRecentFiles: true,
    .trackAllFilesInRecentOpenMenu: true,
    .floatingControlBarMargin: 5,
    .controlBarPositionHorizontal: Float(0.5),
    .controlBarPositionVertical: Float(0.1),
    .floatingControlBarWidth: 440.0,
    .controlBarStickToCenter: true,
    .controlBarAutoHideTimeout: Float(2.5),
    .showCachedRangesInSlider: true,
    .roundSliderBarRects: true,
    .sliderBarDoneColor: SliderBarLeftColor.defaultValue.rawValue,
    .useSliderFocusMagnifyEffect: true,
    .alwaysShowSliderKnob: false,
    .showChapterPos: true,
    .enableControlBarAutoHide: true,
    .controlBarToolbarButtons: [ToolBarButton.pip.rawValue, ToolBarButton.playlist.rawValue, ToolBarButton.settings.rawValue],
    .enableOSC: true,
    .titleBarBtnsGlow: false,
    .showTopBarTrigger: ShowTopBarTrigger.defaultValue.rawValue,
    .topBarPlacement: PanelPlacement.insideViewport.rawValue,
    .bottomBarPlacement: PanelPlacement.insideViewport.rawValue,
    .oscBarHeight: 60,
    .oscBarPlayIconSizeTicks: 1,
    .oscBarPlayIconSpacingTicks: 2,
    .oscBarToolIconSizeTicks: 1,
    .oscBarToolIconSpacingTicks: 2,
    .oscBarPlayIconSize: 33,
    .oscBarPlayIconSpacing: 16,
    .oscBarToolIconSize: 33,
    .oscBarToolIconSpacing: 7,
    .oscPosition: OSCPosition.defaultValue.rawValue,
    .oscColorScheme: OSCColorScheme.defaultValue.rawValue,
    .oscForceSingleRow: false,
    .oscTimeLabelsAlwaysWrapSlider: false,
    .hideFadeableViewsWhenOutsideWindow: true,
    .playlistWidth: 270,
    .settingsTabGroupLocation: SidebarLocation.leadingSidebar.rawValue,
    .playlistTabGroupLocation: SidebarLocation.trailingSidebar.rawValue,
    .pluginsTabGroupLocation: SidebarLocation.leadingSidebar.rawValue,
    .leadingSidebarPlacement: PanelPlacement.outsideViewport.rawValue,
    .trailingSidebarPlacement: PanelPlacement.outsideViewport.rawValue,
    .showLeadingSidebarToggleButton: true,
    .showTrailingSidebarToggleButton: true,
    .hideLeadingSidebarOnClick: true,
    .hideTrailingSidebarOnClick: true,
    .prefetchPlaylistVideoDuration: true,
    .prefetchPlaylistVideoGeometry: false,
    .themeMaterial: Theme.system.rawValue,
    .playerWindowOpacity: 1.0,
    .enableOSD: true,
    .enableOSDInMusicMode: false,
    .osdPosition: OSDPosition.defaultValue.rawValue,
    .disableOSDFileStartMsg: false,
    .disableOSDPauseResumeMsgs: false,
    .disableOSDSeekMsg: false,
    .disableOSDSpeedMsg: false,
    .disableOSDVideoZoomMsg: false,
    .osdAutoHideTimeout: Float(1),
    .osdTextSize: Float(28),
    .softVolume: 100,
    .arrowButtonAction: ArrowButtonAction.defaultValue.rawValue,
    .resetSpeedWhenPaused: false,
    .useForceTouchForSpeedArrows: true,
    .lockViewportToVideoSize: false,
    .moveWindowIntoVisibleScreenOnResize: true,
    .allowVideoToOverlapCameraHousing: false,
    .pauseWhenOpen: false,
    .hideWindowsWhenInactive: false,
    .useLegacyWindowedMode: true,
    .fullScreenWhenOpen: false,
    .useLegacyFullScreen: true,
    .resumeLastPosition: false,
    .preventScreenSaver: true,
    .allowScreenSaverForAudio: true,
    .useMediaKeys: true,
    .alwaysFloatOnTop: false,
    .alwaysShowOnTopIcon: false,
    .blackOutMonitor: false,
    .pauseWhenMinimized: false,
    .pauseWhenInactive: false,
    .pauseWhenLeavingFullScreen: false,
    .pauseWhenGoesToSleep: true,
    .playWhenEnteringFullScreen: false,

      .playlistAutoAdd: true,
    .playlistAutoPlayNext: true,
    .playlistShowMetadata: true,
    .playlistShowMetadataInMusicMode: true,
    .usePhysicalResolution: false,
    .autoRepeat: false,
    .defaultRepeatMode: DefaultRepeatMode.playlist.rawValue,
    .initialWindowSizePosition: "",
    .resizeWindowScheme: ResizeWindowScheme.defaultValue.rawValue,
    .resizeWindowTiming: ResizeWindowTiming.defaultValue.rawValue,
    .resizeWindowOption: ResizeWindowOption.defaultValue.rawValue,
    .keepVideoAwayFromBars: true,
    .showRemainingTime: false,
    .scaleRemainingTime: false,
    .timeDisplayPrecision: 0,
    .touchbarShowRemainingTime: true,

    .enableThumbnailPreview: true,
    .enableThumbnailForRemoteFiles: true,
    .enableThumbnailForMusicMode: false,
    .showThumbnailDuringSliderSeek: true,
    .thumbnailBorderStyle: ThumnailBorderStyle.defaultValue.rawValue,
    .thumbnailSizeOption: ThumbnailSizeOption.defaultValue.rawValue,
    .thumbnailFixedLength: 240,
    .thumbnailRawSizePercentage: 100,
    .thumbnailDisplayedSizePercentage: 25,
    .maxThumbnailPreviewCacheSize: 500,
    .integrateWithThumbfast: false,

      .seekPreviewHasTimeDelta: true,
    .seekPreviewHasChapter: true,
    .seekPreviewShadow: Shadow.dark.rawValue,

      .autoSwitchToMusicMode: true,
    .musicModeShowPlaylist: false,
    .musicModePlaylistHeight: 300,
    .musicModeShowAlbumArt: true,
    .musicModeMaxWidth: 2500,
    .displayTimeAndBatteryInFullScreen: false,

      .windowBehaviorWhenPip: WindowBehaviorWhenPip.defaultValue.rawValue,
    .pauseWhenPip: false,
    .togglePipByMinimizingWindow: false,
    .togglePipWhenSwitchingSpaces: false,
    .togglePipByMinimizingWindowForVideoOnly: false,
    .disableAnimations: false,
    .windowLaunchAnimation: WindowOpenCloseAnimation.useDefault.rawValue,
    .playerWindowOpenCloseAnimation: WindowOpenCloseAnimation.useDefault.rawValue,
    .auxWindowOpenCloseAnimation: WindowOpenCloseAnimation.useDefault.rawValue,

      .videoThreads: 0,
    .hardwareDecoder: HardwareDecoderOption.autoCopy.rawValue,
    .forceDedicatedGPU: false,
    .loadIccProfile: false,
    .enableHdrSupport: false,
    .enableToneMapping: false,
    .toneMappingTargetPeak: 0,
    .toneMappingAlgorithm: "auto",
    .audioDriverEnableAVFoundation: false,
    .audioThreads: 0,
    .audioLanguage: "",
    .maxVolume: 100,
    .spdifAC3: false,
    .spdifDTS: false,
    .spdifDTSHD: false,
    .audioDevice: "auto",
    .audioDeviceDesc: "Autoselect device",
    .enableInitialVolume: false,
    .initialVolume: 100,
    .enablePlaylistLoop: false,
    .enableFileLoop: false,
    .shortenFileGroupsInPlaylist: true,
    .replayGain: ReplayGainOption.no.rawValue,
    .replayGainPreamp: 0,
    .replayGainClip: false,
    .replayGainFallback: 0,
    .gaplessAudio: GaplessAudioOption.weak.rawValue,

      .subAutoLoadIINA: IINAAutoLoadAction.iina.rawValue,
    .subAutoLoadPriorityString: "",
    .subAutoLoadSearchPath: "./*",
    .ignoreAssStyles: false,
    .subOverrideLevel: SubOverrideLevel.scale.rawValue,
    .secondarySubOverrideLevel: SubOverrideLevel.scale.rawValue,
    .subTextFont: Constants.String.mpvDefaultFont,
    .subTextSize: Float(55),
    .subTextColorString: NSColor.white.usingColorSpace(.deviceRGB)!.mpvColorString,
    .subBgColorString: NSColor.clear.usingColorSpace(.deviceRGB)!.mpvColorString,
    .subBold: false,
    .subItalic: false,
    .subBlur: Float(0),
    .subSpacing: Float(0),
    .subBorderSize: Float(3),
    .subBorderColorString: NSColor.black.usingColorSpace(.deviceRGB)!.mpvColorString,
    .subShadowSize: Float(0),
    .subShadowColorString: NSColor.clear.usingColorSpace(.deviceRGB)!.mpvColorString,
    .subAlignX: SubAlign.center.rawValue,
    .subAlignY: SubAlign.bottom.rawValue,
    .subMarginX: Float(25),
    .subMarginY: Float(22),
    .subPos: Float(100),
    .subScale: 1,
    .subLang: "",
    .legacyOnlineSubSource: 1, /* openSub */
    .onlineSubProvider: OnlineSubtitle.Providers.openSub.id,
    .displayInLetterBox: true,
    .subScaleWithWindow: true,
    .openSubUsername: "",
    .assrtToken: "",
    .defaultEncoding: "auto",
    .autoSearchOnlineSub: false,
    .autoSearchThreshold: 20,

      .enableCache: true,
    .defaultCacheSize: 153600,
    .cacheBufferSize: 153600,
    .secPrefech: 36000,
    .showBufferingThrobber: true,
    .showSeekingThrobber: true,
    .userAgent: "",
    .transportRTSPThrough: RTSPTransportation.tcp.rawValue,
    .ytdlEnabled: true,
    .ytdlSearchPath: "/usr/local/bin",
    .ytdlRawOptions: "",
    .httpProxy: "",

      .currentInputConfigName: Constants.InputConf.defaultConfNamesSorted[0],

      .enableAdvancedSettings: false,
    .useMpvOsd: false,
    .enableLogging: false,
    .logLevel: Logger.Level.debug.rawValue,
    .stdoutLogLevel: Logger.Level.error.rawValue,
    .mpvEventLogLevel: MPVLogLevel.warn.rawValue,
    .enablePiiMaskingInLog: true,
    .logKeyBindingsRebuild: false,
    .logPlayerSave: false,
    .logNonInteractiveLaunches: false,
    .displayKeyBindingRawValues: false,
    .showKeyBindingsFromAllSources: true,
    .useInlineEditorInsteadOfDialogForNewInputConf: true,
    .acceptRawTextAsKeyBindings: false,
    .animateKeyBindingTableReloadAll: true,
    .tableEditKeyNavContinuesBetweenRows: true,
    .launchCount: 0,
    .enableRestoreUIState: true,
    .alwaysAskBeforeRestoreAtLaunch: false,
    .alwaysPauseMediaWhenRestoringAtLaunch: false,
    .enableRestoreUIStateForCmdLineLaunches: false,
    .isRestoreInProgress: false,
    .uiPrefWindowSearchString: "",
    .uiPrefWindowNavTableSelectionIndex: 0,
    .uiPrefDetailViewScrollOffsetY: 0.0,
    .uiCollapseViewSuppressOSDMessages: true,
    .uiCollapseViewSubAutoLoadAdvanced: false,
    .uiPrefBindingsTableSearchString: "",
    .uiPrefBindingsTableScrollOffsetY: 0,
    .uiInspectorWindowTabIndex: 0,
    .uiHistoryTableGroupBy: HistoryGroupBy.lastPlayedDay.rawValue,
    .uiHistoryTableSearchType: HistorySearchType.fullPath.rawValue,
    .uiHistoryTableSearchString: "",
    .uiLastClosedWindowedModeGeometry: "",
    .uiLastClosedMusicModeGeometry: "",
    .userOptions: [[String]](),
    .useUserDefinedConfDir: false,
    .userDefinedConfDir: "~/.config/mpv/",
    .iinaEnablePluginSystem: true,

      .keepOpenOnFileEnd: true,
    .quitWhenNoOpenedWindow: false,
    .resumeFromEndRestartsPlayback: true,
    .actionWhenNoOpenWindow: ActionWhenNoOpenWindow.sameActionAsLaunch.rawValue,
    .useExactSeek: SeekOption.exact.rawValue,
    .followGlobalSeekTypeWhenAdjustSlider: false,
    .relativeSeekAmount: 3,
    .volumeScrollAmount: 3,
    .playbackSpeedScrollAmount: 3,
    .verticalScrollAction: ScrollAction.volume.rawValue,
    .horizontalScrollAction: ScrollAction.seek.rawValue,
    .enableScrollOverSliders: true,
    .videoViewAcceptsFirstMouse: true,
    .singleClickAction: MouseClickAction.hideOSC.rawValue,
    .doubleClickAction: MouseClickAction.fullscreen.rawValue,
    .rightClickAction: MouseClickAction.pause.rawValue,
    .middleClickAction: MouseClickAction.none.rawValue,
    .pinchAction: PinchAction.defaultValue.rawValue,
    .rotateAction: RotateAction.defaultValue.rawValue,
    .forceTouchAction: MouseClickAction.none.rawValue,
    .enablePinchToVideoZoom: true,
    .pinchMaxZoom: 4.0,

      .screenshotSaveToFile: true,
    .screenshotCopyToClipboard: false,
    .screenshotFolder: "~/Pictures/Screenshots",
    .screenshotIncludeSubtitle: true,
    .screenshotFormat: ScreenshotFormat.png.rawValue,
    .screenshotTemplate: "%F-%n",
    .screenshotShowPreview: true,

      .watchProperties: [String](),
    .savedVideoFilters: [SavedFilter](),
    .savedAudioFilters: [SavedFilter](),

    .enableRecentDocumentsWorkaround: false,
    .recentDocuments: [Any & Sendable](),

    .aspectRatioPanelPresets: "4:3,16:9,16:10,21:9,5:4",
    .cropPanelPresets: "4:3,16:9,16:10,21:9,5:4",

    .killNonInteractiveLaunchesAtReopen: true,
    .killRequest: 0,
    .enableFFmpegImageDecoder: true,
    .enableHdrWorkaround: true,
    .enableNowPlayingArtwork: true,
    .enableDisplayIdle: true
  ]


  static private var ud: UserDefaults { UserDefaults.standard }

  static func object(for key: Key) -> Any? {
    return ud.object(forKey: key.rawValue)
  }

  static func array(for key: Key) -> [Any]? {
    return ud.array(forKey: key.rawValue)
  }

  static func url(for key: Key) -> URL? {
    return ud.url(forKey: key.rawValue)
  }

  static func dictionary(for key: Key) -> [String : Any]? {
    return ud.dictionary(forKey: key.rawValue)
  }

  static func string(for key: Key) -> String? {
    return ud.string(forKey: key.rawValue)
  }

  static func csvStringArray(for key: Key) -> [String]? {
    if let csv = ud.string(forKey: key.rawValue) {
      return csv.split(separator: ",").map{String($0).trimmingCharacters(in: .whitespacesAndNewlines)}
    }
    return nil
  }

  static func stringArray(for key: Key) -> [String]? {
    return ud.stringArray(forKey: key.rawValue)
  }

  static func data(for key: Key) -> Data? {
    return ud.data(forKey: key.rawValue)
  }

  static func bool(for key: Key) -> Bool {
    return ud.bool(forKey: key.rawValue)
  }

  static func integer(for key: Key) -> Int {
    return ud.integer(forKey: key.rawValue)
  }

  static func float(for key: Key) -> Float {
    return ud.float(forKey: key.rawValue)
  }

  static func double(for key: Key) -> Double {
    return ud.double(forKey: key.rawValue)
  }

  static func value(for key: Key) -> Any? {
    return ud.value(forKey: key.rawValue)
  }

  static func typedValue<T>(for key: Key) -> T {
    if let val = Preference.value(for: key) as? T {
      return val
    }
    fatalError("Unexpected type or missing default for preference key \(key.rawValue.quoted)")
  }

  static func typedDefault<T>(for key: Key) -> T {
    if let defaultVal = Preference.defaultPreference[key] as? T {
      return defaultVal
    }
    fatalError("Unexpected type or missing default for preference key \(key.rawValue.quoted)")
  }

  static func set(_ value: Bool, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: Int, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: String, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: Float, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: Double, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: URL, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func set(_ value: Any?, for key: Key) {
    ud.set(value, forKey: key.rawValue)
  }

  static func `enum`<T: InitializingFromKey>(for key: Key) -> T {
    return T.init(key: key) ?? T.defaultValue
  }

  @MainActor
  static func keyHasBeenPersisted(_ key: Key) -> Bool {
    let identifier = InfoDictionary.shared.bundleIdentifier
    guard let persisted = ud.persistentDomain(forName: identifier) else { return false }
    return persisted.keys.contains(key.rawValue)
  }
  
  static var isAdvancedEnabled: Bool {
    return Preference.bool(for: .enableAdvancedSettings)
  }

  static func seekScrollSensitivity() -> Double {
    let ticks = Preference.integer(for: .relativeSeekAmount).clamped(to: 1...8)
    let pow10 = Int(ticks / 2) - 2
    let extra = (ticks %% 2) == 1 ? 5 : 1
    return pow(10.0, Double(pow10)) * Double(extra)
  }

  static func volumeScrollSensitivity() -> Double {
    let ticks = Preference.integer(for: .volumeScrollAmount).clamped(to: 1...6)
    let pow10 = Int(ticks / 2) - 2
    let extra = (ticks %% 2) == 1 ? 5 : 1
    return pow(10.0, Double(pow10)) * Double(extra)
  }
}
