//
//  AppDelegate.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import MediaPlayer
import Sparkle

let IINA_ENABLE_PLUGIN_SYSTEM = Preference.bool(for: .iinaEnablePluginSystem)

/** Tags for "Open File/URL" menu item when "Always open file in new windows" is off. Vice versa. */
fileprivate let NormalMenuItemTag = 0
/** Tags for "Open File/URL in New Window" when "Always open URL" when "Open file in new windows" is off. Vice versa. */
fileprivate let AlternativeMenuItemTag = 1

class Startup {

  enum OpenWindowsState: Int {
    case stillEnqueuing = 1
    case doneEnqueuing
    case doneOpening
  }

  var state: OpenWindowsState = .stillEnqueuing

  var restoreTimer: Timer? = nil
  var restoreTimeoutAlertPanel: NSAlert? = nil

  /**
   Becomes true once `application(_:openFile:)`, `handleURLEvent()` or `droppedText()` is called.
   Mainly used to distinguish normal launches from others triggered by drag-and-dropping files.
   */
  var openFileCalled = false
  var shouldIgnoreOpenFile = false

  /// Try to wait until all windows are ready so that we can show all of them at once.
  /// Make sure order of `wcsToRestore` is from back to front to restore the order properly
  var wcsToRestore: [NSWindowController] = []
  var wcForOpenFile: PlayerWindowController? = nil

  var wcsReady = Set<NSWindowController>()
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

  /// The `AppDelegate` singleton object.
  static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

  // MARK: Properties

  let observedPrefKeys: [Preference.Key] = [
    .logLevel,
    .enableLogging,
    .enableAdvancedSettings,
    .enableCmdN,
    .resumeLastPosition,
//    .hideWindowsWhenInactive, // TODO: #1, see below
  ]
  private var observers: [NSObjectProtocol] = []

  @IBOutlet var menuController: MenuController!

  @IBOutlet weak var dockMenu: NSMenu!

  // Need to store these somewhere which isn't only inside a struct.
  // Swift doesn't seem to count them as strong references
  private let bindingTableStateManger: BindingTableStateManager = BindingTableState.manager
  private let confTableStateManager: ConfTableStateManager = ConfTableState.manager

  // MARK: Window controllers

  lazy var initialWindow = InitialWindowController()
  lazy var openURLWindow = OpenURLWindowController()
  lazy var aboutWindow = AboutWindowController()
  lazy var fontPicker = FontPickerWindowController()
  lazy var inspector = InspectorWindowController()
  lazy var historyWindow = HistoryWindowController()
  lazy var guideWindow = GuideWindowController()
  lazy var logWindow = LogWindowController()

  lazy var vfWindow = FilterWindowController(filterType: MPVProperty.vf, .videoFilter)
  lazy var afWindow = FilterWindowController(filterType: MPVProperty.af, .audioFilter)

  lazy var preferenceWindowController = PreferenceWindowController()

  // MARK: State

  var startup = Startup()
  // TODO: roll this into Startup class
  private var commandLineStatus = CommandLineStatus()

  private var shutdownHandler = ShutdownHandler()

  private var lastClosedWindowName: String = ""
  var isShowingOpenFileWindow = false

  var isTerminating: Bool {
    return shutdownHandler.isTerminating
  }

  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }

    if keyPath == Preference.UIState.launchName {
      if let newLaunchLifecycleState = change[.newKey] as? Int {
        guard !isTerminating else { return }
        guard newLaunchLifecycleState != 0 else { return }
        Logger.log("Detected change to this instance's lifecycle state pref (\(keyPath.quoted)). Probably a newer instance of IINA has started and is attempting to restore")
        Logger.log("Changing our lifecycle state back to 'stillRunning' so the other launch will skip this instance.")
        UserDefaults.standard.setValue(Preference.UIState.LaunchLifecycleState.stillRunning.rawValue, forKey: keyPath)
        DispatchQueue.main.async { [self] in
          NotificationCenter.default.post(Notification(name: .savedWindowStateDidChange, object: self))
        }
      }
      return
    }

    switch keyPath {
    case PK.enableAdvancedSettings.rawValue, PK.enableLogging.rawValue, PK.logLevel.rawValue:
      Logger.updateEnablement()
      // depends on advanced being enabled:
      menuController.refreshCmdNStatus()
      menuController.refreshBuiltInMenuItemBindings()

    case PK.enableCmdN.rawValue:
      menuController.refreshCmdNStatus()
      menuController.refreshBuiltInMenuItemBindings()

    case PK.resumeLastPosition.rawValue:
      HistoryController.shared.async {
        HistoryController.shared.log.verbose("Reloading playback history in response to change for 'resumeLastPosition'.")
        HistoryController.shared.reloadAll()
      }

      // TODO: #1, see above
//    case PK.hideWindowsWhenInactive.rawValue:
//      if let newValue = change[.newKey] as? Bool {
//        for window in NSApp.windows {
//          guard window as? PlayerWindow == nil else { continue }
//          window.hidesOnDeactivate = newValue
//        }
//      }

    default:
      break
    }
  }

  // MARK: - FFmpeg version parsing

  /// Extracts the major version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MAJOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The major version number
  private static func avVersionMajor(_ version: UInt32) -> UInt32 {
    version >> 16
  }

  /// Extracts the minor version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MINOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The minor version number
  private static func avVersionMinor(_ version: UInt32) -> UInt32 {
    (version & 0x00FF00) >> 8
  }

  /// Extracts the micro version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MICRO`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The micro version number
  private static func avVersionMicro(_ version: UInt32) -> UInt32 {
    version & 0xFF
  }

  /// Forms a string representation from the given FFmpeg encoded version number.
  ///
  /// FFmpeg returns the version number of its libraries encoded into an unsigned integer. The FFmpeg source
  /// `libavutil/version.h` describes FFmpeg's versioning scheme and provides C macros for operating on encoded
  /// version numbers. Since the macros can't be used in Swift code we've had to code equivalent functions in Swift.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: A string containing the version number.
  private static func versionAsString(_ version: UInt32) -> String {
    let major = AppDelegate.avVersionMajor(version)
    let minor = AppDelegate.avVersionMinor(version)
    let micro = AppDelegate.avVersionMicro(version)
    return "\(major).\(minor).\(micro)"
  }

  // MARK: - Logs

  private func logAllAppDetails() {
    // Start the log file by logging the version of IINA producing the log file.
    Logger.log(InfoDictionary.shared.printableBuildInfo)

    // The copyright is used in the Finder "Get Info" window which is a narrow window so the
    // copyright consists of multiple lines.
    let copyright = InfoDictionary.shared.copyright
    copyright.enumerateLines { line, _ in
      Logger.log(line)
    }

    logDependencyDetails()
    logBuildDetails()
    logPlatformDetails()
  }

  /// Useful to know the versions of significant dependencies that are being used so log that
  /// information as well when it can be obtained.

  /// The version of mpv is not logged at this point because mpv does not provide a static
  /// method that returns the version. To obtain version related information you must
  /// construct a mpv object, which has side effects. So the mpv version is logged in
  /// applicationDidFinishLaunching to preserve the existing order of initialization.
  private func logDependencyDetails() {
    Logger.log("FFmpeg \(String(cString: av_version_info()))")
    // FFmpeg libraries and their versions in alphabetical order.
    let libraries: [(name: String, version: UInt32)] = [("libavcodec", avcodec_version()), ("libavformat", avformat_version()), ("libavutil", avutil_version()), ("libswscale", swscale_version())]
    for library in libraries {
      // The version of FFmpeg libraries is encoded into an unsigned integer in a proprietary
      // format which needs to be decoded into a string for display.
      Logger.log("  \(library.name) \(AppDelegate.versionAsString(library.version))")
    }
  }

  /// Log details about when and from what sources IINA was built.
  ///
  /// For developers that take a development build to other machines for testing it is useful to log information that can be used to
  /// distinguish between development builds.
  ///
  /// In support of this the build populated `Info.plist` with keys giving:
  /// - The build date
  /// - The git branch
  /// - The git commit
  private func logBuildDetails() {
    guard let date = InfoDictionary.shared.buildDate,
          let sdk = InfoDictionary.shared.buildSDK,
          let xcode = InfoDictionary.shared.buildXcode else { return }
    let toString = DateFormatter()
    toString.dateStyle = .medium
    toString.timeStyle = .medium
    // Always use the en_US locale for dates in the log file.
    toString.locale = Locale(identifier: "en_US")
    Logger.log("Built using Xcode \(xcode) and macOS SDK \(sdk) on \(toString.string(from: date))")
    guard let branch = InfoDictionary.shared.buildBranch,
          let commit = InfoDictionary.shared.buildCommit else { return }
    Logger.log("From branch \(branch), commit \(commit)")
  }

  /// Log details about the Mac IINA is running on.
  ///
  /// Certain IINA capabilities, such as hardware acceleration, are contingent upon aspects of the Mac IINA is running on. If available,
  /// this method will log:
  /// - macOS version
  /// - model identifier of the Mac
  /// - kind of processor
  private func logPlatformDetails() {
    Logger.log("Running under macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    guard let cpu = Sysctl.shared.machineCpuBrandString, let model = Sysctl.shared.hwModel else { return }
    Logger.log("On a \(model) with an \(cpu) processor")
  }

  // MARK: - Auto update

  @IBOutlet var updaterController: SPUStandardUpdaterController!

  func feedURLString(for updater: SPUUpdater) -> String? {
    return Preference.bool(for: .receiveBetaUpdate) ? AppData.appcastBetaLink : AppData.appcastLink
  }

  // MARK: - Startup

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Must setup preferences before logging so log level is set correctly.
    registerUserDefaultValues()

    Logger.initLogging()
    logAllAppDetails()

    Logger.log("App will launch. LaunchID: \(Preference.UIState.launchID)")

    // Start asynchronously gathering and caching information about the hardware decoding
    // capabilities of this Mac.
    HardwareDecodeCapabilities.shared.checkCapabilities()

    for key in self.observedPrefKeys {
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    /// Attach this in `applicationWillFinishLaunching`, because `application(openFiles:)` will be called after this but
    /// before `applicationDidFinishLaunching`.
    observers.append(NotificationCenter.default.addObserver(forName: .windowIsReadyToShow, object: nil, queue: .main,
                                                            using: self.windowIsReadyToShow))

    observers.append(NotificationCenter.default.addObserver(forName: .windowMustCancelShow, object: nil, queue: .main,
                                                            using: self.windowMustCancelShow))

    // Check for legacy pref entries and migrate them to their modern equivalents.
    // Must do this before setting defaults so that checking for existing entries doesn't result in false positives
    LegacyMigration.migrateLegacyPreferences()

    // Call this *before* registering for url events, to guarantee that menu is init'd
    confTableStateManager.startUp()

    HistoryController.shared.start()
    
    // register for url event
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(self.handleURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    // Hide Window > "Enter Full Screen" menu item, because this is already present in the Video menu
    UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")

    // handle command line arguments
    let arguments = ProcessInfo.processInfo.arguments.dropFirst()
    if !arguments.isEmpty {
      parseCommandLine(arguments)
    }
  }

  private func registerUserDefaultValues() {
    UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map { ($0.0.rawValue, $0.1) }))
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    Logger.log("App launched")

    menuController.bindMenuItems()
    // FIXME: this actually causes a window to open in the background. Should wait until intending to show it
    // show alpha in color panels
    NSColorPanel.shared.showsAlpha = true

    // see https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html#/c:objc(cs)SPUUpdater(im)clearFeedURLFromUserDefaults
    updaterController.updater.clearFeedURLFromUserDefaults()

    // other initializations at App level
    NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
    NSWindow.allowsAutomaticWindowTabbing = false

    JavascriptPlugin.loadGlobalInstances()

    if RemoteCommandController.useSystemMediaControl {
      Logger.log("Setting up MediaPlayer integration")
      RemoteCommandController.setup()
      NowPlayingInfoManager.updateInfo(state: .unknown)
    }

    menuController.updatePluginMenu()
    menuController.refreshBuiltInMenuItemBindings()

    // Register to restore for successive launches. Set status to currently running so that it isn't restored immediately by the next launch
    UserDefaults.standard.setValue(Preference.UIState.LaunchLifecycleState.stillRunning.rawValue, forKey: Preference.UIState.launchName)
    UserDefaults.standard.addObserver(self, forKeyPath: Preference.UIState.launchName, options: .new, context: nil)

    // Restore window state *before* hooking up the listener which saves state.
    restoreWindowsFromPreviousLaunch()

    if commandLineStatus.isCommandLine {
      startFromCommandLine()
    }

    startup.state = .doneEnqueuing
    // Callbacks may have already fired before getting here. Check again to make sure we don't "drop the ball":
    showWindowsIfReady()
  }

  private func showWindowsIfReady() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard startup.state == .doneEnqueuing else { return }
    guard startup.wcsReady.count == startup.wcsToRestore.count else {
      restartRestoreTimer()
      return
    }
    // TODO: change this for multi-window open
    guard !startup.openFileCalled || startup.wcForOpenFile != nil else { return }
    let log = Logger.Subsystem.restore

    log.verbose("All \(startup.wcsToRestore.count) restored \(startup.wcForOpenFile == nil ? "" : "& 1 new ")windows ready. Showing all")
    startup.restoreTimer?.invalidate()

    for wc in startup.wcsToRestore {
      if !(wc.window?.isMiniaturized ?? false) {
        wc.showWindow(self)  // orders the window to the front
      }
    }
    if let wcForOpenFile = startup.wcForOpenFile, !(wcForOpenFile.window?.isMiniaturized ?? false) {
      wcForOpenFile.showWindow(self)  // open last, thus making frontmost
    }

    let didRestoreSomething = !startup.wcsToRestore.isEmpty

    if Preference.bool(for: .isRestoreInProgress) {
      log.verbose("Done restoring windows")
      Preference.set(false, for: .isRestoreInProgress)
    }

    startup.state = .doneOpening

    let didOpenSomething = didRestoreSomething || startup.wcForOpenFile != nil
    if !commandLineStatus.isCommandLine && !didOpenSomething {
      // Fall back to default action:
      doLaunchOrReopenAction()
    }

    /// Make sure to do this *after* `startup.state = .doneOpening`:
    dismissTimeoutAlertPanel()

    Logger.log("Adding window observers")

    // The "action on last window closed" action will vary slightly depending on which type of window was closed.
    // Here we add a listener which fires when *any* window is closed, in order to handle that logic all in one place.
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                            queue: .main, using: self.windowWillClose))

    if Preference.UIState.isSaveEnabled {
      // Save ordered list of open windows each time the order of windows changed.
      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil,
                                                              queue: .main, using: self.windowDidBecomeMain))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil,
                                                              queue: .main, using: self.windowWillBeginSheet))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil,
                                                              queue: .main, using: self.windowDidEndSheet))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil,
                                                              queue: .main, using: self.windowDidMiniaturize))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil,
                                                              queue: .main, using: self.windowDidDeminiaturize))

    } else {
      // TODO: remove existing state...somewhere
      Logger.log("Note: UI state saving is disabled")
    }

    if RemoteCommandController.useSystemMediaControl {
      Logger.log("Setting up MediaPlayer integration")
      RemoteCommandController.setup()
      NowPlayingInfoManager.updateInfo(state: .unknown)
    }

    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    NSApplication.shared.servicesProvider = self
  }

  /// Returns `true` if any windows were restored; `false` otherwise.
  @discardableResult
  private func restoreWindowsFromPreviousLaunch() -> Bool {
    assert(DispatchQueue.isExecutingIn(.main))
    let log = Logger.Subsystem.restore

    guard Preference.UIState.isRestoreEnabled else {
      log.debug("Restore is disabled. Wll not restore windows")
      return false
    }

    if commandLineStatus.isCommandLine && !(Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .enableRestoreUIStateForCmdLineLaunches)) {
      log.debug("Restore is disabled for command-line launches. Wll not restore windows or save state for this launch")
      Preference.UIState.disableSaveAndRestoreUntilNextLaunch()
      return false
    }

    let pastLaunches: [Preference.UIState.LaunchState] = Preference.UIState.collectLaunchStateForRestore()
    log.verbose("Found \(pastLaunches.count) past launches to restore")
    if pastLaunches.isEmpty {
      return false
    }

    let stopwatch = Utility.Stopwatch()

    let isRestoreApproved: Bool // false means delete restored state
    if Preference.bool(for: .isRestoreInProgress) {
      // If this flag is still set, the last restore probably failed. If it keeps failing, launch will be impossible.
      // Let user decide whether to try again or delete saved state.
      log.debug("Looks like there was a previous restore which didn't complete (pref \(Preference.Key.isRestoreInProgress.rawValue)=Y). Asking user whether to retry or skip")
      isRestoreApproved = Utility.quickAskPanel("restore_prev_error", useCustomButtons: true)
    } else if Preference.bool(for: .alwaysAskBeforeRestoreAtLaunch) {
      log.verbose("Prompting user whether to restore app state, per pref")
      isRestoreApproved = Utility.quickAskPanel("restore_confirm", useCustomButtons: true)
    } else {
      isRestoreApproved = true
    }

    if !isRestoreApproved {
      // Clear out old state. It may have been causing errors, or user wants to start new
      log.debug("User denied restore. Clearing all saved launch state.")
      Preference.UIState.clearAllSavedLaunches()
      Preference.set(false, for: .isRestoreInProgress)
      return false
    }

    // If too much time has passed (in particular if user took a long time to respond to confirmation dialog), consider the data stale.
    // Due to 1s delay in chosen strategy for verifying whether other instances are running, try not to repeat it twice.
    // Users who are quick with their user interface device probably know what they are doing and will be impatient.
    let pastLaunchesCache = stopwatch.secElapsed > Constants.TimeInterval.pastLaunchResponseTimeout ? nil : pastLaunches
    let savedWindowsBackToFront = Preference.UIState.consolidateSavedWindowsFromPastLaunches(pastLaunches: pastLaunchesCache)

    guard !savedWindowsBackToFront.isEmpty else {
      log.debug("Will not restore windows: stored window list empty")
      return false
    }

    if savedWindowsBackToFront.count == 1 {
      let onlyWindow = savedWindowsBackToFront[0].saveName

      if onlyWindow == WindowAutosaveName.inspector {
        // Do not restore this on its own
        log.verbose("Will not restore windows: only open window was Inspector")
        return false
      }

      let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
      if (onlyWindow == WindowAutosaveName.welcome && action == .welcomeWindow)
          || (onlyWindow == WindowAutosaveName.openURL && action == .openPanel)
          || (onlyWindow == WindowAutosaveName.playbackHistory && action == .historyWindow) {
        log.verbose("Will not restore windows: the only open window was identical to launch action (\(action))")
        // Skip the prompts below because they are just unnecessary nagging
        return false
      }
    }

    log.verbose("Starting restore of \(savedWindowsBackToFront.count) windows")
    Preference.set(true, for: .isRestoreInProgress)

    // Show windows one by one, starting at back and iterating to front:
    for savedWindow in savedWindowsBackToFront {
      log.verbose("Starting restore of window: \(savedWindow.saveName)\(savedWindow.isMinimized ? " (minimized)" : "")")

      let wc: NSWindowController
      switch savedWindow.saveName {
      case .playbackHistory:
        showHistoryWindow(self)
        wc = historyWindow
      case .welcome:
        showWelcomeWindow()
        wc = initialWindow
      case .preferences:
        showPreferencesWindow(self)
        wc = preferenceWindowController
      case .about:
        showAboutWindow(self)
        wc = aboutWindow
      case .openFile:
        // TODO: persist isAlternativeAction too
        showOpenFileWindow(isAlternativeAction: true)
        // No windowController for Open File window; will have to show it immediately
        // TODO: show with others
        continue
      case .openURL:
        // TODO: persist isAlternativeAction too
        showOpenURLWindow(isAlternativeAction: true)
        wc = openURLWindow
      case .inspector:
        // Do not show Inspector window. It doesn't support being drawn in the background, but it loads very quickly.
        // So just mark it as 'ready' and show with the rest when they are ready.
        wc = inspector
        startup.wcsReady.insert(wc)
      case .videoFilter:
        showVideoFilterWindow(self)
        wc = vfWindow
      case .audioFilter:
        showAudioFilterWindow(self)
        wc = afWindow
      case .logViewer:
        showLogWindow(self)
        wc = logWindow
      case .playerWindow(let id):
        guard let player = PlayerCoreManager.shared.restoreFromPriorLaunch(playerID: id) else { continue }
        wc = player.windowController
      case .newFilter, .editFilter, .saveFilter:
        log.debug("Restoring sheet window \(savedWindow.saveString) is not yet implemented; skipping")
        continue
      default:
        log.error("Cannot restore unrecognized autosave enum: \(savedWindow.saveName)")
        continue
      }

      // Rebuild window maps as we go:
      if savedWindow.isMinimized {
        Preference.UIState.windowsMinimized.insert(savedWindow.saveName.string)
      } else {
        Preference.UIState.windowsOpen.insert(savedWindow.saveName.string)
      }

      if savedWindow.isMinimized {
        // Don't need to wait for wc
        wc.window?.miniaturize(self)
      } else {
        // Add to list of windows to wait for
        startup.wcsToRestore.append(wc)
      }
    }

    return !startup.wcsToRestore.isEmpty
  }

  @objc
  func restoreTimedOut() {
    assert(DispatchQueue.isExecutingIn(.main))
    let log = Logger.Subsystem.restore
    guard startup.state == .doneEnqueuing else {
      log.error("Restore timed out but state is \(startup.state)")
      return
    }

    let namesReady = startup.wcsReady.compactMap{$0.window?.savedStateName}
    let wcsStalled: [NSWindowController] = startup.wcsToRestore.filter{ !namesReady.contains($0.window!.savedStateName) }
    var namesStalled: [String] = []
    for (index, wc) in wcsStalled.enumerated() {
      let winID = wc.window!.savedStateName
      let str: String
      if index > Constants.SizeLimit.maxWindowNamesInRestoreTimeoutAlert {
        break
      } else if index == Constants.SizeLimit.maxWindowNamesInRestoreTimeoutAlert {
        str = "…"
      } else if let path = (wc as? PlayerWindowController)?.player.info.currentPlayback?.path {
        str = "\(index+1). \(path.quoted)  [\(winID)]"
      } else {
        str = "\(index+1). \(winID)"
      }
      namesStalled.append(str)
    }

    log.debug("Restore timed out. Progress: \(namesReady.count)/\(startup.wcsToRestore.count). Stalled: \(namesStalled)")
    log.debug("Prompting user whether to discard them & continue, or quit")

    let countFailed = "\(wcsStalled.count)"
    let countTotal = "\(startup.wcsToRestore.count)"
    let namesStalledString = namesStalled.joined(separator: "\n")
    let msgArgs = [countFailed, countTotal, namesStalledString]
    let askPanel = Utility.buildThreeButtonAskPanel("restore_timeout", msgArgs: msgArgs, alertStyle: .critical)
    startup.restoreTimeoutAlertPanel = askPanel
    let userResponse = askPanel.runModal()  // this will block for an indeterminate time

    switch userResponse {
    case .alertFirstButtonReturn:
      log.debug("User chose button 1: keep waiting")
      guard startup.state != .doneOpening else {
        log.debug("Looks like windows finished opening - no need to restart restore timer")
        return
      }
      restartRestoreTimer()

    case .alertSecondButtonReturn:
      log.debug("User chose button 2: discard stalled windows & continue with partial restore")
      startup.restoreTimeoutAlertPanel = nil  // Clear this (no longer needed)
      guard startup.state != .doneOpening else {
        log.debug("Looks like windows finished opening - no need to close anything")
        return
      }
      for wcStalled in wcsStalled {
        guard !startup.wcsReady.contains(wcStalled) else {
          log.verbose("Window has become ready; skipping close: \(wcStalled.window!.savedStateName)")
          continue
        }
        log.verbose("Telling stalled window to close: \(wcStalled.window!.savedStateName)")
        if let pWin = wcStalled as? PlayerWindowController {
          /// This will guarantee `windowMustCancelShow` notification is sent
          pWin.player.closeWindow()
        } else {
          wcStalled.close()
          // explicitly call this, as the line above may fail
          wcStalled.window?.postWindowMustCancelShow()
        }
      }

    case .alertThirdButtonReturn:
      log.debug("User chose button 3: quit")
      NSApp.terminate(nil)

    default:
      log.fatalError("User responded to Restore Timeout alert with unrecognized choice!")
    }
  }

  private func dismissTimeoutAlertPanel() {
    guard let restoreTimeoutAlertPanel = startup.restoreTimeoutAlertPanel else { return }

    /// Dismiss the prompt (if any). It seems we can't just call `close` on its `window` object, because the
    /// responder chain is left unusable. Instead, click its default button after setting `startup.state`.
    let keepWaitingBtn = restoreTimeoutAlertPanel.buttons[0]
    keepWaitingBtn.performClick(self)
    startup.restoreTimeoutAlertPanel = nil

    /// This may restart the timer if not in the correct state, so account for that.
  }

  private func restartRestoreTimer() {
    startup.restoreTimer?.invalidate()

    dismissTimeoutAlertPanel()

    startup.restoreTimer = Timer.scheduledTimer(timeInterval: TimeInterval(Constants.TimeInterval.restoreWindowsTimeout),
                                                target: self, selector: #selector(self.restoreTimedOut), userInfo: nil, repeats: false)
  }

  private func abortWaitForOpenFilePlayerStartup() {
    Logger.log.verbose("Aborting wait for Open File player startup")
    startup.openFileCalled = false
    startup.wcForOpenFile = nil
    showWindowsIfReady()
  }

  // MARK: - Window notifications

  /// Window is done loading and is ready to show.
  private func windowIsReadyToShow(_ notification: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    let log = Logger.Subsystem.restore

    guard let window = notification.object as? NSWindow else { return }
    guard let wc = window.windowController else {
      log.error("Restored window is ready, but no windowController for window: \(window.savedStateName.quoted)!")
      return
    }

    if Preference.bool(for: .isRestoreInProgress) {
      startup.wcsReady.insert(wc)

      log.verbose("Restored window is ready: \(window.savedStateName.quoted). Progress: \(startup.wcsReady.count)/\(startup.state == .doneEnqueuing ? "\(startup.wcsToRestore.count)" : "?")")

      // Show all windows if ready
      showWindowsIfReady()
    } else if !window.isMiniaturized {
      log.verbose("OpenWindow: showing window \(window.savedStateName.quoted)")
      wc.showWindow(window)
    }
  }

  /// Window failed to load. Stop waiting for it
  private func windowMustCancelShow(_ notification: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard let window = notification.object as? NSWindow else { return }
    let log = Logger.Subsystem.restore

    guard Preference.bool(for: .isRestoreInProgress) else { return }
    log.verbose("Restored window cancelled: \(window.savedStateName.quoted). Progress: \(startup.wcsReady.count)/\(startup.state == .doneEnqueuing ? "\(startup.wcsToRestore.count)" : "?")")

    // No longer waiting for this window
    startup.wcsToRestore.removeAll(where: { wc in
      wc.window!.savedStateName == window.savedStateName
    })

    showWindowsIfReady()
  }

  /// Sheet window is opening. Track it like a regular window.
  ///
  /// The notification provides no way to actually know which sheet is being added.
  /// So prior to opening the sheet, the caller must manually add it using `Preference.UIState.addOpenSheet`.
  private func windowWillBeginSheet(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let activeWindowName = window.savedStateName
    guard !activeWindowName.isEmpty else { return }

    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      guard let sheetNames = Preference.UIState.openSheetsDict[activeWindowName] else { return }

      for sheetName in sheetNames {
        Logger.log("Sheet opened: \(sheetName.quoted)", level: .verbose)
        Preference.UIState.windowsOpen.insert(sheetName)
      }
      Preference.UIState.saveCurrentOpenWindowList()
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
      guard let sheetNames = Preference.UIState.openSheetsDict[activeWindowName] else { return }
      Preference.UIState.removeOpenSheets(fromWindow: activeWindowName)

      for sheetName in sheetNames {
        Logger.log("Sheet closed: \(sheetName.quoted)", level: .verbose)
        Preference.UIState.windowsOpen.remove(sheetName)
      }

      Preference.UIState.saveCurrentOpenWindowList()
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
      if Preference.UIState.windowsMinimized.remove(activeWindowName) != nil {
        Logger.log("Minimized window become main; adding to open windows list: \(activeWindowName.quoted)", level: .verbose)
        Preference.UIState.windowsOpen.insert(activeWindowName)
      } else {
        // Do not process. Another listener will handle it
        Logger.log("Window became main: \(activeWindowName.quoted)", level: .verbose)
        return
      }

      Preference.UIState.saveCurrentOpenWindowList()
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
      Logger.log("Window did minimize; adding to minimized windows list: \(savedStateName.quoted)", level: .verbose)
      Preference.UIState.windowsOpen.remove(savedStateName)
      Preference.UIState.windowsMinimized.insert(savedStateName)
      Preference.UIState.saveCurrentOpenWindowList()
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
      Logger.log("App window did deminiaturize; removing from minimized windows list: \(savedStateName.quoted)", level: .verbose)
      Preference.UIState.windowsOpen.insert(savedStateName)
      Preference.UIState.windowsMinimized.remove(savedStateName)
      Preference.UIState.saveCurrentOpenWindowList()
    }
  }

  // MARK: - Window Close

  private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    windowWillClose(window)
  }

  /// This method can be called multiple times safely because it always runs on the main thread and does not
  /// continue unless the window is found to be in an existing list
  func windowWillClose(_ window: NSWindow) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !isTerminating else { return }

    let windowName = window.savedStateName
    guard !windowName.isEmpty else { return }

    let wasOpen = Preference.UIState.windowsOpen.remove(windowName) != nil
    let wasMinimized = Preference.UIState.windowsMinimized.remove(windowName) != nil

    guard wasOpen || wasMinimized else {
      Logger.log("Window already closed, ignoring: \(windowName.quoted)", level: .verbose)
      return
    }

    Logger.log("Window will close: \(windowName)", level: .verbose)
    lastClosedWindowName = windowName

    /// Query for the list of open windows and save it (excluding the window which is about to close).
    /// Most cases are covered by saving when `windowDidBecomeMain` is called, but this covers the case where
    /// the user closes a window which is not in the foreground.
    Preference.UIState.saveCurrentOpenWindowList(excludingWindowName: window.savedStateName)

    if let player = (window.windowController as? PlayerWindowController)?.player {
      player.windowController.windowWillClose()
      // Player window was closed; need to remove some additional state
      player.clearSavedState()
    }

    if window.isOnlyOpenWindow {
      doActionWhenLastWindowWillClose()
    }
  }

  /// Question mark
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !isTerminating else { return false }
    guard startup.state == .doneOpening else { return false }

    /// Certain events (like when PIP is enabled) can result in this being called when it shouldn't.
    /// Another case is when the welcome window is closed prior to a new player window opening.
    /// For these reasons we must keep a list of windows which meet our definition of "open", which
    /// may not match Apple's definition which is more closely tied to `window.isVisible`.
    guard Preference.UIState.windowsOpen.isEmpty else {
      Logger.log("App will not terminate: \(Preference.UIState.windowsOpen.count) windows are still in open list: \(Preference.UIState.windowsOpen)", level: .verbose)
      return false
    }

    if let activePlayer = PlayerCoreManager.shared.activePlayer, activePlayer.windowController.isWindowHidden {
      return false
    }

    if Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow) == .quit {
      Preference.UIState.clearSavedLaunchForThisLaunch()
      Logger.log("Last window was closed. App will quit due to configured pref", level: .verbose)
      return true
    }

    Logger.log("Last window was closed. Will do configured action", level: .verbose)
    doActionWhenLastWindowWillClose()
    return false
  }

  private func doActionWhenLastWindowWillClose() {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !isTerminating else { return }
    guard let noOpenWindowAction = Preference.ActionWhenNoOpenWindow(key: .actionWhenNoOpenWindow) else { return }
    Logger.log("ActionWhenNoOpenWindow: \(noOpenWindowAction). LastClosedWindowName: \(lastClosedWindowName.quoted)", level: .verbose)
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
          guard !Preference.UIState.windowsOpen.isEmpty else {
            return
          }
          quitForAction = .welcomeWindow
        default:
          quitForAction = nil
        }
      }

      if launchAction == quitForAction {
        Logger.log("Last window closed was the configured ActionWhenNoOpenWindow. Will quit instead of re-opening it.")
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
      Logger.log("Clearing all state for this launch because all windows have closed!")
      Preference.UIState.clearSavedLaunchForThisLaunch()
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

    ObjcUtils.silenced { [self] in
      observers.forEach {
        NotificationCenter.default.removeObserver($0)
      }

      // Remove observers for IINA preferences.
      for key in observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  // MARK: - Open file(s)

  func application(_ sender: NSApplication, openFiles filePaths: [String]) {
    Logger.log("application(openFiles:) called with: \(filePaths.map{$0.pii})")
    // if launched from command line, should ignore openFile during launch
    if startup.state.rawValue < Startup.OpenWindowsState.doneOpening.rawValue, startup.shouldIgnoreOpenFile {
      startup.shouldIgnoreOpenFile = false
      return
    }
    let urls = filePaths.map { URL(fileURLWithPath: $0) }
    
    // if installing a plugin package
    if let pluginPackageURL = urls.first(where: { $0.pathExtension == "iinaplgz" }) {
      Logger.log("Opening plugin URL: \(pluginPackageURL.absoluteString.pii.quoted)")
      showPreferencesWindow(self)
      preferenceWindowController.performAction(.installPlugin(url: pluginPackageURL))
      return
    }

    startup.openFileCalled = true

    DispatchQueue.main.async { [self] in
      Logger.log.debug("Opening URLs (count: \(urls.count))")
      // open pending files
      let player = PlayerCoreManager.shared.getActiveOrCreateNew()
      startup.wcForOpenFile = player.windowController
      if player.openURLs(urls) == 0 {
        abortWaitForOpenFilePlayerStartup()

        Logger.log("Notifying user nothing was opened", level: .verbose)
        Utility.showAlert("nothing_to_open")
      }
    }
  }

  // MARK: - Accept dropped string and URL on Dock icon

  @objc
  func droppedText(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
    Logger.log("Text dropped on app's Dock icon", level: .verbose)
    guard let url = pboard.string(forType: .string) else { return }

    guard let player = PlayerCore.active else { return }
    startup.openFileCalled = true
    startup.wcForOpenFile = player.windowController
    if player.openURLString(url) == 0 {
      abortWaitForOpenFilePlayerStartup()
    }
  }

  // MARK: - URL Scheme

  @objc func handleURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    Logger.log("Handling URL event: \(url)")
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
      Logger.log("Cannot parse URL using URLComponents", level: .warning)
      return
    }
    
    if parsed.scheme != "iina" {
      // try to open the URL directly
      let player = PlayerCoreManager.shared.getActiveOrNewForMenuAction(isAlternative: false)
      startup.openFileCalled = true
      startup.wcForOpenFile = player.windowController
      if player.openURLString(url) == 0 {
        abortWaitForOpenFilePlayerStartup()
      }
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
        player = PlayerCoreManager.shared.getIdleOrCreateNew()
      } else {
        player = PlayerCoreManager.shared.getActiveOrNewForMenuAction(isAlternative: false)
      }

      startup.openFileCalled = true
      startup.wcForOpenFile = player.windowController

      // enqueue
      if let enqueueValue = queryDict["enqueue"], enqueueValue == "1",
         let lastActivePlayer = PlayerCoreManager.shared.lastActivePlayer,
         !lastActivePlayer.info.playlist.isEmpty {
        lastActivePlayer.addToPlaylist(urlValue)
        lastActivePlayer.sendOSD(.addToPlaylist(1))
      } else {
        if player.openURLString(urlValue) == 0 {
          abortWaitForOpenFilePlayerStartup()
        }
      }

      // presentation options
      if let fsValue = queryDict["full_screen"], fsValue == "1" {
        // full_screen
        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
      } else if let pipValue = queryDict["pip"], pipValue == "1" {
        // pip
        player.windowController.enterPIP()
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
    }
  }

  // MARK: - App Reopen

  /// Called when user clicks the dock icon of the already-running application.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // Once termination starts subsystems such as mpv are being shutdown. Accessing mpv
    // once it has been instructed to shutdown can trigger a crash. MUST NOT permit
    // reopening once termination has started.
    guard !isTerminating else { return false }
    guard startup.state == .doneOpening else { return false }
    // OpenFile is an NSPanel, which AppKit considers not to be a window. Need to account for this ourselves.
    guard !hasVisibleWindows && !isShowingOpenFileWindow else { return true }

    Logger.log("Handle reopen")
    doLaunchOrReopenAction()
    return true
  }

  private func doLaunchOrReopenAction() {
    guard startup.state == .doneOpening else {
      Logger.log.verbose("Still starting up; skipping actionAfterLaunch")
      return
    }

    let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
    Logger.log("Doing actionAfterLaunch: \(action)", level: .verbose)

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
  @MainActor func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func applicationDidBecomeActive(_ notfication: Notification) {
    // When using custom window style, sometimes AppKit will remove their entries from the Window menu (e.g. when hiding the app).
    // Make sure to add them again if they are missing:
    for player in PlayerCoreManager.shared.playerCores {
      if player.windowController.loaded && !player.isShutDown {
        player.windowController.updateTitle()
      }
    }
  }

  func applicationWillResignActive(_ notfication: Notification) {
  }

  // MARK: - Menu IBActions

  @IBAction func openFile(_ sender: AnyObject) {
    Logger.log("Menu - Open File")
    showOpenFileWindow(isAlternativeAction: sender.tag == AlternativeMenuItemTag)
  }

  @IBAction func openURL(_ sender: AnyObject) {
    Logger.log("Menu - Open URL")
    showOpenURLWindow(isAlternativeAction: sender.tag == AlternativeMenuItemTag)
  }

  /// Only used if `Preference.Key.enableCmdN` is set to `true`
  @IBAction func menuNewWindow(_ sender: Any) {
    showWelcomeWindow()
  }

  @IBAction func menuOpenScreenshotFolder(_ sender: NSMenuItem) {
    let screenshotPath = Preference.string(for: .screenshotFolder)!
    let absoluteScreenshotPath = NSString(string: screenshotPath).expandingTildeInPath
    let url = URL(fileURLWithPath: absoluteScreenshotPath, isDirectory: true)
      NSWorkspace.shared.open(url)
  }

  @IBAction func menuSelectAudioDevice(_ sender: NSMenuItem) {
    if let name = sender.representedObject as? String {
      PlayerCore.active?.setAudioDevice(name)
    }
  }

  @IBAction func showPreferencesWindow(_ sender: AnyObject) {
    Logger.log("Opening Preferences window", level: .verbose)
    preferenceWindowController.openWindow(self)
  }

  @IBAction func showVideoFilterWindow(_ sender: AnyObject) {
    Logger.log("Opening Video Filter window", level: .verbose)
    vfWindow.openWindow(self)
  }

  @IBAction func showAudioFilterWindow(_ sender: AnyObject) {
    Logger.log("Opening Audio Filter window", level: .verbose)
    afWindow.openWindow(self)
  }

  @IBAction func showAboutWindow(_ sender: AnyObject) {
    Logger.log("Opening About window", level: .verbose)
    aboutWindow.openWindow(self)
  }

  @IBAction func showHistoryWindow(_ sender: AnyObject) {
    Logger.log("Opening History window", level: .verbose)
    historyWindow.openWindow(self)
  }

  @IBAction func showLogWindow(_ sender: AnyObject) {
    Logger.log("Opening Log window", level: .verbose)
    logWindow.openWindow(self)
  }

  @IBAction func showHighlights(_ sender: AnyObject) {
    guideWindow.show(pages: [.highlights])
  }

  @IBAction func helpAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink)!)
  }

  @IBAction func githubAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.githubLink)!)
  }

  @IBAction func websiteAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }

  // MARK: - Other window open methods

  func showWelcomeWindow() {
    Logger.log("Showing WelcomeWindow", level: .verbose)
    initialWindow.openWindow(self)
  }

  func showOpenFileWindow(isAlternativeAction: Bool) {
    Logger.log.verbose("Showing OpenFileWindow (isAlternativeAction: \(isAlternativeAction))")
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
        Logger.log("OpenFile: user chose \(panel.urls.count) files", level: .verbose)
        if Preference.bool(for: .recordRecentFiles) {
          let urls = panel.urls  // must call this on the main thread
          HistoryController.shared.async {
            HistoryController.shared.noteNewRecentDocumentURLs(urls)
          }
        }
        let playerCore = PlayerCoreManager.shared.getActiveOrNewForMenuAction(isAlternative: isAlternativeAction)
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

  func showOpenURLWindow(isAlternativeAction: Bool) {
    Logger.log("Showing OpenURLWindow, isAltAction=\(isAlternativeAction.yn)", level: .verbose)
    openURLWindow.isAlternativeAction = isAlternativeAction
    openURLWindow.openWindow(self)
  }

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

  // MARK: - Command Line
  // TODO: refactor to put this all in CommandLineStatus class
  private func parseCommandLine(_ args: ArraySlice<String>) {
    var iinaArgs: [String] = []
    var iinaArgFilenames: [String] = []
    var dropNextArg = false

    Logger.log("Command-line arguments \("\(args)".pii)")
    for arg in args {
      if dropNextArg {
        dropNextArg = false
        continue
      }
      if arg.first == "-" {
        let indexAfterDash = arg.index(after: arg.startIndex)
        if indexAfterDash == arg.endIndex {
          // single '-'
          commandLineStatus.isStdin = true
        } else if arg[indexAfterDash] == "-" {
          // args starting with --
          iinaArgs.append(arg)
        } else {
          // args starting with -
          dropNextArg = true
        }
      } else {
        // assume args starting with nothing is a filename
        iinaArgFilenames.append(arg)
      }
    }

    commandLineStatus.parseArguments(iinaArgs)
    Logger.log("Filenames from args: \(iinaArgFilenames)")
    Logger.log("Derived mpv properties from args: \(commandLineStatus.mpvArguments)")

    print(InfoDictionary.shared.printableBuildInfo)

    guard !iinaArgFilenames.isEmpty || commandLineStatus.isStdin else {
      print("This binary is not intended for being used as a command line tool. Please use the bundled iina-cli.")
      print("Please ignore this message if you are running in a debug environment.")
      return
    }

    startup.shouldIgnoreOpenFile = true
    commandLineStatus.isCommandLine = true
    commandLineStatus.filenames = iinaArgFilenames
  }

  private func startFromCommandLine() {
    var lastPlayerCore: PlayerCore? = nil
    let getNewPlayerCore = { [self] () -> PlayerCore in
      let pc = PlayerCoreManager.shared.getIdleOrCreateNew()
      commandLineStatus.applyMPVArguments(to: pc)
      lastPlayerCore = pc
      return pc
    }
    if commandLineStatus.isStdin {
      getNewPlayerCore().openURLString("-")
    } else {
      let validFileURLs: [URL] = commandLineStatus.filenames.compactMap { filename in
        if Regex.url.matches(filename) {
          return URL(string: filename.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? filename)
        } else {
          return FileManager.default.fileExists(atPath: filename) ? URL(fileURLWithPath: filename) : nil
        }
      }
      guard !validFileURLs.isEmpty else {
        Logger.log("No valid file URLs provided via command line! Nothing to do", level: .error)
        return
      }

      if commandLineStatus.openSeparateWindows {
        validFileURLs.forEach { url in
          getNewPlayerCore().openURL(url)
        }
      } else {
        getNewPlayerCore().openURLs(validFileURLs)
      }
    }

    if let pc = lastPlayerCore {
      if commandLineStatus.enterMusicMode {
        Logger.log("Entering music mode as specified via command line", level: .verbose)
        if commandLineStatus.enterPIP {
          // PiP is not supported in music mode. Combining these options is not permitted and is
          // rejected by iina-cli. The IINA executable must have been invoked directly with
          // arguments.
          Logger.log("Cannot specify both --music-mode and --pip", level: .error)
          // Command line usage error.
          exit(EX_USAGE)
        }
        pc.enterMusicMode()
      } else if commandLineStatus.enterPIP {
        Logger.log("Entering PIP as specified via command line", level: .verbose)
        pc.windowController.enterPIP()
      }
    }
  }
}


struct CommandLineStatus {
  var isCommandLine = false
  var isStdin = false
  var openSeparateWindows = false
  var enterMusicMode = false
  var enterPIP = false
  var mpvArguments: [(String, String)] = []
  var iinaArguments: [(String, String)] = []
  var filenames: [String] = []

  mutating func parseArguments(_ args: [String]) {
    mpvArguments.removeAll()
    iinaArguments.removeAll()
    for arg in args {
      let splitted = arg.dropFirst(2).split(separator: "=", maxSplits: 1)
      let name = String(splitted[0])
      if (name.hasPrefix("mpv-")) {
        // mpv args
        let strippedName = String(name.dropFirst(4))
        if strippedName == "-" {
          isStdin = true
        } else {
          let argPair: (String, String)
          if splitted.count <= 1 {
            argPair = (strippedName, "yes")
          } else {
            argPair = (strippedName, String(splitted[1]))
          }
          mpvArguments.append(argPair)
        }
      } else {
        // other args
        if splitted.count <= 1 {
          iinaArguments.append((name, "yes"))
        } else {
          iinaArguments.append((name, String(splitted[1])))
        }
        if name == "stdin" {
          isStdin = true
        }
        if name == "separate-windows" {
          openSeparateWindows = true
        }
        if name == "music-mode" {
          enterMusicMode = true
        }
        if name == "pip" {
          enterPIP = true
        }
      }
    }
  }

  func applyMPVArguments(to playerCore: PlayerCore) {
    Logger.log("Setting mpv properties from arguments: \(mpvArguments)")
    for argPair in mpvArguments {
      if argPair.0 == "shuffle" && argPair.1 == "yes" {
        // Special handling for this one
        Logger.log("Found \"shuffle\" request in command-line args. Adding mpv hook to shuffle playlist")
        playerCore.addShufflePlaylistHook()
        continue
      }
      playerCore.mpv.setString(argPair.0, argPair.1)
    }
  }
}

class RemoteCommandController {
  static let remoteCommand = MPRemoteCommandCenter.shared()

  static var useSystemMediaControl: Bool = Preference.bool(for: .useMediaKeys)

  static func setup() {
    remoteCommand.playCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.resume()
      return .success
    }
    remoteCommand.pauseCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.pause()
      return .success
    }
    remoteCommand.togglePlayPauseCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.togglePause()
      return .success
    }
    remoteCommand.stopCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.stop()
      return .success
    }
    remoteCommand.nextTrackCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.navigateInPlaylist(nextMedia: true)
      return .success
    }
    remoteCommand.previousTrackCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.navigateInPlaylist(nextMedia: false)
      return .success
    }
    remoteCommand.changeRepeatModeCommand.addTarget { _ in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.nextLoopMode()
      return .success
    }
    remoteCommand.changeShuffleModeCommand.isEnabled = false
    // remoteCommand.changeShuffleModeCommand.addTarget {})
    remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
    remoteCommand.changePlaybackRateCommand.addTarget { event in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.setSpeed(Double((event as! MPChangePlaybackRateCommandEvent).playbackRate))
      return .success
    }
    remoteCommand.skipForwardCommand.preferredIntervals = [15]
    remoteCommand.skipForwardCommand.addTarget { event in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.seek(relativeSecond: (event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
      return .success
    }
    remoteCommand.skipBackwardCommand.preferredIntervals = [15]
    remoteCommand.skipBackwardCommand.addTarget { event in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.seek(relativeSecond: -(event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
      return .success
    }
    remoteCommand.changePlaybackPositionCommand.addTarget { event in
      guard let player = PlayerCore.lastActive else { return .commandFailed }
      player.seek(absoluteSecond: (event as! MPChangePlaybackPositionCommandEvent).positionTime)
      return .success
    }
  }

  static func disableAllCommands() {
    remoteCommand.playCommand.removeTarget(nil)
    remoteCommand.pauseCommand.removeTarget(nil)
    remoteCommand.togglePlayPauseCommand.removeTarget(nil)
    remoteCommand.stopCommand.removeTarget(nil)
    remoteCommand.nextTrackCommand.removeTarget(nil)
    remoteCommand.previousTrackCommand.removeTarget(nil)
    remoteCommand.changeRepeatModeCommand.removeTarget(nil)
    remoteCommand.changeShuffleModeCommand.removeTarget(nil)
    remoteCommand.changePlaybackRateCommand.removeTarget(nil)
    remoteCommand.skipForwardCommand.removeTarget(nil)
    remoteCommand.skipBackwardCommand.removeTarget(nil)
    remoteCommand.changePlaybackPositionCommand.removeTarget(nil)
  }
}
