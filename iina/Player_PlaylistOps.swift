//
//  Player_PlaylistOps.swift
//  iina
//
//  Created by Matt Svoboda on 2025-05-26.
//  Copyright © 2025 lhc. All rights reserved.
//

// mpv: Playlist Operations

extension PlayerCore {

  enum UndoOption {
    /// Executes the associated operation but do not register a new undo. Use this for the initial operation, or if undo / redo
    /// is being handled elsewhere.
    case ignoreUndoRedo

    /// After executing the associated operation, calls the `registerUndo` method of the window's `UndoManager` to make it undoable within the window.
    /// The undo operation will also be set to call `UndoManager.registerUndo`, so that it is redoable.
    case registerUndoRedo

    /// Clear the undo stack of the window's `UndoManager`. Use this if the operation cannot be undone, e.g. if hard-deleting a file,
    /// or if an error occurred which left the undo stack in an uncertain state.
    case clearUndoStack
  }

  // MARK: - Insert / Add / Append

  /// Moves the given items so that they are immediately following the now-playing item
  /// (i.e. they will be next in the queue).
  func playNextInPlaylist(_ playlistItemIndexes: IndexSet) {
    mpv.queue.async { [self] in
      let current = mpv.getInt(MPVProperty.playlistPos)
      movePlaylistRows(from: playlistItemIndexes, to: current + 1, .registerUndoRedo)
    }
  }

  /// For restore, or auto-load. Adds all the media in `pathList` to the current playlist, except for the now-playing item.
  /// Each item in `pathList` may be either a file path or a network URL.
  ///
  /// • The current mpv core is expected to have only this item in its playlist at the time of this operation. If additional
  ///   items are present in the playlist, they will get pushed to the top or to the bottom of the playlist.
  /// • This inserts around the currently playing item is in the list, so that it may end up at `indexOfCurrentItem`
  ///   (if provided), which may be in the middle of the playlist.
  func _addAllToPlaylist(pathListIncludingCurrent pathList: [String], indexOfCurrentItem currentItemExplicitIndex: Int? = nil) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    // This checks for !isStopping, so we don't have to
    guard _reloadPlaylistAndReturn() != nil else { return }

    if info.playlist.count != 1 {
      log.debug("[Playlist] Expected exactly 1 item in playlist before bulk-add, but found \(info.playlist.count). Some items may be out of order afterwards")
    }

    let currentItem: Int
    if let currentItemExplicitIndex {
      // Newer versions should include this info
      currentItem = currentItemExplicitIndex
    } else if let currentPath = info.currentPlayback?.path {
      if let firstMatchingIndex = pathList.firstIndex(of: currentPath) {
        // Try to derive current item index.
        // Use index of first match found. If there are duplicate paths in the playlist, this will be wrong,
        // but older versions of IINA did not support duplicates in the playlist, so shouldn't be an issue.
        currentItem = firstMatchingIndex
      } else {
        log.warn("[Playlist] Playlist (count=\(info.playlist.count) items) does not contain currently playing item (\(currentPath.pii.quoted))")
        currentItem = -1
      }
    } else {
      log.warn("[Playlist] Cannot determine current item index: currentPlayback is nil!")
      assert(false, "currentPlayback should never be nil if used properly!")
      currentItem = -1
    }

    let itemsAtInsertIndexes: [(Int, String)] = pathList.enumerated().compactMap { index, path in
      // skip current item bc it's already present in playlist
      if index == currentItem { return nil }
      // Insert in 2 blocks: before & after current item, respectively
      return (index < currentItem ? 0 : 1, path)
    }

    _playlistInsert(itemsAtIndexes: itemsAtInsertIndexes, info.playlist, onSuccess: { [self] in
      log.verbose("[Playlist] Done adding \(pathList.count) items. Playlist count is now \(info.playlist.count)")
      _reloadPlaylist(savePlayerState: false)  // will send notification
      DispatchQueue.main.async { [self] in
        guard pwc.loaded else { return }
        pwc.playlistView.scrollPlaylistToCurrentItem()
      }
    })
  }

  func appendToPlaylist(_ path: String,
                        onSuccess: OnSuccessCallback? = nil, onError: OnErrorCallback? = nil) {
    appendToPlaylist([path], onSuccess: onSuccess, onError: onError)
  }

  func appendToPlaylist(_ paths: [String],
                        onSuccess: OnSuccessCallback? = nil, onError: OnErrorCallback? = nil) {
    addToPlaylist(paths: paths, onSuccess: onSuccess, onError: onError, .registerUndoRedo)
  }

  func appendToPlaylist(urls: any Collection<URL>,
                        onSuccess: OnSuccessCallback? = nil, onError: OnErrorCallback? = nil) {
    let paths = urls.map({PlaybackID.path(from: $0)})
    addToPlaylist(paths: paths, onSuccess: onSuccess, onError: onError, .registerUndoRedo)
  }

  func addToPlaylist(paths: [String], at targetRowIndex: Int? = nil,
                     onSuccess: OnSuccessCallback? = nil, onError: OnErrorCallback? = nil,
                     _ undoOption: UndoOption) {

    let rowList = paths.compactMap{PlaybackID(path: $0)}
    insertPlaylistRows(rowList, at: targetRowIndex, undoOption)
  }

  /// All playlist "insert" operations should ultimately call this method.
  func insertPlaylistRows(_ desiredRowList: [PlaybackID], at targetRowIndex: Int? = nil, _ undoOption: UndoOption) {
    let playableFiles = getPlayableFiles(in: desiredRowList.map{ $0.url })
    guard playableFiles.count > 0 else { return }
    let rowList = playableFiles.map { PlaybackID($0) }
    log.verbose("[Playlist] Inserting \(rowList.count) rows at index \(targetRowIndex?.description ?? "nil"): \(rowList.map{$0.path.pii})")
    let expectedCurrentPlaylist = displayedPlaylist  // make sure user is moving what they expect!

    let (tableUIChange, allItemsNew) = pwc.playlistView.isViewLoaded
    ? pwc.playlistView.playlistTableView.buildInsert(of: rowList, at: targetRowIndex, in: expectedCurrentPlaylist)
    : TableUIChangeBuilder.shared.buildInsert(of: rowList, at: targetRowIndex ?? displayedPlaylist.count, in: expectedCurrentPlaylist)

    let playlistSize = expectedCurrentPlaylist.count
    var insertStartIndex = targetRowIndex ?? playlistSize
    insertStartIndex = (insertStartIndex >= 0 && insertStartIndex <= playlistSize) ? insertStartIndex : playlistSize
    let paths = rowList.map { $0.path }
    let itemsAtIndexes = paths.map ({ path in (insertStartIndex, path)} )

    mpv.queue.async { [self] in
      _playlistInsert(itemsAtIndexes: itemsAtIndexes, expectedCurrentPlaylist, onSuccess: { [self] in
        displayedPlaylist = info.playlist                                          // update cached data
        tableUIChange.postNotification(name: playlistTableChangeNotificationName)  // update UI
        sendOSD(.addToPlaylist(paths.count))

        // Register undo/redo for this action?
        switch undoOption {
        case .ignoreUndoRedo:
          break
        case .clearUndoStack:
          log.debug("[Playlist] Clearing undo stack for playlist after 'insert'")
          DispatchQueue.main.async { [self] in
            undoHelper.clearUndoes()
          }
        case .registerUndoRedo:
          DispatchQueue.main.async { [self] in
            let actionName = undoHelper.buildActionName(basedOn: tableUIChange)
            undoHelper.register(actionName, undo: { [self] in
              mpv.queue.async { [self] in
                guard validateItemsAreEqual(displayedPlaylist, allItemsNew) else {
                  log.error("[Playlist] Cannot undo insert: playlist is in unexpected state! Clearing undo stack & aborting.")
                  playlistErrorDidOccur()
                  return
                }
                let rmStartIndex = tableUIChange.toInsert!.first!
                let rmEndIndex = rmStartIndex + rowList.count
                let rowIndexesToRemove = IndexSet(rmStartIndex..<rmEndIndex)
                DispatchQueue.main.async { [self] in
                  removePlaylistRows(rowIndexesToRemove, .ignoreUndoRedo)
                }
              }
            }, redo: { [self] in
              insertPlaylistRows(rowList, at: targetRowIndex, .ignoreUndoRedo)
            })
          }
        }
      })

    }  // end mpv.queue.async

  }

  /// Insert playlist items at mapped indexes. Internal: should *only* be called by `insertPlaylistRows` or by
  /// other non-private `PlayerCore` methods.
  /// - `itemsAtIndexes` must be in ascending index order.
  func _playlistInsert(itemsAtIndexes: [(Int, String)],
                       _ expectedCurrentPlaylist: [PlaybackID]? = nil,
                       onSuccess: OnSuccessCallback? = nil) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    log.verbose("[Playlist] Insert requested: \(itemsAtIndexes.count) total items @ mpvIndexes=\(itemsAtIndexes.map(\.0))")

    // Verify playlist state first before changing anything
    let expectedPlaylistBeforeInsert = expectedCurrentPlaylist ?? info.playlist
    guard syncAndValidatePlaylist(expectedPlaylist: expectedPlaylistBeforeInsert) else { return }

    // Insert at playlist.count => append
    for (itemsAtIndexIndex, itemsAtIndex) in itemsAtIndexes.enumerated() {
      guard (itemsAtIndex.0 >= 0) && (itemsAtIndex.0 <= info.playlist.count + itemsAtIndexIndex) else {
        log.error("[Playlist] Cannot insert items: 1 or more indexes are out of bounds! Indexes=\(itemsAtIndexes.map(\.0)) PlaylistSize=\(info.playlist.count)")
        playlistErrorDidOccur()
        return
      }
    }
    var expectedPlaylistAfterInsert = expectedPlaylistBeforeInsert
    var prevInsertCount = 0
    for (itemToInsertIndex, itemToInsertPath) in itemsAtIndexes {
      let insertIndex = itemToInsertIndex + prevInsertCount
      let returnCode = mpv.playlistInsert(itemToInsertPath, index: insertIndex)
      guard returnCode == 0 else {
        playlistErrorDidOccur(returnCode, opDesc: "insert playlist item \(prevInsertCount) / \(itemsAtIndexes.count)")
        return
      }
      guard let playbackInserted = PlaybackID(path: itemToInsertPath) else {
        log.error("[Playlist] Failed to create PlaybackID from item path (will cancel remaining inserts): path=\(itemToInsertPath)")
        playlistErrorDidOccur()
        return
      }
      expectedPlaylistAfterInsert.insert(playbackInserted, at: insertIndex)
      prevInsertCount += 1
    }

    // Now verify playlist state again to ensure changes were correct
    guard syncAndValidatePlaylist(expectedPlaylist: expectedPlaylistAfterInsert) else { return }

    saveState()
    if let onSuccess {
      _ = onSuccess()
    }
  }

  // MARK: - Move

  func playlistMove(_ fromIndex: Int, to targetRowIndex: Int) {
    movePlaylistRows(from: IndexSet(integer: fromIndex), to: targetRowIndex, .registerUndoRedo)
  }

  func movePlaylistRows(from rowIndexes: IndexSet, to insertIndex: Int, _ undoOption: UndoOption) {
    let (tableUIChange, allItemsNew) = TableUIChangeBuilder.shared.buildMove(rowIndexes, to: insertIndex, in: displayedPlaylist)
    let allItemsOld = displayedPlaylist  // save in case of undo

    let moveIndexPairs = buildMpvMoveIndexPairs(from: rowIndexes, to: insertIndex)
    log.verbose("[Playlist] Moving indexes=\(rowIndexes.toArray()) → \(insertIndex); indexPairs=\(moveIndexPairs)")

    playlistMoveIndexPairs(moveIndexPairs, expectedPlaylistBefore: allItemsOld, expectedPlaylistAfter: allItemsNew,
                           onSuccess: { [self] in
      displayedPlaylist = info.playlist                                          // Update cached data
      tableUIChange.postNotification(name: playlistTableChangeNotificationName)  // notify UI

      switch undoOption {
      case .ignoreUndoRedo:
        break
      case .clearUndoStack:
        DispatchQueue.main.async { [self] in
          log.debug("[Playlist] Clearing undo stack after 'move'")
          undoHelper.clearUndoes()
        }
      case .registerUndoRedo:
        DispatchQueue.main.async { [self] in
          undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
            log.verbose("[Playlist] Requested: undo move of \(rowIndexes.count) items")

            // Builds an insert. Unlike the undo for `insertPlaylistRows()`, this is non-trivial because the original deleted items
            // can be at non-contiguous indexes in the playlist.
            let tableUIChangeUndo = tableUIChange.inverted(selectNextRowAfterDelete: playlistTableSelectNextRowAfterDelete)
            // FIXME: there is a bug here
            let undoMoveIndexPairs = buildInvertedMpvMoveIndexPairs(from: rowIndexes, to: insertIndex, movePairs: moveIndexPairs)

            log.verbose("[Playlist] Undo move (original op: move rows=\(rowIndexes.toArray()) → \(insertIndex); undoMoveIndexPairs=\(undoMoveIndexPairs))")
            playlistMoveIndexPairs(undoMoveIndexPairs, expectedPlaylistBefore: allItemsNew, expectedPlaylistAfter: allItemsOld,
                                   onSuccess: { [self] in
              displayedPlaylist = info.playlist                                              // Update cached data
              tableUIChangeUndo.postNotification(name: playlistTableChangeNotificationName)  // notify UI
            })
          }, redo: { [self] in
            mpv.queue.async { [self] in
              // Make sure this is an exact same redo! Need to run this in mpv queue to avoid races
              guard syncAndValidatePlaylist(expectedPlaylist: allItemsOld) else { return }

              DispatchQueue.main.async { [self] in
                movePlaylistRows(from: rowIndexes, to: insertIndex, .ignoreUndoRedo)
              }
            }
          })
        }
      }

    })
  }

  /// Drag & drop within `playlistTableView`. Should be called only by `movePlaylistRows`.
  private func playlistMoveIndexPairs(_ indexPairs: [(Int, Int)],
                                      expectedPlaylistBefore: [PlaybackID],
                                      expectedPlaylistAfter: [PlaybackID],
                                      onSuccess: @escaping OnSuccessCallback) {
    mpv.queue.async { [self] in
      log.debug("[Playlist] Executing move of (src,dst) indexPairs=\(indexPairs)")

      // Verify playlist state first before changing anything. This will take proper steps on failure, so just return in that case.
      guard syncAndValidatePlaylist(expectedPlaylist: expectedPlaylistBefore) else { return }

      for (srcIndex, dstIndex) in indexPairs {
        let returnCode = mpv.playlistMove(srcIndex, to: dstIndex)
        guard returnCode == 0 else {
          return playlistErrorDidOccur(returnCode, opDesc: "move playlist item \(srcIndex) → \(dstIndex)")
        }
      }

      guard syncAndValidatePlaylist(expectedPlaylist: expectedPlaylistAfter) else {
        if log.isVerboseEnabled {
          let tableChangeExpected = TableUIChangeBuilder.shared.buildDiff(oldRows: expectedPlaylistBefore,
                                                                          newRows: expectedPlaylistAfter)
          let tableChangeActual = TableUIChangeBuilder.shared.buildDiff(oldRows: expectedPlaylistBefore,
                                                                        newRows: info.playlist)
          let expStr: String = tableChangeExpected.toMove?.compactMap{"\($0.0) → \($0.1)"}.joined(separator: "\n") ?? "nil"
          let actStr: String = tableChangeActual.toMove?.compactMap{"\($0.0) → \($0.1)"}.joined(separator: "\n") ?? "nil"
          log.warn("[Playlist] Mismatch after MOVE:\nEXPECTED:\n\(expStr)\n\nACTUAL:\n\(actStr)")
        }
        return
      }

      // Success!
      saveState()
      onSuccess()
    }

  }

  /// The arguments for mpv's `playlist-move` command are slightly different than Cocoa's
  /// `NSTableView.moveRow` command. If row's source index is above the insert index, Cocoa requires an
  /// extra -1 subtracted from its destination index, whereas mpv does not.
  ///
  /// See `TableUIChangeBuilder.buildMove` for the Cocoa version.
  private func buildMpvMoveIndexPairs(from rowIndexes: IndexSet, to insertIndex: Int) -> [(Int, Int)] {
    var moveIndexPairs: [(Int, Int)] = []
    var moveFromOffset = 0
    var moveToOffset = 0
    for origIndex in rowIndexes {
      if origIndex < insertIndex {
        moveIndexPairs.append((origIndex + moveFromOffset, insertIndex))
        moveFromOffset -= 1
      } else {
        moveIndexPairs.append((origIndex, insertIndex + moveToOffset))
        moveToOffset += 1
      }
    }
    return moveIndexPairs
  }

  /// Given the arguments for a list of mpv `playlist-move` commands which were executed together to rearrange playlist rows,
  /// returns a list of "inverted" (src, dst) index pairs which can be used to undo the first list of commands.
  /// * `rowIndexes`, `insertIndex`: source indexes & insert index args from the original "move" operation.
  /// * `movePairs`: mpv (source, destination) pairs created by `buildMpvMoveIndexPairs()`.
  private func buildInvertedMpvMoveIndexPairs(from rowIndexes: IndexSet, to insertIndex: Int,
                                              movePairs: [(Int, Int)]) -> [(Int, Int)] {
    var movePairsInverted: [(Int, Int)] = []

    var undoSrcOffset = 0
    var undoDstOffset = 0
    for (origIndex, (_, opDstIndex)) in zip(rowIndexes, movePairs).reversed() {
      if origIndex < insertIndex {
        undoSrcOffset -= 1
        movePairsInverted.append((opDstIndex + undoSrcOffset, origIndex))
      } else {
        undoDstOffset += 1
        movePairsInverted.append((opDstIndex + undoSrcOffset, origIndex + undoDstOffset))
      }
    }
    return movePairsInverted.reversed()
  }


  // MARK: - Remove

  func playlistRemove(_ index: Int, _ undoOption: UndoOption) {
    playlistRemove(IndexSet(integer: index), undoOption)
  }

  func playlistRemove(_ indexSet: IndexSet,_ undoOption: UndoOption) {
    removePlaylistRows(indexSet, undoOption)
  }

  func removePlaylistRows(_ rowIndexes: IndexSet, _ undoOption: UndoOption) {
    guard !rowIndexes.isEmpty else { return }

    let (tableUIChange, allItemsNew) = TableUIChangeBuilder.shared.buildRemove(rowIndexes, in: displayedPlaylist,
                                                                         selectNextRowAfterDelete: playlistTableSelectNextRowAfterDelete)
    let allItemsOld = displayedPlaylist     // save in case of undo

    mpv.queue.async { [self] in
      log.verbose("[Playlist] Remove requested: mpvIndexes=\(rowIndexes.map{$0})")

      guard syncAndValidatePlaylist(expectedPlaylist: allItemsOld) else { return }

      // Remove playlist items one at a time, from top to bottom (increasing index).
      // After an item is removed, the indexes of all items below it are subtracted by 1.
      var countRemoved = 0
      for origIndex in rowIndexes {
        let index = origIndex - countRemoved
        log.verbose("[Playlist] Sending mpv remove cmd for row \(index)")
        let returnCode = mpv.playlistRemove(index)
        // If error occurred, report using callback, reload state, and do not continue
        guard returnCode == 0 else {
          return playlistErrorDidOccur(returnCode, opDesc: "remove playlist item \(countRemoved) / \(rowIndexes.count)")
        }
        countRemoved += 1
      }

      guard syncAndValidatePlaylist(expectedPlaylist: allItemsNew) else { return }
      displayedPlaylist = info.playlist                                          // update cached data
      tableUIChange.postNotification(name: playlistTableChangeNotificationName)  // update UI
      sendOSD(.removeFromPlaylist(countRemoved))
      saveState()

      // Register undo/redo?
      switch undoOption {
      case .ignoreUndoRedo:
        break
      case .clearUndoStack:
        DispatchQueue.main.async { [self] in
          log.debug("[Playlist] Clearing undo stack after 'remove'")
          undoHelper.clearUndoes()
        }
      case .registerUndoRedo:
        DispatchQueue.main.async { [self] in  // Must reference UndoManager only in main(?)
          undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
            mpv.queue.async { [self] in
              // Builds an insert. Unlike the undo for `insertPlaylistRows()`, this is non-trivial because the original deleted items
              // can be at non-contiguous indexes in the playlist.
              let indexedInsertItems = rowIndexes.enumerated().map{ ($0.element - $0.offset, allItemsOld[$0.element].path) }
              assert(indexedInsertItems.map(\.0).sorted(by: { $0 < $1 }).elementsEqual(indexedInsertItems.map(\.0)),
                     "itemsAtIndexes must be sorted in ascending order, but found: \(indexedInsertItems.map(\.0))")
              let tableUIChangeUndo = tableUIChange.inverted(selectNextRowAfterDelete: playlistTableSelectNextRowAfterDelete)

              _playlistInsert(itemsAtIndexes: indexedInsertItems, allItemsNew, onSuccess: { [self] in
                displayedPlaylist = info.playlist                                              // update cached data
                tableUIChangeUndo.postNotification(name: playlistTableChangeNotificationName)  // update UI
                sendOSD(.addToPlaylist(indexedInsertItems.count))
              })
            }
          }, redo: { [self] in
            // Almost the same code as above. But don't want to re-register an undo action
            removePlaylistRows(rowIndexes, .ignoreUndoRedo)
          })
        }
      }
    }
  }

  func playlistReorder(newPlaylist newPlaylistRows: [PlaybackID], _ undoOption: UndoOption = .registerUndoRedo) {
    let oldPlaylistRows = info.playlist

    guard Set(oldPlaylistRows) == Set(newPlaylistRows) else { return }
    if oldPlaylistRows == newPlaylistRows { return }

    let tableUIChange = TableUIChangeBuilder.shared.buildDiff(oldRows: oldPlaylistRows, newRows: newPlaylistRows)

    mpv.queue.async { [self] in
      guard syncAndValidatePlaylist(expectedPlaylist: oldPlaylistRows) else { return }
      log.verbose("[Playlist] Reorder playlist requested")

      let clearRC = mpv.command(.playlistClear)
      guard clearRC == 0 else {
        return playlistErrorDidOccur(clearRC, opDesc: "clear playlist to reorder")
      }

      guard let currentURL = info.currentPlayback?.url, let currentPlaying = newPlaylistRows.firstIndex(where: { $0.url == currentURL } ) else {
        for item in newPlaylistRows {
          let returnCode = mpv.playlistAppend(item.path)
          guard returnCode == 0 else {
            return playlistErrorDidOccur(returnCode, opDesc: "reorder playlist (with no currentURL)")
          }
        }
        return
      }

      for i in (0..<currentPlaying).reversed() {
        let returnCode = mpv.playlistInsert(newPlaylistRows[i].path, index: 0)
        guard returnCode == 0 else {
          return playlistErrorDidOccur(returnCode, opDesc: "insert to reorder playlist")
        }
      }
      for i in currentPlaying + 1..<newPlaylistRows.count {
        let returnCode = mpv.playlistAppend(newPlaylistRows[i].path)
        guard returnCode == 0 else {
          return playlistErrorDidOccur(returnCode, opDesc: "append to reorder playlist")
        }
      }

      guard syncAndValidatePlaylist(expectedPlaylist: newPlaylistRows) else { return }

      displayedPlaylist = info.playlist                                          // update cached data
      tableUIChange.postNotification(name: playlistTableChangeNotificationName)  // update UI
      postNotification(.iinaPlaylistChanged)
      saveState()

      // Register undo/redo?
      switch undoOption {
      case .ignoreUndoRedo:
        break
      case .clearUndoStack:
        DispatchQueue.main.async { [self] in
          log.debug("[Playlist] Clearing undo stack after 'remove'")
          undoHelper.clearUndoes()
        }
      case .registerUndoRedo:
        DispatchQueue.main.async { [self] in
          undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
            mpv.queue.async { [self] in
              playlistReorder(newPlaylist: oldPlaylistRows, .ignoreUndoRedo)
            }
          }, redo: { [self] in
            // Don't want to re-register an undo action
            playlistReorder(newPlaylist: newPlaylistRows, .ignoreUndoRedo)
          })
        }
      }
    }
  }

  // MARK: - Reload

  /// Reloads playlist from mpv, then enqueues state save & sends `iinaPlaylistChanged` notification.
  func reloadPlaylist(thenPostNotification: Bool = true, savePlayerState: Bool = true) {
    mpv.queue.async { [self] in
      _reloadPlaylist(thenPostNotification: thenPostNotification, savePlayerState: savePlayerState)
    }
  }

  func _reloadPlaylist(thenPostNotification: Bool = true, savePlayerState: Bool = true) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isStopping else { return }

    guard _reloadPlaylistAndReturn() != nil else { return }

    if thenPostNotification {
      postNotification(.iinaPlaylistChanged)
    }

    if savePlayerState {
      saveState()  // save playlist URLs to prefs
    }
  }

  /// 1. Gets the up-to-date playlist & `playlist-pos` (now playing item index) from mpv.
  /// 2. Updates `info.playlist` & `info.currentPlayback?.playlistPos`.
  /// 3. Returns the up-to-date playlist (or `nil` on error or incorrect state).
  func _reloadPlaylistAndReturn() -> [PlaybackID]? {
    assert(DispatchQueue.isExecutingIn(mpv.queue))
    guard !isStopping else { return nil }

    var newPlaylist: [PlaybackID] = []
    let playlistCount = mpv.getInt(MPVProperty.playlistCount)
    log.verbose("[Playlist] Reloading with \(playlistCount) items")
    for index in 0..<playlistCount {
      let urlPath = mpv.getString(MPVProperty.playlistNFilename(index))!
      guard let playlistItem = PlaybackID(path: urlPath) else {
        log.error("[Playlist] Item has invalid path, skipping: \(urlPath.pii.quoted)")
        continue
      }
      newPlaylist.append(playlistItem)
    }

    let mpvPlaylistPos = mpv.getInt(MPVProperty.playlistPos)
    if let playback = info.currentPlayback {
      info.currentPlayback = playback.clone(playlistPos: mpvPlaylistPos)
    }
    info.playlist = newPlaylist
    log.verbose("[Playlist] After reloading: playlistPos=\(mpvPlaylistPos)")

    return newPlaylist
  }

  // MARK: - Other playlist ops

  func clearPlaylist() {
    mpv.queue.async { [self] in
      guard !isStopping else { return }
      log.verbose("[Playlist] Sending 'playlist-clear' cmd to mpv")
      mpv.command(.playlistClear, checkError: false)
      _reloadPlaylist()
      DispatchQueue.main.async { [self] in
        log.verbose("[Playlist] Clearing undo stack after 'playlist-clear' cmd")
        undoHelper.clearUndoes()
      }
    }
  }

  func playFile(_ path: String) {
    mpv.queue.async { [self] in
      guard !isStopping else { return }
      info.shouldAutoLoadFiles = true
      let returnCode = mpv.command(.loadfile, args: [path, "replace"], checkError: false)
      guard returnCode == 0 else {
        // TODO: report error
        return
      }
      _reloadPlaylist()
    }
  }

  func playFileInPlaylist(_ pos: Int) {
    mpv.queue.async { [self] in
      guard !isStopping else { return }
      log.verbose("[Playlist] Changing mpv playlist-pos to \(pos)")
      mpv.setInt(MPVProperty.playlistPos, pos)
    }
  }

  func navigateInPlaylist(nextMedia: Bool) {
    mpv.queue.async { [self] in
      guard !isStopping else { return }
      if nextMedia {
        mpv.command(.playlistNext, checkError: false)
      } else {
        // Prev
        let playlistPos = mpv.getInt(MPVProperty.playlistPos)
        if playlistPos == 0 {
          seek(absoluteSecond: 0)
        } else {
          mpv.command(.playlistPrev, checkError: false)
        }
      }
    }
  }

  // MARK: - Utils

  private func validateItemsAreEqual(_ p1: [PlaybackID], _ p2: [PlaybackID]) -> Bool {
    let p1Paths = p1.map{ $0.path }
    return (p1.count == p2.count) && p2.map({$0.path}).elementsEqual(p1Paths)
  }

  private func syncAndValidatePlaylist(expectedPlaylist: [PlaybackID]) -> Bool {
    guard let actualPlaylist = _reloadPlaylistAndReturn() else {
      return false
    }

    if validateItemsAreEqual(actualPlaylist, expectedPlaylist) {
      log.trace("[Playlist] Playlist validation passed")
      return true
    } else {
      log.error("[Playlist] Playlist mismatch! Will clear undo stack to prevent further issues")
      playlistErrorDidOccur()
      return false
    }
  }

  private func playlistErrorDidOccur(_ returnCode: Int32, opDesc: String) {
    let errorString = mpv.errorString(returnCode)
    log.error("[Playlist] Failed to \(opDesc) (will clear undo stack): \(errorString)")
    playlistErrorDidOccur()
  }

  private func playlistErrorDidOccur() {
    DispatchQueue.main.async { [self] in
      undoHelper.clearUndoes()
      reloadPlaylist(savePlayerState: false)
      // TODO: beep
    }
  }

}
