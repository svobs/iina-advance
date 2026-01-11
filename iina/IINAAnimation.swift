//
//  IINAAnimation.swift
//  iina
//
//  Created by Matt Svoboda on 2023-04-09.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

typealias SwiftTask = Task  // workaround for conflict with our Task type, epp
class IINAAnimation {
  typealias TaskFunc = (@Sendable @MainActor () throws -> Void)

  // MARK: Misc static stuff

  /// "Disable all" override switch
  nonisolated(unsafe)
  private static var disableAllAnimation = false

  nonisolated(unsafe)
  static var isAnimationEnabled: Bool {
    return !disableAllAnimation && !Preference.bool(for: .disableAnimations) && !AccessibilityPreferences.motionReductionEnabled
  }

  // Wrap a block of code inside this function to disable its animations
  @MainActor
  @discardableResult
  static func disableAnimation<T>(_ closure: () throws -> T) rethrows -> T {
    let prevDisableState = disableAllAnimation
    disableAllAnimation = true
    CATransaction.begin()
    defer {
      CATransaction.commit()
      disableAllAnimation = prevDisableState
    }
    return try closure()
  }

  /// Convenience func to reduce code verbosity
  @MainActor
  static func runAsync(duration: CGFloat? = nil, _ timingName: CAMediaTimingFunctionName? = nil,
                       _ runFunc: @escaping TaskFunc, then doAfter: TaskFunc? = nil) {
    runAsync(Task(duration: duration, timing: timingName, runFunc), then: doAfter)
  }

  /// Convenience func for running the giving closure in a transactional way
  @MainActor
  static func runInstantAsync(_ runFunc: @escaping TaskFunc, then doAfter: TaskFunc? = nil) {
    runAsync(.instantTask(runFunc), then: doAfter)
  }

  /// Convenience wrapper for running a task asynchronously and immediately via `NSAnimationContext.runAnimationGroup()`.
  /// Does not use pipeline.
  @MainActor
  static func runAsync(_ task: Task, then doAfter: TaskFunc? = nil) {
    runAsync([task], then: doAfter)
  }

  /// Convenience wrapper for executing a chain of tasks sequentially via `NSAnimationContext.runAnimationGroup()`.
  /// The first task in the chain is launched immediately & asynchronously (does not use pipeline).
  @MainActor
  static func runAsync(_ tasks: [Task], then doAfter: TaskFunc? = nil) {
    var tasks = tasks
    if let doAfter {
      tasks.append(.instantTask(doAfter))
    }

    let taskIterator: IndexingIterator<Array<Task>> = tasks.makeIterator()
    runSequentially(taskIterator)
  }

  // Recursive function which executes code for a single Task in a chain of tasks.
  @MainActor
  private static func runSequentially(_ taskIterator: IndexingIterator<Array<Task>>) {
    var taskIterator = taskIterator
    guard let task = taskIterator.next() else { return }
    let nextTasIter = taskIterator
    NSAnimationContext.runAnimationGroup({ context in
      let disableAnimation = !isAnimationEnabled
      if disableAnimation {
        context.duration = 0
      } else {
        context.duration = task.duration
      }
      context.allowsImplicitAnimation = !disableAnimation

      if let timingName = task.timingName {
        context.timingFunction = CAMediaTimingFunction(name: timingName)
      }
      do {
        try task.runFunc()
      } catch IINAError.cancelAnimationTransaction {
        Logger.log.debug("[Pipeline] Async task was cancelled")
      } catch {
        Logger.log.error("[Pipeline] Unexpected error thrown by async task: \(error)")
      }
    }, completionHandler: {
      SwiftTask { @MainActor in
        runSequentially(nextTasIter)
      }
    })
  }
}

extension IINAAnimation {
  struct Task: Sendable {
    let duration: CGFloat
    let timingName: CAMediaTimingFunctionName?
    let runFunc: TaskFunc

    init(duration: CGFloat? = nil,
         timing timingName: CAMediaTimingFunctionName? = nil,
         _ runFunc: @escaping TaskFunc) {
      self.duration = duration ?? Constants.AnimationDuration.standard
      self.timingName = timingName
      self.runFunc = runFunc
    }

    static func instantTask(_ runFunc: @escaping TaskFunc) -> Task {
      return Task(duration: 0, timing: nil, runFunc)
    }
  }

  class Transaction {
    var tasks: [Task]

    init(tasks: [Task]) {
      self.tasks = tasks
    }

    init() {
      self.tasks = []
    }

    func append(_ task: Task) {
      tasks.append(task)
    }

    /// Append a Task (convenience func)
    func append(duration: CGFloat? = nil, timing timingName: CAMediaTimingFunctionName? = nil,
                _ runFunc: @escaping TaskFunc) {
      tasks.append(Task(duration: duration, timing: timingName, runFunc))
    }
  }
}

extension IINAAnimation {
  /// Serial queue which executes `Task`s one after another.
  class Pipeline {

    /// ID of the latest transaction to be generated, but not necessarily run.
    /// (Basically used for ID generation).
    private var newestTxID: Int = 0
    /// ID of the currently executing transaction. When enqueued, all tasks in the same transaction are
    /// associated with an identical ID, which is one greater than the previous transaction
    /// (see `newestTxID`). If an exception is thrown by any task, `currentTxID` will be incremented. Any task associated with ID less than `currentTxID` will not be run, but if a task is found to have an ID greater
    /// than `currentTxID`, then `currentTxID` will be updated to its value and the task will be run.
    /// In this way, if any task in the transaction throws an exception, this will cause the remaining tasks
    /// to be skipped.
    private var currentTxID: Int = 0

    private(set) var isExecuting = false
    private var taskQueue = LinkedList<(Int, Task)>()

    // GeometryTransform queue
    private var gtfQueue = LinkedList<GeometryTransform>()
    let gtfLock = Lock()
    var gtfCurrentlyRunningID: Int? = nil
    var lastGeneratedID: Int = 0
    var wantsVideoGeoSync: Bool = false

    var enableRunning = true

    init(_ player: PlayerCore?) {
      self.player = player
      self.log = player?.log ?? Logger.log
    }

    unowned var player: PlayerCore?
    var pwc: PlayerWindowController? { player?.pwc }
    let log: any Logger.Subsystem

    // Convenience function. Run the task with no animation / zero duration.
    // Useful for updating constraints, etc., which cannot be animated or do not look good animated.
    func submitInstantTask(_ runFunc: @escaping TaskFunc, then doAfter: TaskFunc? = nil) {
      submit(.instantTask(runFunc), then: doAfter)
    }

    /// Convenience function. Same as `submit(Task)`
    func submitTask(duration: CGFloat? = nil, timing timingName: CAMediaTimingFunctionName? = nil,
                    _ runFunc: @escaping TaskFunc, then doAfter: TaskFunc? = nil) {
      let task = Task(duration: duration, timing: timingName, runFunc)
      submit(task)
    }

    /// Convenience function. Same as `submit([Task])`, but for a single animation.
    func submit(_ task: Task, then doAfter: TaskFunc? = nil) {
      submit([task], then: doAfter)
    }

    func submit(_ tx: Transaction, then doAfter: TaskFunc? = nil) {
      submit(tx.tasks, then: doAfter)
    }

    /// Recursive function which enqueues each of the given `AnimationTask`s for execution, one after another.
    /// Will execute without animation if motion reduction is enabled, or if wrapped in a call to `IINAAnimation.disableAnimation()`.
    /// If animating, it uses either the supplied `duration` for duration, or if that is not provided, uses `Constants.AnimationDuration.standard`.
    func submit(_ tasks: [Task], then doAfter: TaskFunc? = nil) {
      SwiftTask { @MainActor in
        // Add tasks to queue.
        enqueue(tasks, then: doAfter)

        if isExecuting {
          // Already running tasks. Let the existing chain pop the new animations & run them when it is ready.
        } else {
          // Start executing tasks in the queue
          isExecuting = true
          executeNextTask()
        }
      }
    }

    private var submitCounter: Int = 0
    private var lastLoggedTaskCount: Int = 0
    private var alarmActivated = false
    private static let alarmStartWatermark: Int = 100
    private static let alarmResetWatermark: Int = 10

    @MainActor
    fileprivate func enqueue(_ tasks: [Task], then doAfter: TaskFunc? = nil) {
      var enqueuedCount = 0

      if !tasks.isEmpty {
        newestTxID += 1
        let transactionID = newestTxID

        for task in tasks {
          taskQueue.append((transactionID, task))
        }
        enqueuedCount += tasks.count
      }

      if let doAfter {
        newestTxID += 1
        taskQueue.append((newestTxID, .instantTask(doAfter)))
        enqueuedCount += 1
      }

      guard enqueuedCount > 0 else { return }
      submitCounter += enqueuedCount

      if log.isVerboseEnabled {
        let taskQueueSize = taskQueue.count
        let submitCount = submitCounter
        if alarmActivated {
          let canDismissAlarm = taskQueueSize < IINAAnimation.Pipeline.alarmResetWatermark
          if canDismissAlarm {
            alarmActivated = false
          }
          if canDismissAlarm || (submitCount >= lastLoggedTaskCount + 20) {
            lastLoggedTaskCount = submitCount
            log.verbose("[Pipeline] Queue size: \(taskQueueSize)")
          }
        } else if taskQueue.count >= IINAAnimation.Pipeline.alarmStartWatermark {
          alarmActivated = true
          lastLoggedTaskCount = submitCounter
          log.verbose("[Pipeline] Work exceeds watermark! Queue size: \(taskQueueSize)")
        }
      }
    }

    @MainActor
    private func executeNextTask() {
      guard enableRunning else {
        isExecuting = false
        return
      }
      let nextTask: Task

      // Favor executing GeometryTransforms before regular Tasks - unless isAnimatingLayoutTransition is true.
      if let pwc, pwc.isAnimatingLayoutTransition {
        // This is very important in certain places (e.g. when entering interactive mode) where we cannot
        // submit tasks all in one block because the work is split up between asynchronous blocks, but we
        // do not want to allow other tasks to execute in between.
        guard let task = popNextValidTask() else { return }
        nextTask = task
      } else if let gtfTask = popNextReadyGTF() {
        // Kick-start the GTF via a Task
        nextTask = gtfTask
      } else {
        guard let task = popNextValidTask() else { return }
        nextTask = task
      }

      NSAnimationContext.runAnimationGroup({ context in
        let disableAnimation = !isAnimationEnabled
        if disableAnimation {
          context.duration = 0
        } else {
          context.duration = nextTask.duration
        }
        context.allowsImplicitAnimation = !disableAnimation

        if let timingName = nextTask.timingName {
          context.timingFunction = CAMediaTimingFunction(name: timingName)
        }
        do {
          try nextTask.runFunc()
        } catch IINAError.cancelAnimationTransaction {
          log.verbose("[Pipeline] Task was cancelled")
          currentTxID += 1  // cancel txn
        } catch {
          log.error("[Pipeline] Unexpected error thrown by task: \(error)")
        }
      }, completionHandler: {
        SwiftTask { @MainActor in
          self.executeNextTask()
        }
      })
    }

    private func popNextValidTask() -> IINAAnimation.Task? {
      while true {
        guard let (taskTxID, poppedTask) = taskQueue.removeFirst() else {
          self.isExecuting = false
          return nil
        }

        guard taskTxID >= currentTxID else {
          log.verbose("[Pipeline] Skipping task with cancelled txID \(taskTxID) (next valid txID: \(currentTxID))")
          continue
        }
        currentTxID = taskTxID
        return poppedTask
      }
    }

    // MARK: - GeometryTransform

    /// Returns true if no GTFs are running and none are enqueued.
    private var isDoneWithAllGTFs: Bool {
      return gtfCurrentlyRunningID == nil && gtfQueue.isEmpty
    }

    /// Currently this "work" is always just a reload of the current QuickSettings tab, if shown.
    /// Flattening all requests to this single instance works as a debouncer for reload requests.
    private var pendingWorkAfterGTFs: TaskFunc? = nil
    
    // TODO: replace this logic with a simple flag
    func doAfterGTFs(_ work: @escaping TaskFunc) {
      gtfLock.withLock{ [self] in
        pendingWorkAfterGTFs = work
      }
      
      log.trace("[Pipeline] Submitting ReloadQuickSettings task")
      submitInstantTask{}
    }
    
    /// Checks that the last GeometryTransform is done, and if there is an enqueued GeometryTransform waiting.
    /// If so, pops & returns it.
    @MainActor
    private func popNextReadyGTF() -> Task? {
      gtfLock.withLock{ [self] in
        guard gtfCurrentlyRunningID == nil else { return nil }
        if let nextGTF = gtfQueue.removeFirst() {
          gtfCurrentlyRunningID = nextGTF.id
          log.verbose("[Pipeline] Starting GTF: \(nextGTF.name.quoted); queue size: \(gtfQueue.count)")
          return Task.instantTask{nextGTF.execute()}
        }
        if isDoneWithAllGTFs {
          if wantsVideoGeoSync, let player {
            wantsVideoGeoSync = false
            let gtf = GeometryTransform("SyncVidGeo", id: nextID_NoLock(), player)
            return Task.instantTask{gtf.execute()}
          } else if let workAfterGTFs = pendingWorkAfterGTFs {
            pendingWorkAfterGTFs = nil
            return Task.instantTask(workAfterGTFs)
          }
        }

        return nil
      }
    }

    func nextID_NoLock() -> Int {
      lastGeneratedID += 1
      return lastGeneratedID
    }

    /// Uses a queue if necessary to ensure that only one `GeometryTransform` is ever running at a time.
    /// This is a safety feature. The transform's work takes place asynchronously via multiple tasks across
    /// multiple `DispatchQueue`s, while drawing from disparate state variables, so if they overlapped they
    /// could interfere with each other in difficult-to-predict ways.
    func submitGTF(_ gtf: GeometryTransform) {
      gtfLock.withLock{ [self] in
        gtfQueue.append(gtf)
        log.verbose("[Pipeline] Enqueued GTF: \(gtf.name.quoted); queue size: \(gtfQueue.count)")
      }

      // Kick the queue if it's idle:
      submitInstantTask{}
    }

    func enqueueVideoSyncTaskIfNeeded(_ player: PlayerCore) {
      gtfLock.withLock{ [self] in
        guard !wantsVideoGeoSync else { return }
        log.verbose("Setting wantsVideoGeoSync = YES")
        wantsVideoGeoSync = true
      }

      submitInstantTask{}
    }
    
    func geoTransformDidFinish(_ gtf: GeometryTransform, success: Bool) {
      let postWork: TaskFunc? = gtfLock.withLock{ [self] in
        gtfCurrentlyRunningID =  nil
        if success {
          log.verbose("[Pipeline] GTF done: \(gtf.name.quoted); queue size: \(gtfQueue.count)")
        }

        if let workFunc = pendingWorkAfterGTFs, isDoneWithAllGTFs {
          pendingWorkAfterGTFs = nil
          log.trace("[Pipeline] Running pending post-GTF work (ReloadQuickSettings)")
          return workFunc
        } else {
          return nil
        }
      }

      // Always run this task, even if empty, to give the pipeline a kick and run its next loop, so that the next GTF will run immediately
      submitInstantTask{
        if let postWork {
          try postWork()
        }
      }
    }

  }
}

// MARK: - Extensions for disabling animation

extension NSLayoutConstraint {
  /// Even when executed inside an animation block, MacOS only sometimes creates implicit animations for changes to constraints.
  /// Using an explicit call to `animator()` seems to be required to guarantee it, but we do not always want it to animate.
  /// This function will automatically disable animations in case they are disabled.
  @MainActor
  func animateToConstant(_ newConstantValue: CGFloat) {
    if IINAAnimation.isAnimationEnabled {
      self.animator().constant = newConstantValue
    } else {
      self.constant = newConstantValue
    }
  }
}
