//
//  TableUIChangeBuilder.swift
//  iina
//
//  Created by Matt Svoboda on 11/26/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

struct TableUIChangeBuilder {
  static let shared = TableUIChangeBuilder()
  
  /// Derives the inverse of the given `TableUIChange` (as suitable for an Undo) and returns it.
  /// `indexAdjustment`: if given, shifts all indexes by this amount. Should not be needed for most cases.
  func inverted(from original: TableUIChange, andAdjustAllIndexesBy indexAdjustment: Int = 0,
                selectNextRowAfterDelete: Bool, useFlashForChangedRows: Bool = false,
                completionHandler: TableUIChange.CompletionHandler? = nil) -> TableUIChange {
    
    let invertedChangeType: TableUIChange.ContentChangeType
    switch original.changeType {

    case .removeRows:
      invertedChangeType = .insertRows

    case .insertRows:
      invertedChangeType = .removeRows

    case .moveRows:
      invertedChangeType = .moveRows

    case .updateRows:
      invertedChangeType = .updateRows

    case .none, .reloadAll, .wholeTableDiff:
      // Will not cause a failure. But can't think of a reason to ever invert these types
      Logger.log.warn("Calling inverted() on content change type '\(original.changeType)': was this intentional?")
      invertedChangeType = original.changeType
    }

    var newSelectedRowIndexes: IndexSet? = nil
    var oldSelectedRowIndexes: IndexSet? = nil
    var toInsertSet: IndexSet? = nil
    var toRemoveSet: IndexSet? = nil
    var toUpdateSet: IndexSet? = nil
    /// Used by `ContentChangeType.moveRows`. Ordered list of pairs of (fromIndex, toIndex)
    var toMoveSet: [(Int, Int)]? = nil

    if invertedChangeType != .none && invertedChangeType != .reloadAll {
      newSelectedRowIndexes = IndexSet()
    }

    if let removed = original.toRemove {
      let toInsert = IndexSet(removed.map({ $0 + indexAdjustment }))
      toInsertSet = toInsert
      // Add inserted lines to selection
      for insertIndex in toInsert {
        newSelectedRowIndexes?.insert(insertIndex)
      }
      Logger.log.verbose("Invert: changed removes=\(removed.toArray()) into inserts=\(toInsert.toArray())")
    }
    if let inserted = original.toInsert {
      let toRemove = IndexSet(inserted.map({ $0 + indexAdjustment }))
      toRemoveSet = toRemove
      Logger.log.verbose("Invert: changed inserts=\(inserted.toArray()) into removes=\(toRemove.toArray())")
    }
    if let updated = original.toUpdate {
      let toUpdate = IndexSet(updated.map({ $0 + indexAdjustment }))
      toUpdateSet = toUpdate
      Logger.log.verbose("Invert: changed updates=\(updated.toArray()) into updates=\(toUpdate.toArray())")
      // Add updated lines to selection
      for updateIndex in toUpdate {
        newSelectedRowIndexes?.insert(updateIndex)
      }
    }
    if let movedPairs = original.toMove {
      var movePairsInverted: [(Int, Int)] = []

      for (fromIndex, toIndex) in movedPairs {
        let fromIndexNew = toIndex + indexAdjustment
        let toIndexNew = fromIndex + indexAdjustment
        movePairsInverted.append((fromIndexNew, toIndexNew))
      }

      movePairsInverted = movePairsInverted.reversed()  // Need to reverse order for proper animation
      toMoveSet = movePairsInverted

      // Preserve selection if possible:
      if let origBeginningSelection = original.oldSelectedRowIndexes,
         let origEndingSelection = original.newSelectedRowIndexes, invertedChangeType == .moveRows {
        newSelectedRowIndexes = origBeginningSelection
        oldSelectedRowIndexes = origEndingSelection
        Logger.log.verbose("Invert: changed movePairs from \(movedPairs) to \(movePairsInverted.map{$0}); changed selection from \(origEndingSelection.map{$0}) to \(origBeginningSelection.map{$0})")
      }
    }

    // Select next row after delete event (maybe):

    if selectNextRowAfterDelete, toMoveSet == nil, toInsertSet == nil, let toRemoveSet {
      // After selected rows are deleted, keep a selection on the table by selecting the next row
      if let lastRemoveIndex = toRemoveSet.last {
        let newSelectionIndex: Int = lastRemoveIndex - toRemoveSet.count + 1
        if newSelectionIndex < 0 {
          Logger.log("selectNextRowAfterDelete: new selection index is less than zero! Discarding", level: .error)
        } else {
          newSelectedRowIndexes = IndexSet(integer: newSelectionIndex)
          Logger.log("TableUIChange: selecting next index after removed rows: \(newSelectionIndex)", level: .verbose)
        }
      }
    }

    let inverted = TableUIChange(invertedChangeType,
                                 toRemove: toRemoveSet, toInsert: toInsertSet, toUpdate: toUpdateSet, toMove: toMoveSet,
                                 newSelectedRowIndexes: newSelectedRowIndexes, oldSelectedRowIndexes: oldSelectedRowIndexes,
                                 useFlashForChangedRows: useFlashForChangedRows,
                                 completionHandler: completionHandler)
    return inverted
  }

  // MARK: Diff

  /**
   Creates a new `TableUIChange` and populates its `toRemove, `toInsert`, and `toMove` fields
   based on a diffing algorithm similar to Git's.

   Note for tables containing non-unique rows:
   If changes were made to row(s) which not unique in the table, the diffing algorithm can't reliably
   identify which of the duplicates changed and which didn't, and may pick the wrong ones.
   Assuming the positions of shared rows are fungible, this isn't exactly wrong but may be visually
   inconvenient for things like undo. Where possible, this should be avoided in favor of explicit information.

   Solution shared by Giles Hammond:
   https://stackoverflow.com/a/63281265/1347529S
   Further reference:
   https://swiftrocks.com/how-collection-diffing-works-internally-in-swift
   */
  func buildDiff<R>(oldRows: Array<R>, newRows: Array<R>,
                    newSelectedRowIndexes: IndexSet? = nil,
                    useFlashForChangedRows: Bool = false,
                    completionHandler: TableUIChange.CompletionHandler? = nil,
                    reloadAllExistingRows: Bool = false,
                    overrideSingleRowMove: Bool = true) -> TableUIChange where R:Hashable {
    var toRemove = IndexSet()
    var toInsert = IndexSet()
    var toUpdate = IndexSet()
    var toMove: [(Int, Int)] = []

    // Remember, AppKit expects the order of operations to be: 1. Delete, 2. Insert, 3. Move

    let steps = newRows.difference(from: oldRows).steps
    Logger.log.verbose("Computing TableUIChange from diff: found \(steps.count) differences between \(oldRows.count) old & \(newRows.count) new rows")

    // If overrideSingleRowMove==true, override default behavior for single row: treat del + ins as move.
    // This results in a more pleasant animation in cases such as when an inline edit is finished.
    if overrideSingleRowMove && steps.count == 2 {
      switch steps[0] {
      case let .remove(_, indexToRemove):
        switch steps[1] {
        case let .insert(_, indexToInsert):
          if indexToRemove == indexToInsert {
            toUpdate = IndexSet(integer: indexToInsert)
            Logger.log.verbose("Overrode TableUIChange from diff: changed 1 rm + 1 add into 1 update: \(indexToInsert)")
          } else {
            toMove.append((indexToRemove, indexToInsert))
            Logger.log.verbose("Overrode TableUIChange from diff: changed 1 rm + 1 add into 1 move: from \(indexToRemove) to \(indexToInsert)")
          }
          return TableUIChange(.wholeTableDiff,
                               toUpdate: toUpdate, toMove: toMove,
                               useFlashForChangedRows: useFlashForChangedRows,
                               reloadAllExistingRows: reloadAllExistingRows,
                               completionHandler: completionHandler)
        default: break
        }
      default: break
      }
    }

    for step in steps {
      switch step {
      case let .remove(_, index):
        // If toOffset != nil, it signifies a MOVE from fromOffset -> toOffset. But the offset must be adjusted for removes!
        toRemove.insert(index)
      case let .insert(_, index):
        toInsert.insert(index)
      case let .move(_, from, to):
        toMove.append((from, to))
      }
    }

    let diff = TableUIChange(.wholeTableDiff,
                             toRemove: toRemove, toInsert: toInsert, toUpdate: toUpdate, toMove: toMove,
                             newSelectedRowIndexes: newSelectedRowIndexes,
                             useFlashForChangedRows: useFlashForChangedRows,
                             reloadAllExistingRows: reloadAllExistingRows,
                             completionHandler: completionHandler)

    return diff
  }

  /// Do not use this moving forward. Use the equivalent `EditableTableView` method.
  func buildInsert<T>(of itemsToInsert: [T], at insertIndex: Int, in allCurrentItems: [T],
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    let toInsert = IndexSet(insertIndex..<(insertIndex+itemsToInsert.count))
    let tableUIChange = TableUIChange(.insertRows,
                                      toInsert: toInsert, newSelectedRowIndexes: toInsert,
                                      completionHandler: completionHandler)

    var allItemsNew = allCurrentItems
    allItemsNew.insert(contentsOf: itemsToInsert, at: insertIndex)

    return (tableUIChange, allItemsNew)
  }

  /// Do not use this moving forward. Use the equivalent `EditableTableView` method.
  func buildRemove<T>(_ indexesToRemove: IndexSet,
                      in allCurrentRows: [T],
                      selectNextRowAfterDelete: Bool,
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    var remainingRows: [T] = []
    var lastRemovedIndex = 0
    for (rowIndex, row) in allCurrentRows.enumerated() {
      if indexesToRemove.contains(rowIndex) {
        lastRemovedIndex = rowIndex
      } else {
        remainingRows.append(row)
      }
    }

    var newSelectedRowIndexes: IndexSet? = nil
    if selectNextRowAfterDelete {
      // After removal, select the single row after the last one removed:
      let countRemoved = allCurrentRows.count - remainingRows.count
      if countRemoved < allCurrentRows.count {
        let newSelectionIndex: Int = lastRemovedIndex - countRemoved + 1
        newSelectedRowIndexes = IndexSet(integer: newSelectionIndex)
      }
    }

    let tableUIChange = TableUIChange(.removeRows,
                                      toRemove: indexesToRemove,
                                      newSelectedRowIndexes: newSelectedRowIndexes,
                                      completionHandler: completionHandler)


    return (tableUIChange, remainingRows)
  }

  /// Do not use this moving forward. Use the equivalent `EditableTableView` method.
  func buildMove<T>(_ indexesToMove: IndexSet,
                    to insertIndex: Int,
                    in allCurrentRows: [T],
                    completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {

    // Divide all the rows into 3 groups: before + after the insert, + the insert itself.
    // Since each row will be moved in order from top to bottom, it's fairly easy to calculate where each row will go
    var beforeInsert: [T] = []
    var afterInsert: [T] = []
    var movedRows: [T] = []
    var moveIndexPairs: [(Int, Int)] = []
    var dstIndexes = IndexSet()
    var moveFromOffset = 0
    var moveToOffset = 0

    // Drag & Drop reorder algorithm: https://stackoverflow.com/questions/2121907/drag-drop-reorder-rows-on-nstableview
    for (origIndex, row) in allCurrentRows.enumerated() {
      if indexesToMove.contains(origIndex) {
        if origIndex < insertIndex {
          // If we moved the row from above to below, all rows up to & including its new location get shifted up 1
          moveIndexPairs.append((origIndex + moveFromOffset, insertIndex - 1))
          dstIndexes.insert(insertIndex + moveFromOffset - 1)  // new selected index
          moveFromOffset -= 1
        } else {
          moveIndexPairs.append((origIndex, insertIndex + moveToOffset))
          dstIndexes.insert(insertIndex + moveToOffset)  // new selected index
          moveToOffset += 1
        }
        movedRows.append(row)
      } else if origIndex < insertIndex {
        beforeInsert.append(row)
      } else {
        afterInsert.append(row)
      }
    }
    let allRowsUpdated = beforeInsert + movedRows + afterInsert
    let tableUIChange = TableUIChange(.moveRows,
                                      toMove: moveIndexPairs,
                                      newSelectedRowIndexes: dstIndexes,
                                      oldSelectedRowIndexes: indexesToMove,
                                      completionHandler: completionHandler)

    return (tableUIChange, allRowsUpdated)
  }

  func buildUpdate<T>(ofRow indexToUpdate: Int,
                      to newValue: T,
                      in allCurrentRows: [T],
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {

    let toUpdate = IndexSet(integer: indexToUpdate)
    let tableUIChange = TableUIChange(.updateRows,
                                      toUpdate: toUpdate,
                                      newSelectedRowIndexes: toUpdate,
                                      oldSelectedRowIndexes: toUpdate,
                                      completionHandler: completionHandler)

    var allRowsUpdated = allCurrentRows
    allRowsUpdated[indexToUpdate] = newValue

    return (tableUIChange, allRowsUpdated)
  }
}

// MARK: - EditableTableView

extension EditableTableView {

  func buildInsert<T>(of itemsToInsert: [T], at desiredInsertIndex: Int? = nil, in allCurrentItems: [T],
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    // Append row after last selected row, or if no selection, to end of table
    let insertIndex: Int
    if let desiredInsertIndex {
      insertIndex = desiredInsertIndex
    } else if let lastSelectedRow = selectedRowIndexes.last {
      insertIndex = lastSelectedRow + 1
    } else {
      insertIndex = numberOfRows
    }
    return TableUIChangeBuilder.shared.buildInsert(of: itemsToInsert, at: insertIndex, in: allCurrentItems,
                                                   completionHandler: completionHandler)
  }

  func buildRemove<T>(_ indexesToRemove: IndexSet, in allCurrentRows: [T],
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    return TableUIChangeBuilder.shared.buildRemove(indexesToRemove, in: allCurrentRows,
                                                   selectNextRowAfterDelete: selectNextRowAfterDelete,
                                                   completionHandler: completionHandler)
  }

  func buildMove<T>(_ indexesToMove: IndexSet,
                    to insertIndex: Int,
                    in allCurrentRows: [T],
                    completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    return TableUIChangeBuilder.shared.buildMove(indexesToMove, to: insertIndex, in: allCurrentRows,
                                                 completionHandler: completionHandler)
  }

  func buildUpdate<T>(ofRow rowIndex: Int,
                      to newValue: T,
                      in allCurrentRows: [T],
                      completionHandler: TableUIChange.CompletionHandler? = nil) -> (TableUIChange, [T]) {
    return TableUIChangeBuilder.shared.buildUpdate(ofRow: rowIndex, to: newValue, in: allCurrentRows,
                                                   completionHandler: completionHandler)
  }
}
