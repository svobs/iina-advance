//
//  TableUIChange.swift
//  iina
//
//  Created by Matt Svoboda on 9/29/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

/// Each instance of this class:
/// • Represents an atomic state change to the UI of an associated `EditableTableView`
/// • Contains all the metadata (though not the actual data) needed to transition from {State_N} to {State_N+1}, where each state refers
///   to a single user action or the response to some external update. All of thiis is needed in order to make AppKit animations work.
///
/// In order to facilitate table animations, and to get around some AppKit limitations such as the tendency
/// for it to lose track of the row selection, much additional boilerplate is needed to keep track of state.
/// This objects attempts to provide as much of this as possible and provide future reusability.
struct TableUIChange: Sendable {

  // MARK: - Static definitions

  typealias CompletionHandler = @Sendable @MainActor (TableUIChange) -> Void

  enum ContentChangeType {
    case removeRows

    case insertRows

    case moveRows

    case updateRows

    // No changes to content, but can specify changes to metadata (selection change, completionHandler, ...)
    case none

    // Due to AppKit limitations (removes selection, disables animations, seems to send extra events)
    // use this only when absolutely needed:
    case reloadAll

    // Can have any number of inserts, removes, moves, and updates:
    case wholeTableDiff
  }

  // MARK: - Instance Vars

  // Required
  let changeType: ContentChangeType

  let toRemove: IndexSet?
  let toInsert: IndexSet?
  let toUpdate: IndexSet?
  /// Used by `ContentChangeType.moveRows`. Ordered list of pairs of (fromIndex, toIndex)
  let toMove: [(Int, Int)]?

  /// `NSTableView` already updates previous selection indexes if added/removed rows cause them to move.
  /// To select added rows, or select next index after remove, etc, will need an explicit call to update selection afterwards.
  /// Will not call to update selection if this is nil.
  let newSelectedRowIndexes: IndexSet?

  /// MARK: - Optional vars

  /// Provide this to restore old selection when calculating the inverse of this change (when doing an undo of "move").
  // TODO: (optimization) figure out how to calculate this from `toMove` instead of storing this
  let oldSelectedRowIndexes: IndexSet?

  /// Optional animations
  let flashBefore: IndexSet?
  let flashAfter: IndexSet?

  /// Animation overrides. Leave nil to use the value from the table
  let rowInsertAnimation: NSTableView.AnimationOptions?
  let rowRemoveAnimation: NSTableView.AnimationOptions?

  /// If true, reload all existing rows after executing the primary differences (to cover the case that one of them may have changed)
  let reloadAllExistingRows: Bool

  /// If true:
  /// • If there are selected row(s), scroll the table so that the first selected row is visible to the user.
  /// • Else if there are inserted rows, scroll the table so that the last inserted row is visible
  /// Does this after `reloadAllExistingRows` but before `completionHandler`.
  let scrollToShowChangedRow: Bool

  /// A method which, if supplied, is called at the end of execute()
  let completionHandler: TableUIChange.CompletionHandler?

  var log: any Logger.Subsystem { Logger.log }

  var hasRemove: Bool {
    if let toRemove {
      return !toRemove.isEmpty
    }
    return false
  }

  var hasInsert: Bool {
    if let toInsert {
      return !toInsert.isEmpty
    }
    return false
  }

  var hasMove: Bool {
    if let toMove {
      return !toMove.isEmpty
    }
    return false
  }

  var hasSelectionAfterChange: Bool {
    if let newSelectedRowIndexes {
      return !newSelectedRowIndexes.isEmpty
    }
    return false
  }

  init(_ changeType: ContentChangeType,
       toRemove: IndexSet? = nil,
       toInsert: IndexSet? = nil,
       toUpdate: IndexSet? = nil,
       toMove: [(Int, Int)]? = nil,
       newSelectedRowIndexes: IndexSet? = nil,
       oldSelectedRowIndexes: IndexSet? = nil,
       useFlashForChangedRows: Bool = false,
       flashAfter: IndexSet? = nil,
       rowInsertAnimation: NSTableView.AnimationOptions? = nil,
       rowRemoveAnimation: NSTableView.AnimationOptions? = nil,
       reloadAllExistingRows: Bool = false,
       scrollToShowChangedRow: Bool = true,
       completionHandler: TableUIChange.CompletionHandler? = nil) {
    self.changeType = changeType
    self.toRemove = toRemove
    self.toInsert = toInsert
    self.toUpdate = toUpdate
    self.toMove = toMove
    self.newSelectedRowIndexes = newSelectedRowIndexes
    // to help restore selection on undo
    self.oldSelectedRowIndexes = oldSelectedRowIndexes

    // If useFlashForChangedRows==true, set up a flash animation to make it clear which rows were updated or removed.
    // Don't need to worry about moves & inserts, because those will be highlighted.
    self.flashBefore = useFlashForChangedRows ? toRemove : nil
    self.flashAfter = flashAfter

    self.rowInsertAnimation = rowInsertAnimation
    self.rowRemoveAnimation = rowRemoveAnimation
    self.reloadAllExistingRows = reloadAllExistingRows
    self.scrollToShowChangedRow = scrollToShowChangedRow
    self.completionHandler = completionHandler
  }

  // MARK: - Execute

  @MainActor
  func execute(on tableView: EditableTableView) {
    let log = tableView.log
    var animationTasks: [IINAAnimation.Task] = []

    // 2. Perform row update animations
    var flashCount = 0

    // 1. "Before" animations (if provided)
    if let flashBefore, !flashBefore.isEmpty {
      flashCount += 1
      animationTasks.append(.init(duration: Constants.AnimationDuration.tableUIFlash) { [self] in
        // Doesn't matter the Task animation duration; it will be changed inside animateFlash()
        let context = NSAnimationContext.current
        log.verbose("Flashing rows before animation: \(flashBefore.map({$0}))")
        animateFlash(forIndexes: flashBefore, in: tableView, context)
      })
    }

    if (!(flashAfter == nil || flashAfter!.isEmpty)) {
      flashCount += 1
    }

    // Strive for a consistent animation duration for all operations.
    // Operations such as "remove" may have a flash animation which takes some time, so subtract from this animation to compensate
    let duration = max(0.0, Constants.AnimationDuration.tableUIChange - (CGFloat(flashCount) * Constants.AnimationDuration.tableUIFlash))
    animationTasks.append(.init(duration: duration) { [self] in
      executeRowUpdates(on: tableView)

      if let newSelectedRowIndexes {
        log.verbose("TableUIChange: changing row selection (\(newSelectedRowIndexes.count) rows)")
        tableView.selectApprovedRowIndexes(newSelectedRowIndexes)
      } else {
        log.trace("TableUIChange: no change to row selection")
      }
    })


    // track this so we don't do it more than once (it fires the selectionChangedListener every time)
    let wantsReloadOfExistingRows: Bool
    if changeType == .reloadAll {
      // Don't reload twice
      wantsReloadOfExistingRows = false
    } else if reloadAllExistingRows || changeType == .updateRows || (!(toUpdate?.isEmpty ?? true)) {
      // Just schedule a reload for all of them. This is a very inexpensive operation, and much easier
      // than chasing down all the possible ways other rows could be updated.
      wantsReloadOfExistingRows = true
    } else {
      wantsReloadOfExistingRows = false
    }

    if wantsReloadOfExistingRows {
      // 3. Reload.
      // MUST NOT DO THIS IN THE SAME ANIMATION TASK AS ROW UPDATES or else weird selection "burn-in" can result
      animationTasks.append(.instantTask {
        log.verbose("TableUIChange: reloading existing rows")
        /// Also uses `newSelectedRowIndexes`, if it is not nil:
        tableView.reloadExistingRows(reselectRowsAfter: true)
      })
    }

    // 4. (maybe) scroll to changed row.
    if scrollToShowChangedRow {
      animationTasks.append(.instantTask { [self] in
        if let newSelectedRowIndexes,
           let firstSelectedRowIndex = newSelectedRowIndexes.first {
          log.verbose("TableUIChange: scrolling to first selected row index: \(firstSelectedRowIndex)")
          tableView.scrollRowToVisible(firstSelectedRowIndex)
        } else if changeType == .wholeTableDiff {
          // TODO: figure out how to show changed row while not changing if not necessary
        } else if changeType != .reloadAll {
          if let lastInsertedRowIndex = toInsert?.last {
            log.verbose("TableUIChange: scrolling to last inserted row index: \(lastInsertedRowIndex)")
            tableView.scrollRowToVisible(lastInsertedRowIndex)
          } else if let lastRemovedRowIndex = toRemove?.last {
            let index = min(max(0, tableView.numberOfRows - 1), lastRemovedRowIndex)
            log.verbose("TableUIChange: scrolling to last removed row index: \(index)")
            tableView.scrollRowToVisible(index)
          } else if let (_, newIndex) = toMove?.last {
            let index = min(max(0, tableView.numberOfRows - 1), newIndex)
            log.verbose("TableUIChange: scrolling to last moved row index: \(index)")
            tableView.scrollRowToVisible(index)
          }
        }
      })
    }

    // 5. "After" animations (if provided)
    if let flashAfter, !flashAfter.isEmpty {
      animationTasks.append(.init(duration: Constants.AnimationDuration.tableUIFlash) { [self] in
        let context = NSAnimationContext.current
        log.verbose("Flashing rows after animation: \(flashAfter.map({$0}))")
        animateFlash(forIndexes: flashAfter, in: tableView, context)
      })
    }

    if let completionHandler {
      animationTasks.append(.instantTask{ [self] in
        log.trace("TableUIChange: running completion handler")
        completionHandler(self)
      })
    }

    if let animationPipeline = tableView.animationPipeline {
      animationPipeline.submit(animationTasks)
    } else if let animationPipeline = tableView.pwc?.animationPipeline {
      animationPipeline.submit(animationTasks)
    } else {
      IINAAnimation.runAsync(animationTasks)
    }
  }

  @MainActor
  private func executeRowUpdates(on tableView: EditableTableView) {
    let insertAnimation = IINAAnimation.isAnimationEnabled ? (rowInsertAnimation ?? tableView.rowInsertAnimation) : []
    let removeAnimation = IINAAnimation.isAnimationEnabled ? (rowRemoveAnimation ?? tableView.rowRemoveAnimation) : []

    let log = tableView.log
    log.verbose("Executing TableUIChange type=\"\(changeType)\": removes=\(toRemove?.count ?? 0) inserts=\(toInsert?.count ?? 0) moves=\(toMove?.count ?? 0) updates=\(toUpdate?.count ?? 0) reloadExisting=\(reloadAllExistingRows.yn) selectedRows=\(newSelectedRowIndexes?.count.description ?? "nil")")

    switch changeType {

    case .removeRows:
      if let indexes = toRemove {
        tableView.removeRows(at: indexes, withAnimation: removeAnimation)
      }

    case .insertRows:
      if let indexes = toInsert {
        tableView.insertRows(at: indexes, withAnimation: insertAnimation)
      }

    case .moveRows:
      if let movePairs = toMove {
        for (oldIndex, newIndex) in movePairs {
          log.verbose("TableUIChange: Moving row \(oldIndex) → \(newIndex)")
          tableView.moveRow(at: oldIndex, to: newIndex)
        }
      }

    case .updateRows:
      // will reload rows in next step
      break

    case .none:
      break

    case .reloadAll:
      // Try not to use this much, if at all
      log.verbose("Executing TableUIChange: ReloadAll")
      tableView.reloadData()

    case .wholeTableDiff:
      if let toRemove,
         let toInsert,
         let toUpdate,
         let movePairs = toMove {
        guard !toRemove.isEmpty || !toInsert.isEmpty || !toUpdate.isEmpty || !movePairs.isEmpty else {
          log.verbose("Executing changes from diff: no rows changed")
          break
        }
        // Remember, AppKit expects the order of operations to be: 1. Delete, 2. Insert, 3. Move
        tableView.removeRows(at: toRemove, withAnimation: removeAnimation)
        tableView.insertRows(at: toInsert, withAnimation: insertAnimation)
        for (oldIndex, newIndex) in movePairs {
          log.verbose("Executing changes from diff: moving row: \(oldIndex) → \(newIndex)")
          tableView.moveRow(at: oldIndex, to: newIndex)
        }
      }
    }
  }

  @MainActor
  private func animateFlash(forIndexes indexes: IndexSet, in tableView: NSTableView, _ context: NSAnimationContext) {
    context.duration = Constants.AnimationDuration.tableUIFlash

    for index in indexes {
      if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) {
        let animation = CAKeyframeAnimation()
        animation.keyPath = "backgroundColor"
        animation.values = [NSColor.textBackgroundColor.cgColor,
                            NSColor.controlTextColor.cgColor,
                            NSColor.textBackgroundColor.cgColor]
        animation.keyTimes = [0, 0.25, 1]
        animation.duration = context.duration
        rowView.layer?.add(animation, forKey: "bgFlash")
      }
    }
  }

  // MARK: - Other Utils

  func postNotification(name tableChangeNotificationName: Notification.Name) {
    let not = Notification(name: tableChangeNotificationName, object: self)
    Logger.log.trace("Posting \(not.name.rawValue.quoted) notification with changeType \(changeType)")
    NotificationCenter.default.post(not)
  }


  func inverted(adjustAllIndexesBy indexAdjustment: Int = 0,
                selectNextRowAfterDelete: Bool, completionHandler: TableUIChange.CompletionHandler? = nil) -> TableUIChange {
    TableUIChangeBuilder.shared.inverted(from: self, andAdjustAllIndexesBy: indexAdjustment,
                                   selectNextRowAfterDelete: selectNextRowAfterDelete, completionHandler: completionHandler)
  }
}
