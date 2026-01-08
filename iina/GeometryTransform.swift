//
//  GeometryTransform.swift
//  iina
//
//  Created by Matt Svoboda on 2024-12-08.
//

/// Contains a set of transform functions, along with any initial state, which forms a recipe for making changes to
/// a given window's geometry. Each instance must be executed via an `IINAAnimation.Pipeline` for any work to be done.
///
/// # Important Fields:
/// - `sessionStateTransform`: optional operator function (functor) for transforming `sessionState` and/or cancelling the transform.
///   - If `nil`, the transform will proceed with the existing `sessionState`.
///   - If non-nil, this function will be run in the mpv queue. It is given the current window's `sessionState` & is expected
///     to output a new value of `sessionState` to set at the end of the transform if it succeeds.
///     But if it returns `nil`, the transform will be cancelled.
/// - `videoTransform`: optional operator function which, if provided, will run in the mpv queue.
///   - If `nil`, the transform will proceed with the existing `VideoGeometry`.
///   - If non-`nil`: t is given the current window's `VideoGeometry` (and other context), & is expected to output a new, possibly
///     transformed ` VideoGeometry`. But if it returns `nil`, then transform will be cancelled and no state will be changed.
/// - `pWinGeoTransform`: optional operator function which if provided, will run in the main queue.
///   - If non-nil, and if in music mode, this function is given the `PWinGeometry` which would otherwise be applied and is
///     is expected to output a ` PWinGeometry` containing further transforms which should be applied. If it returns `nil`,
///     the transform will ignore it and will proceed with its calculated values.
///
/// See also: `VideoGeo_Sync.swift` for syncing `VideoGeometry` from mpv.
struct GeometryTransform: Sendable {
  // Transforms (functors) for different types
  typealias PWinSessionStateTF = (PWinSessionState, ContextStage2) -> PWinSessionState?
  typealias VideoGeometryTF = (VideoGeometry, ContextStage2) -> VideoGeometry?
  typealias PWinGeometryTF = (GeometryTransform.ContextStage3) -> PWinGeometry?

  // MARK: - GeometryTransform Fields

  /// Descriptive name of the transform, and its `id` (string).
  let name: String
  /// The unique identifier of this `GeometryTransform`.
  let id: Int

  /// If `true`, then prior to executing `videoTransform`, call `GeometryTransform.Context.syncVideoParamsFromMpv` to update
  /// `ctx.inputGeoSet` with the latest video geometry from mpv (or abort if it returns `nil`).
  let syncVideoParams: Bool

  let currentPlayback: Playback?

  nonisolated(unsafe)
  private let player: PlayerCore
  private var pwc: PlayerWindowController { player.pwc! }
  private var log: any Logger.Subsystem { player.log }

  // - mpv queue transforms

  /// If `sessionStateTransform` is `nil` (omitted), treat as no-op and continue to `videoTransform`.
  /// If `sessionStateTransform` returns `nil`, transition should be aborted.
  nonisolated(unsafe)
  private let sessionStateTransform: PWinSessionStateTF?

  /// This always runs in the `mpv` `DispatchQueue`, and can be used for other functionality.
  nonisolated(unsafe)
  private let videoTransform: VideoGeometryTF?

  // - main queue transforms

  /// Can be used for custom logic for building `PWinGeometryTF`.
  ///
  /// See also `buildPWinGeoTransformTasks`.
  nonisolated(unsafe)
  private let pWinGeoTransform: PWinGeometryTF?

  /// If provided, overrides all logic for generating the window geometry transform tasks.
  ///
  /// This option is mutually exclusive with the `pWinGeoTransform` option; both should not both be provided in the same GTF.
  nonisolated(unsafe)
  private let buildPWinGeoTransformTasks: ((GeometryTransform.ContextStage3) -> [IINAAnimation.Task])?

  nonisolated(unsafe)
  private let onSuccess: (() -> Void)?

  init(_ name: String,
       id pregeneratedID: Int? = nil,
       _ player: PlayerCore,
       currentPlayback: Playback? = nil,
       syncVideoParams: Bool = true,
       sessionState: PWinSessionStateTF? = nil,
       video: VideoGeometryTF? = nil,
       windowed: PWinGeometryTF? = nil,
       buildPWinGeoTransformTasks: ((GeometryTransform.ContextStage3) -> [IINAAnimation.Task])? = nil,
       onSuccess: (() -> Void)? = nil) {
    let pipeline = player.pwc.animationPipeline
    self.id = pregeneratedID ?? pipeline.gtfLock.withLock {
      pipeline.nextID_NoLock()
    }
    self.name = "\(name)-\(id)"
    self.player = player
    self.currentPlayback = currentPlayback ?? player.info.currentPlayback
    self.syncVideoParams = syncVideoParams
    self.sessionStateTransform = sessionState
    self.videoTransform = video
    self.pWinGeoTransform = windowed
    self.buildPWinGeoTransformTasks = buildPWinGeoTransformTasks
    self.onSuccess = onSuccess
  }

  /// Convenience method which enqueues this GeometryTransform for execution.
  func submit() {
    pwc.animationPipeline.submitGTF(self)
  }

  /// Aborts the transform (`animationPipeline` must always be notified for either success or failure).
  private func abort(_ reasonDebugMsg: String) {
    log.verbose("[GTF:\(name)] Aborting GTF: \(reasonDebugMsg)")
    pwc.animationPipeline.geoTransformDidFinish(self, success: false)
  }

  /// Do not call directly. Should only be called from an animation pipeline.
  /// Use `IINAAnimation.Pipeline.submit` to execute a `GeometryTransform`.
  @MainActor
  func execute() {
    // MARK: - STAGE 1

    /// Get a copy of videoGeo inside animationPipeline to ensure serial access.
    /// This is reused asynchronously down below, so some parts of it may fall out of date, but
    /// shouldn't be the parts we need for now...
    let outputVideoGeo = pwc.geo.video

    /// Quick summary of how we will avoid race conditions with `pwc.sessionState` (tag: #SessionState-Race)
    /// 1. All reads and writes of this variable occur on the main DQ.
    /// 2. In `player.openPlayerWindow`, the use of `mpv.queue.sync` creates a sort of checkpoint betwween
    /// the mpv & main queues, ensuring that the mpv queue is emptied (& thus discarding any enqueued GTFs) before
    /// proceeding with an update of the variable.
    /// 3. The logic in `IINAAnimation.Pipeline` ensures that each GTF starts after the last one has completed.
    /// Thus, no GTFs overlap in their execution, even across the two queues.
    /// 4. We set `pwc.sessionState = .closedSession` when closing the player window. But we can check for this
    /// before updating it at the end of the GTF, and pair with a check for `player.isStopping` in the mpv queue
    /// to cover both cases.
    let prevSessionState = pwc.sessionState

    // MARK: - STAGE 2
    // -- mpv queue -------------------------------------------------------------------------
    // Need to be inside mpv queue to ensure serial access to `vid` & other mpv state
    player.mpv.queue.async { [self] in
      // Check for window close (tag: #SessionState-Race)
      guard !player.isStopping else { return abort("player stopping (status=\(player.state))") }
      guard let currentPlayback else { return abort("currentPlayback is nil") }


      // File needs to be loaded before we can know its video geometry.
      // ...Unless we are restoring. But then we still want to wait until all windows are done loading, so we can open them all at once.
      // ...But streaming files can often fail to connect. So reopen those right away if restoring (we already have their saved geometry anyway).
      guard currentPlayback.state.isAtLeast(.loadedButNeedsSizing) || (prevSessionState.isRestoring && currentPlayback.isNetworkResource) else {
        return abort("playbackState=\(currentPlayback.state) restoring=\(prevSessionState.isRestoring.yn) network=\(currentPlayback.isNetworkResource.yn)")
      }

      // Get the freshest value of vid track from mpv
      let vidTrackID = Int(player.mpv.getInt(MPVOption.TrackSelection.vid))

      let ctxStage2 = ContextStage2(tf: self, currentPlayback: currentPlayback, vidTrackID: vidTrackID,
                                    currentMediaAudioStatus: player.info.currentMediaAudioStatus)

      let gtfSessionState: PWinSessionState
      /// 2a: Apply `sessionStateTransform` if present
      if let sessionStateTransform {
        log.verbose("[GTF:\(name)] Calling sessionStateTransform")
        guard let updatedSessionState = sessionStateTransform(prevSessionState, ctxStage2) else {
          return abort("sessionStateTF returned nil from prevSessionState=\(prevSessionState)")
        }
        gtfSessionState = updatedSessionState
        log.verbose("[GTF:\(name)] Result of sessionStateTF: \(prevSessionState) → \(gtfSessionState.description)")
      } else {
        gtfSessionState = prevSessionState
        log.verbose("[GTF:\(name)] No sessionStateTF provided; using prev value: \(gtfSessionState)")
      }

      var outputVideoGeo = outputVideoGeo

      if gtfSessionState.isStartingNewSession {
        log.verbose("[GTF:\(name)] Resetting mpv videoGeo for new session")
        outputVideoGeo = VideoGeometry.defaultGeometry(log)
      }

      /// 2b: Sync video params from mpv, if `syncVideoParams` is true.
      if syncVideoParams {
        if player.isRestoring {
          // If restoring, can assume the saved video params are still correct.
          // Moreover, sometimes mpv returns nil for video-out-params, which will result in the GTF aborting
          // & the "windowIsReadyToShow" signal not being sent, which will cause restore to hang forever
          log.verbose("[GTF:\(name)] Skipping syncVideoParamsFromMpv ∵ we're restoring")
        } else {
          log.verbose("[GTF:\(name)] Calling syncVideoParamsFromMpv as configured")
          let syncedVideoGeo = ctxStage2.syncVideoParamsFromMpv(startingWith: outputVideoGeo)
          if let syncedVideoGeo {
            log.verbose("[GTF:\(name)] Result of video sync: \(syncedVideoGeo)")
            /// The result is the new `outputVideoGeo`
            outputVideoGeo = syncedVideoGeo
          } else {
            // May not get vid-dec-params for network stream, and that's OK
            guard currentPlayback.isNetworkResource else {
              return abort("syncVideoParamsFromMpv returned nil for file")
            }
          }
        }
      }

      /// 2c: Apply `videoTransform` if present.
      /// This needs to be on the mpv queue, because some transforms make mpv calls.
      if let videoTransform {
        log.verbose("[GTF:\(name)] Calling videoTF")
        guard let transformedVidGeo = videoTransform(outputVideoGeo, ctxStage2) else {
          return abort("videoTF returned nil")
        }
        log.verbose("[GTF:\(name)] Result of videoTF: \(transformedVidGeo)")
        outputVideoGeo = transformedVidGeo
      } else {
        log.verbose("[GTF:\(name)] No videoTF given, skipping. Will use: \(outputVideoGeo)")
      }

      // MARK: - STAGE 3
      // -- main queue -------------------------------------------------------------------------
      Task { @MainActor in
        pwc.animationPipeline.submitInstantTask { [self] in
          // Do not reference these variables until inside this animation task to ensure serial access
          let inputLayout = pwc.currentLayout

          // Update context's geo with current window frame
          let inputGeoSet = pwc.buildGeoSet(layoutMode: inputLayout.mode,
                                            forceWinFrameUpdate: !gtfSessionState.isStartingSession)
          log.verbose("[GTF:\(name)] Input geoSet=\(inputGeoSet)")

          let ctxStage3 = GeometryTransform.ContextStage3(ctxStage2, gtfSessionState: gtfSessionState,
                                                          inputGeoSet: inputGeoSet, outputVidGeo: outputVideoGeo,
                                                          inputLayout: inputLayout)

          doMainQueueWork(ctxStage3)
        }
      }
    }
  }

  @MainActor
  private func doMainQueueWork(_ ctxInput: GeometryTransform.ContextStage3) {
    var ctx = ctxInput
    log.trace("[GTF:\(name)] Starting main thread work: startingSession=\(ctx.gtfSessionState.isStartingSession)")

    /// 3. Build tasks to transition the window to its "initial" layout (new sessions only)
    var immediateTasks: [IINAAnimation.Task] = buildInitialLayoutTasks(&ctx)

    var remainingTasks: [IINAAnimation.Task]
    /// 4. Build tasks which apply `pWinGeoTransform` (if it exists), as well as any needed adjustments for `outputVidGeo`.
    /// Important: must be called *after* building the initial layout tasks!
    /// (expects `ctx.outputLayout`, `ctx.needsNativeFullScreen` to have been set)
    if let buildPWinGeoTransformTasks {
      assert(pWinGeoTransform == nil, "buildPWinGeoTransformTasks & pWinGeoTransform cannot both be set")
      remainingTasks = buildPWinGeoTransformTasks(ctx)
    } else {
      remainingTasks = ctx.buildPWinGeoTransformTasks()
    }
    remainingTasks.append(.instantTask{ ctx.doPostApplyWork() })

    /// 5. Need to switch to/from music mode, or enter full screen (if not done elsewhere)?
    /// If so, append to "remaining" tasks.
    if let toggleMusicModeTasks = ctx.buildToggleMusicModeTasksIfNeeded() {
      remainingTasks += toggleMusicModeTasks
    } else if let enterFullScreenTask = ctx.buildEnterFullScreenTaskIfNeeded() {
      // Or need to enter full screen?
      remainingTasks.append(enterFullScreenTask)
    }

    // If restoring minimized: can't rely on showWindow() being called, but window changes won't be seen anyway.
    // So run end task right away even though it's technically starting a new session.
    let window = ctx.pwc.window!
    let isRestoringMinimizedWindow = ctx.gtfSessionState.isRestoring && UIState.shared.windowsMinimized.contains(window.savedStateName)
    if isRestoringMinimizedWindow {
      log.verbose("[GTF:\(name)] Restoring minimized window: will run tasks immediately instead of enqueueing")
    }

    if ctx.gtfSessionState.isStartingSession, !isRestoringMinimizedWindow {
      /// These tasks should not execute until *after* `super.showWindow` is called (in the post-layout task).
      log.verbose("[GTF:\(name)] Adding pending tasks: count=\(remainingTasks.count) timeTotal=\(remainingTasks.reduce(0) { $0 + $1.duration })")
      pwc.pendingVideoGeoUpdateTasks = remainingTasks
    } else {
      immediateTasks += remainingTasks
    }


    log.verbose("[GTF:\(name)] Submitting immediate tasks: count=\(immediateTasks.count) timeTotal=\(immediateTasks.reduce(0) { $0 + $1.duration })")
    pwc.animationPipeline.submit(immediateTasks)
  }

  /// For new sessions, constructs & returns tasks to set up the "initial" window layout.
  /// Returns empty list if no initial layout needed.
  ///
  /// This is in Stage 3 (main queue), and the value of `ctx.outputVidGeo` has already been determined.
  @MainActor
  private func buildInitialLayoutTasks(_ ctx: inout GeometryTransform.ContextStage3) -> [IINAAnimation.Task] {
    let window = ctx.pwc.window!

    switch ctx.gtfSessionState {

    case .restoring(let priorState):
      /// Restoring from prior launch.
      /// Side effects: sets `ctx.outputLayout`, `ctx.needsNativeFullScreen`.
      return ctx.pwc.buildTasksToRestoreLayout(priorState, &ctx)

    case .newReplacingOpen:
      /// Reusing existing window for new file.
      log.verbose("[GTF:\(ctx.name)] Opening a new file in an already open window, mode=\(ctx.inputLayout.mode)")

      /// `windowFrame` may be slightly off; update it
      if ctx.inputLayout.mode == .windowedNormal {
        /// Set this so that `transformGeometry` will use the correct default window frame if it looks for it.
        /// Side effect: future opened windows may use this size even if this window wasn't closed. Should be ok?
        PlayerWindowController.windowedModeGeoLastClosed = ctx.inputLayout.buildGeometry(windowFrame: window.frame,
                                                                                         screenID: ctx.pwc.bestScreen.screenID,
                                                                                         ctx.outputVidGeo)
      } else if ctx.inputLayout.mode == .musicMode {
        /// Set this so that `transformGeometry` will use the correct default window frame if it looks for it.
        PlayerWindowController.musicModeGeoLastClosed = ctx.inputGeoSet.musicMode.cloneMusicMode(windowFrame: window.frame,
                                                                                                 screenID: ctx.pwc.bestScreen.screenID,
                                                                                                 video: ctx.outputVidGeo)
      }
      // No initial layout tasks needed. Fall through to add finishing task
      return [ctx.buildFinalInitialLayoutTask()]

    case .creatingNew, .newReplacingClosed:
      log.verbose("[GTF:\(ctx.name)] Brand new window is opening: building initial layout tasks")
      /// Side effects: sets `ctx.outputLayout`, `ctx.needsNativeFullScreen`.
      return ctx.pwc.buildTasksForNewWindow(&ctx)

    default:
      log.verbose("[GTF:\(ctx.name)] No initial layout tasks needed")
      return []
    }
  }

  // MARK: - Context

  /// Builds on the state in the `GeometryTransform` object and adds the variables retrieved in Stage 2 (mpv queue).
  /// Used as input for `PWinSessionStateTF` & `VideoGeometryTF` functions.
  struct ContextStage2 : Sendable {
    /// The transform spec. Immutable.
    let tf: GeometryTransform

    // - Variables retrieved from mpv

    let currentPlayback: Playback
    let vidTrackID: Int
    let currentMediaAudioStatus: PlaybackInfo.MediaAudioStatus

    // - Other derived properties

    var name: String { tf.name }
    var player: PlayerCore { tf.player }
    var pwc: PlayerWindowController { player.pwc! }
    var log: any Logger.Subsystem { player.log }
  }

  /// Builds on the `ContextStage2` state, adding the results from the `PWinSessionState` & `VideoGeometry` transforms,
  /// & additional state retrieved / computed in the final main queue stage.
  /// Used as input for `PWinGeometry` transforms, as well as a useful container to pass around internal methods.
  struct ContextStage3: Sendable {
    let ctxStage2: ContextStage2

    var tf: GeometryTransform { ctxStage2.tf }
    var currentPlayback: Playback { ctxStage2.currentPlayback }
    var vidTrackID: Int { ctxStage2.vidTrackID }
    var currentMediaAudioStatus: PlaybackInfo.MediaAudioStatus { ctxStage2.currentMediaAudioStatus }

    /// The `PWinSessionState` at the start of the transform. In some cases this has been updated from
    /// `PlayerWindowController`'s `sessionState` to a value which is applicable only during the execution of the GTF.
    /// Do not query `PlayerWindowController.sessionState` during the transform. Use this instead.
    let gtfSessionState: PWinSessionState

    /// Contains most up-to-date version of the geometries (as well as possibly unapplied changes), which transforms should build
    /// on top of. (The `PlayerWindowController`'s `geo` field should not be referenced in any transform functions).
    var inputGeoSet: GeometrySet

    /// Returns the `VideoGeometry` from `inputGeoSet`.
    var inputVidGeo: VideoGeometry { inputGeoSet.video }
    /// The transformed `VideoGeometry`.
    let outputVidGeo: VideoGeometry

    let inputLayout: LayoutState

    /// Defaults to `inputLayout`, but can be overwritten by `buildWindowInitialLayoutTasks`.
    /// Do not reference until after that is called.
    var outputLayout: LayoutState

    fileprivate var needsNativeFullScreen = false

    // - Other derived properties

    var name: String { tf.name }
    var player: PlayerCore { tf.player }
    var pwc: PlayerWindowController { player.pwc! }
    var log: any Logger.Subsystem { player.log }

    init(_ ctxStage2: ContextStage2, gtfSessionState: PWinSessionState,
         inputGeoSet: GeometrySet, outputVidGeo: VideoGeometry,
         inputLayout: LayoutState) {
      self.ctxStage2 = ctxStage2
      self.gtfSessionState = gtfSessionState
      self.inputGeoSet = inputGeoSet
      self.outputVidGeo = outputVidGeo
      self.inputLayout = inputLayout
      self.outputLayout = inputLayout  // until updated
    }

    /// Default album art: to avoid race conditions, use the context's state instead of player.info
    /// If `showDefaultArt == nil`, don't change existing visibility.
    fileprivate var shouldChangeDefaultArt: Bool? {
      // Don't show art if currently loading
      if currentPlayback.state.isAtLeast(.loaded) {
        // Show art if no video track is selected (i.e., vid=0)
        return vidTrackID == 0
      }
      return nil
    }

    /// Applies the `pWinGeoTransform` (if it exists), and generates tasks which animate any changes caused
    /// by the transform  or by changes in `outputVidGeo`.
    /// Only `transformGeometry` should call this.
    @MainActor
    fileprivate func buildPWinGeoTransformTasks() -> [IINAAnimation.Task] {
      log.verbose("[GTF:\(name)] Building 'applyPWin' tasks, mode=\(outputLayout.mode) vidTrackID=\(vidTrackID) sess=\(gtfSessionState)")

      // There's no good animation for rotation (yet), so just do as little animation as possible in this case
      var duration: CGFloat = Constants.AnimationDuration.videoReconfig
      var timing = CAMediaTimingFunctionName.easeInEaseOut

      switch outputLayout.mode {

      case .windowedNormal:

        let resizedGeo: PWinGeometry?

        switch gtfSessionState {
        case .restoring:
          if currentPlayback.isNetworkResource, let showDefaultArt = shouldChangeDefaultArt {
            log.verbose("[GTF:\(name)] Restoring a streaming window: will set defaultArtVisibility to \(showDefaultArt.yn)")
            return [.instantTask {
              pwc.updateDefaultArtVisibility(to: showDefaultArt)
            }]
          }
          log.verbose("[GTF:\(name)] Restore is in progress: no 'apply' tasks needed for windowed mode")
          assert(tf.pWinGeoTransform == nil)
          return []

        case .creatingNew, .newReplacingClosed, .creatingCLI:
          // Just opened new window. Use a longer duration for this one, because the window starts small & will zoom into place.
          assert(tf.pWinGeoTransform == nil)
          duration = Constants.AnimationDuration.initialVideoReconfig
          timing = .linear
          resizedGeo = applyResizePrefsForNewPlaybackInWindowedMode()

        case .newReplacingOpen:
          duration = Constants.AnimationDuration.initialVideoReconfig
          fallthrough

        case .existingSession_startingNewPlayback:
          assert(tf.pWinGeoTransform == nil)
          resizedGeo = applyResizePrefsForNewPlaybackInWindowedMode()
          if let resizedGeo, resizedGeo.windowFrame != inputGeoSet.windowed.windowFrame {
          } else {
            // No need for animation if window's frame didn't change. Video param transitions are not animated by mpv
            duration = 0.0
          }

        case .existingSession_videoTrackChangedForSamePlayback, .existingSession_continuing:
          // Not a new file. Some other change to a video geo property. Use TF func if it exists.
          if let pWinGeoTransform = tf.pWinGeoTransform {
            log.verbose("[GTF:\(name)] Calling pWinGeoTransform")
            resizedGeo = pWinGeoTransform(self)
          } else {
            // Will resize minimally
            resizedGeo = nil
          }

        case .noSession, .closedSession:
          Logger.fatal("[GTF:\(name)] Invalid gtfSessionState: \(gtfSessionState)")
        }

        let outputGeo = resizedGeo ?? inputGeoSet.windowed.resizeMinimally(forNewVideoGeo: outputVidGeo)
        let showDefaultArt: Bool? = shouldChangeDefaultArt

        log.verbose("[GTF:\(name)] Building 'apply' tasks for windowed mode: sess=\(gtfSessionState) defaultArt=\(showDefaultArt?.yn ?? "nil") dur=\(duration) → \(outputGeo)")
        return pwc.buildApplyPWinGeoTasks(to: outputGeo, duration: duration, timing: timing, showDefaultArt: showDefaultArt)

      case .fullScreenNormal:
        let newWindowedGeo = inputGeoSet.windowed.resizeMinimally(forNewVideoGeo: outputVidGeo)
        let fsGeo = outputLayout.buildFullScreenGeometry(inScreenID: newWindowedGeo.screenID, outputVidGeo)
        let showDefaultArt: Bool? = shouldChangeDefaultArt

        log.verbose("[GTF:\(name)] Building 'apply' tasks for FS mode: defaultArt=\(showDefaultArt?.yn ?? "nil") dur=\(duration) \(fsGeo)")
        var tasks = pwc.buildApplyPWinGeoTasks(to: fsGeo, duration: duration, timing: timing, showDefaultArt: showDefaultArt)
        tasks.append(.instantTask {
          /// Update this even if not currently in windowed mode, as it is used to store the (updated) VideoGeometry
          pwc.windowedModeGeo = newWindowedGeo
        })
        return tasks

      case .musicMode:
        if case .creatingNew = gtfSessionState,
           case .restoring = gtfSessionState {
          log.verbose("[GTF:\(name)] No 'apply' tasks needed; music mode already handled for sessState=\(gtfSessionState): \(inputGeoSet.musicMode)")
          return []
        }
        let inputMusicModeGeo = inputGeoSet.musicMode  // has updated windowFrame
        let outputMusicModeGeo: PWinGeometry
        /// Use transformed music mode geo if provided. Otherwise update minimally for new `VideoGeometry`:
        if let pWinGeoTransform = tf.pWinGeoTransform, let transformedGeo = pWinGeoTransform(self) {
          assert(transformedGeo.mode == .musicMode, "[GTF:\(name)] Tranform expected to return geometry with mode=.musicMode, but got: \(transformedGeo) ")

          outputMusicModeGeo = transformedGeo

        } else {
          /// Keep prev `windowFrame`. Just adjust height to fit new video aspect ratio.
          /// (But call `refitted()` in case it doesn't fit on screen or other special cases).
          outputMusicModeGeo = inputMusicModeGeo.clone(video: outputVidGeo).refitted()
        }

        let isTogglingViewport = inputMusicModeGeo.isViewportShown != outputMusicModeGeo.isViewportShown
        let isTogglingPlaylist = inputMusicModeGeo.isMusicModePlaylistShown != outputMusicModeGeo.isMusicModePlaylistShown
        if isTogglingViewport || isTogglingPlaylist {
          // Only set nonzero duration for the step which is being applied
          duration = Constants.AnimationDuration.toggleVideoView
          let isOpeningViewport = !inputMusicModeGeo.isViewportShown && outputMusicModeGeo.isViewportShown
          let isClosingViewport = inputMusicModeGeo.isViewportShown && !outputMusicModeGeo.isViewportShown
          let isOpeningPlaylist = !inputMusicModeGeo.isMusicModePlaylistShown && outputMusicModeGeo.isMusicModePlaylistShown
          let isClosingPlaylist = inputMusicModeGeo.isMusicModePlaylistShown && !outputMusicModeGeo.isMusicModePlaylistShown
          let closingDuration = isClosingViewport || isClosingPlaylist ? duration : 0
          let openingDuration = isOpeningViewport || isOpeningPlaylist ? duration : 0

          log.verbose("[GTF:\(name)] Building transition tasks for musicMode: sess=\(gtfSessionState) togglingVideo=\(isTogglingViewport.yn) togglingPlaylist=\(isTogglingPlaylist.yn) dur=\(duration) → \(outputMusicModeGeo)")
          // Need to use LayoutTransition for complex layout changes
          let transition = pwc.buildLayoutTransition(named: name, from: inputLayout,
                                                     to: outputLayout, outputGeo: outputMusicModeGeo, inputGeoSet)
          return pwc.buildTasks(for: transition, totalStartingDuration: closingDuration, totalEndingDuration: openingDuration)
        } else {
          let showDefaultArt: Bool? = shouldChangeDefaultArt
          log.verbose("[GTF:\(name)] Building 'apply' tasks for musicMode: sess=\(gtfSessionState) defaultArt=\(showDefaultArt?.yn ?? "nil") dur=\(duration) → \(outputMusicModeGeo)")
          return pwc.buildApplyPWinGeoTasks(to: outputMusicModeGeo, duration: duration, showDefaultArt: showDefaultArt)
        }

      default:
        // Interactive mode. Should be handled by its special code. Don't step on it.
        log.warn("[GTF:\(name)] Invalid mode for 'apply': \(outputLayout.mode). Doing nothing")
        return []
      }
    }

    /// Conforms to `IINAnimation.TaskFunc`. Does cleanup, updates state vars & UI.
    @MainActor
    fileprivate func doPostApplyWork() {
      log.verbose("[GTF:\(name)] Running final task, sess=\(gtfSessionState) vid=\(vidTrackID)")
      let pwc = player.pwc!

      // (tag: #SessionState-Race)
      guard !player.isStopping else { return tf.abort("In final task (main): player is stopping") }

      if case .closedSession = pwc.sessionState {
        return tf.abort("In final task: found 'closedSession' for sessionState, assuming the player is stopping")
      }
      // Apply new session state (need to do this in .main). This will always be `.continuing`.
      pwc.sessionState = .existingSession_continuing

      // Must only modify currentPlayback state inside mpv queue
      player.mpv.queue.async{ [self] in
        guard !player.isStopping else { return tf.abort("In final task (mpv): player is stopping") }

        if gtfSessionState.isChangingVideoTrack {
          // Update `currentPlayback`'s state. If, by chance, playback has changed since the start of this GTF's
          // execution, then `player.info.currentPlayback` will have been set to a new object, and thus the
          // following updates will be made to a disused object and will not cause trouble.
          // (Posting the notifications below is similarly harmless - at leas for now. Unclear if/how they may
          // be used by plugins).

          // Wait until window is completely opened before setting this, so that OSD will not be displayed until then.
          // The OSD can have weird stretching glitches if displayed while zooming open...
          if currentPlayback.state == .loadedButNeedsSizing,
             let playerPlayback = player.info.currentPlayback, playerPlayback.id == currentPlayback.id,
             playerPlayback.state.isNotYet(.loadedAndSized) {
            log.debug("[GTF:\(name)] Updating playback.state = .loadedAndSized + will emit fileLoaded")
            player.info.currentPlayback = playerPlayback.changingState(to: .loadedAndSized)

            Task { @MainActor in
              pwc.animationPipeline.submitInstantTask {
                sendInitialWindowScaleToMpv()
                // Should refresh EDR each time switching files
                pwc.videoView.refreshAllVideoDisplayState()
                // If is network resource, may not be loaded yet. If file, it will be.
                player.postNotification(.iinaFileLoaded)
                player.events.emit(.fileLoaded, data: currentPlayback.url.absoluteString)
              }
            }
          }
        }
      }

      // If minimized, the call to DispatchQueue.main.async below doesn't seem to execute. Just do the below for all cases now.
      // Need to call here to ensure file title OSD is displayed when navigating playlist...
      player.refreshSyncUITimer()
      // Fix rare case where window is still invisible after closing in music mode and reopening in windowed
      pwc.updateWindowBorderAndOpacity()

      // Always do this in case the video geometry changed:
      player.setQuickSettingsViewNeedsUpdate()

      // Must force drawing to cover the case where this player was previously used to play a video
      // and is now playing an audio file without an album cover and without using music mode.
      // See issue #5403.
      pwc.videoView.forceDraw()

      if let onSuccess = tf.onSuccess {
        onSuccess()
      }

      pwc.animationPipeline.geoTransformDidFinish(tf, success: true)
    }

    /// This should only be called in response to start of new window session, or video track change
    @MainActor
    private func sendInitialWindowScaleToMpv() {
      let basisGeo: PWinGeometry

      // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
      switch outputLayout.mode {
      case .windowedNormal:
        basisGeo = pwc.windowedModeGeo
      case .musicMode:
        basisGeo = pwc.musicModeGeo
      case .fullScreenNormal:
        basisGeo = outputLayout.buildFullScreenGeometry(inScreenID: pwc.windowedModeGeo.screenID, outputVidGeo)
      default:
        return
      }

      log.verbose("[mpv-window-scale] Calling sendWindowScaleToMPV for initial geometry")
      pwc.sendWindowScaleToMPV(basedOn: basisGeo)
    }

    /// Applies the prefs `.resizeWindowTiming` & `resizeWindowScheme`, if applicable.
    /// Returns `nil` if no applicable settings were found/applied, and should fall back to minimal resize.
    @MainActor
    private func applyResizePrefsForNewPlaybackInWindowedMode() -> PWinGeometry? {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        log.verbose("[GTF:\(name)] FileOpened & resizeTiming='Always' → will resize window")
      case .onlyWhenOpen:
        if !gtfSessionState.isStartingNewPlaybackManually {
          log.verbose("[GTF:\(name)] FileOpened & resizeTiming='OnlyWhenOpen', but isStartingNewPlaybackManually=N → will resize minimally")
          return nil
        }
      case .never:
        if !gtfSessionState.isStartingNewPlaybackManually {
          log.verbose("[GTF:\(name)] FileOpened (not manually) & resizeTiming='Never' → will resize minimally")
          return nil
        }
        log.verbose("[GTF:\(name)] FileOpenedManually & resizeTiming='Never' → using windowedModeGeoLastClosed: \(PlayerWindowController.windowedModeGeoLastClosed)")
        return outputLayout.convertWindowedModeGeometry(from: PlayerWindowController.windowedModeGeoLastClosed,
                                                        video: outputVidGeo,
                                                        pinWidthOrHeightIfAtMax: true,
                                                        applyOffsetIndex: player.openedWindowsSetIndex, log)
      }

      let windowGeo = inputGeoSet.windowed.clone(video: outputVidGeo)
      let screenVisibleFrame = NSScreen.getScreenOrDefault(screenID: windowGeo.screenID).visibleFrame

      let resizeScheme: Preference.ResizeWindowScheme = Preference.enum(for: .resizeWindowScheme)
      switch resizeScheme {
      case .mpvGeometry:
        // check if have mpv geometry set (initial window position/size)
        guard let mpvGeometry = player.getMPVGeometry() else {
          if gtfSessionState.isStartingNewPlaybackManually {
            log.debug("[GTF:\(name)] No mpv geometry found, starting new playback: will fall back to windowedModeGeoLastClosed")
            return outputLayout.convertWindowedModeGeometry(from: PlayerWindowController.windowedModeGeoLastClosed,
                                                            video: outputVidGeo,
                                                            pinWidthOrHeightIfAtMax: true,
                                                            applyOffsetIndex: player.openedWindowsSetIndex, log)
          } else {
            log.debug("[GTF:\(name)] No mpv geometry found. Will fall back to minimal resize")
            return nil
          }
        }

        var preferredGeo = windowGeo
        if Preference.bool(for: .lockViewportToVideoSize) {
          // There is some fuzziness for window size when lockViewportToVideoSize==true. Try to provide a strong hint
          preferredGeo = inputGeoSet.windowed.resizeMinimally(forNewVideoGeo: outputVidGeo)
        }
        log.verbose("[GTF:\(name)] Applying mpv \(mpvGeometry) within screen \(screenVisibleFrame)")
        return windowGeo.apply(mpvGeometry: mpvGeometry, desiredWindowSize: preferredGeo.windowFrame.size)

      case .simpleVideoSizeMultiple:
        let resizeWindowStrategy: Preference.ResizeWindowOption = Preference.enum(for: .resizeWindowOption)
        if resizeWindowStrategy == .fitScreen {
          log.verbose("[GTF:\(name)] ResizeWindowOption=FitToScreen. Using screenFrame \(screenVisibleFrame)")
          return windowGeo.scalingViewport(to: screenVisibleFrame.size, screenFit: .centerInside)
        } else {
          let resizeRatio = resizeWindowStrategy.ratio
          let scaledVideoWidth = (outputVidGeo.videoSizeCAR.width * resizeRatio).rounded()
          log.verbose("[GTF:\(name)] Applied resizeRatio (\(resizeRatio)) to newVideoWidth → \(scaledVideoWidth)")
          let centeredScaledGeo = windowGeo.scalingVideo(toWidth: scaledVideoWidth, screenFit: .centerInside, mode: outputLayout.mode)
          log.verbose("[GTF:\(name)] After scaleVideo: \(centeredScaledGeo)")
          return centeredScaledGeo
        }
      }
    }

    /// Post-layout task: update various internal UI stuff, and finally (maybe) post `windowIsReadyToShow` or `windowMustCancelShow`.
    /// Requires `ctx.outputLayout`.
    @MainActor
    fileprivate func buildFinalInitialLayoutTask() -> IINAAnimation.Task {
      return IINAAnimation.Task.instantTask{
        log.verbose("[GTF:\(name)] Running final initial layout task")
        // Run this early when restoring, before showWindow(), to avoid noticeable color flickering
        pwc.videoView.refreshAllVideoDisplayState()

        player.refreshSyncUITimer()
        DispatchQueue.main.async { [self] in
          player.touchBarSupport.setupTouchBarUI()
        }

        // At this point it is safe to assume that `musicModeGeo` will have be set
        let shouldDecideDefaultArtStatus = !outputLayout.isMusicMode || pwc.musicModeGeo.isViewportShown
        let showDefaultArt: Bool? = shouldDecideDefaultArtStatus ? shouldChangeDefaultArt : nil
        if let showDefaultArt {
          // May need to set this while restoring a network audio stream
          pwc.updateDefaultArtVisibility(to: showDefaultArt)
        }

        pwc.updateTitle()
        pwc.playlistView.needsScrollToCurrentItem = true  // reset flag for when it does open

        pwc.addAllObservers()

        if gtfSessionState.isStartingNewSession {
          // Make sure to always do this for new session:
          player.reloadQuickSettingsViewNow()
        }

        // Post "ready to show" notification? Or post cancellation? Or do nothing more?
        if case .restoring(let previousState) = gtfSessionState {
          if let (miniturized, hidden) = pwc.restoreFromMiscWindowBools(previousState) {
            if miniturized {
              log.verbose("[GTF:\(name)] Previously minimized window is being restored: skipping windowIsReadyToShow")
              return
            }

            if hidden {
              log.verbose("[GTF:\(name)] Previously hidden video is being restored: posting windowMustCancelShow")
              pwc.postWindowMustCancelShow()
              return
            }
          }
        }

        /// This will fire a notification to `AppDelegate` which will respond by calling `showWindow` when all windows are ready. Post this always.
        log.verbose("[GTF:\(name)] Done with initial layout: posting windowIsReadyToShow")
        pwc.videoView.activateForcedRedraws()  // needed if restoring while paused
        pwc.postWindowIsReadyToShow()
      }
    }

    @MainActor
    fileprivate func buildToggleMusicModeTasksIfNeeded() -> [IINAAnimation.Task]? {
      guard Preference.bool(for: .autoSwitchToMusicMode) else { return nil }

      switch gtfSessionState {
      case .existingSession_startingNewPlayback,
          .newReplacingOpen:

        let layout = outputLayout
        if player.overrideAutoMusicMode {
          log.verbose("[GTF:\(name)] Skipping music mode auto-switch ∴ overrideAutoMusicMode=Y")
          return nil
        } else if currentMediaAudioStatus.isAudio && !layout.isMusicMode && !layout.isFullScreen {
          log.debug("[GTF:\(name)] Opened media is audio: auto-switching to music mode")
          let geo = pwc.buildGeoSet(video: outputVidGeo, layoutMode: layout.mode)
          return pwc.buildTasksToEnterMusicMode(automatically: true, from: layout, geo)
        } else if currentMediaAudioStatus == .notAudio && layout.isMusicMode {
          log.debug("[GTF:\(name)] Opened media is not audio: auto-switching to normal window")
          let geo = pwc.buildGeoSet(video: outputVidGeo, layoutMode: layout.mode)
          return pwc.buildTasksToExitMusicMode(automatically: true, from: layout, geo)
        }
      default:
        break
      }
      return nil
    }

    @MainActor
    fileprivate func buildEnterFullScreenTaskIfNeeded() -> IINAAnimation.Task? {
      guard needsNativeFullScreen else { return nil }

      return IINAAnimation.Task.instantTask {
        log.debug("[GTF:\(name)] Changing to full screen because \(Preference.Key.fullScreenWhenOpen.rawValue)==Y")
        pwc.enterFullScreen()
      }
    }

  }  // end struct GeometryTransform.ContextStage3
}

// MARK: - Window Initial Layout

extension PlayerWindowController {

  /// Generates animation tasks to adjust the window layout appropriately for a newly opened file.
  @MainActor
  private func buildTransitionTasksToInitialLayout(_ ctx: GeometryTransform.ContextStage3,
                                                   outputGeoSet: GeometrySet) -> [IINAAnimation.Task] {

    // Set this now, instead of waiting for it to be set by `initialTransition`.
    // Don't want window resize/move listeners doing something untoward.
    isAnimatingLayoutTransition = true

    // Send GeometrySet object to builder so that it doesn't default to current window frame
    log.verbose("[GTF:\(ctx.name)] Setting initial \(ctx.outputLayout), windowedModeGeo=\(outputGeoSet.windowed), musicModeGeo=\(outputGeoSet.musicMode)")

    let isRestoring = ctx.gtfSessionState.isRestoring
    let transitionName = "\(isRestoring ? "Restore" : "Set")InitialLayout"
    let initialTransition = buildLayoutTransition(named: transitionName,
                                                  from: ctx.inputLayout, to: ctx.outputLayout,
                                                  isWindowInitialLayout: true, outputGeoSet)
    var tasks: [IINAAnimation.Task] = []

    tasks.append(.instantTask { [self] in
      // For initial layout (when window is first shown), to avoid jitteriness when drawing, do all the layout
      // in a single animation block.
      do {
        for task in buildTasks(for: initialTransition) {
          try task.runFunc()
        }
      } catch {
        log.error("[GTF:\(ctx.name)] Failed to run initial layout tasks: \(error)")
      }

      // Reset other views to initial minimums:
      speedLabelBtmConstraint.isActive = false

      hideSeekPreviewImmediately()

      if !ctx.outputLayout.mode.isInteractiveMode {
        /// Set `window.contentView`'s background to black so that the windows behind this one don't bleed through
        /// when `lockViewportToVideoSize` is disabled, or when in legacy full screen on a Macbook screen  with a
        /// notch and the preference `allowVideoToOverlapCameraHousing` is false. Also needed so that sidebars don't
        /// bleed through during their show/hide animations.
        setEmptySpaceColor(to: Constants.Color.defaultWindowBackgroundColor)
      }

      if !isRestoring {
        if ctx.outputLayout.mode == .windowedNormal {
          // Set window opacity to 0 initially to start fade-in effect
          updateWindowBorderAndOpacity(using: ctx.outputLayout, windowOpacity: 0.0)
        }

        if !ctx.outputLayout.isFullScreen, Preference.bool(for: .alwaysFloatOnTop) && !player.info.isPaused {
          log.verbose("[GTF:\(ctx.name)] Setting window OnTop=Y per app pref")
          setWindowFloatingOnTop(true, from: ctx.outputLayout)
        }
      }

      /// Note: `isAnimatingLayoutTransition` should be `false` now
      log.verbose("[GTF:\(ctx.name)] Done with transition to initial layout")
    })

    if isRestoring {
      /// Stored window state may not be consistent with global IINA prefs.
      /// To check this, build another `LayoutState` from the global prefs, then compare it to the player's.
      let prefsLayout = LayoutState.fromPrefs(fillingInFrom: ctx.outputLayout)
      if validateLayoutFields(from: ctx.outputLayout, matchLayoutFromPrefs: prefsLayout) {
        log.verbose("[GTF:\(ctx.name)] Saved layout is consistent with IINA global prefs")
      } else {
        // Not consistent. But we already have the correct spec, so just build a layout from it and transition to correct layout
        log.errorDebugAlert("Player's saved layout does not match IINA app prefs! Will attempt to fix & apply a corrected layout")
        log.debug("[GTF:\(ctx.name)] SavedLayout=\(currentLayout). LayoutFromPrefs=\(prefsLayout)")
        let repairTransition = buildLayoutTransition(named: "FixInvalidInitialLayout",
                                                     from: initialTransition.outputLayout, to: prefsLayout)

        tasks.append(contentsOf: buildTasks(for: repairTransition))
      }
    }

    tasks.append(ctx.buildFinalInitialLayoutTask())

    return tasks
  }

  /// Returns `true` if `other` has the same values which are configured from IINA app-wide prefs
  @MainActor
  fileprivate func validateLayoutFields(from tgt: LayoutState, matchLayoutFromPrefs pref: LayoutState) -> Bool {
    func cmpAndLogError(_ expected: AnyHashable, _ actual: AnyHashable, _ fieldName: String) -> Bool {
      if expected == actual {
        return true
      }
      log.warn("Field \(fieldName.quoted) does not match prefs value! Expected=\(expected) Actual=\(actual)")
      return false
    }
    var allEqual = true
    allEqual = allEqual && cmpAndLogError(pref.enableOSC, tgt.enableOSC, "enableOSC")
    allEqual = allEqual && cmpAndLogError(pref.oscPosition, tgt.oscPosition, "oscPosition")
    allEqual = allEqual && cmpAndLogError(pref.oscColorScheme, tgt.oscColorScheme, "oscColorScheme")
    allEqual = allEqual && cmpAndLogError(pref.isLegacyStyle, tgt.isLegacyStyle, "isLegacyStyle")
    allEqual = allEqual && cmpAndLogError(pref.topBarPlacement, tgt.topBarPlacement, "topBarPlacement")
    allEqual = allEqual && cmpAndLogError(pref.bottomBarPlacement, tgt.bottomBarPlacement, "bottomBarPlacement")
    allEqual = allEqual && cmpAndLogError(pref.leadingSidebarPlacement, tgt.leadingSidebarPlacement, "leadingSidebarPlacement")
    allEqual = allEqual && cmpAndLogError(pref.trailingSidebarPlacement, tgt.trailingSidebarPlacement, "trailingSidebarPlacement")
    allEqual = allEqual && cmpAndLogError(pref.leadingSidebar.tabGroups, tgt.leadingSidebar.tabGroups, "leadingSidebar.tabGroups")
    allEqual = allEqual && cmpAndLogError(pref.trailingSidebar.tabGroups, tgt.trailingSidebar.tabGroups, "trailingSidebar.tabGroups")
    // Allow different values for `moreSidebarState.playlistSidebarWidth` in different windows even though it's in prefs
    return allEqual
  }

  /// Creates tasks which transition to initial layout for a window which is being restored (`PWinSessionState.restoring`).
  /// Side effects: sets `ctx.outputLayout`.
  @MainActor
  fileprivate func buildTasksToRestoreLayout(_ priorState: PlayerSaveState,
                                             _ ctx: inout GeometryTransform.ContextStage3) -> [IINAAnimation.Task] {
    let modeToRestore: PlayerWindowMode
    if let priorLayout = priorState.layoutState {
      ctx.outputLayout = priorLayout
      modeToRestore = priorLayout.mode
      ctx.needsNativeFullScreen = priorState.needsNativeFullScreen
      log.verbose("[GTF:\(ctx.name)] Transitioning to initial layout from prior window state: mode=\(modeToRestore), needsNativeFS=\(ctx.needsNativeFullScreen.yn)")
    } else {
      log.error("[GTF:\(ctx.name)] Failed to read LayoutState object for restore! Will try to assemble window from prefs instead")
      modeToRestore = .windowedNormal
      ctx.outputLayout = LayoutState.fromPrefs(andMode: modeToRestore, fillingInFrom: lastWindowedLayoutState)
    }

    return buildTransitionTasksToInitialLayout(ctx, outputGeoSet: priorState.geoSet)
  }

  /// Creates tasks which transition to initial layout for a brand new, greenfield window (`PWinSessionState.creatingNew`).
  /// Side effects: sets `ctx.outputLayout`, `ctx.needsNativeFullScreen`.
  @MainActor
  fileprivate func buildTasksForNewWindow(_ ctx: inout GeometryTransform.ContextStage3) -> [IINAAnimation.Task] {
    let mode: PlayerWindowMode

    if player.startInMusicModeRequested {
      log.debug("[GTF:\(ctx.name)] Will open window in music mode as requested via CLI")
      player.startInMusicModeRequested = false  // reset for reuse
      mode = .musicMode
    } else if Preference.bool(for: .autoSwitchToMusicMode) && ctx.currentMediaAudioStatus.isAudio {
      log.debug("[GTF:\(ctx.name)] Opened media is audio: will open window in music mode")
      mode = .musicMode
    } else if Preference.bool(for: .fullScreenWhenOpen) {
      player.didEnterFullScreenViaUserToggle = false
      let useLegacyFS = Preference.bool(for: .useLegacyFullScreen)
      log.debug("[GTF:\(ctx.name)] Changing to \(useLegacyFS ? "legacy " : "")fullscreen because \(Preference.Key.fullScreenWhenOpen.rawValue)==Y")
      if useLegacyFS {
        mode = .fullScreenNormal
      } else {
        mode = .windowedNormal
        ctx.needsNativeFullScreen = true
      }
    } else {
      mode = .windowedNormal  // default
    }

    // Set to default layout, but use existing aspect ratio & video size for now, because we don't have that info yet for the new video
    ctx.outputLayout = LayoutState.fromPrefs(andMode: mode, fillingInFrom: lastWindowedLayoutState)

    let outputGeoSet = buildGeoSetForNewWindow(ctx)
    return buildTransitionTasksToInitialLayout(ctx, outputGeoSet: outputGeoSet)
  }

  /// Builds the initial `GeometrySet` for a brand new window (case `PWinSessionState.creatingNew`).
  ///
  /// - Uses `musicModeGeoLastClosed` for `musicMode`
  /// - Uses `windowedModeGeoLastClosed` for `windowedMode` if not in windowed mode, but uses a minimized window if in windowed mode
  ///   (as the start of window open animation)
  @MainActor
  private func buildGeoSetForNewWindow(_ ctx: GeometryTransform.ContextStage3) -> GeometrySet {
    // Should only be here if window is a new window or was previously closed. Copy layout from the last closed window
    let musicModeGeo = PlayerWindowController.musicModeGeoLastClosed.clone(video: ctx.outputVidGeo)

    let windowedModeGeo: PWinGeometry
    if ctx.outputLayout.isFullScreen || ctx.outputLayout.isMusicMode {
      windowedModeGeo = PlayerWindowController.windowedModeGeoLastClosed

    } else {
      /// Use `minVideoSize` at first when a new window is opened, so that when `GeometryTransform` is submitted shortly after,
      /// it expands and creates a nice zooming effect. But try to start with video's correct aspect, if available
      let viewportSize = CGSize.computeMinSize(withAspect: ctx.outputVidGeo.videoAspectCAR,
                                               minWidth: Constants.Window.minViewportSize.width,
                                               minHeight: Constants.Window.minViewportSize.height)
      let intendedWindowSize = NSSize(width: viewportSize.width + ctx.outputLayout.outsideBars.totalWidth,
                                      height: viewportSize.height + ctx.outputLayout.outsideBars.totalHeight)
      let windowFrame = NSRect(origin: NSPoint.zero, size: intendedWindowSize)
      /// Change the window origin so that it opens where the mouse was when `openURLs` was called. This visually reinforces the user-initiated
      /// behavior and is less jarring than popping out of the periphery. It will move while zooming to its final location, which remains
      /// well-defined based on current user prefs and/or last closed window.
      let mouseLoc = PlayerCore.mouseLocationAtLastOpen ?? NSEvent.mouseLocation
      let mouseLocScreenID = NSScreen.getOwnerOrDefaultScreenID(forPoint: mouseLoc, fallbackScreenID: ctx.inputGeoSet.windowed.screenID)
      let initialGeo = ctx.outputLayout.buildGeometry(windowFrame: windowFrame, screenID: mouseLocScreenID, ctx.outputVidGeo)
        .refitted(using: .stayInside)
      let windowSize = initialGeo.windowFrame.size
      let windowOrigin = NSPoint(x: round(mouseLoc.x - (windowSize.width * 0.5)), y: round(mouseLoc.y - (windowSize.height * 0.5)))
      log.verbose("[GTF:\(ctx.name)] Initial layout: starting with tiny window, videoAspect=\(ctx.outputVidGeo.videoAspectCAR), windowSize=\(windowSize)")
      windowedModeGeo = initialGeo.clone(windowFrame: NSRect(origin: windowOrigin, size: windowSize)).refitted(using: .stayInside)
    }

    return GeometrySet(windowed: windowedModeGeo, musicMode: musicModeGeo, video: ctx.outputVidGeo)
  }

}
