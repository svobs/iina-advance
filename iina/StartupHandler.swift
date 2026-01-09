//
//  swift
//  iina
//
//  Created by Matt Svoboda on 2024-12-03.
//  Copyright © 2024 lhc. All rights reserved.
//


import Foundation

/// Encapsulates code for opening/restoring windows at application startup...and, um, also opening windows when files or URLs
/// are opened manually.
/// See also: `AppDelegate`
final class StartupHandler {

  enum OpenWindowsState: Int {
    case stillEnqueuing = 1
    case doneEnqueuing
    case doneOpening
  }

  // MARK: Properties

  let launchStartTime = CFAbsoluteTimeGetCurrent()

  var state: OpenWindowsState = .stillEnqueuing

  var isDoneLaunching: Bool { state == .doneOpening }

  // - Opening Files Manually

  /// Serves as a queue to store file paths received across multiple invocations of `application(_:openFiles:)` within a short interval.
  private var pendingFilesForApplicationOpenFiles: [URL] = []
  /// The timer for `OpenFileRepeatTime` and `application(_:openFiles:)`.
  private let openFilesTimer = TimeoutTimer(timeout: Constants.TimeInterval.applicationOpenFilesRepeatTimeout)

  // TODO: clean up messy & confusing logic for `isAwaitingNewWindowsForOpenedFile` & `pwcsForOpenFiles`
  /// When launching, this variable indicates that the UI needs to wait for opened file(s) to finish loading before showing all windows.
  ///
  /// Should be set to `true` when `application(_:openFiles:)`, `handleURLEvent()` or `droppedText()` is called with file(s),
  /// & shortly afterwards, `pwcsForOpenFiles` is expected be set to a non-nil (and non-empty) value.
  /// If needing to abort the wait for new windows for any reason, this variable should be reset to `false`.
  ///
  /// This variable has evolved from its original incarnation in upstream IINA, where it is still named `openFileCalled`.
  var isAwaitingNewWindowsForOpenedFile = false
  var pwcsForOpenFiles: [PlayerWindowController]? = nil
  var pwcsDoneWithFileOpen: [PlayerWindowController] = []

  // - Restore

  /// The enqueued list of windows to restore, when restoring at launch.
  /// Try to wait until all windows are ready so that we can show all of them at once (compare with `wcsDoneWithRestore`).
  /// Make sure order of `wcsToRestore` is from back to front to restore the order properly.
  var wcsToRestore: [WindowController] = []
  var wcsDoneWithRestore = Set<WindowController>()
  /// Special case for Open File window when restoring. Because it is a panel, not a window, it will not have
  /// an `NSWindowController`.
  var restoreOpenFileWindow = false

  /// Calls `self.restoreDidTimeOut` on timeout.
  let restoreTimer = TimeoutTimer(timeout: Constants.TimeInterval.restoreWindowsTimeout)
  var restoreTimeoutAlertPanel: NSAlert? = nil

  // Command Line

  var commandLineState: CommandLineState? = nil

  var isCommandLine: Bool {
    commandLineState != nil
  }

  /// If launched from command line, should ignore `application(_, openFiles:)` during launch.
  /// This is because the above will be called redundantly by MacOS after startup has finished, and after the filenames have already
  /// been parsed from the command line args and we've already handled them. So we need a way to know to ignore these.
  /// However, the system may also call the same API later via various other sources, and we don't want to ignore those.
  /// So we need to set this back to `false` after we receive the call(s) we want to ignore (when the `openFilesTimer` action fires).
  var shouldIgnoreOpenFile = false

  // MARK: Init

  @MainActor
  init() {
    restoreTimer.action = restoreDidTimeOut
    openFilesTimer.action = handleOpenFilesTimeout
  }

  @MainActor
  func doStartup() {
    // Register to restore for successive launches. Set status to currently running so that it isn't restored immediately by the next launch.
    // Do this *before* restoring, because the cleanup task will reassign windows to this launch
    if UIState.shared.isSaveEnabled {
      Logger.log.verbose("Setting pref \(UIState.shared.currentLaunchName.quoted) = \(UIState.LaunchLifecycleState.stillRunning.rawValue)")
      UserDefaults.standard.setValue(UIState.LaunchLifecycleState.stillRunning.rawValue, forKey: UIState.shared.currentLaunchName)
    }
    // Add observer even if save is disabled; it may be re-enabled again
    UserDefaults.standard.addObserver(AppDelegate.shared, forKeyPath: UIState.shared.currentLaunchName, options: .new, context: nil)

    // Restore window state *before* hooking up the listener which saves state.
    restoreWindowsFromPreviousLaunch()

    // If launched via command line, use the logic below to open files and/or stdin, bypassing the normal application openFiles callback
    openFilesFromCommandLine()

    state = .doneEnqueuing
    // Callbacks may have already fired before getting here. Check again to make sure we don't "drop the ball":
    showWindowsIfReady()
  }

  @MainActor
  func applicationOpenFilesWasReceived(with filePaths: [String]) {
    let urls = filePaths.map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty else {
      Logger.log.verbose("application(openFiles:) called with: no URLs; returning")
      return
    }

    guard AppDelegate.shared.isInteractiveLaunch else {
      Logger.log.debug("OpenFiles: Launch is not interactive. Ignoring \(urls.count) requested files")
      return
    }

    openFilesTimer.restart()
    pendingFilesForApplicationOpenFiles.append(contentsOf: urls)
  }

  @MainActor
  private func handleOpenFilesTimeout() {
    let urls = pendingFilesForApplicationOpenFiles
    pendingFilesForApplicationOpenFiles = []
    guard !urls.isEmpty else { return }

    Logger.log.debug("OpenFiles: collected \(urls.map{PlaybackID.path(from: $0).pii})\(shouldIgnoreOpenFile ? ". Ignoring; launched from CLI" : "")")
    // if launched from command line, should ignore openFile during launch
    guard !shouldIgnoreOpenFile else {
      shouldIgnoreOpenFile = false
      return
    }


    Logger.log.verbose("OpenFiles: collected \(urls.count) files before timeout")

    // if installing a plugin package
    if let pluginPackageURL = urls.first(where: { $0.pathExtension == "iinaplgz" }) {
      Logger.log.debug("Opening plugin URL: \(pluginPackageURL.absoluteString.pii.quoted)")
      AppDelegate.shared.showPreferencesWindow(self)
      AppDelegate.shared.preferenceWindowController.performAction(.installPlugin(url: pluginPackageURL))
      return
    }

    let openedSomething = openFiles(urls, applyingCLI: nil) > 0
    if openedSomething {
      Logger.log.verbose("Replying to NSApp: success")
      NSApp.reply(toOpenOrPrint: .success)

      showWindowsIfReady()
    } else {
      Logger.log.verbose("Replying to NSApp: fail")
      NSApp.reply(toOpenOrPrint: .failure)
    }
  }

  @MainActor
  private func openFilesFromCommandLine() {
    guard let cli = commandLineState else { return }
    let validFileURLs: [URL] = cli.filenames.compactMap { filename in
      if Regex.url.matches(filename) {
        return URL(string: filename.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? filename)
      } else {
        return FileManager.default.fileExists(atPath: filename) ? URL(fileURLWithPath: filename) : nil
      }
    }
    guard !validFileURLs.isEmpty else {
      Logger.log.error("No valid file URLs provided via command line! Nothing to do")
      return
    }
    Logger.log.verbose("Will open \(validFileURLs.count) URLs from command line")
    shouldIgnoreOpenFile = true
    openFiles(validFileURLs, applyingCLI: cli)
  }

  /// Open files either from `application(_ ,openFiles:)`, or via command line interface (CLI).
  @MainActor
  @discardableResult
  private func openFiles(_ urls: [URL], applyingCLI cli: CommandLineState?) -> Int {
    let shouldOpenMultipleWindows: Bool
    if let separateWindowsCLI = cli?.openSeparateWindows {
      // Can force --separate-windows via CLI in addition to pref, for both yes/no
      shouldOpenMultipleWindows = separateWindowsCLI
    } else {
      shouldOpenMultipleWindows = Preference.bool(for: .alwaysOpenInNewWindow) && urls.count > 1
    }

    if !shouldOpenMultipleWindows {
      // Use only if opening single window.
      // If multiple windows, don't wait; open each as soon as it loads
      isAwaitingNewWindowsForOpenedFile = true
    }

    var totalFilesOpened = 0
    var totalExistingFilesShown = 0

    var lastPlayer: PlayerCore? = nil
    var pwcsForOpenFiles: [PlayerWindowController] = []

    if shouldOpenMultipleWindows {
      Logger.log.debug("Opening multiple windows for URLs: count=\(urls.count) CLI=\((cli != nil).yesno)")

      let urlsToOpen: [URL]
      if Preference.bool(for: .allowDuplicatePlayers) {
        urlsToOpen = urls
      } else {
        urlsToOpen = urls.filter{ url in
          // skip if url is already open in some player
          let activePlayerCores = PlayerManager.shared.playerCores.filter { !$0.isIdleOrUnused }
          let relevantActivePlayerCore = activePlayerCores.first { $0.info.currentURL == url }

          if let relevantActivePlayerCore {
            Logger.log.debug("Requested URL is already playing in open window; will show it instead: \(url.path.pii.quoted)")
            relevantActivePlayerCore.pwc.showWindow(nil)
            totalExistingFilesShown += 1
            return false
          }
          return true
        }
      }

      if urlsToOpen.count > 10 {
        // TODO: put up a confirmation prompt
        Logger.log.warn("User requested to open a large number of windows (count: \(urlsToOpen.count))")
      }

      for url in urlsToOpen {
        // open one window per file
        let player: PlayerCore
        if let cli {
          // TODO: do we ever need to reuse a PlayerCore for command line?
          player = PlayerManager.shared.createNewPlayerCore(applyingCLI: cli)
        } else {
          player = PlayerManager.shared.getIdleOrCreateNew()
        }
        let playerFilesOpened = player.openURLs([url])

        guard playerFilesOpened > 0 else { continue }
        player.openedWindowsSetIndex = pwcsForOpenFiles.count
        pwcsForOpenFiles.append(player.pwc)
        totalFilesOpened += playerFilesOpened
        lastPlayer = player
      }

    } else {
      Logger.log.debug("Opening single window for URLs: count=\(urls.count) CLI=\((cli != nil).yesno)")
      let player: PlayerCore
      if let cli {
        player = PlayerManager.shared.createNewPlayerCore(applyingCLI: cli)
      } else {
        // Open pending files in single window. Replace existing player if available
        player = PlayerManager.shared.getActiveOrCreateNew()
      }
      let playerFilesOpened = player.openURLs(urls)
      if playerFilesOpened > 0 {
        pwcsForOpenFiles.append(player.pwc)
        totalFilesOpened += playerFilesOpened
        lastPlayer = player
      }
    }

    if let cli, cli.isStdin {
      Logger.log.debug("Opening player for stdin from CLI")
      let player = PlayerManager.shared.createNewPlayerCore(applyingCLI: cli)
      lastPlayer = player
      player.openURLString("-")
      totalFilesOpened += 1
    }

    if (totalFilesOpened == 0) && (totalExistingFilesShown == 0) {
      DispatchQueue.main.async { [self] in
        abortWaitForOpenFilePlayerStartup()
        Logger.log.verbose("Notifying user nothing was opened")
        Utility.showAlert("nothing_to_open")
      }
    } else {
      Logger.log.verbose("Will open \(pwcsForOpenFiles.count) new windows for \(totalFilesOpened) files, & will show \(totalExistingFilesShown) existing")
      if AppDelegate.shared.isInteractiveLaunch {
        // Set pwcsForOpenFiles so they can be tracked & shown when ready:
        self.pwcsForOpenFiles = pwcsForOpenFiles
      } else {
        // Clear this flag to avoid waiting on opened files
        isAwaitingNewWindowsForOpenedFile = false
      }

      if let cli, let lastPlayer {
        cli.applySpecialModeToLastPlayer(lastPlayer)
      }
    }
    return totalFilesOpened + totalExistingFilesShown
  }

  /// Returns `true` if any windows were restored; `false` otherwise.
  @MainActor
  @discardableResult
  private func restoreWindowsFromPreviousLaunch() -> Bool {
    let log = Logger.restore

    guard UIState.shared.isRestoreEnabled else {
      log.debug("Restore is disabled. Skipping restore")
      return false
    }

    if isCommandLine && !Preference.bool(for: .enableRestoreUIStateForCmdLineLaunches) {
      log.debug("Restore is disabled for command-line launches. Will not restore launches or save this launch's state")
      UIState.shared.disableSaveAndRestoreUntilNextLaunch()
      return false
    }

    let pastLaunches: [UIState.LaunchState] = UIState.shared.collectLaunchStateForRestore()
    log.verbose("Found \(pastLaunches.count) past launches to restore")
    if pastLaunches.isEmpty {
      return false
    }

    let stopwatch = Utility.Stopwatch()

    let isRestoreApproved = checkForRestoreApproval()
    if !isRestoreApproved {
      // Clear out old state. It may have been causing errors, or user wants to start new
      log.debug("User denied restore. Clearing all saved launch state.")
      UIState.shared.clearAllSavedLaunches()
      Preference.set(false, for: .isRestoreInProgress)
      return false
    }

    // If too much time has passed (in particular if user took a long time to respond to confirmation dialog), consider the data stale.
    // Due to 1s delay in chosen strategy for verifying whether other instances are running, try not to repeat it twice.
    // Users who are quick with their user interface device probably know what they are doing and will be impatient.
    let pastLaunchesCache = stopwatch.secElapsed > Constants.TimeInterval.pastLaunchResponseTimeout ? nil : pastLaunches
    let savedWindowsBackToFront = UIState.shared.consolidateSavedWindowsFromPastLaunches(pastLaunches: pastLaunchesCache)

    guard !savedWindowsBackToFront.isEmpty else {
      log.debug("Nothing to restore: stored window list empty")
      return false
    }

    if savedWindowsBackToFront.count == 1 {
      let onlyWindow = savedWindowsBackToFront[0].saveName

      if onlyWindow == WindowAutosaveName.inspector {
        // Do not restore this on its own
        log.verbose("Nothing to restore: only open window was Inspector")
        return false
      }

      let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
      if (onlyWindow == WindowAutosaveName.welcome && action == .welcomeWindow)
          || (onlyWindow == WindowAutosaveName.openURL && action == .openPanel)
          || (onlyWindow == WindowAutosaveName.playbackHistory && action == .historyWindow) {
        log.verbose("Nothing to restore: the only open window was identical to launch action (\(action))")
        // Skip the prompts below because they are just unnecessary nagging
        return false
      }
    }

    log.verbose("Starting restore of \(savedWindowsBackToFront.count) windows")
    Preference.set(true, for: .isRestoreInProgress)

    let app = AppDelegate.shared
    // Show windows one by one, starting at back and iterating to front:
    for savedWindow in savedWindowsBackToFront {
      log.verbose("Starting restore of window: \(savedWindow.saveName)\(savedWindow.isMinimized ? " (minimized)" : "")")

      switch savedWindow.saveName {
      case .playbackHistory:
        addWindowToRestore(savedWindow, app.historyWindow)
        app.showHistoryWindow(self)
      case .welcome:
        addWindowToRestore(savedWindow, app.initialWindow)
        app.showWelcomeWindow()
      case .preferences:
        addWindowToRestore(savedWindow, app.preferenceWindowController)
        app.showPreferencesWindow(nil)
      case .about:
        addWindowToRestore(savedWindow, app.aboutWindow)
        app.showAboutWindow(self)
      case .openFile:
        // No windowController for Open File window. Set flag instead
        restoreOpenFileWindow = true
        UIState.shared.windowsOpen.insert(savedWindow.saveName.string)
      case .openURL:
        // TODO: persist isAlternativeAction too
        addWindowToRestore(savedWindow, app.openURLWindow)
        app.showOpenURLWindow(isAlternativeAction: true)
      case .fontPicker:
        // TODO: restore font picker
        continue
      case .inspector:
        // Do not show Inspector window. It doesn't support being drawn in the background, but it loads very quickly.
        // So just mark it as 'ready' and show with the rest when they are ready.
        wcsDoneWithRestore.insert(app.inspector)
        addWindowToRestore(savedWindow, app.inspector)
      case .videoFilter:
        addWindowToRestore(savedWindow, app.vfWindow)
        app.showVideoFilterWindow(nil)
      case .audioFilter:
        addWindowToRestore(savedWindow, app.afWindow)
        app.showAudioFilterWindow(nil)
      case .logViewer:
        addWindowToRestore(savedWindow, app.logWindow)
        app.showLogWindow(nil)
      case .playerWindow(let id):
        restorePlayerWindowFromPriorLaunch(savedWindow, playerID: id)
      case .newFilter, .editFilter, .saveFilter:
        log.debug("Restoring sheet window \(savedWindow.saveString) is not yet implemented; skipping")
        continue
      default:
        // Note: Guide is not saved
        log.error("Cannot restore unrecognized autosave enum: \(savedWindow.saveName)")
        continue
      }

    }

    return !wcsToRestore.isEmpty || restoreOpenFileWindow
  }

  /// Attempt to exactly restore play state & UI from last run of IINA (for given player)
  @MainActor
  private func restorePlayerWindowFromPriorLaunch(_ savedWindow: SavedWindow, playerID id: String) {
    let log = UIState.shared.log
    log.debug("Creating new PlayerCore & restoring saved state for \(WindowAutosaveName.playerWindow(id: id).string.quoted)")

    guard let savedState = UIState.shared.getPlayerSaveState(forPlayerID: id) else {
      log.errorDebugAlert("Cannot restore window: could not find saved state for \(WindowAutosaveName.playerWindow(id: id).string.quoted)")
      return
    }

    // This will call `player.openURLs()` when done
    guard let player = savedState.restorePlayer(id: id) else { return }
    addWindowToRestore(savedWindow, player.pwc)
  }


  @MainActor
  func addWindowToRestore(_ savedWindow: SavedWindow, _ wc: WindowController) {
    Logger.restore.verbose("Adding window to restore: \(savedWindow.saveName.string.quoted), minimized=\(savedWindow.isMinimized.yn)")

    // Rebuild UIState window sets as we go:
    if savedWindow.isMinimized {
      // No need to worry about partial show, so skip wcsToRestore
      wc.window?.miniaturize(self)
      UIState.shared.windowsMinimized.insert(savedWindow.saveName.string)
    } else {
      // Add to list of windows to wait for, so we can show them all nicely
      wcsToRestore.append(wc)
      UIState.shared.windowsOpen.insert(savedWindow.saveName.string)
    }
  }

  /// If this returns true, restore should be attempted using the saved launch state.
  /// If false is returned, then the saved launch state should be deleted and app should launch fresh.
  private func checkForRestoreApproval() -> Bool {
#if DEBUG
    if DebugConfig.alwaysApproveRestore {
      // skip approval to make testing easier
      Logger.restore.debug("Skipping restore approval ∵ pref 'alwaysApproveRestore' is enabled")
      return true
    }
#endif

    if Preference.bool(for: .isRestoreInProgress) {
      // If this flag is still set, the last restore probably failed. If it keeps failing, launch will be impossible.
      // Let user decide whether to try again or delete saved state.
      Logger.restore.debug("Looks like there was a previous restore which didn't complete (pref \(Preference.Key.isRestoreInProgress.rawValue)=Y). Asking user whether to retry or skip")
      return Utility.quickAskPanel("restore_prev_error", useCustomButtons: true)

    } else if Preference.bool(for: .alwaysAskBeforeRestoreAtLaunch) {
      Logger.restore.verbose("Prompting user whether to restore app state, per pref")
      return Utility.quickAskPanel("restore_confirm", useCustomButtons: true)

    } else {
      Logger.restore.trace("No approval for restore required")
      return true
    }
  }

  /// Called by a `TimeoutTimer` if the restore process is taking too long.  Displays a dialog prompting
  /// the user to discard the stored state, or keep waiting.
  @MainActor
  private func restoreDidTimeOut() {
    let log = Logger.restore
    guard state == .doneEnqueuing else {
      log.error("Restore timed out but state is \(state)")
      return
    }

    // FIXME: also show if waiting on opened file

    let namesReady = wcsDoneWithRestore.compactMap{$0.window?.savedStateName}
    let wcsStalled: [WindowController] = wcsToRestore.filter{ !namesReady.contains($0.window!.savedStateName) }
    var namesStalled: [String] = []
    for (index, wc) in wcsStalled.enumerated() {
      let winID = wc.window!.savedStateName
      let str: String
      if index > Constants.maxWindowNamesInRestoreTimeoutAlert {
        break
      } else if index == Constants.maxWindowNamesInRestoreTimeoutAlert {
        str = "…"
      } else if let path = (wc as? PlayerWindowController)?.player.info.currentPlayback?.path {
        str = "\(index+1). \(path.quoted)  [\(winID)]"
      } else {
        str = "\(index+1). \(winID)"
      }
      namesStalled.append(str)
    }

    log.debug("Restore timed out. Progress: \(namesReady.count)/\(wcsToRestore.count). Stalled: \(namesStalled)")
    log.debug("Prompting user whether to discard them & continue, or quit")

    let countStalled = "\(wcsStalled.count)"
    let countTotal = "\(wcsToRestore.count)"
    let namesStalledString = namesStalled.joined(separator: "\n")
    let msgArgs = [countStalled, countTotal, namesStalledString]
    let askPanel = Utility.buildThreeButtonAskPanel("restore_timeout", msgArgs: msgArgs, middleBtnArgs: [countStalled],
                                                    alertStyle: .critical)
    restoreTimeoutAlertPanel = askPanel
    let userResponse = askPanel.runModal()  // this will block for an indeterminate time

    switch userResponse {
    case .alertFirstButtonReturn:
      log.debug("User chose button 1: keep waiting")
      guard state != .doneOpening else {
        log.debug("Looks like windows finished opening - no need to restart restore timer")
        return
      }
      dismissTimeoutAlertPanel()
      restoreTimer.restart()

    case .alertSecondButtonReturn:
      // Launch async in case loading actually finished
      DispatchQueue.main.async { [self] in
        log.debug("User chose button 2: discard stalled windows & continue with partial restore")
        restoreTimeoutAlertPanel = nil  // Clear this (no longer needed)
        guard state != .doneOpening else {
          log.debug("Looks like windows finished opening - no need to close anything")
          return
        }
        for wcStalled in wcsStalled {
          guard !wcsDoneWithRestore.contains(wcStalled) else {
            log.verbose("Window has become ready; skipping close: \(wcStalled.window!.savedStateName)")
            continue
          }
          log.debug("Telling stalled window to close: \(wcStalled.window!.savedStateName)")
          if let pWin = wcStalled as? PlayerWindowController {
            /// This will guarantee `windowMustCancelShow` notification is sent
            pWin.player.closeWindow()
          } else {
            wcStalled.close()
            // explicitly call this, as the line above may fail
            wcStalled.postWindowMustCancelShow()
          }
        }
      }

    case .alertThirdButtonReturn:
      log.debug("User chose button 3: quit")
      NSApp.terminate(nil)

    case .abort:
      log.debug("Restore timeout alert aborted; terminating")
      NSApp.terminate(nil)
    case .stop:
      log.debug("Restore timeout alert stopped; terminating")
      NSApp.terminate(nil)

    default:
      log.fatalError("User responded to Restore Timeout alert with unrecognized choice!")
    }
  }

  /// Called if all the windows become ready while still displaying the timeout dialog, Dismisses the dialog
  /// automatically, so the user does not have to do it themselves.
  @MainActor
  private func dismissTimeoutAlertPanel() {
    guard let restoreTimeoutAlertPanel else { return }

    /// Dismiss the prompt (if any). It seems we can't just call `close` on its `window` object, because the
    /// responder chain is left unusable. Instead, click its default button after setting `state`.
    Logger.log.debug("Dismissing Restore Timeout alert panel")
    let keepWaitingBtn = restoreTimeoutAlertPanel.buttons[0]
    keepWaitingBtn.performClick(self)
    self.restoreTimeoutAlertPanel = nil

    /// This may restart the timer if not in the correct state, so account for that.
  }

  /// Call this if the user opened a new file at startup but we want to discard the state for it
  /// (for example if it couldn't be opened).
  @MainActor
  func abortWaitForOpenFilePlayerStartup() {
    Logger.log.verbose("Aborting wait for open files")
    isAwaitingNewWindowsForOpenedFile = false
    pwcsForOpenFiles = nil
    pwcsDoneWithFileOpen.removeAll()
    showWindowsIfReady()
  }

  @MainActor
  func showWindowsIfReady() {
    let log = Logger.restore
    let isInteractiveLaunch = AppDelegate.shared.isInteractiveLaunch

    if isInteractiveLaunch {
      switch state {
      case .stillEnqueuing:
        log.verbose("ShowAllWindows: not ready, still enqueuing")
        return
      case .doneEnqueuing:
        // This is the only case we care about
        break
      case .doneOpening:
        log.verbose("ShowAllWindows: not needed (startup done)")
        return
      }
      guard state == .doneEnqueuing else {
        log.verbose("Skipping showWindowsIfReady: state (\(state)) != doneEnqueuing")
        return
      }

      guard wcsDoneWithRestore.count == wcsToRestore.count else {
        log.verbose({
          let openStr: String
          if let pwcsForOpenFiles {
            openStr = " & opening \(pwcsDoneWithFileOpen.count) / \(pwcsForOpenFiles.count)"
          } else {
            openStr = ""
          }
          return "Restarting restore timer: only done restoring \(wcsDoneWithRestore.count) / \(wcsToRestore.count)\(openStr)"
        }())
        dismissTimeoutAlertPanel()
        restoreTimer.restart()
        return
      }

      // If an new player window was opened at startup (i.e. not a restored window), wait for this also.
      if isAwaitingNewWindowsForOpenedFile {
        guard let pwcsForOpenFiles else {
          // Probably still building the list. Return for now.
          log.verbose("Startup: isAwaitingNewWindowsForOpenedFile=Y but pwcsForOpenFiles is nil; returning")
          return
        }

        // If opening more than 1 file, proceed immediately. Otherwise wait for it to be ready.
        guard (pwcsForOpenFiles.count > 1) || (pwcsForOpenFiles.count == pwcsDoneWithFileOpen.count) else {
          log.verbose("Startup: still waiting for opened file")
          return
        }
      }

      let newWindCount = pwcsForOpenFiles?.count ?? 0
      if newWindCount == 0 && wcsToRestore.count == 0 {
        log.verbose("No windows exist to wait for; finishing startup")
      } else {
        log.verbose("All \(wcsToRestore.count) restored\(newWindCount > 0 ? " & \(newWindCount) new windows ready" : ""). Showing all")
      }
      restoreTimer.cancel()

      var prevWindowNumber: Int? = nil
      for wc in wcsToRestore {
        let wndName = wc.window!.savedStateName
        let windowIsMinimized = UIState.shared.windowsMinimized.contains(wndName)
        log.verbose("Showing restored window: \(wndName)\(windowIsMinimized ? " (minimized)" : "")")
        guard !windowIsMinimized else { continue }

        if let prevWindowNumber {
          wc.window?.order(.above, relativeTo: prevWindowNumber)
        }
        prevWindowNumber = wc.window?.windowNumber
        wc.showWindow(self)
      }

      // Windows for opened files (if any).
      // Don't wait for these to be ready. But at least ensure that their ordering is correct.
      if let pwcsForOpenFiles {
        for pwc in pwcsForOpenFiles {
          let wndName = pwc.window!.savedStateName
          log.verbose("Showing new window: \(wndName)")

          // Make this topmost
          if let prevWindowNumber {
            pwc.window?.order(.above, relativeTo: prevWindowNumber)
          }
          prevWindowNumber = pwc.window?.windowNumber
          pwc.showWindow(self)
        }
      }

      if restoreOpenFileWindow {
        // TODO: persist isAlternativeAction too
        AppDelegate.shared.showOpenFileWindow(isAlternativeAction: false)
      }

      // Bring this app to the front, possibly annoying the user who got bored waiting & is now doing something else.
      Logger.log.debug("Activating app")
      NSApp.activate(ignoringOtherApps: true)

      if Preference.bool(for: .isRestoreInProgress) {
        log.verbose("Done restoring windows (\(wcsToRestore.count))")
        Preference.set(false, for: .isRestoreInProgress)
      } else {
        log.verbose("Done opening windows")
      }
    }

    state = .doneOpening

    if isInteractiveLaunch {
      /// Make sure to do this *after* `state = .doneOpening`
      /// (note: this does nothing in recent versions of MacOS cuz it is a modal alert
      // FIXME: reimplement timeout alert with custom non-modal window so it can be auto-closed
      dismissTimeoutAlertPanel()

      initAppUI()

      let didRestoreSomething = !wcsToRestore.isEmpty || restoreOpenFileWindow
      let didShowSomething = didRestoreSomething || (pwcsForOpenFiles != nil)
      let canShowWelcomeWindowByDefault = Preference.enum(for: .actionAfterLaunch) == Preference.ActionAfterLaunch.welcomeWindow
      var didShowWelcomeWindow = wcsToRestore.contains(where: { $0.windowFrameAutosaveName == WindowAutosaveName.welcome.string })
      if !isCommandLine {
        if !didShowSomething {
          // Fall back to default action:
          AppDelegate.shared.doLaunchOrReopenAction()
          if canShowWelcomeWindowByDefault {
            didShowWelcomeWindow = true
          }
          DispatchQueue.main.async {
            // Optimization: pre-load a new idle player if none started, for a snappier drag & drop effect in Welcome window
            log.debug("No players were explicitly opened at launch - will preemptively create a new idle player")
            // Don't load "Additional mpv options" yet - they may immediately show error pop-ups if invalid.
            // And they will be loaded again when the user actually opens a window, so don't do duplicate work.
            _ = PlayerManager.shared.getIdleOrCreateNew(loadAdditionalMpvOptionsFromPrefs: false)
          }
        }

        // Optimization: pre-load welcome window dependencies if it can be shown
        if !didShowWelcomeWindow {
          let canShowWelcomeWindow = Preference.bool(for: .enableCmdN) || canShowWelcomeWindowByDefault
          if canShowWelcomeWindow {
            log.debug("Welcome window can be shown but is not yet shown; will preemptively load it from XIB & start History service for it")
            let _ = AppDelegate.shared.initialWindow.window
            HistoryController.shared.start()
          }
        }
      }
    }

    let timeElapsed: Double = CFAbsoluteTimeGetCurrent() - launchStartTime
    Logger.log.verbose("Done with startup (\(timeElapsed.stringMaxFrac2)s)")
  }


  @MainActor
  func initAppUI() {
    Logger.log.debug("Init app UI")
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }

    // Various initializations at App level
    NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
    // Make sure this is enabled so that tab-related menu items show up in the Window menu.
    // We will disable tabbing on a per-window basis in each window controller's constructor method.
    NSWindow.allowsAutomaticWindowTabbing = true

    JavascriptPlugin.loadGlobalInstances()

    if let menuController = AppDelegate.shared.menuController {
      menuController.initMenus()
    }

#if !MACOS_13_AVAILABLE
    // show alpha in color panels
    // This actually causes a window to open in the background. Only run this if newer API can't be used
    NSColorPanel.shared.showsAlpha = true
#endif

    // Init MediaPlayer integration
    MediaPlayerIntegration.shared.update()

    NSApplication.shared.servicesProvider = self

    Logger.log.verbose("Registering for URL events")
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(AppDelegate.shared.handleURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    // Hide Window > "Enter Full Screen" menu item, because this is already present in the Video menu
    UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
  }

  // MARK: - Notification Listeners

  /// Window is done loading and is ready to show.
  /// If the application has already finished launching, this simply calls `showWindow` for the calling window.
  /// If restoring, this should not be fired at all if the window being restored is minimized or hidden due to PiP.
  @MainActor
  func windowIsReadyToShow(_ notification: Notification) {
    let log = Logger.restore

    guard let window = notification.object as? NSWindow else { return }
    guard let wc = window.windowController as? WindowController else {
      log.error("Restored window is ready, but no WindowController for window: \(window.savedStateName.quoted)!")
      return
    }
    let savedStateName = window.savedStateName

    if isDoneLaunching {
      if window.isMiniaturized {
        Logger.log.verbose("OpenWindow: deminiaturizing window \(window.savedStateName.quoted)")
        // Need to call this instead of showWindow if minimized (otherwise there are visual glitches)
        window.deminiaturize(self)
      } else {
        Logger.log.verbose("OpenWindow: showing window \(window.savedStateName.quoted)")
        wc.showWindow(window)
      }

    } else { // Not done launching
      if Preference.bool(for: .isRestoreInProgress), wcsToRestore.contains(wc) {
        wcsDoneWithRestore.insert(wc)
        log.verbose("Restored window is ready: \(savedStateName.quoted). Progress: \(wcsDoneWithRestore.count)/\(state == .doneEnqueuing ? "\(wcsToRestore.count)" : "?")")
      } else if let pwcsForOpenFiles, pwcsForOpenFiles.contains(where: {$0.window!.savedStateName == savedStateName}) {
        pwcsDoneWithFileOpen.append(wc as! PlayerWindowController)
        log.verbose("OpenedFile window is ready: \(savedStateName.quoted)")
      }
      // Else may be multiple files opened at launch

      // Show all windows if ready
      showWindowsIfReady()
    }
  }

  /// Window failed to load or is hidden. Stop waiting for it
  @MainActor
  func windowMustCancelShow(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let log = Logger.restore

    guard !isDoneLaunching else { return }

    // No longer waiting for this window before showing all windows
    let toRestoreCountOld = wcsToRestore.count
    wcsToRestore.removeAll(where: { wc in
      wc.window!.savedStateName == window.savedStateName
    })

    let toOpenFileCountOld = pwcsForOpenFiles?.count ?? 0
    pwcsForOpenFiles?.removeAll(where: { pwc in
      pwc.window!.savedStateName == window.savedStateName
    })
    let toOpenFileCountNew = pwcsForOpenFiles?.count ?? 0

    let toRestoreCountNew = wcsToRestore.count
    let removedFromRestoreCount = toRestoreCountOld - toRestoreCountNew
    let removedFromOpenCount = toOpenFileCountOld - toOpenFileCountNew

    log.verbose("Canceled wait for window: \(window.savedStateName.quoted) (removedFromRestoreCount=\(removedFromRestoreCount), removedFromOpenCount=\(removedFromOpenCount)). Progress is now: \(wcsDoneWithRestore.count)/\(state == .doneEnqueuing ? "\(wcsToRestore.count)" : "?")")

    showWindowsIfReady()
  }

  // MARK: - Command Line

  @MainActor
  func processCommandLine(_ cmdLineArgs: ArraySlice<String>) {
    if cmdLineArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
      print(InfoDictionary.shared.iinaBinaryUsageText)
      exit(0)
    }

    commandLineState = CommandLineState(cmdLineArgs)
    guard let commandLineState else { return }

    // Apply args

    // Replicate logic from main.swift in case this launch did not originate there
    if commandLineState.enterMusicMode && commandLineState.enterPIP {
      // Music mode does not support Picture-in-Picture. Combining these options is not permitted.
      print("Cannot specify both --music-mode and --pip")
      // Command line usage error.
      exit(EX_USAGE)
    }

    let activationPolicy = commandLineState.mpvArguments.last(where: { arg in
      (arg.key == MPVOption.GPURendererOptions.macosAppActivationPolicy) && !arg.val.isEmpty
    })
    if let activationPolicy {
      switch activationPolicy.val {
      case "regular":
        NSApp.setActivationPolicy(.regular)
      case "accessory":
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.shared.isInteractiveLaunch = false
      case "prohibited":
        NSApp.setActivationPolicy(.prohibited)
      default:
        break
      }
    }

    if commandLineState.mpvArguments.contains(where: { $0.key == MPVEncoding.o }) {
      AppDelegate.shared.isInteractiveLaunch = false
    }
  }
}
