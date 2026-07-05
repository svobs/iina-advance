//
//  MenuController.swift
//  iina
//
//  Created by lhc on 31/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class MenuController: NSObject, NSMenuDelegate {

  /** For convenient bindings. see `bind(...)` below. [menu: check state block] */
  private var menuBindingList: [NSMenu: @MainActor (NSMenuItem) -> Bool] = [:]

  var sectionMappingItemPairs: [String: [(KeyMapping, NSMenuItem)]] = [:]

  private var stringForOpen: String!
  private var stringForOpenAlternative: String!
  private var stringForOpenURL: String!
  private var stringForOpenURLAlternative: String!

  // File
  @IBOutlet weak var fileMenu: NSMenu!
  @IBOutlet weak var open: NSMenuItem!
  @IBOutlet weak var openAlternative: NSMenuItem!
  @IBOutlet weak var openURL: NSMenuItem!
  @IBOutlet weak var openURLAlternative: NSMenuItem!
  @IBOutlet weak var savePlaylist: NSMenuItem!
  @IBOutlet weak var showCurrentFileInFinder: NSMenuItem!
  @IBOutlet weak var deleteCurrentFile: NSMenuItem!
  @IBOutlet weak var newWindow: NSMenuItem!
  @IBOutlet weak var newWindowSeparator: NSMenuItem!
  @IBOutlet weak var otherKeyBindingsMenu: NSMenu!
  // Playback
  @IBOutlet weak var playbackMenu: NSMenu!
  @IBOutlet weak var pause: NSMenuItem!
  @IBOutlet weak var stop: NSMenuItem!
  @IBOutlet weak var forward: NSMenuItem!
  @IBOutlet weak var nextFrame: NSMenuItem!
  @IBOutlet weak var backward: NSMenuItem!
  @IBOutlet weak var previousFrame: NSMenuItem!
  @IBOutlet weak var jumpToBegin: NSMenuItem!
  @IBOutlet weak var jumpTo: NSMenuItem!
  @IBOutlet weak var speedIndicator: NSMenuItem!
  @IBOutlet weak var speedUp: NSMenuItem!
  @IBOutlet weak var speedUpSlightly: NSMenuItem!
  @IBOutlet weak var speedDown: NSMenuItem!
  @IBOutlet weak var speedDownSlightly: NSMenuItem!
  @IBOutlet weak var speedReset: NSMenuItem!
  @IBOutlet weak var screenshot: NSMenuItem!
  @IBOutlet weak var gotoScreenshotFolder: NSMenuItem!
  @IBOutlet weak var advancedScreenshot: NSMenuItem!
  @IBOutlet weak var abLoop: NSMenuItem!
  @IBOutlet weak var fileLoop: NSMenuItem!
  @IBOutlet weak var playlistPanel: NSMenuItem!
  @IBOutlet weak var playlist: NSMenuItem!
  @IBOutlet weak var playlistLoop: NSMenuItem!
  @IBOutlet weak var playlistMenu: NSMenu!
  @IBOutlet weak var nextMedia: NSMenuItem!
  @IBOutlet weak var previousMedia: NSMenuItem!
  @IBOutlet weak var chapterPanel: NSMenuItem!
  @IBOutlet weak var nextChapter: NSMenuItem!
  @IBOutlet weak var previousChapter: NSMenuItem!
  @IBOutlet weak var chapter: NSMenuItem!
  @IBOutlet weak var chapterMenu: NSMenu!
  // Video
  @IBOutlet weak var videoMenu: NSMenu!
  @IBOutlet weak var quickSettingsVideo: NSMenuItem!
  @IBOutlet weak var cycleVideoTracks: NSMenuItem!
  @IBOutlet weak var videoTrack: NSMenuItem!
  @IBOutlet weak var videoTrackMenu: NSMenu!
  @IBOutlet weak var halfSize: NSMenuItem!
  @IBOutlet weak var normalSize: NSMenuItem!
  @IBOutlet weak var doubleSize: NSMenuItem!
  @IBOutlet weak var biggerSize: NSMenuItem!
  @IBOutlet weak var smallerSize: NSMenuItem!
  @IBOutlet weak var fitToScreen: NSMenuItem!
  @IBOutlet weak var fullScreen: NSMenuItem!
  @IBOutlet weak var pictureInPicture: NSMenuItem!
  @IBOutlet weak var alwaysOnTop: NSMenuItem!
  @IBOutlet weak var lockAspectRatio: NSMenuItem!
  @IBOutlet weak var liveText: NSMenuItem!
  @IBOutlet weak var aspectMenu: NSMenu!
  @IBOutlet weak var cropMenu: NSMenu!
  @IBOutlet weak var rotationMenu: NSMenu!
  @IBOutlet weak var flipMenu: NSMenu!
  @IBOutlet weak var mirror: NSMenuItem!
  @IBOutlet weak var flip: NSMenuItem!
  @IBOutlet weak var deinterlace: NSMenuItem!
  @IBOutlet weak var delogo: NSMenuItem!
  @IBOutlet weak var videoFilters: NSMenuItem!
  @IBOutlet weak var savedVideoFiltersMenu: NSMenu!
  //Audio
  @IBOutlet weak var audioMenu: NSMenu!
  @IBOutlet weak var quickSettingsAudio: NSMenuItem!
  @IBOutlet weak var cycleAudioTracks: NSMenuItem!
  @IBOutlet weak var audioTrackMenu: NSMenu!
  @IBOutlet weak var loadExternalAudio: NSMenuItem!
  @IBOutlet weak var volumeIndicator: NSMenuItem!
  @IBOutlet weak var increaseVolume: NSMenuItem!
  @IBOutlet weak var increaseVolumeSlightly: NSMenuItem!
  @IBOutlet weak var decreaseVolume: NSMenuItem!
  @IBOutlet weak var decreaseVolumeSlightly: NSMenuItem!
  @IBOutlet weak var mute: NSMenuItem!
  @IBOutlet weak var audioDelayIndicator: NSMenuItem!
  @IBOutlet weak var increaseAudioDelay: NSMenuItem!
  @IBOutlet weak var increaseAudioDelaySlightly: NSMenuItem!
  @IBOutlet weak var decreaseAudioDelay: NSMenuItem!
  @IBOutlet weak var decreaseAudioDelaySlightly: NSMenuItem!
  @IBOutlet weak var resetAudioDelay: NSMenuItem!
  @IBOutlet weak var audioFilters: NSMenuItem!
  @IBOutlet weak var audioDeviceMenu: NSMenu!
  @IBOutlet weak var savedAudioFiltersMenu: NSMenu!
  // Subtitle
  @IBOutlet weak var subMenu: NSMenu!
  @IBOutlet weak var quickSettingsSub: NSMenuItem!
  @IBOutlet weak var hideSubtitles: NSMenuItem!
  @IBOutlet weak var hideSecondSubtitles: NSMenuItem!
  @IBOutlet weak var cycleSubtitles: NSMenuItem!
  @IBOutlet weak var subTrackMenu: NSMenu!
  @IBOutlet weak var secondSubTrackMenu: NSMenu!
  @IBOutlet weak var loadExternalSub: NSMenuItem!
  @IBOutlet weak var increaseTextSize: NSMenuItem!
  @IBOutlet weak var decreaseTextSize: NSMenuItem!
  @IBOutlet weak var resetTextSize: NSMenuItem!
  @IBOutlet weak var subDelayIndicator: NSMenuItem!
  @IBOutlet weak var increaseSubDelay: NSMenuItem!
  @IBOutlet weak var increaseSubDelaySlightly: NSMenuItem!
  @IBOutlet weak var decreaseSubDelay: NSMenuItem!
  @IBOutlet weak var decreaseSubDelaySlightly: NSMenuItem!
  @IBOutlet weak var resetSubDelay: NSMenuItem!
  @IBOutlet weak var encodingMenu: NSMenu!
  @IBOutlet weak var subFont: NSMenuItem!
  @IBOutlet weak var findOnlineSub: NSMenuItem!
  @IBOutlet weak var onlineSubSourceMenu: NSMenu!
  @IBOutlet weak var saveDownloadedSub: NSMenuItem!
  // Plugin
  @IBOutlet weak var pluginMenu: NSMenu!
  @IBOutlet weak var pluginMenuItem: NSMenuItem!
  // Window
  @IBOutlet weak var customTouchBar: NSMenuItem!
  @IBOutlet weak var inspector: NSMenuItem!
  @IBOutlet weak var miniPlayer: NSMenuItem!

  @IBOutlet weak var debugDump: NSMenuItem!

  /// If `true` then all menu items are disabled.
  private var isDisabled = false

  var bindableMenuItems: [BindableMenuItem] = []

  // MARK: - Construct Menus

  /// Should be called only once, at application start
  @MainActor
  func initMenus() {
    bindMenuItems()
    updatePluginMenu()
    refreshStaticMenuItemBindings()
    bindableMenuItems = buildBindableMenuItems()
  }

  @MainActor
  private func bindMenuItems() {

    [cycleSubtitles, cycleAudioTracks, cycleVideoTracks].forEach { item in
      item?.action = #selector(PlayerWindowController.menuCycleTrack(_:))
    }

    // File menu

    fileMenu.delegate = self

    stringForOpen = open.title
    stringForOpenURL = openURL.title
    stringForOpenAlternative = openAlternative.title
    stringForOpenURLAlternative = openURLAlternative.title

    savePlaylist.action = #selector(PlayerWindowController.menuSavePlaylist(_:))
    showCurrentFileInFinder.action = #selector(PlayerWindowController.menuShowCurrentFileInFinder(_:))
    deleteCurrentFile.action = #selector(PlayerWindowController.menuDeleteCurrentFile(_:))

    refreshCmdNStatus()

    otherKeyBindingsMenu.delegate = self

    // Playback menu

    playbackMenu.delegate = self

    pause.action = #selector(PlayerWindowController.menuTogglePause(_:))
    stop.action = #selector(PlayerWindowController.menuStop(_:))

    // -- seeking
    forward.action = #selector(PlayerWindowController.menuStep(_:))
    nextFrame.action = #selector(PlayerWindowController.menuStepNextFrame(_:))
    backward.action = #selector(PlayerWindowController.menuStep(_:))
    previousFrame.action = #selector(PlayerWindowController.menuStepPrevFrame(_:))
    jumpToBegin.action = #selector(PlayerWindowController.menuJumpToBegin(_:))
    jumpTo.action = #selector(PlayerWindowController.menuJumpTo(_:))

    // -- speed
    [speedUp, speedDown, speedUpSlightly, speedDownSlightly, speedReset].forEach { item in
      item?.action = #selector(PlayerWindowController.menuChangeSpeed(_:))
    }

    // -- screenshot
    screenshot.action = #selector(PlayerWindowController.menuSnapshot(_:))
    gotoScreenshotFolder.action = #selector(AppDelegate.menuOpenScreenshotFolder(_:))
    // advancedScreenShot

    // -- list and chapter
    abLoop.action = #selector(PlayerWindowController.menuABLoop(_:))
    fileLoop.action = #selector(PlayerWindowController.menuFileLoop(_:))
    playlistMenu.delegate = self
    chapterMenu.delegate = self
    playlistLoop.action = #selector(PlayerWindowController.menuPlaylistLoop(_:))
    playlistPanel.action = #selector(PlayerWindowController.menuShowPlaylistPanel(_:))
    chapterPanel.action = #selector(PlayerWindowController.menuShowChaptersPanel(_:))

    nextMedia.action = #selector(PlayerWindowController.menuNextMedia(_:))
    previousMedia.action = #selector(PlayerWindowController.menuPreviousMedia(_:))

    nextChapter.action = #selector(PlayerWindowController.menuNextChapter(_:))
    previousChapter.action = #selector(PlayerWindowController.menuPreviousChapter(_:))

    // Video menu

    videoMenu.delegate = self

    quickSettingsVideo.action = #selector(PlayerWindowController.menuShowVideoQuickSettings(_:))
    videoTrackMenu.delegate = self

    // -- window size
    halfSize.tag = 0
    normalSize.tag = 1
    doubleSize.tag = 2
    fitToScreen.tag = 3
    smallerSize.tag = 10
    biggerSize.tag = 11
    for item in [halfSize, normalSize, doubleSize, fitToScreen, biggerSize, smallerSize] {
      item?.action = #selector(PlayerWindowController.menuChangeWindowSize(_:))
    }

    // -- screen
    fullScreen.action = #selector(PlayerWindowController.menuToggleFullScreen(_:))
    pictureInPicture.action = #selector(PlayerWindowController.menuTogglePIP(_:))
    alwaysOnTop.action = #selector(PlayerWindowController.menuAlwaysOnTop(_:))
    lockAspectRatio.action = #selector(PlayerWindowController.menuLockAspectRatio(_:))
    liveText.action = #selector(PlayerWindowController.menuToggleLiveText(_:))

    // -- aspect
    let aspectRatioIdentifiers = [Aspect.defaultIdentifier] + Aspect.aspectsInMenu
    /// we need to set the represented object separately, since `StringConstants.default` may be localized.
    let aspectRatioMenuItemTitles = [StringConstants.default] + Aspect.aspectsInMenu
    bind(menu: aspectMenu, withOptions: aspectRatioMenuItemTitles, objects: aspectRatioIdentifiers, objectMap: nil,
         action: #selector(PlayerWindowController.menuChangeAspect(_:))) {
      /// return `true` if menu item should be checked (i.e. if current aspect matches menu item)
      return PlayerManager.shared.activePlayer?.pwc.geo.video.userAspectLabel == $0.representedObject as? String
    }

    // -- crop
    let cropMenuItemTitles = [StringConstants.none] + Aspect.aspectsInMenu + [StringConstants.custom]
    // same as aspectList above.
    let cropIdentifiers = [StringConstants.noneCropIdentifier] + Aspect.aspectsInMenu + [StringConstants.customCropIdentifier]
    let changeCropAction = #selector(PlayerWindowController.menuChangeCrop(_:))
    bind(menu: cropMenu, withOptions: cropMenuItemTitles, objects: cropIdentifiers, objectMap: nil, action: changeCropAction) {
      return PlayerManager.shared.activePlayer?.pwc.geo.video.selectedCropLabel == $0.representedObject as? String
    }
    // Separate "Custom..." from other crop sizes.
    cropMenu.insertItem(NSMenuItem.separator(), at: 1 + Aspect.aspectsInMenu.count)

    // -- rotation
    let rotationTitles = Constants.rotations.map { "\($0)\(StringConstants.degree)" }
    let rotationAction = #selector(PlayerWindowController.menuChangeRotation(_:))
    bind(menu: rotationMenu, withOptions: rotationTitles, objects: Constants.rotations, objectMap: nil, action: rotationAction) {
      PlayerManager.shared.activePlayer?.pwc.geo.video.userRotation == $0.representedObject as? Int
    }

    // -- flip and mirror
    flipMenu.delegate = self
    flip.action = #selector(PlayerWindowController.menuToggleFlip(_:))
    mirror.action = #selector(PlayerWindowController.menuToggleMirror(_:))

    // -- deinterlace
    deinterlace.action = #selector(PlayerWindowController.menuToggleDeinterlace(_:))

    // -- delogo
    delogo.action = #selector(PlayerWindowController.menuSetDelogo(_:))

    // -- filter
    videoFilters.action = #selector(AppDelegate.showVideoFilterWindow(_:))

    savedVideoFiltersMenu.delegate = self
    updateSavedFilters(forType: MPVProperty.vf,
                       from: Preference.array(for: .savedVideoFilters)?.compactMap(SavedFilter.init(dict:)) ?? [])

    // Audio menu

    audioMenu.delegate = self
    quickSettingsAudio.action = #selector(PlayerWindowController.menuShowAudioQuickSettings(_:))
    audioTrackMenu.delegate = self
    loadExternalAudio.action = #selector(PlayerWindowController.menuLoadExternalAudio(_:))

    // - volume
    [increaseVolume, decreaseVolume, increaseVolumeSlightly, decreaseVolumeSlightly].forEach { item in
      item?.action = #selector(PlayerWindowController.menuChangeVolume(_:))
    }
    mute.action = #selector(PlayerWindowController.menuToggleMute(_:))

    // - audio delay
    [increaseAudioDelay, decreaseAudioDelay, increaseAudioDelaySlightly, decreaseAudioDelaySlightly].forEach { item in
      item?.action = #selector(PlayerWindowController.menuChangeAudioDelay(_:))
    }
    resetAudioDelay.action = #selector(PlayerWindowController.menuResetAudioDelay(_:))

    // - audio device
    audioDeviceMenu.delegate = self

    // - filters
    audioFilters.action = #selector(AppDelegate.showAudioFilterWindow(_:))

    savedAudioFiltersMenu.delegate = self
    updateSavedFilters(forType: MPVProperty.af,
                       from: Preference.array(for: .savedAudioFilters)?.compactMap(SavedFilter.init(dict:)) ?? [])

    // Subtitle

    subMenu.delegate = self
    quickSettingsSub.action = #selector(PlayerWindowController.menuShowSubQuickSettings(_:))
    loadExternalSub.action = #selector(PlayerWindowController.menuLoadExternalSub(_:))
    subTrackMenu.delegate = self
    hideSubtitles.action = #selector(PlayerWindowController.menuToggleSubVisibility(_:))
    hideSecondSubtitles.action = #selector(PlayerWindowController.menuToggleSecondSubVisibility(_:))
    secondSubTrackMenu.delegate = self

    findOnlineSub.action = #selector(PlayerWindowController.menuFindOnlineSub(_:))
    saveDownloadedSub.action = #selector(PlayerWindowController.saveDownloadedSub(_:))

    onlineSubSourceMenu.delegate = self

    // - text size
    [increaseTextSize, decreaseTextSize, resetTextSize].forEach {
      $0.action = #selector(PlayerWindowController.menuChangeSubScale(_:))
    }

    // - delay
    [increaseSubDelay, decreaseSubDelay, increaseSubDelaySlightly, decreaseSubDelaySlightly].forEach { item in
      item?.action = #selector(PlayerWindowController.menuChangeSubDelay(_:))
    }
    resetSubDelay.action = #selector(PlayerWindowController.menuResetSubDelay(_:))

    // encoding
    let encodingTitles = Constants.encodings.map { $0.title }
    let encodingObjects = Constants.encodings.map { $0.code }
    let action = #selector(PlayerWindowController.menuSetSubEncoding(_:))
    bind(menu: encodingMenu, withOptions: encodingTitles, objects: encodingObjects, objectMap: nil, action: action) {
      PlayerManager.shared.activePlayer?.info.subEncoding == $0.representedObject as? String
    }
    subFont.action = #selector(PlayerWindowController.menuSubFont(_:))
    // Separate Auto from other encoding types
    encodingMenu.insertItem(NSMenuItem.separator(), at: 1)

    // Plugin

    if AppDelegate.iinaPluginSystemEnabled {
      pluginMenu.delegate = self
      pluginMenu.autoenablesItems = false
    } else {
      pluginMenuItem.isHidden = true
    }

    // Window

    customTouchBar.action = #selector(NSApplication.toggleTouchBarCustomizationPalette(_:))

    inspector.action = #selector(AppDelegate.shared.toggleInspectorWindow(_:))
    miniPlayer.action = #selector(PlayerWindowController.menuSwitchToMiniPlayer(_:))

    // Debug

    debugDump.isAlternate = true
    debugDump.keyEquivalentModifierMask = .option
  }

  func refreshCmdNStatus() {
    let isEnabled = Preference.isAdvancedEnabled && Preference.bool(for: .enableCmdN)
    newWindowSeparator.isHidden = !isEnabled
    newWindow.isHidden = !isEnabled
  }

  // MARK: - Update Menus

  @MainActor
  func updateOtherKeyBindings(replacingAllWith newItems: [NSMenuItem]) {
    otherKeyBindingsMenu.removeAllItems()
    for item in newItems {
      item.allowsKeyEquivalentWhenHidden = true
      otherKeyBindingsMenu.addItem(item)
    }
  }

  @MainActor
  private func updatePlaylist() {
    playlistMenu.removeAllItems()
    guard let player = PlayerManager.shared.activePlayer else { return }
    let nowPlayingIndex = player.info.nowPlayingIndex
    for (index, item) in player.info.playlist.enumerated() {
      playlistMenu.addItem(withTitle: item.displayName, action: #selector(PlayerWindowController.menuPlaylistItem(_:)),
                           tag: index, obj: nil, stateOn: index == nowPlayingIndex)
    }
  }

  @MainActor
  private func updateChapterList() {
    chapterMenu.removeAllItems()
    guard let player = PlayerManager.shared.activePlayer else { return }
    let info = player.info
    let chapters = info.chapters
    let standard = (chapters.last?.startTimeString ?? "").reversed()
    let padder = { (time: String) -> String in
      return String((time.reversed() + standard[standard.index(standard.startIndex, offsetBy: time.count)...].map {
        $0 == ":" ? ":" : "0"
      }).reversed())
    }
    for (index, chapter) in chapters.enumerated() {
      let menuTitle = "\(padder(chapter.startTimeString)) – \(chapter.title)"
      let chapterSwitchAction = #selector(PlayerWindowController.menuChapterSwitch(_:))
      let menuItem = NSMenuItem(title: menuTitle, action: chapterSwitchAction, keyEquivalent: "")
      menuItem.tag = index
      let isPlaying = index == info.chapter
      menuItem.state = isPlaying ? .on : .off
      let font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
      menuItem.attributedTitle = NSAttributedString(string: menuTitle, attributes: [.font: font])
      chapterMenu.addItem(menuItem)
    }
  }

  @MainActor
  private func updateTracks(forMenu menu: NSMenu, type: MPVTrack.TrackType) {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let info = player.info
    menu.removeAllItems()
    let action = #selector(PlayerWindowController.menuChangeTrack(_:))
    let noTrackMenuItem = NSMenuItem(title: StringConstants.trackNone, action: action, keyEquivalent: "")
    noTrackMenuItem.representedObject = MPVTrack.emptyTrack(for: type)
    if info.trackId(type) == 0 {  // no track
      noTrackMenuItem.state = .on
    }
    menu.addItem(noTrackMenuItem)
    for track in info.trackList(type) {
      menu.addItem(withTitle: track.readableTitle, action: #selector(PlayerWindowController.menuChangeTrack(_:)),
                   tag: nil, obj: (track, type), stateOn: track.id == info.trackId(type))
    }
  }

  @MainActor
  private func updatePlaybackMenu() {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let isDisplayingPlaylist = player.pwc.isOpen(sidebarTab: .playlist)
    playlistPanel?.title = isDisplayingPlaylist ? StringConstants.hidePlaylistPanel : StringConstants.playlistPanel
    let isDisplayingChapters = player.pwc.isOpen(sidebarTab: .chapters)
    chapterPanel?.title = isDisplayingChapters ? StringConstants.hideChaptersPanel : StringConstants.chaptersPanel
    pause.title = player.info.isPaused ? StringConstants.resume : StringConstants.pause
    let speed = player.info.playSpeed.groupedStringUpTo6Decimals
    speedIndicator.title = String(format: NSLocalizedString("menu.speed", comment: "Speed:"), speed)
    let info = player.info
    let abLoopActive = info.isABLoopActive
    let loopMode = info.loopMode
    abLoop.state = abLoopActive ? .on : .off
    fileLoop.state = loopMode == .file ? .on : .off
    playlistLoop.state = loopMode == .playlist ? .on : .off
  }

  @MainActor
  private func updateVideoMenu() {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let isDisplayingSettings = player.pwc.isOpen(sidebarTab: .video)
    quickSettingsVideo?.title = isDisplayingSettings ? StringConstants.hideVideoPanel : StringConstants.videoPanel
    let isInFullScreen = player.pwc.isFullScreen
    let isInPIP = player.pwc.currentLayout.isInPiP
    let isOnTop = player.pwc.isOnTop
    let isDelogo = player.info.delogoFilter != nil
    alwaysOnTop.state = isOnTop ? .on : .off
    lockAspectRatio.state = Preference.unlockWindowAspectRatio ? .off : .on
    lockAspectRatio.isEnabled = Preference.bool(for: .edgeToEdgeVideo)
    liveText.state = Preference.isLiveTextEnabled ? .on : .off
    deinterlace.state = player.info.deinterlace ? .on : .off
    fullScreen.title = isInFullScreen ? StringConstants.exitFullScreen : StringConstants.fullScreen
    pictureInPicture?.title = isInPIP ? StringConstants.exitPIP : StringConstants.pip
    miniPlayer.title = player.isInMiniPlayer ? StringConstants.exitMiniPlayer : StringConstants.miniPlayer
    delogo.state = isDelogo ? .on : .off
  }

  @MainActor
  private func updateAudioMenu() {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let isDisplayingSettings = player.pwc.isOpen(sidebarTab: .audio)
    quickSettingsAudio?.title = isDisplayingSettings ? StringConstants.hideAudioPanel :
        StringConstants.audioPanel
    let volFmtString: String
    if player.info.isMuted {
      volFmtString = NSLocalizedString("menu.volume_muted", comment: "Volume: (Muted)")
      mute.state = .on
    } else {
      volFmtString = NSLocalizedString("menu.volume", comment: "Volume:")
      mute.state = .off
    }
    let volumeString = player.info.volume.groupedStringUpTo6Decimals
    volumeIndicator.title = String(format: volFmtString, volumeString)
    let audioDelayString = player.info.audioDelay.groupedStringUpTo6Decimals
    audioDelayIndicator.title = String(format: NSLocalizedString("menu.audio_delay", comment: "Audio Delay:"), audioDelayString)
  }

  @MainActor
  private func updateAudioDevice() {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let devices = player.getAudioDevices()
    let currAudioDevice = player.mpv.getString(MPVProperty.audioDevice)
    audioDeviceMenu.removeAllItems()
    for device in devices {
      audioDeviceMenu.addItem(withTitle: String(describing: device),
                              action: #selector(AppDelegate.menuSelectAudioDevice(_:)), tag: nil,
                              obj: device.name, stateOn: device.name == currAudioDevice)
    }
  }

  @MainActor
  private func updateFlipAndMirror() {
    guard let info = PlayerManager.shared.activePlayer?.info else { return }
    flip.state = info.isFlippedVertical ? .on : .off
    mirror.state = info.isFlippedHorizontal ? .on : .off
  }

  @MainActor
  private func updateSubMenu() {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let isDisplayingSettings = player.pwc.isOpen(sidebarTab: .sub)
    quickSettingsSub?.title = isDisplayingSettings ? StringConstants.hideSubtitlesPanel :
    StringConstants.subtitlesPanel
    hideSubtitles.title = player.info.isSubVisible ? StringConstants.hideSubtitles :
    StringConstants.showSubtitles
    hideSecondSubtitles.title = player.info.isSecondSubVisible ? StringConstants.hideSecondSubtitles :
    StringConstants.showSecondSubtitles
    let subDelayString = player.info.subDelay.groupedStringUpTo6Decimals
    subDelayIndicator.title = String(format: NSLocalizedString("menu.sub_delay", comment: "Subtitle Delay:"), subDelayString)

    let encodingCode = player.info.subEncoding ?? "auto"
    for encoding in Constants.encodings {
      if encoding.code == encodingCode {
        encodingMenu.item(withTitle: encoding.title)?.state = .on
      }
    }

    let providerID = Preference.string(for: .onlineSubProvider) ?? OnlineSubtitle.Providers.openSub.id
    let providerName = OnlineSubtitle.Providers.nameForID(providerID)
    findOnlineSub.title = String(format: StringConstants.findOnlineSubtitles, providerName)
  }

  private func updateOnlineSubSourceMenu() {
    OnlineSubtitle.populateMenu(onlineSubSourceMenu,
                                action: #selector(PlayerWindowController.menuFindOnlineSub(_:)))
  }

  @MainActor
  func updateSavedFiltersMenu(type: String) {
    guard let player = PlayerManager.shared.activePlayer else { return }
    let filters = type == MPVProperty.vf ? player.info.videoFilters : player.info.audioFilters
    let menu: NSMenu! = type == MPVProperty.vf ? savedVideoFiltersMenu : savedAudioFiltersMenu
    for item in menu.items {
      if let string = item.representedObject as? String, let asObject = MPVFilter(rawString: string) {
        // Filters that support multiple parameters have more than one valid string representation.
        // Must compare filters using their object representation.
        item.state = filters.contains { $0 == asObject } ? .on : .off
      }
    }
  }

  @MainActor
  func updatePluginMenu() {
    guard AppDelegate.iinaPluginSystemEnabled else { return }
    Logger.log.trace("Updating Plugin menu")
    pluginMenu.removeAllItems()

    let activePlayer = PlayerManager.shared.activePlayer
    let managePluginsItem = NSMenuItem(title: StringConstants.managePlugins,
                                       action: #selector(AppDelegate.showPluginPreferences(_:)),
                                       keyEquivalent: "")
    let developerToolTitle = NSLocalizedString("menu.developer_tool", comment: "Developer Tool")
    let developerTool = NSMenuItem(title: developerToolTitle, action: nil, keyEquivalent: "")
    let developerToolSubmenu = NSMenu()
    developerTool.submenu = developerToolSubmenu
    let reloadTitle = NSLocalizedString("menu.reload_plugins", comment: "Reload All Plugins")
    let reloadPluginsItem = NSMenuItem(title: reloadTitle, action: #selector(AppDelegate.reloadAllPlugins(_:)),
                                       keyEquivalent: "")

    pluginMenu.addItem(managePluginsItem)

    if let pwc = activePlayer?.pwc {
      let isDisplayingPluginsPanel = pwc.isTabGroupVisible(.plugins)
      let title = isDisplayingPluginsPanel ? StringConstants.hidePluginsPanel : StringConstants.showPluginsPanel
      let showPanelItem = NSMenuItem(title: title, action: #selector(pwc.showPluginsPanel(_:)), keyEquivalent: "")

      pluginMenu.addItem(showPanelItem)
    }
    pluginMenu.addItem(.separator())
    var justAddedSeparator = true

    var mappingItemPairs: [(KeyMapping, NSMenuItem)] = []

    guard let activePlayer else { return }

    let plugins = activePlayer.plugins
    for instance in plugins {
      var counter = 0
      var rootMenu: NSMenu! = pluginMenu
      let menuItems = (instance.plugin.globalInstance?.menuItems ?? []) + instance.menuItems
      if menuItems.isEmpty { continue }

      pluginMenu.addItem(.sectionHeader(title: instance.plugin.name))
      justAddedSeparator = false

      for item in menuItems {
        if counter == 5 {
          Logger.log.warn("Please avoid adding too many first-level menu items. IINA will only display the first 5 of them.")
          let moreItem = NSMenuItem()
          moreItem.title = NSLocalizedString("menu.more_plugin", comment: "More…")
          rootMenu = NSMenu()
          moreItem.submenu = rootMenu
          pluginMenu.addItem(moreItem)
        }
        add(menuItemDef: item, to: rootMenu, for: instance, mappingItemPairs: &mappingItemPairs)
        counter += 1
      }

      let devToolItem = NSMenuItem()
      devToolItem.title = instance.plugin.name
      developerToolSubmenu.addItem(
        menuItem(forPluginInstance: instance, tag: JavasctiptDevTool.JSMenuItemInstance))
      if let globalInst = instance.plugin.globalInstance {
        developerToolSubmenu.addItem(
          menuItem(forPluginInstance: globalInst, tag: JavasctiptDevTool.JSMenuItemInstance))
      }
    }

    if !justAddedSeparator {
      pluginMenu.addItem(.separator())
    }
    pluginMenu.addItem(developerTool)
    pluginMenu.addItem(reloadPluginsItem)

    sectionMappingItemPairs[MPVInputSection.Shared.PLUGINS_SECTION_NAME] = mappingItemPairs
  }

  @discardableResult
  private func add(menuItemDef item: JavascriptPluginMenuItem,
                   to menu: NSMenu,
                   for plugin: JavascriptPluginInstance,
                   mappingItemPairs: inout [(KeyMapping, NSMenuItem)]) -> NSMenuItem {
    if item.isSeparator {
      let item = NSMenuItem.separator()
      menu.addItem(item)
      return item
    }

    Logger.log.verbose("Adding Plugin menu item: \"\(item.title)\", key=\"\(item.keyBinding ?? "")\"")

    let menuItem: NSMenuItem
    if item.action == nil {
      menuItem = menu.addItem(withTitle: item.title, action: nil, target: plugin, obj: item)
    } else {
      menuItem = menu.addItem(withTitle: item.title,
                              action: #selector(plugin.menuItemAction(_:)),
                              target: plugin,
                              obj: item)
    }

    menuItem.isEnabled = item.enabled
    menuItem.state = item.selected ? .on : .off
    if let rawKey = item.keyBinding {
      // Store the item with its pair - the PlayerInputContext will set the binding & deal with conflicts
      let actionDescription = "\(plugin.plugin.name) → \(menuItem.title)"
      // #MenuItemKeyBinding
      let keyMapping = KeyMapping(rawKey: rawKey, rawAction: nil, isIINACommand: true,
                                  comment: actionDescription, sourceName: plugin.plugin.name)
      mappingItemPairs.append((keyMapping, menuItem))
    }
    if !item.items.isEmpty {
      menuItem.submenu = NSMenu()
      for submenuItem in item.items {
        add(menuItemDef: submenuItem, to: menuItem.submenu!, for: plugin, mappingItemPairs: &mappingItemPairs)
      }
    }
    item.nsMenuItem = menuItem
    return menuItem
  }

  /**
   Bind a menu with a list of available options.

   - parameter menu:            the NSMenu
   - parameter withOptions:     option titles for each menu item, as an array
   - parameter objects:         objects that will be bind to each menu item, as an array
   - parameter objectMap:       alternatively, can pass a map like [title: object]
   - parameter action:          the action for each menu item
   - parameter checkStateBlock: a block to set each menu item's state
   */
  private func bind(menu: NSMenu,
                    withOptions titles: [String]?, objects: [Any?]?,
                    objectMap: [String: Any?]?,
                    action: Selector?, checkStateBlock block: @MainActor @escaping (NSMenuItem) -> Bool) {
    // if use title
    if let titles = titles {
      // options and objects must be same
      guard objects == nil || titles.count == objects?.count else {
        Logger.log.error("different object count when binding menu")
        return
      }
      // add menu items
      for (index, title) in titles.enumerated() {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let object = objects?[index] {
          menuItem.representedObject = object
        } else {
          menuItem.representedObject = title
        }
        menu.addItem(menuItem)
      }
    }
    // if use map
    if let objectMap = objectMap {
      for (title, obj) in objectMap {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.representedObject = obj
        menu.addItem(menuItem)
      }
    }
    // add to list
    menu.delegate = self
    menuBindingList.updateValue(block, forKey: menu)
  }

  @MainActor
  private func updateOpenMenuItems() {
    if PlayerManager.shared.getNonIdle().count == 0 {
      open.title = stringForOpen
      openAlternative.title = stringForOpen
      openURL.title = stringForOpenURL
      openURLAlternative.title = stringForOpenURL
    } else {
      if Preference.bool(for: .alwaysOpenInNewWindow) {
        open.title = stringForOpenAlternative
        openAlternative.title = stringForOpen
        openURL.title = stringForOpenURLAlternative
        openURLAlternative.title = stringForOpenURL
      } else {
        open.title = stringForOpen
        openAlternative.title = stringForOpenAlternative
        openURL.title = stringForOpenURL
        openURLAlternative.title = stringForOpenURLAlternative
      }
    }
  }

  // MARK: - Menu delegate

  @MainActor
  func menuWillOpen(_ menu: NSMenu) {
    Logger.log.verbose("Updating menu: \(menu.title.quoted)")

    // If all menu items are disabled do not update the menus.
    guard !isDisabled else { return }
    switch menu {
    case fileMenu:
      updateOpenMenuItems()
    case playlistMenu:
      updatePlaylist()
    case chapterMenu:
      updateChapterList()
    case playbackMenu:
      updatePlaybackMenu()
    case videoMenu:
      updateVideoMenu()
    case videoTrackMenu:
      updateTracks(forMenu: menu, type: .video)
    case flipMenu:
      updateFlipAndMirror()
    case audioMenu:
      updateAudioMenu()
    case audioTrackMenu:
      updateTracks(forMenu: menu, type: .audio)
    case audioDeviceMenu:
      updateAudioDevice()
    case subMenu:
      updateSubMenu()
    case subTrackMenu:
      updateTracks(forMenu: menu, type: .sub)
    case secondSubTrackMenu:
      updateTracks(forMenu: menu, type: .secondSub)
    case onlineSubSourceMenu:
      updateOnlineSubSourceMenu()
    case savedVideoFiltersMenu:
      updateSavedFiltersMenu(type: MPVProperty.vf)
    case savedAudioFiltersMenu:
      updateSavedFiltersMenu(type: MPVProperty.af)
    case pluginMenu:
      PlayerManager.shared.activePlayer?.events.emit(.menuUpdate)
      updatePluginMenu()
    default: break
    }
    // check conveniently bound menus
    if let checkEnableBlock = menuBindingList[menu] {
      for item in menu.items {
        item.state = checkEnableBlock(item) ? .on : .off
      }
    }
  }

  // MARK: - Others

  func updateSavedFilters(forType type: String, from filters: [SavedFilter]) {
    let isVideo = type == MPVProperty.vf
    var keyMappings: [KeyMapping] = []
    var mappingItemPairs: [(KeyMapping, NSMenuItem)] = []

    let sectionName: String
    let filterTypeString: String
    if isVideo {
      sectionName = MPVInputSection.Shared.VIDEO_FILTERS_SECTION_NAME
      filterTypeString = "Toggle video filter"
    } else {
      sectionName = MPVInputSection.Shared.AUDIO_FILTERS_SECTION_NAME
      filterTypeString = "Toggle audio filter"
    }

    let menu: NSMenu! = isVideo ? savedVideoFiltersMenu : savedAudioFiltersMenu
    menu.removeAllItems()
    for filter in filters {
      let menuItem = NSMenuItem()
      menuItem.title = filter.name
      if isVideo {
        menuItem.action = #selector(PlayerWindowController.menuToggleVideoFilterString(_:))
      } else {
        menuItem.action = #selector(PlayerWindowController.menuToggleAudioFilterString(_:))
      }
      menuItem.keyEquivalent = ""
      menuItem.representedObject = filter.filterString
      menu.addItem(menuItem)

      if DebugConfig.logBindingsRebuild {
        let readableKey = KeyCodeHelper.readableString(fromKey: filter.shortcutKey, modifiers: filter.shortcutKeyModifiers)
        Logger.log.verbose("Updating menuItem for \(isVideo ? "VF" : "AF") \(filter.name.quoted) with keyEquiv: \(readableKey.quoted)")
      }

      let rawKey = KeyCodeHelper.macOSToMpv(key: filter.shortcutKey, modifiers: filter.shortcutKeyModifiers)
      if !rawKey.isEmpty {
        // #MenuItemKeyBinding
        let description = "\(filterTypeString): \(filter.name.quoted)"
        let keyMapping = KeyMapping(rawKey: rawKey, rawAction: nil, isIINACommand: true, comment: description, sourceName: filter.name)
        keyMappings.append(keyMapping)
        mappingItemPairs.append((keyMapping, menuItem))
      }
    }

    sectionMappingItemPairs[sectionName] = mappingItemPairs
    AppInputConfig.replaceMappings(forSharedSectionName: sectionName, with: keyMappings)
  }

  /// Refreshes the lastmost (i.e., highest-priority) input section, which contains the app's built-in menu items.
  /// Instead of trying to keep track of them manually, just recurse through all the menus and find all the menu item
  /// bindings which haven't already been accounted for.
  func refreshStaticMenuItemBindings() {
    let actionBlacklist = sectionMappingItemPairs.filter({ $0.key != MPVInputSection.Shared.STATIC_MENU_ITEMS_SECTION_NAME })
      .flatMap({$0.value})
      .compactMap({ $0.1.action })
    var staticMenuItemBindings: [KeyMapping] = []

    for rootMenu in NSApp.mainMenu!.items {
      guard rootMenu.hasSubmenu, let subMenu = rootMenu.submenu else { continue }
      for rootMenuItem in subMenu.items {
        forMenuItemAndAllDescendents(rootMenuItem, do: { menuItem in
          guard !menuItem.keyEquivalent.isEmpty else { return }
          // filter out media keys; they can't be bound anyway
          guard KeyCodeHelper.isPrintable(menuItem.keyEquivalent) else { return }
          let rawKey = KeyCodeHelper.macOSToMpv(key: menuItem.keyEquivalent, modifiers: menuItem.keyEquivalentModifierMask)
          guard !rawKey.isEmpty else { return }

          if let menuItemAction = menuItem.action, actionBlacklist.contains(menuItemAction) { return }
          /// Exclude `File` > `New Window` if it is not enabled
          if menuItem.action == #selector(AppDelegate.menuNewWindow(_:)) && menuItem.isHidden { return }
          // #MenuItemKeyBinding
          let actionDesc = menuItem.menuPathDescription
          let keyMapping = KeyMapping(rawKey: rawKey, rawAction: nil, isIINACommand: true, comment: actionDesc, sourceName: "built-in")
          staticMenuItemBindings.append(keyMapping)
        })
      }
    }

    AppInputConfig.replaceMappings(forSharedSectionName: MPVInputSection.Shared.STATIC_MENU_ITEMS_SECTION_NAME,
                                   with: staticMenuItemBindings, onlyIfDifferent: true)
  }

  private func forMenuItemAndAllDescendents(_ menuItem: NSMenuItem, do callback: (NSMenuItem) -> Void) {
    callback(menuItem)
    if menuItem.hasSubmenu, let subMenu = menuItem.submenu {
      for subMenuItem in subMenu.items {
        forMenuItemAndAllDescendents(subMenuItem, do: callback)
      }
    }
  }

  /// Disable all menu items.
  ///
  /// This method is used during application termination to stop any further input from the user and when displaying alerts.
  func disableAllMenus() {
    isDisabled = true
    setIsEnabledInAllMenuItems(NSApp.mainMenu!, false)
  }

  func enableAllMenus() {
    isDisabled = false
    setIsEnabledInAllMenuItems(NSApp.mainMenu!, true)
  }

  /// Set `isEnabled` to the given value in all menu items in the given menu and any submenus.
  ///
  /// This method recursively descends through the entire tree of menu items setting `isEnabled` in all items.
  /// - Parameter menu: Menu to disable or enable.
  /// - Parameter value: Value to set `isEnabled` to.
  private func setIsEnabledInAllMenuItems(_ menu: NSMenu, _ value: Bool) {
    for item in menu.items {
      if item.hasSubmenu {
        setIsEnabledInAllMenuItems(item.submenu!, value)
      }
      item.isEnabled = value
    }
  }
}
