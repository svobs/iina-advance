//
//  AppDelegate.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import Sparkle

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

  /// The `AppDelegate` singleton object.
  @MainActor
  static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

  // MARK: Properties

  @IBOutlet var menuController: MenuController!

  @IBOutlet weak var dockMenu: NSMenu!

  // MARK: Window controllers

  @MainActor lazy var initialWindow = InitialWindowController()
  @MainActor lazy var openURLWindow = OpenURLWindowController()
  @MainActor lazy var aboutWindow = AboutWindowController()
  @MainActor lazy var fontPicker = FontPickerWindowController()
  @MainActor lazy var inspector = InspectorWindowController()
  @MainActor lazy var historyWindow = HistoryWindowController()
  @MainActor lazy var guideWindow = GuideWindowController()
  @MainActor lazy var logWindow = LogWindowController()

  @MainActor lazy var vfWindow = FilterWindowController(filterType: MPVProperty.vf, .videoFilter)
  @MainActor lazy var afWindow = FilterWindowController(filterType: MPVProperty.af, .audioFilter)

  @MainActor lazy var preferenceWindowController = PreferenceWindowController()

  // MARK: State

  /// If false, app was launched in a special mode which does not allow windows to be shown.
  /// Can be set to `false` if launched in non-interactive modes, e.g. encoding mode (`--o`),
  ///  or with `--macos-app-activation-policy=accessory`.
  ///
  /// If disabled, disables save/restore, history, plugins, and general UI for this launch.
  var isInteractiveLaunch: Bool = true {
    didSet {
      let isEnabled = isInteractiveLaunch
      if !isEnabled {
        UIState.shared.disableSaveAndRestoreUntilNextLaunch()
      }
      HistoryController.shared.async {
        HistoryController.shared.historyEnabled = isEnabled
      }
    }
  }

  static let iinaPluginSystemEnabled = Preference.bool(for: .iinaEnablePluginSystem)

  var startupHandler: StartupHandler!
  private let shutdownHandler = ShutdownHandler()
  private var notiHandler: NotificationHandler!

  private var lastClosedWindowName: String = ""
  var isShowingOpenFileWindow = false

  @MainActor
  func ensureInteractiveLaunchEnabled() {
    guard !isInteractiveLaunch else { return }

    isInteractiveLaunch = true
    Logger.updateEnablement()  // in case it was disabled previously
    Logger.log.debug("Re-enabling interactive launch")
    startupHandler.initAppUI()
    HistoryController.shared.start()
  }

  var isTerminating: Bool {
    return shutdownHandler.isTerminating
  }

  /// Returns a `PlayerWindowController` array containing all currently open player windows.
  @MainActor var playerWindows: [PlayerWindowController] {
    return NSApp.windows.compactMap{ $0.windowController as? PlayerWindowController }.filter{ $0.isOpen }
  }

  /// Called each time a pref `key`'s value is set
  func prefDidChange(_ key: Preference.Key, _ newValue: Any?) {
    switch key {
    case PK.enableAdvancedSettings, PK.enableLogging, PK.logLevel:
      Task { @MainActor in
        Logger.updateEnablement()
        // depends on advanced being enabled:
        menuController.refreshCmdNStatus()
        menuController.refreshStaticMenuItemBindings()
      }

    case PK.enableCmdN:
      Task { @MainActor in
        menuController.refreshCmdNStatus()
        menuController.refreshStaticMenuItemBindings()
      }

    case PK.resumeLastPosition:
      HistoryController.shared.async {
        HistoryController.shared.log.verbose("Reloading playback history in response to change for 'resumeLastPosition'.")
        HistoryController.shared.startOrStopMonitoringWatchLaterDir()
        HistoryController.shared.reloadAll()
      }

    case PK.useMediaKeys:
      DispatchQueue.main.async {
        MediaPlayerIntegration.shared.update()
      }

    // TODO: #1, see above
//    case PK.hideWindowsWhenInactive:
//      if let newValue = newValue as? Bool {
//        for window in NSApp.windows {
//          guard window as? PlayerWindow == nil else { continue }
//          window.hidesOnDeactivate = newValue
//        }
//      }

    case .killRequest:
      Task { @MainActor in
        appDidReceiveKillRequest()
      }

    default:
      break
    }
  }

  /// Only implemented for special case of `UIState.shared.currentLaunchName`. All other prefs should be checked in `prefDidChange`.
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, let change else { return }

    switch keyPath {
    case UIState.shared.currentLaunchName:
      guard let newLaunchLifecycleState = change[.newKey] as? Int else { return }
      guard !isTerminating else { return }
      guard newLaunchLifecycleState != UIState.LaunchLifecycleState.missingOrInvalid.rawValue else { return }

      if UIState.shared.isSaveEnabled {
        Logger.log("Detected change to this instance's lifecycle state pref (\(keyPath.quoted)). Probably a younger instance of IINA has started and is attempting to restore")
        Logger.log("Changing our lifecycle state back to 'stillRunning' so the other launch will skip this instance.")
        UserDefaults.standard.setValue(UIState.LaunchLifecycleState.stillRunning.rawValue, forKey: keyPath)
      } else {
        Logger.log("Detected change to this instance's lifecycle state pref (\(keyPath.quoted)), but save is disabled; ignoring")
      }
      Task { @MainActor in
        NotificationCenter.default.post(Notification(name: .savedWindowStateDidChange, object: self))
      }

    default:
      return
    }
  }

  // MARK: - Auto update

  @IBOutlet var updaterController: SPUStandardUpdaterController!

  func feedURLString(for updater: SPUUpdater) -> String? {
    return Preference.bool(for: .receiveBetaUpdate) ? AppData.appcastBetaLink : AppData.appcastLink
  }

  // MARK: - Startup

  var isDoneLaunching: Bool {
    startupHandler.isDoneLaunching
  }

  @MainActor
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Must setup preferences before logging so log level is set correctly.
    registerUserDefaultValues()

    startupHandler = StartupHandler()

    // Parse & process command line arguments, if any.
    // Do this *before* loading history or even initLogging, because both can be disabled by CLI args.
    let cmdLineArgs = ProcessInfo.processInfo.arguments.dropFirst()
    startupHandler.processCommandLine(cmdLineArgs)  /// may update `isInteractiveLaunch`

    Logger.initLogging()

    // This will also start the demo player
    let demoPlayer = PlayerManager.shared.getOrCreateDemo()
    // Init MPVOptionDefaults: we need this for logAllAppDetails()
    MPVOptionDefaults.shared = MPVOptionDefaults(demoPlayer: demoPlayer)

    AppDetailsLogging.shared.logAllAppDetails()

    Logger.log.debug("App will launch\(isInteractiveLaunch ? "" : " (non-interactive)"). LaunchID: \(UIState.shared.currentLaunchID)")

    Logger.log.debug("All app arguments: \(cmdLineArgs)")
    if let cli = startupHandler.commandLineState {
      Logger.log.debug("Parsed IINA CLI args: stdin=\(cli.isStdin.yn) separateWindows=\(cli.openSeparateWindows?.yn ?? "nil") musicMode=\(cli.enterMusicMode.yn) pip=\(cli.enterPIP.yn). Filenames from arguments: \(cli.filenames.map{$0.pii})")
      Logger.log.debug("Derived mpv properties from args: \(cli.mpvArguments)")
    }

    // Start asynchronously gathering and caching information about the hardware decoding
    // capabilities of this Mac.
    HardwareDecodeCapabilities.shared.checkCapabilities()

    // Wait until after logging is done to run this (need PII):
    UIState.shared.updateCachedScreens()

    // Set up observers

    var ncDefaultObservers: [NotificationHandler.NCObserver] = [ .init(.windowIsReadyToShow, startupHandler.windowIsReadyToShow),
                                                           .init(.windowMustCancelShow, startupHandler.windowMustCancelShow)]
    // The "action on last window closed" action will vary slightly depending on which type of window was closed.
    // Here we add a listener which fires when *any* window is closed, in order to handle that logic all in one place.
    ncDefaultObservers.append(.init(NSWindow.willCloseNotification, windowWillClose))

    // Save ordered list of open windows each time the order of windows changed.
    ncDefaultObservers.append(.init(NSWindow.didBecomeMainNotification, windowDidBecomeMain))
    ncDefaultObservers.append(.init(NSWindow.willBeginSheetNotification, windowWillBeginSheet))
    ncDefaultObservers.append(.init(NSWindow.didEndSheetNotification, windowDidEndSheet))
    ncDefaultObservers.append(.init(NSWindow.didMiniaturizeNotification, windowDidMiniaturize))
    ncDefaultObservers.append(.init(NSWindow.didDeminiaturizeNotification, windowDidDeminiaturize))

#if DEBUG
    if DebugConfig.logAllScreenChangeEvents {
      ncDefaultObservers.append(.init(NSWindow.didChangeScreenNotification, { noti in
        let window = noti.object as! NSWindow
        let screenID = window.screen?.screenID.quoted ?? "nil"
        Logger.log.verbose("WindowDidChangeScreen \(window.windowNumber): \(screenID)")
      }))
    }
#endif

    let observedPrefKeys: [Preference.Key] = !isInteractiveLaunch ? [] : [
      .logLevel,
      .enableLogging,
      .enableAdvancedSettings,
      .enableCmdN,
      .resumeLastPosition,
      .useMediaKeys,
      //    .hideWindowsWhenInactive, // TODO: #1, see below
      .killRequest,
    ]

    /// Attach this in `applicationWillFinishLaunching`, because `application(openFiles:)` will be called after this but
    /// before `applicationDidFinishLaunching`.
    notiHandler = NotificationHandler(Logger.log, prefDidChange: prefDidChange,
                                      legacyPrefKeyObserver: self,
                                      observedPrefKeys, [
                                        .default: ncDefaultObservers
                                      ])

    // Install plugins
    if AppDelegate.iinaPluginSystemEnabled, FirstRunManager.isFirstRun(for: .init("installedDefaultPlugins")) {
      var hasError = false
      Logger.log.debug("Installing default plugins")
      let pluginPath = Bundle.main.resourcePath?.appending("/plugins")
      if let pluginPath, FileManager.default.fileExists(atPath: pluginPath),
         let contents = try? FileManager.default.contentsOfDirectory(atPath: pluginPath) {
        let defaultPlugins = contents.filter { $0.hasSuffix(".iinaplgz") }
        for defaultPlugin in defaultPlugins {
          do {
            Logger.log.debug("Installing default plugin: \(defaultPlugin)")
            let path = pluginPath.appending("/\(defaultPlugin)")
            let plugin = try JavascriptPlugin.create(fromPackageURL: URL(fileURLWithPath: path))
            if JavascriptPlugin.plugins.contains(where: { $0.identifier == plugin.identifier }) {
              Logger.log("Skipped \(plugin.identifier), already installed")
              continue
            }
            plugin.normalizePath()
            JavascriptPlugin.plugins.append(plugin)
            plugin.enabled = true
            Logger.log("Installed \(plugin.identifier)")
          } catch let error {
            hasError = true
            Logger.log(error.localizedDescription, level: .error)
          }
        }
      } else {
        hasError = true
        Logger.log("Cannot find default plugins", level: .error)
      }

      if hasError {
        Logger.log.verbose("Error occurred installing default plugins; unsetting flag installedDefaultPlugins")
        FirstRunManager.unsetFirstRun(for: .init("installedDefaultPlugins"))
      }
    }

    notiHandler.addAllObservers()

    // Check for legacy pref entries and migrate them to their modern equivalents.
    // Must do this before setting defaults so that checking for existing entries doesn't result in false positives
    LegacyMigration.migrateLegacyPreferences()

#if DEBUG
    /// Set the NSUserDefault NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints to YES to have
    /// `-[NSWindow visualizeConstraints:]` automatically called when [conflicting constraints] happens.
    ///  And/or, set a symbolic breakpoint on `LAYOUT_CONSTRAINTS_NOT_SATISFIABLE` to catch this in the debugger.
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
#endif

    // Call this *before* registering for url events, to guarantee that menu is init'd
    AppInputConfig.loadSelectedConfBindingsIntoAppConfig()
  }

  private func registerUserDefaultValues() {
    UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map { ($0.0.rawValue, $0.1) }))
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    Logger.log.verbose("App did finish launching")
    startupHandler.doStartup()
  }

  // MARK: - Window Notifications
  // Keep maintaining the window lists even if save is disabled, because it may be needed if save is enabled again.

  /// Sheet window is opening. Track it like a regular window.
  ///
  /// The notification provides no way to actually know which sheet is being added.
  /// So prior to opening the sheet, the caller must manually add it using `UIState.shared.addOpenSheet`.
  private func windowWillBeginSheet(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let activeWindowName = window.savedStateName
    guard !activeWindowName.isEmpty else { return }

    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      guard let sheetNames = UIState.shared.openSheetsDict[activeWindowName] else { return }

      for sheetName in sheetNames {
        Logger.log.verbose("Sheet opened: \(sheetName.quoted)")
        UIState.shared.windowsOpen.insert(sheetName)
      }
      UIState.shared.saveCurrentOpenWindowList()
    }
  }

  /// Sheet window did close
  private func windowDidEndSheet(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let activeWindowName = window.savedStateName
    guard !activeWindowName.isEmpty else { return }

    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      // NOTE: not sure how to identify which sheet will end. In the future this could cause problems
      // if we use a window with multiple sheets. But for now we can assume that there is only one sheet,
      // so that is the one being closed.
      guard let sheetNames = UIState.shared.openSheetsDict[activeWindowName] else { return }
      UIState.shared.removeOpenSheets(fromWindow: activeWindowName)

      for sheetName in sheetNames {
        Logger.log.verbose("Sheet closed: \(sheetName.quoted)")
        UIState.shared.windowsOpen.remove(sheetName)
      }

      UIState.shared.saveCurrentOpenWindowList()
    }
  }

  /// Saves an ordered list of current open windows (if configured) each time *any* window becomes the main window.
  private func windowDidBecomeMain(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Assume new main window is the active window. AppKit does not provide an API to notify when a window is opened,
    // so this notification will serve as a proxy, since a window which becomes active is by definition an open window.
    let activeWindowName = window.savedStateName
    guard !activeWindowName.isEmpty else { return }

    // Query for the list of open windows and save it.
    // Don't do this too soon, or their orderIndexes may not yet be up to date.
    DispatchQueue.main.async { [self] in
      // This notification can sometimes happen if the app had multiple windows at shutdown.
      // We will ignore it in this case, because this is exactly the case that we want to save!
      guard !isTerminating else { return }

      // This notification can also happen after windowDidClose notification,
      // so make sure this a window which is recognized.
      if UIState.shared.windowsMinimized.remove(activeWindowName) != nil {
        Logger.log.verbose("Minimized window become main; adding to open windows list: \(activeWindowName.quoted)")
        UIState.shared.windowsOpen.insert(activeWindowName)
      } else {
        // Do not process. Another listener will handle it
        Logger.log.trace("Window became main: \(activeWindowName.quoted)")
        return
      }

      UIState.shared.saveCurrentOpenWindowList()
    }
  }

  /// A window was minimized. Need to update lists of tracked windows.
  func windowDidMiniaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let savedStateName = window.savedStateName
    guard !savedStateName.isEmpty else { return }

    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      Logger.log.verbose("Window did minimize; adding to minimized windows list: \(savedStateName.quoted)")
      if !AppDelegate.shared.startupHandler.isDoneLaunching, let wc = window.windowController as? WindowController,
         AppDelegate.shared.startupHandler.wcsToRestore.contains(wc) {
        Logger.log.verbose("Marking window as done with restore: \(savedStateName.quoted)")
        AppDelegate.shared.startupHandler.wcsDoneWithRestore.insert(wc)
        AppDelegate.shared.startupHandler.showWindowsIfReady()
      }
      UIState.shared.windowsOpen.remove(savedStateName)
      UIState.shared.windowsMinimized.insert(savedStateName)
      UIState.shared.saveCurrentOpenWindowList()
    }
  }

  /// A window was un-minimized. Update state of tracked windows.
  private func windowDidDeminiaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let savedStateName = window.savedStateName
    guard !savedStateName.isEmpty else { return }

    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      Logger.log.verbose("App window did deminiaturize; removing from minimized windows list: \(savedStateName.quoted)")
      UIState.shared.windowsOpen.insert(savedStateName)
      UIState.shared.windowsMinimized.remove(savedStateName)
      UIState.shared.saveCurrentOpenWindowList()
    }
  }

  // MARK: - Window Close

  @MainActor
  private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    windowWillClose(window)
  }

  /// This method can be called multiple times safely because it always runs on the main thread and does not
  /// continue unless the window is found to be in an existing list
  @MainActor
  func windowWillClose(_ window: NSWindow) {
    guard !isTerminating else { return }

    let windowName = window.savedStateName
    guard !windowName.isEmpty else { return }

    Logger.log.verbose("Window will close: \(windowName)")

    let wasOpen = UIState.shared.windowsOpen.remove(windowName) != nil
    let wasMinimized = UIState.shared.windowsMinimized.remove(windowName) != nil

    if wasOpen || wasMinimized {
      lastClosedWindowName = windowName

      /// Query for the list of open windows and save it (excluding the window which is about to close).
      /// Most cases are covered by saving when `windowDidBecomeMain` is called, but this covers the case where
      /// the user closes a window which is not in the foreground.
      UIState.shared.saveCurrentOpenWindowList(excludingWindowName: window.savedStateName)
    } else {
      Logger.log.verbose("Window was not listed as open or minimized; skipping state update for \(windowName.quoted)")
    }

    (window.windowController as? WindowController)?.refreshWindowOpenCloseAnimation()

    if let player = (window.windowController as? PlayerWindowController)?.player {
      player.pwc.doPriorToWindowWillClose(window)
      // Player window was closed; need to remove some additional state
      player.clearSavedState()

      MediaPlayerIntegration.shared.update()
    }

    if window.isOnlyOpenWindow {
      doActionWhenLastWindowWillClose()
    }
  }

  /// Question mark
  @MainActor
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    guard !isTerminating else { return false }
    guard startupHandler.state == .doneOpening else {
      Logger.log.verbose("App will not terminate due to window closed: not yet done launching (state: \(startupHandler.state))")
      return false
    }

    /// Certain events (like when PIP is enabled) can result in this being called when it shouldn't.
    /// Another case is when the welcome window is closed prior to a new player window opening.
    /// For these reasons we must keep a list of windows which meet our definition of "open", which
    /// may not match Apple's definition which is more closely tied to `window.isVisible`.
    guard UIState.shared.windowsOpen.isEmpty else {
      Logger.log.verbose("App will not terminate: \(UIState.shared.windowsOpen.count) windows are still in open list: \(UIState.shared.windowsOpen)")
      return false
    }

    // Window hidden for PiP? Need special check becuase it will not be in windowsOpen set
    if let activePlayer = PlayerManager.shared.activePlayer, activePlayer.pwc.isWindowHidden {
      Logger.log.verbose("App will not terminate: found active but hidden player (\(activePlayer.label))")
      return false
    }

    guard isInteractiveLaunch else {
      Logger.log.verbose("Received `last window closed' notification for non-interactive launch. App will quit")
      return true
    }

    guard Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow) == .quit else {
      Logger.log.verbose("Last window was closed. Will do configured action")
      doActionWhenLastWindowWillClose()
      return false
    }

    assert(Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow) == .quit,
           "Unexpected actionWhenNoOpenWindow for quit: \(Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow).debugDescription)")
    UIState.shared.clearSavedLaunchForThisLaunch()
    Logger.log.verbose("Last window was closed. App will quit as configured via pref")
    return true
  }

  @MainActor
  private func doActionWhenLastWindowWillClose() {
    guard isInteractiveLaunch else {
      Logger.log.debug("Aborting action when last window closed: app-wide UI is disabled")
      return
    }
    guard !isTerminating else { return }
    guard let noOpenWindowAction = Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow) else { return }
    Logger.log.verbose("ActionWhenNoOpenWindow: \(noOpenWindowAction). LastClosedWindowName: \(lastClosedWindowName.quoted)")
    var shouldTerminate: Bool = false

    switch noOpenWindowAction {
    case .none:
      break
    case .quit:
      shouldTerminate = true
    case .sameActionAsLaunch:
      let launchAction: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
      var quitForAction: Preference.ActionAfterLaunch? = nil

      // Check if user just closed the window we are configured to open. If so, exit app instead of doing nothing
      if let closedWindowName = WindowAutosaveName(lastClosedWindowName) {
        switch closedWindowName {
        case .playbackHistory:
          quitForAction = .historyWindow
        case .openFile:
          quitForAction = .openPanel
        case .welcome:
          let windowsOpen = UIState.shared.windowsOpen
          guard windowsOpen.isEmpty else {
            Logger.log.verbose("LastWindowClosed == ActionWhenNoOpenWindow == welcomeWindow, but \(windowsOpen.count) other windows are open(ing): ignoring")
            return
          }
          quitForAction = .welcomeWindow
        default:
          quitForAction = nil
        }
      }

      if launchAction == quitForAction {
        Logger.log.debug("Last window closed was the configured ActionWhenNoOpenWindow. Will quit instead of re-opening it.")
        shouldTerminate = true
      } else {
        switch launchAction {
        case .welcomeWindow:
          showWelcomeWindow()
        case .openPanel:
          showOpenFileWindow(isAlternativeAction: true)
        case .historyWindow:
          showHistoryWindow(self)
        case .none:
          break
        }
      }
    }

    if shouldTerminate {
      Logger.log.debug("Clearing all state for this launch because all windows have closed!")
      UIState.shared.clearSavedLaunchForThisLaunch()
      NSApp.terminate(nil)
    }
  }

  // MARK: - Application termination

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Logger.log("App should terminate")
    if shutdownHandler.beginShutdown() {
      return .terminateNow
    }

    // Tell AppKit that it is ok to proceed with termination, but wait for our reply.
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    Logger.log("App will terminate")
    Logger.closeLogFiles()
  }

  // MARK: - Open file(s)


  func application(_ sender: NSApplication, openFiles filePaths: [String]) {
    startupHandler.applicationOpenFilesWasReceived(with: filePaths)
  }

  // MARK: - Accept dropped URL string on Dock icon

  @objc
  func droppedText(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
    Logger.log.verbose("Text dropped on app's Dock icon")
    guard let url = pboard.string(forType: .string) else { return }

    DispatchQueue.main.async { [self] in
      guard let player = PlayerManager.shared.activePlayer else { return }
      startupHandler.isAwaitingNewWindowsForOpenedFile = true
      if player.openURLString(url) == 0 {
        startupHandler.abortWaitForOpenFilePlayerStartup()
      } else {
        startupHandler.pwcsForOpenFiles = [player.pwc]
      }
      startupHandler.showWindowsIfReady()
    }
  }

  // MARK: - URL Scheme

  @objc func handleURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    Logger.log.debug("Handling URL event: \(url)")
    parsePendingURL(url)
  }

  /**
   Parses the pending iina:// url.
   - Parameter url: the pending URL.
   - Note:
   The iina:// URL scheme currently supports the following actions:

   __/open__
   - `url`: a url or string to open.
   - `new_window`: 0 or 1 (default) to indicate whether open the media in a new window.
   - `enqueue`: 0 (default) or 1 to indicate whether to add the media to the current playlist.
   - `full_screen`: 0 (default) or 1 to indicate whether open the media and enter fullscreen.
   - `pip`: 0 (default) or 1 to indicate whether open the media and enter pip.
   - `mpv_*`: additional mpv options to be passed. e.g. `mpv_volume=20`.
   Options starting with `no-` are not supported.
   */
  private func parsePendingURL(_ url: String) {
    Logger.log("Parsing URL \(url.pii)")
    guard let parsed = URLComponents(string: url) else {
      Logger.log.warn("Cannot parse URL using URLComponents")
      return
    }

    DispatchQueue.main.async { [self] in
      if parsed.scheme != "iina" {
        // try to open the URL directly
        let player = PlayerManager.shared.getActiveOrNewForMenuAction(inverseOpenInNewWindowPref: false)
        startupHandler.isAwaitingNewWindowsForOpenedFile = true
        if player.openURLString(url) == 0 {
          startupHandler.abortWaitForOpenFilePlayerStartup()
        } else {
          startupHandler.pwcsForOpenFiles = [player.pwc]
        }
        startupHandler.showWindowsIfReady()
        return
      }

      // handle url scheme
      guard let host = parsed.host else { return }

      if host == "open" || host == "weblink" {
        // open a file or link
        guard let queries = parsed.queryItems else { return }
        let queryDict = [String: String](uniqueKeysWithValues: queries.map { ($0.name, $0.value ?? "") })

        // url
        guard let urlValue = queryDict["url"], !urlValue.isEmpty else {
          Logger.log("Cannot find parameter \"url\", stopped")
          return
        }

        // new_window
        let player: PlayerCore
        if let newWindowValue = queryDict["new_window"], newWindowValue == "1" {
          player = PlayerManager.shared.getIdleOrCreateNew()
        } else {
          player = PlayerManager.shared.getActiveOrNewForMenuAction(inverseOpenInNewWindowPref: false)
        }

        // enqueue
        if let enqueueValue = queryDict["enqueue"], enqueueValue == "1",
           let lastActivePlayer = PlayerManager.shared.lastActivePlayer,
           !lastActivePlayer.info.playlist.isEmpty {
          lastActivePlayer.appendToPlaylist(urlValue)
        } else {
          startupHandler.isAwaitingNewWindowsForOpenedFile = true
          if player.openURLString(urlValue) == 0 {
            startupHandler.abortWaitForOpenFilePlayerStartup()
          } else {
            startupHandler.pwcsForOpenFiles = [player.pwc]
          }
        }

        // presentation options
        if let fsValue = queryDict["full_screen"], fsValue == "1" {
          // full_screen
          player.mpv.setFlag(MPVOption.Window.fullscreen, true)
        } else if let pipValue = queryDict["pip"], pipValue == "1" {
          // pip
          player.pwc.enterPIP()
        }

        // mpv options
        for query in queries {
          if query.name.hasPrefix("mpv_") {
            let mpvOptionName = String(query.name.dropFirst(4))
            guard let mpvOptionValue = query.value else { continue }
            Logger.log("Setting \(mpvOptionName) to \(mpvOptionValue)")
            player.mpv.setString(mpvOptionName, mpvOptionValue)
          }
        }

        Logger.log("Finished URL scheme handling")
        startupHandler.showWindowsIfReady()
      }
    }
  }

  // MARK: - App Reopen

  /// Called when user clicks the dock icon of the already-running application.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // Once termination starts subsystems such as mpv are being shut down. Accessing mpv
    // once it has been instructed to shutdown can trigger a crash. MUST NOT permit
    // reopening once termination has started.
    guard !isTerminating else { return false }
    guard startupHandler.state == .doneOpening else { return false }

    if terminateIfNotInteractiveLaunch() {
      return true
    }

    // OpenFile is an NSPanel, which AppKit considers not to be a window. Need to account for this ourselves.
    guard !hasVisibleWindows && !isShowingOpenFileWindow else {
      Logger.log.verbose("HandleReopen: has visible windows")
      return true
    }

    Logger.log.debug("HandleReopen: doing actionAfterLaunch")
    doLaunchOrReopenAction()
    return true
  }

  /// Returns `true` if app termination was initiated.
  @MainActor
  private func terminateIfNotInteractiveLaunch() -> Bool {
    if isInteractiveLaunch {
      return false
    }

    guard Preference.bool(for: .killNonInteractiveLaunchesAtReopen) else { return false }

    Logger.log.debug("HandleReopen: this is a non-interactive launch! Sending killRequest to all running instances")
    Preference.set(Preference.integer(for: .killRequest) + 1, for: .killRequest)

    // Start our own shutdown immediately
    appDidReceiveKillRequest()
    return true
  }

  @MainActor
  func doLaunchOrReopenAction() {
    guard startupHandler.isDoneLaunching else {
      Logger.log.verbose("Still starting up; skipping actionAfterLaunch")
      return
    }

    let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
    Logger.log.verbose("Doing actionAfterLaunch: \(action)")

    switch action {
    case .welcomeWindow:
      showWelcomeWindow()
    case .openPanel:
      showOpenFileWindow(isAlternativeAction: true)
    case .historyWindow:
      showHistoryWindow(self)
    case .none:
      break
    }
  }

  @MainActor
  private func appDidReceiveKillRequest() {
    guard Preference.bool(for: .killNonInteractiveLaunchesAtReopen) else {
      Logger.log.debug("Received killRequest but killNonInteractiveLaunchesAtReopen is disabled; ignoring")
      return
    }
    Logger.log.debug("Got killRequest! Terminating this instance.")

    Task { @MainActor in
      NSApp.terminate(nil)
    }
  }

  // MARK: - NSApplicationDelegate (other APIs)

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return dockMenu
  }

  func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
    // Do not re-map keyboard shortcuts based on keyboard position in different locales
    return false
  }

  /// Method to opt-in to secure restorable state.
  ///
  /// From the `Restorable State` section of the [AppKit Release Notes for macOS 14](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14#Restorable-State):
  ///
  /// Secure coding is automatically enabled for restorable state for applications linked on the macOS 14.0 SDK. Applications that
  /// target prior versions of macOS should implement `NSApplicationDelegate.applicationSupportsSecureRestorableState()`
  /// to return`true` so it’s enabled on all supported OS versions.
  ///
  /// This is about conformance to [NSSecureCoding](https://developer.apple.com/documentation/foundation/nssecurecoding)
  /// which protects against object substitution attacks. If an application does not implement this method then a warning will be emitted
  /// reporting secure coding is not enabled for restorable state.
  @available(macOS 12.0, *)
  @MainActor
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Called when this application becomes the frontmost app (as indicated by its name appearing as a menu next to the Apple menu).
  ///
  /// Cases include: at app launch; whenever Dock icon is clicked; when an app window is ordered to front.
  @MainActor
  func applicationDidBecomeActive(_ notfication: Notification) {
    // When using custom window style, sometimes AppKit will remove their entries from the Window menu (e.g. when hiding the app).
    // Make sure to add them again if they are missing:
    for player in PlayerManager.shared.playerCores {
      if player.pwc.loaded && !player.isShutDown {
        player.pwc.updateTitle()
      }
    }
  }

  // MARK: - Menu IBActions

  @MainActor
  @IBAction func openFile(_ sender: AnyObject) {
    Logger.log("Menu - Open File")
    showOpenFileWindow(isAlternativeAction: sender.tag == Constants.Menu.alternativeMenuItemTag)
  }

  @MainActor
  @IBAction func openURL(_ sender: AnyObject) {
    Logger.log("Menu - Open URL")
    showOpenURLWindow(isAlternativeAction: sender.tag == Constants.Menu.alternativeMenuItemTag)
  }

  /// Only used if `Preference.Key.enableCmdN` is set to `true`
  @MainActor
  @IBAction func menuNewWindow(_ sender: AnyObject?) {
    showWelcomeWindow()
  }

  @MainActor
  @IBAction func menuOpenScreenshotFolder(_ sender: NSMenuItem) {
    let screenshotPath = Preference.string(for: .screenshotFolder)!
    let absoluteScreenshotPath = NSString(string: screenshotPath).expandingTildeInPath
    let url = URL(fileURLWithPath: absoluteScreenshotPath, isDirectory: true)
    NSWorkspace.shared.open(url)
  }

  @MainActor
  @IBAction func menuSelectAudioDevice(_ sender: NSMenuItem) {
    if let name = sender.representedObject as? String {
      PlayerManager.shared.activePlayer?.setAudioDevice(name)
    }
  }

  @MainActor
  @IBAction func showPreferencesWindow(_ sender: AnyObject?) {
    Logger.log("Opening Preferences window", level: .verbose)
    preferenceWindowController.openWindow(nil)
  }

  @MainActor
  @objc func showPluginPreferences(_ sender: NSMenuItem?) {
    preferenceWindowController.openPreferenceView(withNibName: "PrefPluginViewController")
  }

  @MainActor
  @IBAction func showVideoFilterWindow(_ sender: AnyObject?) {
    Logger.log("Opening Video Filter window", level: .verbose)
    vfWindow.openWindow(nil)
  }

  @MainActor
  @IBAction func showAudioFilterWindow(_ sender: AnyObject?) {
    Logger.log("Opening Audio Filter window", level: .verbose)
    afWindow.openWindow(nil)
  }

  @MainActor
  @IBAction func showAboutWindow(_ sender: AnyObject?) {
    Logger.log("Opening About window", level: .verbose)
    aboutWindow.openWindow(nil)
  }

  @MainActor
  @IBAction func showHistoryWindow(_ sender: AnyObject?) {
    Logger.log.verbose("Opening History window")
    historyWindow.openWindow(nil)
  }

  @MainActor
  @objc func toggleInspectorWindow(_ sender: AnyObject?) {
    if inspector.window?.isOpen ?? false {
      inspector.close()
    } else {
      showInspectorWindow()
    }
  }

  @IBAction func showLogWindow(_ sender: AnyObject?) {
    Logger.log.verbose("Opening Log window")
    logWindow.openWindow(nil)
  }

  @IBAction func showHighlights(_ sender: AnyObject?) {
    guideWindow.show(pages: [.highlights])
  }

  @IBAction func helpAction(_ sender: AnyObject?) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink)!)
  }

  @IBAction func githubAction(_ sender: AnyObject?) {
    NSWorkspace.shared.open(URL(string: AppData.githubLink)!)
  }

  @IBAction func websiteAction(_ sender: AnyObject?) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }

  // MARK: - Other window open methods

  @MainActor
  func showWelcomeWindow() {
    Logger.log.verbose("Showing WelcomeWindow")
    initialWindow.openWindow(self)
  }

  @MainActor
  func showOpenFileWindow(isAlternativeAction: Bool) {
    Logger.log.verbose("Showing OpenFileWindow: isAltAction=\(isAlternativeAction.yesno)")
    guard !isShowingOpenFileWindow else {
      // Do not allow more than one open file window at a time
      Logger.log.debug("Ignoring request to show OpenFileWindow: already showing one")
      return
    }
    isShowingOpenFileWindow = true
    let panel = NSOpenPanel()
    panel.setFrameAutosaveName(WindowAutosaveName.openFile.string)
    panel.title = NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File")
    panel.canCreateDirectories = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true

    panel.begin(completionHandler: { [self] result in
      if result == .OK {  /// OK
        Logger.log.verbose("OpenFile: user chose \(panel.urls.count) files")
        if Preference.bool(for: .recordRecentFiles) && HistoryController.shared.historyEnabled {
          HistoryController.shared.start()  // ensure documents are restored first, so they will not be overwritten
          let urls = panel.urls  // must call this on the main thread
          HistoryController.shared.async {
            HistoryController.shared.noteNewRecentDocumentURLs(urls)
          }
        }
        let playerCore = PlayerManager.shared.getActiveOrNewForMenuAction(inverseOpenInNewWindowPref: isAlternativeAction)
        if playerCore.openURLs(panel.urls) == 0 {
          Logger.log("OpenFile: notifying user there is nothing to open", level: .verbose)
          Utility.showAlert("nothing_to_open")
        }
      } else {  /// Cancel
        Logger.log("OpenFile: user cancelled", level: .verbose)
      }
      // AppKit does not consider a panel to be a window, so it won't fire this. Must call ourselves:
      windowWillClose(panel)
      isShowingOpenFileWindow = false
    })
  }

  @MainActor
  func showOpenURLWindow(isAlternativeAction: Bool) {
    Logger.log.verbose("Showing OpenURLWindow: isAltAction=\(isAlternativeAction.yn)")
    openURLWindow.inverseOpenInNewWindowPref = isAlternativeAction
    openURLWindow.openWindow(self)
  }

  @MainActor
  func showInspectorWindow() {
    Logger.log("Showing Inspector window", level: .verbose)
    inspector.openWindow(self)
  }

  // MARK: - Recent Documents

  /// Empties the recent documents list for the application.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  /// - Parameter sender: The object that initiated the clearing of the recent documents.
  @IBAction
  func clearRecentDocuments(_ sender: Any?) {
    HistoryController.shared.clearRecentDocuments(sender)
  }
}

