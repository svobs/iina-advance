//
//  HistoryController.swift
//  iina
//
//  Created by lhc on 25/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

final class HistoryController {

  static let shared = HistoryController(plistFileURL: Utility.playbackHistoryURL)

  /// Master kill switch: if false, all history operations become no-ops.
  /// It is preferable to disable history load/save when certain command-line arguments are used,
  /// such as encoding mode, both because they should not be counted as a history entry and to improve performance
  /// by skipping unnecessary operations.
  var historyEnabled: Bool = true

  private(set) var started = false

  let plistURL: URL

  let log = Logger.makeSubsystem("history")
  let folderMonitor = FolderMonitor(url: Utility.watchLaterURL)

  private(set) var cachedRecentDocumentURLs: [URL]

  private(set) var history: [PlaybackHistory]
  /// Starts at 0 at each launch. Used by UI to sync to this database more efficiently
  @Atomic private(set) var historyListVersion: Int = 0

  /// Do not use this directly for tasks. Use `HistoryController.shared.async`.
  private let workDQ = DispatchQueue.newDQ(label: "IINA-History-BG", qos: .background)
  /// Number of tasks currently in workDQ.
  @Atomic var tasksOutstanding = 0

  private let fileExistsDQ = DispatchQueue.newDQ(label: "History-File-BG", qos: .background)
  private(set) var fileExistsMap: [URL: Bool] = [:]
  private var lastCompleteStatusReloadTime = Date(timeIntervalSince1970: 0)
  /// See `stop` func
  private(set) var fileExistsDQ_ShutdownAck = false

  /// Whether graceful stop of history queues has commenced (via `stop` func).
  /// Use this to check for app termination in queues other than main, as that is a prerequisite for
  /// `AppDelegate.shared.isTerminating`.
  private(set) var isAppTerminating = false

  init(plistFileURL: URL) {
    self.plistURL = plistFileURL
    self.history = []
    cachedRecentDocumentURLs = []
    // Support playback history from upstream IINA, and/or future names for PlaybackHistory:
    NSKeyedArchiver.setClassName("IINA.PlaybackHistory", for: PlaybackHistory.self)
    NSKeyedUnarchiver.setClass(PlaybackHistory.self, forClassName: "IINA.PlaybackHistory")
    NSKeyedUnarchiver.setClass(PlaybackHistory.self, forClassName: "iina.PlaybackHistory")
    NSKeyedUnarchiver.setClass(PlaybackHistory.self, forClassName: "PlaybackHistory")
  }

  /// Enqueues the given task argument in workDQ.
  /// If the application is already shutting down, it will not be enqueued or executed.
  func async(_ taskBody: @escaping () -> Void) {
    guard !isAppTerminating else {
      log.verbose("Aborting new task: app is terminating")
      return
    }

    var isTerminating = false
    $tasksOutstanding.withLock {
      if isAppTerminating {
        isTerminating = true
      } else {
        $0 += 1
      }
    }
    guard !isTerminating else {
      log.verbose("Aborting new task: app is terminating")
      return
    }

    workDQ.async { [self] in
      taskBody()

      let tasksOutstanding = $tasksOutstanding.withLock { tasksOutstanding in
        tasksOutstanding -= 1
        return tasksOutstanding
      }
      if tasksOutstanding == 0 {
        DispatchQueue.main.async {
          NotificationCenter.default.post(Notification(name: .iinaHistoryTasksFinished))
        }
      } else {
        // The history controller must be able to finish saving playback history before IINA
        // terminates or history will be lost. If termination times out before saving of playback
        // history has finished then history will be lost. If that happens then the qos of the
        // history batch queue will need to be raised to allow the history controller to keep up
        // with requests to save history.
        log.verbose("History tasks outstanding: \(tasksOutstanding)")
      }
    }
  }

  private func watchLaterDirDidChange() {
    postNotification(Notification(name: .watchLaterDirDidChange))
  }

  func start() {
    guard historyEnabled else {
      log.trace("History disabled; skipping history start")
      return
    }
    // Launch this as a background task! Resolution can take a long time if waiting for remote servers to time out
    // and we don't want to tie up the main thread.
    self.async { [self] in
      guard historyEnabled else {  // check again to avoid race condition
        log.trace("History was disabled; aborting history start")
        return
      }
      guard !started else { return }
      started = true
      let sw = Utility.Stopwatch()
      log.verbose("Starting History")
      startOrStopMonitoringWatchLaterDir()
      reloadAll()

      // Workaround for macOS Sonoma clearing the recent documents list when the IINA code is not signed
      // with IINA's certificate as is the case for developer and nightly builds.
      restoreRecentDocuments()
      log.verbose("Starting History: done in \(sw.secElapsedString)")
    }
  }

  /// Use `shutdown: true` only if application is shutting down
  func stop(shutdown: Bool = false) {
    log.debug("Stopping History")
    folderMonitor.stopMonitoring()

    // Flush workQueue
    if shutdown {
      $tasksOutstanding.withLock { _ in
        isAppTerminating = true
      }
    }

    workDQ.async { [self] in
      log.debug("Reached end of workDQ")
      started = false
    }

    if shutdown {
      fileExistsDQ.async { [self] in
        log.debug("Reached end of fileExistsDQ; sending shutdown acknowledgment")
        fileExistsDQ_ShutdownAck = true
        // Ping ShutdownHandler:
        DispatchQueue.main.async {
          NotificationCenter.default.post(Notification(name: .iinaHistoryTasksFinished))
        }
      }
    }
  }

  func startOrStopMonitoringWatchLaterDir() {
    if Preference.bool(for: .resumeLastPosition) {
      // Make sure to start listening before reload, to avoid creating race condition
      log.debug("Starting monitoring of watch-later dir")
      folderMonitor.folderDidChange = self.watchLaterDirDidChange
      folderMonitor.startMonitoring()
    } else {
      log.debug("Will not monitor watch-later dir: resumeLastPosition=NO")
      folderMonitor.stopMonitoring()
    }
  }

  private func saveHistoryToFile() {
    guard historyEnabled else {
      log.trace("History disabled; skipping history save")
      return
    }
    guard Preference.bool(for: .recordPlaybackHistory) else {
      log.verbose("Pref 'recordPlaybackHistory'=NO: skipping history save")
      return
    }
    if !FileManager.default.fileExists(atPath: plistURL.path) {
      // This is fine if the app was freshly installed. Otherwise it could indicate a permissions error or someone tampering.
      log.warn("History file does not appear to exist; will create: \(plistURL.path.pii.quoted)")
    } else {
      guard FileManager.default.isWritableFile(atPath: plistURL.path) else {
        log.error("Cannot save playback history to disk! Cannot write to file \(plistURL.path.pii.quoted)")
        return
      }
    }
    let sw = Utility.Stopwatch()
    do {
      log.verbose("Saving playback history (entryCount=\(history.count)) to file \(plistURL.path.pii.quoted)")
      let data = try NSKeyedArchiver.archivedData(withRootObject: history, requiringSecureCoding: true)
      try data.write(to: plistURL)
    } catch {
      log.error("Failed to save playback history to file \(plistURL.path.pii.quoted): \(error)")
      return
    }

    log.verbose("Saving playback history done, in \(sw.secElapsedString)")
  }

  /// Returns `true` if successful; `false` if not
  private func readHistoryFromFile() -> Bool {
    assert(DispatchQueue.isExecutingIn(workDQ))
    // Avoid logging a scary error if the file does not exist.
    guard FileManager.default.fileExists(atPath: plistURL.path) else {
      log.debug("Playback history file does not exist: \(plistURL.path.pii.quoted). Clearing cached history from memory")
      history = []
      return true
    }
    guard FileManager.default.isReadableFile(atPath: plistURL.path) else {
      log.error("Cannot read playback history file \(plistURL.path.pii.quoted)")
      return false
    }

    do {
      log.verbose("Reading playback history file \(plistURL.path.pii.quoted)")
      let data = try Data(contentsOf: plistURL)
      let deserData = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, PlaybackHistory.self], from: data)
      guard let historyItemList = deserData as? [PlaybackHistory] else {
        log.error("Failed deserialize PlaybackHistory array from file \(plistURL.path.pii.quoted)!")
        return false
      }
      history = historyItemList
      log.verbose("Loaded playback history (entryCount=\(historyItemList.count))")
      return true
    } catch {
      log.error("Failed to load playback history file \(plistURL.path.pii.quoted): \(error)")
      return false
    }
  }

  func reloadAll() {
    assert(DispatchQueue.isExecutingIn(workDQ))
    guard historyEnabled else {
      log.trace("History disabled; skipping history reload")
      return
    }
    let sw = Utility.Stopwatch()

    log.verbose("ReloadAll starting, from \(plistURL.path.pii.quoted)")

    // Resetting this will also reset watch-later status, which is needed for live update after
    // `PK.resumeLastPosition` is toggled.
    fileExistsMap = [:]

    let didLoadSuccessfully = readHistoryFromFile()
    guard didLoadSuccessfully else {
      // Stop the History service. Must not try to write new history if history load failed
      stop()
      return
    }
    // Force a timeout to trigger full status reload prior to calling historyListDidUpdate()
    lastCompleteStatusReloadTime = Date(timeIntervalSince1970: 0)
    historyListDidUpdate()

    log.verbose("ReloadAll: done reading history file. Loading recentDocumentURLs")
    cachedRecentDocumentURLs = NSDocumentController.shared.recentDocumentURLs

    log.verbose("ReloadAll: posting recentDocumentsDidChange")
    postNotification(Notification(name: .recentDocumentsDidChange))

    log.verbose("ReloadAll done: \(history.count) history entries & \(cachedRecentDocumentURLs.count) recentDocuments in \(sw.secElapsedString)")
  }

  @discardableResult
  private func addPlayback(_ id: PlaybackID, duration: Double) -> PlaybackHistory? {
    assert(DispatchQueue.isExecutingIn(workDQ))
    guard Preference.bool(for: .recordPlaybackHistory) else { return nil }

    if let existingItem = history.first(where: { $0.mpvMd5 == id.mpvMD5 }), let index = history.firstIndex(of: existingItem) {
      history.remove(at: index)
    }
    let newEntry = PlaybackHistory(id: id, duration: duration)
    history.insert(newEntry, at: 0)
    historyListDidUpdate()
    saveHistoryToFile()
    return newEntry
  }

  func remove(_ entries: [PlaybackHistory]) {
    assert(DispatchQueue.isExecutingIn(workDQ))

    log.debug("Clearing \(entries.count) history entries")
    history = history.filter { !entries.contains($0) }
    historyListDidUpdate()
    saveHistoryToFile()
  }

  func removeAll() {
    self.async { [self] in
      log.debug("Clearing all history")
      history = []
      saveHistoryToFile()
      clearRecentDocuments(nil)
      Preference.set(nil, for: .iinaLastPlayedFilePath)

      reloadAll()
    }
  }

  private func historyListDidUpdate() {
    let historyListVersion = $historyListVersion.withLock { version in
      version += 1
      return version
    }
    DispatchQueue.main.async { [self] in
      // This can be a very long-running operation, but is only needed for the History window.
      if !isAppTerminating, AppDelegate.shared.isInteractiveLaunch, AppDelegate.shared.historyWindow.isOpen {
        startAsyncReloadOfFileExistsAndProgress(forVersion: historyListVersion)
      }

      log.verbose("Posting iinaHistoryListUpdated")
      postNotification(Notification(name: .iinaHistoryListUpdated))
    }
  }

  // MARK: - Recent Documents

  /// Empties the recent documents list for the application.
  func clearRecentDocuments(_ sender: Any?) {
    self.async { [self] in
      log.debug("Clearing recent documents")
      NSDocumentController.shared.clearRecentDocuments(sender)
      saveRecentDocuments()
    }
  }

  /// Adds or replaces an Open Recent menu item corresponding to the data located by the URL.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  /// - Parameter url: The URL to evaluate.
  func noteNewRecentDocumentURL(_ url: URL) {
    assert(DispatchQueue.isExecutingIn(workDQ))

    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    saveRecentDocuments()
  }

  func noteNewRecentDocumentURLs(_ urls: [URL]) {
    assert(DispatchQueue.isExecutingIn(workDQ))

    for url in urls {
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    saveRecentDocuments()
  }

  /// Restore the list of recently opened files.
  ///
  /// For macOS Sonoma `sharedfilelistd` was changed to tie the list of recent documents to the app based on its certificate.
  /// if `sharedfilelistd` determines the list is being accessed by a different app then it clears the list. See issue
  /// [#4688](https://github.com/iina/iina/issues/4688) for details.
  ///
  /// This new behavior does not cause a problem when the code is signed with IINA's certificate. However developer and nightly
  /// builds use an ad hoc certificate. This causes the list of recently opened files to be cleared each time a different unsigned IINA build
  /// is run. As a workaround a copy of the list of recent documents is saved in IINA's preference file to preserve the list and allow it to
  /// be restored when `sharedfilelistd` clears its list.
  ///
  /// If the following is true:
  /// - Running under macOS Sonoma and above
  /// - Recording of recent files is enabled
  /// - The list in  [NSDocumentController.shared.recentDocumentURLs](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/1514976-recentdocumenturls) is empty
  /// - The list in the IINA setting `recentDocuments` is not empty
  ///
  /// Then this method assumes that the macOS daemon `sharedfilelistd` cleared the list and it populates the list of recent
  /// document URLs with the list stored in IINA's settings.
  private func restoreRecentDocuments() {
    assert(DispatchQueue.isExecutingIn(workDQ))
    guard historyEnabled else {
      log.verbose("History is disabled; will not restore list of recent documents from prefs")
      return
    }

    /// Make sure `reloadAll()` was called before this
    let recentDocumentsURLs = cachedRecentDocumentURLs
    guard Preference.bool(for: .enableRecentDocumentsWorkaround),
          #available(macOS 14, *), Preference.bool(for: .recordRecentFiles),
          recentDocumentsURLs.isEmpty,
          let recentDocuments = Preference.array(for: .recentDocuments),
          !recentDocuments.isEmpty else {
      log.verbose("Will not restore list of recent documents from prefs")
      return
    }

    log.debug("Restoring list of recent documents from prefs...")

    var newRecentDocuments: [URL] = []
    var foundStale = false
    for document in recentDocuments {
      var isStale = false
      guard let asData = document as? Data,
            let bookmark = try? URL(resolvingBookmarkData: asData, bookmarkDataIsStale: &isStale) else {
        guard let asString = document as? String, let url = URL(string: asString) else { continue }
        // Saving as a bookmark must have failed and instead the URL was saved as a string.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        newRecentDocuments.append(url)
        continue
      }
      foundStale = foundStale || isStale
      NSDocumentController.shared.noteNewRecentDocumentURL(bookmark)
      newRecentDocuments.append(bookmark)
    }
    cachedRecentDocumentURLs = newRecentDocuments

    if foundStale {
      log.debug("Found stale bookmarks in saved recent documents")
      // Save the recent documents in order to refresh stale bookmarks.
      saveRecentDocuments()
    }

    log.debug("Done restoring list of recent documents (\(newRecentDocuments.count)). Posting recentDocumentsDidChange")
    postNotification(Notification(name: .recentDocumentsDidChange))
  }

  /// Save the list of recently opened files.
  ///
  /// Save the list of recent documents in [NSDocumentController.shared.recentDocumentURLs](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/1514976-recentdocumenturls)
  /// to `recentDocuments` in the IINA settings property file.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  func saveRecentDocuments() {
    assert(DispatchQueue.isExecutingIn(workDQ))

    defer {
      // Notify even for older MacOS
      postNotification(Notification(name: .recentDocumentsDidChange))
    }

    guard #available(macOS 14, *) else { return }
    var recentDocuments: [Any] = []
    for document in NSDocumentController.shared.recentDocumentURLs {
      guard let bookmark = try? document.bookmarkData() else {
        // Fall back to storing a string when unable to create a bookmark.
        recentDocuments.append(document.absoluteString)
        continue
      }
      recentDocuments.append(bookmark)
    }
    Preference.set(recentDocuments, for: .recentDocuments)
    if recentDocuments.isEmpty {
      log.debug("Cleared list of recent documents")
    } else {
      log.debug("Saved list of recent documents")
    }
  }

  // MARK: - Playback Lifecycle Events

  func savePlaybackMetaAfterFileDidLoad(for id: PlaybackID, durationSec: Double, positionSec: Double?) {
    guard historyEnabled else { return }
    if !started {
      log.verbose("While trying to save playback after file load: history not started! Starting now")
      start()
    }

    HistoryController.shared.async { [self] in
      guard historyEnabled else {
        log.error("Cannot save playback meta after file load: history is unexpectedly disabled!")
        return
      }
      // 1. Update main history list
      let historyEntry = addPlayback(id, duration: durationSec)

      // 2. IINA's [ancient] "resume last playback" feature
      // Add this now, or else welcome window will fall out of sync with history list
      if Preference.bool(for: .resumeLastPosition) {
        saveToLastPlayedFile(id, duration: durationSec, position: positionSec)
      } else {
        // May need to clear cached progress in case this pref was toggled from on to off during this launch
        MediaMetaCache.shared.updateCacheEntry(id, newDuration: durationSec, newProgress: nil)
      }

      if Preference.bool(for: .recordRecentFiles) {
        // 3. Workaround for File > Recent Documents getting cleared when it shouldn't
        if Preference.bool(for: .trackAllFilesInRecentOpenMenu) {
          HistoryController.shared.noteNewRecentDocumentURL(id.url)
        } else {
          /// This will get called by `noteNewRecentDocumentURL`. But if it's not called, need to call it
          /// so that welcome window is notified when `iinaLastPlayedFilePosition`, etc. are changed
          HistoryController.shared.postNotification(Notification(name: .recentDocumentsDidChange))
        }
      }
      if let historyEntry {
        reloadFileExistsAndProgress(forEntry: historyEntry)
      }
    }
  }

  /// Actually this is called when player is stopping, so needs to account for watch-later, which (if enabled)
  /// should have been written to prior to calling this function.
  func savePlaybackMetaBeforeFileWillClose(_ id: PlaybackID, duration: Double?, position: Double?) {
    guard historyEnabled else { return }
    if !started {
      log.verbose("While trying to save playback after file load: history not started! Starting now")
      start()
    }

    HistoryController.shared.async { [self] in
      guard historyEnabled else {
        log.error("Cannot save playback meta at file close: history is unexpectedly disabled!")
        return
      }
      saveToLastPlayedFile(id, duration: duration, position: position)

      // The rest of the stuff below relates to UI updates and should be cancelled if shutting down.
      guard !isAppTerminating else { return }

      guard let historyEntry = history.first(where: {$0.url == id.url}) else { return }

      // Ensure playlist is updated relatively quickly
      /// this will reload the `mpvProgress` field from the `watch-later` config files
      reloadFileExistsAndProgress(forEntry: historyEntry)
    }
  }

  private func saveToLastPlayedFile(_ id: PlaybackID?, duration: Double?, position: Double?) {
    guard let id else {
      log.warn("Cannot save iinaLastPlayedFilePath or iinaLastPlayedFilePosition: playback ID is nil!")
      return
    }

    // FIXME: remove `iinaLastPlayedFilePath` and `iinaLastPlayedFilePosition` - they are not compatible with welcome window list
    Preference.set(id.url, for: .iinaLastPlayedFilePath)
    if let position {
      log.verbose("Saving iinaLastPlayedFilePosition: \(position)s")
      Preference.set(position, for: .iinaLastPlayedFilePosition)
    } else {
      log.debug("No position found for file; writing 0 to iinaLastPlayedFilePosition for: \(id.path.pii.quoted)")
      Preference.set(0.0, for: .iinaLastPlayedFilePosition)
    }
    //////////////////

    // Write to cache directly (rather than calling `refreshCachedVideoProgress`).
    // If user only closed the window but didn't quit the app, this can make sure playlist displays the correct progress.
    MediaMetaCache.shared.updateCacheEntry(id, newDuration: duration, newProgress: position)
  }

  // MARK: - FileExists & Progress from watch-later

  func startAsyncReloadOfFileExistsAndProgress(forVersion historyListVersion: Int) {
    HistoryController.shared.async { [self] in
      let historyList = history
      fileExistsDQ.async { [self] in
        log.verbose("Starting fileExists work for \(historyList.count) entries, historyVersion=\(historyListVersion)")
        reloadFileExistsAndProgress(forList: historyList, startingAt: 0, withVersion: historyListVersion)
      }
    }
  }

  /// Fills in watch-later meta & the fileExists map for the given single history entry.
  /// NOTE: Unlike `reloadFileExistsAndProgress(forList:)`, this will overwrite any existing entry in the current `fileExistsMap`.
  private func reloadFileExistsAndProgress(forEntry entry: PlaybackHistory) {
    guard !isAppTerminating else { return }

    fileExistsDQ.async { [self] in
      guard !isAppTerminating else {return }
      let fileExists = _reloadFileExistsAndProgress(forEntry: entry)
      fileExistsMap[entry.url] = fileExists
    }
  }

  /// Returns true if entry is file and it was found to exist in the file system
  private func _reloadFileExistsAndProgress(forEntry entry: PlaybackHistory) -> Bool {
    let fileExists = !entry.url.isFileURL || FileManager.default.fileExists(atPath: entry.url.path)

    let watchLaterProgressEnabled = Preference.bool(for: .resumeLastPosition)

    if watchLaterProgressEnabled {
      let progressChanged = loadProgressFromWatchLater(entry)
      if progressChanged {
        // Notify History window + playlist UI in various windows
        MediaMetaCache.shared.postFileHistoryUpdateNotification(forURL: entry.url)
      }
    } else {
      var didClearCachedProgress = false
      if let cachedMediaMeta = MediaMetaCache.shared.getCachedMeta(for: entry.id), cachedMediaMeta.progress != nil {
        MediaMetaCache.shared.updateCacheEntry(entry.id, newDuration: cachedMediaMeta.duration, newProgress: Constants.unknownProgress)
        didClearCachedProgress = true
      }
      // Watch Later is no longer enabled, but its value is still cached?
      let oldProgress = entry.mpvProgress
      entry.mpvProgress = nil
      didClearCachedProgress = didClearCachedProgress || (oldProgress != nil)

      if didClearCachedProgress {
        // After clearing the cached value, notify the UI that it changed (e.g., playlist may need to hide
        // its progress bar)
        MediaMetaCache.shared.postFileHistoryUpdateNotification(forURL: entry.url)
      }
    }

    return fileExists
  }

  /// Fills in watch-later meta & the fileExists map for the given history entries.
  /// Skips over entries which already have values in the current `fileExistsMap` unless it determines that a full reload
  /// is due.
  private func reloadFileExistsAndProgress(forList historyList: [PlaybackHistory],
                                           startingAt startIndex: Int, withVersion historyVersion: Int) {
    // Put all FileManager stuff in fileExistsDQ. It can hang for a long time if there are network problems.
    // Network or file system can change over time and cause our info to become out of date.
    assert(DispatchQueue.isExecutingIn(fileExistsDQ))

    guard historyVersion == self.historyListVersion else {
      // Assume work will be enqueued for the new version. Don't process stale data
      log.verbose("Aborting fileExists task: historyVersion (\(historyVersion)) is not latest (\(self.historyListVersion))")
      return
    }

    guard !isAppTerminating else { return }

    // Do a full reload if too much time has gone by since the last full reload
    let forceFullStatusReload = Date().timeIntervalSince(lastCompleteStatusReloadTime) > Constants.TimeInterval.historyTableCompleteFileStatusReload
    let sw = Utility.Stopwatch()

    var fileExistsMapUpdated: [URL: Bool] = forceFullStatusReload ? [:] : fileExistsMap

    var examinedCount: Int = 0
    var processedCount: Int = 0
    var watchLaterCount: Int = 0
    for entry in historyList[startIndex...] {
      examinedCount += 1
      guard fileExistsMapUpdated[entry.url] == nil else { continue }
      guard !isAppTerminating else { break }

      let fileExists = _reloadFileExistsAndProgress(forEntry: entry)
      fileExistsMapUpdated[entry.url] = fileExists
      processedCount += 1

      let wasWatchLaterFound = entry.mpvProgress != nil
      if wasWatchLaterFound {
        watchLaterCount += 1
      }

      // Do not batch for more than 1sec at a time
      guard sw.secElapsed < 1.0 else { break }

      if (processedCount %% 50) == 0 {
        guard !isAppTerminating else { return }
        guard historyVersion == self.historyListVersion else {
          // Fall through and save progress before returning
          break
        }
      }
    }

    self.fileExistsMap = fileExistsMapUpdated
    log.trace("Filled in fileExists for \(processedCount) / \(examinedCount) histories (\(historyList.count - examinedCount - startIndex) remaining) in \(sw.secElapsedString), fullReload=\(forceFullStatusReload.yn) watchLater=\(watchLaterCount)")
    if forceFullStatusReload {
      lastCompleteStatusReloadTime = Date()
    }

    guard !isAppTerminating else {
      log.verbose("App is terminating; stopping fileExists work early")
      return
    }

    let newStartIndex = examinedCount + startIndex
    let completed = newStartIndex == historyList.count
    if completed {
      log.verbose("Done filling in fileExists map, \(fileExistsMap.count) entries. Notifying UI")
      postNotification(Notification(name: .iinaFileExistsInfoDidUpdate))
    } else {
      // Don't hog the queue; allow other tasks to finish & enqueue behind them:
      fileExistsDQ.async { [self] in
        reloadFileExistsAndProgress(forList: historyList, startingAt: newStartIndex, withVersion: historyVersion)
      }
    }
  }

  // This is a long-running operation. Load this asynchronously
  private func loadProgressFromWatchLater(_ historyEntry: PlaybackHistory) -> Bool {
    let progress = playbackProgressFromWatchLater(historyEntry.mpvMd5)
    let progressDidChange = progress != historyEntry.mpvProgress
    historyEntry.mpvProgress = progress

    if progressDidChange {
      // Copy from the old paradigm into the new...
      let newProgress = progress == nil ? Constants.unknownProgress : progress
      MediaMetaCache.shared.updateCacheEntry(historyEntry.id, newDuration: historyEntry.duration, newProgress: newProgress)
    }
    return progressDidChange
  }

  /// Returns saved playback progress (in seconds) or `nil` if not found in `watch-later` data.
  func playbackProgressFromWatchLater(_ mpvMd5: String) -> Double? {
    // No point in loading/showing this if it's not used
    guard Preference.bool(for: .resumeLastPosition) else { return nil }

    let fileURL = Utility.watchLaterURL.appendingPathComponent(mpvMd5)
    if let reader = StreamReader(path: fileURL.path),
       let firstLine = reader.nextLine(),
       firstLine.hasPrefix("start="),
       let progressString = firstLine.components(separatedBy: "=").last,
       let progress = Double(progressString) {
      return progress
    } else {
      return nil
    }
  }


  // MARK: - Notifications

  func postNotification(_ notification: Notification) {
    /// Launch async on main thread to prevent deadlock. We don't know what thread we are coming from, or
    /// which queue the observers are waiting on. If the two are different, it looks like `NotificationCenter.default.post`
    /// can deadlock the two threads.
    DispatchQueue.main.async {
      guard !AppDelegate.shared.isTerminating else { return }
      NotificationCenter.default.post(notification)
    }
  }

  // TODO: terribly inefficient. History DB needs complete rework
  func history(forURL url: URL) -> PlaybackHistory? {
    let historyList = history
    return historyList.first(where: { $0.url == url })
  }
}

