//
//  TimeoutTimer.swift
//  iina
//
//  Created by Matt Svoboda on 2025-01-16.
//  Copyright © 2025 lhc. All rights reserved.
//

class TimeoutTimer {
  private var scheduledTimer: Timer? = nil
  var timeout: TimeInterval

  private let queue: DispatchQueue

  /// nillable because sometimes this needs to be set after the containing class has finished init
  var action: Callback?

  /// If not nil, is executed before starting or restarting the timer.
  /// If it returns false, the timer will not be started.
  /// Can also be used to execute extra logic before each timer restart.
  var startCondition: ((_ thisTimer: TimeoutTimer) -> Bool)?

  init(timeout: TimeInterval,
       queue: DispatchQueue = .main,
       startCondition: ((TimeoutTimer) -> Bool)? = nil,
       action: Callback? = nil) {
    self.timeout = timeout
    self.queue = queue
    self.startCondition = startCondition
    self.action = action
  }

  func restart(withNewTimeout newTimeout: TimeInterval? = nil) {
    Logger.log.trace("Timer: restarting")
    queue.async { [self] in
      cancel()
      
      if let newTimeout {
        timeout = newTimeout
      }
      
      if let startCondition {
        let canProceed = startCondition(self)
        guard canProceed else {
          return
        }
      }
      scheduledTimer = Timer.scheduledTimer(timeInterval: timeout,
                                            target: self, selector: #selector(self.timeoutReached),
                                            userInfo: nil, repeats: false)
    }
  }

  var isValid: Bool {
    if let scheduledTimer, scheduledTimer.isValid {
      return true
    }
    return false
  }

  func cancel() {
    scheduledTimer?.invalidate()
  }

  /// Convenience method to excute `startCondition` without its boilerplate args.
  func runStartCondition() {
    queue.async { [self] in
      if let startCondition {
        _ = startCondition(self)
      }
    }
  }

  @objc private func timeoutReached() {
    Logger.log.trace("Timer: timeout reached")
    queue.async { [self] in
      cancel()
      if let action {
        action()
      }
    }
  }
}
