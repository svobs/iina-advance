//
//  MPV_EventHandling.swift
//  iina
//
//  Created by Matt Svoboda on 2025-03-27.
//  Copyright © 2025 lhc. All rights reserved.

extension MPVController {
  static let observeProperties: [String: mpv_format] = [
    MPVProperty.trackList: MPV_FORMAT_NONE,
    MPVProperty.vf: MPV_FORMAT_NONE,
    MPVProperty.af: MPV_FORMAT_NONE,
    MPVProperty.audioDeviceList: MPV_FORMAT_NONE,
    MPVOption.Video.videoAspectOverride: MPV_FORMAT_NONE,
    MPVOption.TrackSelection.vid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.aid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.sid: MPV_FORMAT_INT64,
    MPVOption.Subtitles.secondarySid: MPV_FORMAT_INT64,
    MPVOption.PlaybackControl.pause: MPV_FORMAT_FLAG,
    MPVOption.PlaybackControl.loopPlaylist: MPV_FORMAT_STRING,
    MPVOption.PlaybackControl.loopFile: MPV_FORMAT_STRING,
    MPVOption.PlaybackControl.abLoopA: MPV_FORMAT_DOUBLE,
    MPVOption.PlaybackControl.abLoopB: MPV_FORMAT_DOUBLE,
    MPVOption.PlaybackControl.abLoopCount: MPV_FORMAT_STRING,
    MPVOption.OSD.osdLevel: MPV_FORMAT_INT64,
    MPVProperty.chapter: MPV_FORMAT_INT64,
    MPVOption.Video.deinterlace: MPV_FORMAT_FLAG,
    MPVOption.Video.hwdec: MPV_FORMAT_STRING,
    MPVOption.Video.videoRotate: MPV_FORMAT_INT64,
    MPVOption.Video.videoZoom: MPV_FORMAT_DOUBLE,
    MPVOption.Video.videoPanX: MPV_FORMAT_DOUBLE,
    MPVOption.Video.videoPanY: MPV_FORMAT_DOUBLE,
    MPVProperty.dwidth: MPV_FORMAT_INT64,
    MPVProperty.dheight: MPV_FORMAT_INT64,
    MPVOption.Audio.mute: MPV_FORMAT_FLAG,
    MPVOption.Audio.volume: MPV_FORMAT_DOUBLE,
    MPVOption.Audio.audioDelay: MPV_FORMAT_DOUBLE,
    MPVOption.PlaybackControl.speed: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subCodepage: MPV_FORMAT_STRING,
    MPVOption.Subtitles.secondarySubVisibility: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.secondarySubDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.secondarySubPos: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subPos: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subColor: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subFont: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subFontSize: MPV_FORMAT_INT64,
    MPVOption.Subtitles.subBold: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.subBorderColor: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subBorderSize: MPV_FORMAT_INT64,
    MPVOption.Subtitles.subBackColor: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subScale: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subVisibility: MPV_FORMAT_FLAG,
    MPVOption.Equalizer.contrast: MPV_FORMAT_INT64,
    MPVOption.Equalizer.brightness: MPV_FORMAT_INT64,
    MPVOption.Equalizer.gamma: MPV_FORMAT_INT64,
    MPVOption.Equalizer.hue: MPV_FORMAT_INT64,
    MPVOption.Equalizer.saturation: MPV_FORMAT_INT64,
    MPVOption.Window.keepaspectWindow: MPV_FORMAT_FLAG,
    MPVOption.Window.fullscreen: MPV_FORMAT_FLAG,
    MPVOption.Window.ontop: MPV_FORMAT_FLAG,
    MPVOption.Window.cursorAutohide: MPV_FORMAT_STRING,
    MPVOption.Window.cursorAutohideFsOnly: MPV_FORMAT_FLAG,
    /// As of mpv 0.38, cannot listen for `MPVProperty.currentWindowScale`
    MPVProperty.windowScale: MPV_FORMAT_DOUBLE,
    MPVProperty.mediaTitle: MPV_FORMAT_STRING,
    MPVProperty.videoParamsRotate: MPV_FORMAT_INT64,
    MPVProperty.videoParamsPrimaries: MPV_FORMAT_STRING,
    MPVProperty.videoParamsGamma: MPV_FORMAT_STRING,
    MPVProperty.idleActive: MPV_FORMAT_FLAG,
    MPVProperty.currentAo: MPV_FORMAT_STRING
  ]

  func addEventCallbacks() {
    // Set a custom function that should be called when there are new events.
    mpv_set_wakeup_callback(self.mpv, { (ctx) in
      let mpvController = unsafeBitCast(ctx, to: MPVController.self)
      mpvController.readEvents()
    }, mutableRawPointerOf(obj: self))

    // Observe properties.

    for (k, v) in MPVController.observeProperties {
      mpv_observe_property(mpv, 0, k, v)
    }
  }

  /// Start listening for the given property
  func observe(property: String, format: mpv_format = MPV_FORMAT_DOUBLE) {
    player.log.verbose("Adding mpv observer for prop \(property.quoted)")
    mpv_observe_property(mpv, 0, property, format)
  }


  /// As events arrive, read one at a time & handle it async
  func readEvents() {
    queue.async {
      while ((self.mpv) != nil) {
        let event = mpv_wait_event(self.mpv, 0)!
        let eventId = event.pointee.event_id
        // Do not deal with mpv-event-none
        if eventId == MPV_EVENT_NONE {
          break
        }
        self.handleEvent(event)
        // Must stop reading events once the mpv core is shutdown.
        if eventId == MPV_EVENT_SHUTDOWN {
          break
        }
      }
    }
  }

  /// Process the event
  private func handleEvent(_ event: UnsafePointer<mpv_event>!) {
    let eventId: mpv_event_id = event.pointee.event_id

    switch eventId {
    case MPV_EVENT_NONE:
      break

    case MPV_EVENT_PROPERTY_CHANGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      if let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee {
        propertyDidChange(property)
      }

    case MPV_EVENT_QUEUE_OVERFLOW:
      player.log.errorDebugAlert("An mpv event queue overflow was reported!")

    case MPV_EVENT_CLIENT_MESSAGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      let msg = UnsafeMutablePointer<mpv_event_client_message>(dataOpaquePtr)
      let numArgs: Int = Int((msg?.pointee.num_args)!)
      var args: [String] = []
      if numArgs > 0 {
        let bufferPointer = UnsafeBufferPointer(start: msg?.pointee.args, count: numArgs)
        for i in 0..<numArgs {
          args.append(String(cString: (bufferPointer[i])!))
        }

        if args[0] == "thumbfast-info", args.count > 1 {
          if let thumbfastInfo = ThumbfastInfo.fromJSON(args[1], player.log) {
            self.thumbfastInfo = thumbfastInfo
          }
        }
      }
      player.log.verbose("Got mpv '\(eventId)': \(numArgs >= 0 ? "\(args)": "numArgs=\(numArgs)")")

    case MPV_EVENT_SHUTDOWN:
      player.log.verbose("Got mpv shutdown event")
      player.mpvHasShutdown()

    case MPV_EVENT_LOG_MESSAGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      guard let dataPtr = UnsafeMutablePointer<mpv_event_log_message>(dataOpaquePtr) else { break }
      let prefix = String(cString: (dataPtr.pointee.prefix)!)
      let level = String(cString: (dataPtr.pointee.level)!)
      let text = String(cString: (dataPtr.pointee.text)!)

      mpvLogScanner.processLogLine(prefix: prefix, level: level, msg: text)

    case MPV_EVENT_HOOK:
      let userData = event.pointee.reply_userdata
      let hookEvent = event.pointee.data.bindMemory(to: mpv_event_hook.self, capacity: 1).pointee
      let hookID = hookEvent.id
      guard let hook = $hooks.withLock({ $0[userData] }) else {
        // Hook not found, probably because it's from an unloaded plugin.
        // Still need to call hook_continue otherwise it will stuck.
        player.log.warn("Hook \(hookID) not found")
        mpv_hook_continue(self.mpv, hookID)
        break
      }
      hook.call {
        mpv_hook_continue(self.mpv, hookID)
      }

    case MPV_EVENT_AUDIO_RECONFIG, MPV_EVENT_VIDEO_RECONFIG:
      break

    case MPV_EVENT_START_FILE:
      guard let path = getString(MPVProperty.path) else {
        // this can happen when file fails to load
        player.log.error("FileStarted: no path!")
        break
      }
      /// Do not use `playlist_entry_id`. It doesn't make sense outside of FileStarted & FileEnded
      let playlistPos = getInt(MPVProperty.playlistPos)

      player.fileStarted(path: path, playlistPos: playlistPos)

    case MPV_EVENT_FILE_LOADED:
      player.fileLoaded()

    case MPV_EVENT_SEEK:
      if needRecordSeekTime {
        recordedSeekStartTime = CACurrentMediaTime()
      }
      player.seeking()

    case MPV_EVENT_PLAYBACK_RESTART:
      if needRecordSeekTime {
        recordedSeekTimeListener?(CACurrentMediaTime() - recordedSeekStartTime)
        recordedSeekTimeListener = nil
      }

      player.playbackRestarted()

    case MPV_EVENT_END_FILE:
      // if receive end-file when loading file, might be error
      // wait for idle
      guard let dataPtr = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)) else { break }
      let reasonString = dataPtr.pointee.reasonString
      let reasonEnum = event!.pointee.data.load(as: mpv_end_file_reason.self)
      let dueToStopCommand = reasonEnum == MPV_END_FILE_REASON_STOP
      // let reasonString = dataPtr.pointee.reasonString
      player.log.verbose("FileEnded reason=\(reasonEnum.rawValue) detail=\(reasonString.quoted)")
      player.fileEnded(dueToStopCommand: dueToStopCommand, errorDetail: reasonString)

    case MPV_EVENT_COMMAND_REPLY:
      let reply = event.pointee.reply_userdata
      if reply == MPVController.UserData.screenshot {
        let code = event.pointee.error
        guard code >= 0 else {
          let error = errorString(code)
          player.log.error("Cannot take a screenshot, mpv API error: \(error), returnCalue: \(code)")
          // Unfortunately the mpv API does not provide any details on the failure. The error
          // code returned maps to "error running command", so all the alert can report is
          // that we cannot take a screenshot.
          DispatchQueue.main.async {
            Utility.showAlert("screenshot.error_taking")
          }
          return
        }
        player.screenshotCallback()
      } else if reply == MPVController.UserData.screenshotRaw {
        let code = event.pointee.error
        guard code >= 0 else {
          let error = errorString(code)
          player.log.error("Cannot take a screenshot, mpv API error: \(error), returnCalue: \(code)")
          // Unfortunately the mpv API does not provide any details on the failure. The error
          // code returned maps to "error running command", so all the alert can report is
          // that we cannot take a screenshot.
          DispatchQueue.main.async {
            Utility.showAlert("screenshot.error_taking")
          }
          return
        }
        guard var dataNode = UnsafeMutablePointer<mpv_node>(OpaquePointer(event.pointee.data))?.pointee else {
          player.log.error("No data for screenshot-raw response!")
          break
        }
        defer {
          mpv_free_node_contents(&dataNode)
        }

        if let cgImage = parseScreenshotRaw(dataNode) {
          player.log.verbose("Successfully created CGImage from screenshot-raw data")
          let screenshotImage = NSImage(cgImage: cgImage, size: cgImage.size())
          player.screenshotRawCallback(screenshotImage)
        }
      }

    case MPV_EVENT_QUEUE_OVERFLOW:
      // The mpv event system uses an event queue of limited size. If events are not read quickly
      // enough the queue can overflow resulting in events being dropped. This event indicates the
      // ringbuffer overflowed and at least one event was dropped. IINA can recover from the loss of
      // some types of mpv events, but certain mpv events are critical. If a critical event is
      // discarded IINA will experience severe malfunctions. For this reason most of the work of
      // processing an event is dispatched to other queues so that MPVController can move on to
      // reading the next event. This event indicates something went wrong and IINA failed to read
      // events fast enough. As IINA has been ignoring this event we don't know if this has been
      // occurring. For now log this as an error. May want to switch to an alert in the future.
      log.error("Critical failure, mpv events lost, queue overflowed")

    default:
      player.log.trace("Unhandled mpv event: \(eventId)")
      break
    }

    // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
    // plugins from a task in this queue. Accessing EventController data from a thread in this queue
    // results in data races that can cause a crash. See issue 3986.
    if Preference.bool(for: .iinaEnablePluginSystem) {
      DispatchQueue.main.async { [self] in
        let eventName = "mpv.\(String(cString: mpv_event_name(eventId)))"
        player.events.emit(.init(eventName))
      }
    }
  }

  // MARK: - Property listeners

  private func propertyDidChange(_ property: mpv_event_property) {
    let name = String(cString: property.name)

    switch name {

    case MPVProperty.audioDeviceList:
      player.audioDeviceListChanged()

    case MPVProperty.videoParams:
      player.log.verbose("Δ mpv prop: \(MPVProperty.videoParams.quoted)")
      player.setQuickSettingsViewNeedsUpdate()

    case MPVProperty.videoOutParams:
      /** From the mpv manual:
       ```
       video-out-params
       Same as video-params, but after video filters have been applied. If there are no video filters in use, this will contain the same values as video-params. Note that this is still not necessarily what the video window uses, since the user can change the window size, and all real VOs do their own scaling independently from the filter chain.

       Has the same sub-properties as video-params.
       ```
       */
      player.log.verbose("Δ mpv prop: \(MPVProperty.videoOutParams.quoted)")
      break

    case MPVProperty.videoParamsRotate:
      /** `video-params/rotate: Intended display rotation in degrees (clockwise).` - mpv manual
       Do not confuse with the user-configured `video-rotate` (below) */
      guard let totalRotation = property.intData(log) else { return }
      player.log.verbose("Δ mpv prop: 'video-params/rotate' ≔ \(totalRotation)")
      player.saveState()
      /// Any necessary resizing will be handled elsewhere

    case MPVOption.Video.videoRotate:
      guard let userRotation = property.intData(log) else { break }
      // Will only get here if rotation was initiated from mpv. If IINA initiated, the new value would have matched videoGeo.
      player.log.verbose("Δ mpv prop: 'video-rotate' ≔ \(userRotation)")
      player.userRotationDidChange(to: userRotation)

    case MPVOption.Video.videoZoom:
      guard let zoom = property.doubleData(log) else { break }
      player.log.verbose("Δ mpv prop: 'video-zoom' = \(zoom)")
      player.info.videoZoom = zoom
      guard let pwc = player.pwc, pwc.loaded else { return }
      player.sendOSD(.videoZoom(zoom))
      DispatchQueue.main.async { [self] in
        player.videoView.displayActive()
      }

    case MPVOption.Video.videoPanX:
      guard let panX = property.doubleData(log) else { break }
      player.info.videoPanX = panX
      guard let pwc = player.pwc, pwc.loaded else { return }
      DispatchQueue.main.async { [self] in
        player.videoView.displayActive()
      }

    case MPVOption.Video.videoPanY:
      guard let panY = property.doubleData(log) else { break }
      player.info.videoPanY = panY
      guard let pwc = player.pwc, pwc.loaded else { return }
      DispatchQueue.main.async { [self] in
        player.videoView.displayActive()
      }

    case MPVProperty.dwidth:
      let dwidth = Int(getInt(MPVProperty.dwidth))
      player.log.verbose("Δ mpv prop: 'dwidth' ≔ \(dwidth)")
      player.syncVideoParamsFromMpv()

    case MPVProperty.dheight:
      let dheight = Int(getInt(MPVProperty.dheight))
      player.log.verbose("Δ mpv prop: 'dheight' ≔ \(dheight)")
      player.syncVideoParamsFromMpv()
    case MPVProperty.videoParamsPrimaries:
      fallthrough

    case MPVProperty.videoParamsGamma:
      player.refreshEdrMode()

    case MPVOption.TrackSelection.vid:
      let vid = Int(getInt(MPVOption.TrackSelection.vid))
      player.log.verbose("Δ mpv prop: 'vid' ≔ \(vid)")
      player.vidChanged()

    case MPVOption.TrackSelection.aid:
      let aid = Int(getInt(MPVOption.TrackSelection.aid))
      player.log.verbose("Δ mpv prop: 'aid' ≔ \(aid)")
      player.aidChanged(to: aid)

    case MPVOption.TrackSelection.sid:
      let sid = Int(getInt(MPVOption.TrackSelection.sid))
      player.log.verbose("Δ mpv prop: 'sid' ≔ \(sid)")
      player.sidChanged(to: sid, reloadTracksIfNotFound: true)

    case MPVOption.Subtitles.secondarySid:
      let ssid = Int(getInt(MPVOption.Subtitles.secondarySid))
      player.log.verbose("Δ mpv prop: 'secondary-sid' ≔ \(ssid)")
      player.secondarySidChanged(to: ssid, reloadTracksIfNotFound: true)

    case MPVOption.PlaybackControl.pause:
      guard let paused = property.boolData(log) else { break }
      player.log.verbose("Δ mpv prop: 'pause' = \(paused.yn)")
      player.pausedStateDidChange(to: paused)

    case MPVProperty.chapter:
      player.chapterChanged()

    case MPVOption.PlaybackControl.speed:
      guard let pwc = player.pwc, pwc.loaded else { break }
      guard let speed = property.doubleData(log) else { break }
      player.log.verbose("Δ mpv prop: `speed` = \(speed)")
      player.speedDidChange(to: speed)
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.PlaybackControl.loopPlaylist, MPVOption.PlaybackControl.loopFile:
      guard let pwc = player.pwc, pwc.loaded else { break }
      let loopMode = player.getLoopMode()
      switch loopMode {
      case .file:
        player.sendOSD(.fileLoop)
      case .playlist:
        player.sendOSD(.playlistLoop)
      default:
        player.sendOSD(.noLoop)
      }
      pwc.playlistView.updateLoopBtnStatus(loopMode: loopMode)

    case MPVOption.PlaybackControl.abLoopA, MPVOption.PlaybackControl.abLoopB:
      guard let pwc = player.pwc, pwc.loaded else { break }
      player.log.verbose("Δ mpv prop: `\(name)`")
      player.syncAbLoop()

    case MPVOption.PlaybackControl.abLoopCount:
      guard let pwc = player.pwc, pwc.loaded else { break }
      player.log.verbose("Δ mpv prop: `\(name)`")
      player.syncAbLoop()

    case MPVOption.OSD.osdLevel:
      guard let pwc = player.pwc, pwc.loaded else { break }
      guard let level = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: `osdLevel` = \(level)")
      let isUsingMpvOSD: Bool = level != 0
      player.isUsingMpvOSD = isUsingMpvOSD
      if isUsingMpvOSD {
        // If using mpv OSD, then disable IINA's OSD
        player.hideOSD()
      }

    case MPVOption.Video.deinterlace:
      guard let data = property.boolData(log) else { break }
      // this property will fire a change event at file start
      if player.info.deinterlace != data {
        player.log.verbose("Δ mpv prop: `deinterlace` = \(data.yesno)")
        player.info.deinterlace = data
        player.sendOSD(.deinterlace(data))
      }
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Video.hwdec:
      let data = String(cString: property.data.assumingMemoryBound(to: UnsafePointer<UInt8>.self).pointee)
      if player.info.hwdec != data {
        player.log.verbose("Δ mpv prop: `hwdec` = \(data)")
        player.info.hwdec = data
        player.sendOSD(.hwdec(player.info.hwdecEnabled))
      }
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Audio.mute:
      guard let isMuted = property.boolData(log) else { break }
      guard player.info.isMuted != isMuted else { break }
      player.info.isMuted = isMuted
      guard let pwc = player.pwc, pwc.loaded else { break }
      pwc.updateVolumeUI()
      let volume = Int(player.info.volume)
      player.sendOSD(isMuted ? OSDMessage.mute(volume) : OSDMessage.unMute(volume))

    case MPVOption.Audio.volume:
      guard let volume = property.doubleData(log) else { break }
      guard player.info.volume != volume else { break }
      player.info.volume = volume
      guard let pwc = player.pwc, pwc.loaded else { break }
      pwc.updateVolumeUI()
      player.sendOSD(.volume(volume))

    case MPVOption.Audio.audioDelay:
      guard let delayUnrounded = property.doubleData(log) else { break }
      let delay = delayUnrounded.roundedTo6()
      guard player.info.audioDelay != delay else { break }
      player.log.verbose("Δ mpv prop: `audio-delay` = \(delay)")
      player.info.audioDelay = delay
      player.sendOSD(.audioDelay(delay))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subCodepage:
      guard let encoding = getString(MPVOption.Subtitles.subCodepage) else { break }
      player.subCodepageDidChange(to: encoding)

    case MPVOption.Subtitles.subVisibility:
      guard let visible = property.boolData(log) else { break }
      guard player.info.isSubVisible != visible else { break }
      player.log.verbose("Δ mpv prop: `sub-visibility` = \(visible.yn)")
      player.info.isSubVisible = visible
      player.sendOSD(visible ? .subVisible : .subHidden)
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.secondarySubVisibility:
      guard let visible = property.boolData(log) else { break }
      guard player.info.isSecondSubVisible != visible else { break }
      player.log.verbose("Δ mpv prop: `secondary-sub-visibility` = \(visible.yn)")
      player.info.isSecondSubVisible = visible
      player.sendOSD(visible ? .secondSubVisible : .secondSubHidden)
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.secondarySubDelay:
      guard let ssubDelay = property.doubleData(log) else { break }
      player.secondarySubDelayChanged(ssubDelay)

    case MPVOption.Subtitles.subDelay:
      guard let subDelay = property.doubleData(log) else { break }
      player.subDelayChanged(subDelay)

    case MPVOption.Subtitles.subScale:
      guard let subScale = property.doubleData(log) else { break }
      player.log.verbose("Δ mpv prop: 'sub-scale' = \(subScale)")
      player.subScaleChanged(subScale)

    case MPVOption.Subtitles.secondarySubPos:
      guard let ssubPos = property.doubleData(log) else { break }
      player.log.verbose("Δ mpv prop: 'secondary-sub-pos' = \(ssubPos)")
      player.secondarySubPosChanged(ssubPos)

    case MPVOption.Subtitles.subPos:
      guard let subPos = property.doubleData(log) else { break }
      player.log.verbose("Δ mpv prop: 'sub-pos' = \(subPos)")
      player.subPosChanged(subPos)

    case MPVOption.Subtitles.subFont:
      guard let subFont = getString(MPVOption.Subtitles.subFont) else { break }
      player.log.verbose("Δ mpv prop: 'sub-font' = \(subFont.quoted)")
      player.info.subFont = subFont
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subFontSize:
      let subFontSize = getInt(MPVOption.Subtitles.subFontSize)
      guard subFontSize > 0 else { break }
      player.log.verbose("Δ mpv prop: 'sub-font-size' = \(subFontSize)")
      player.info.subFontSize = subFontSize
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subColor:
      guard let subColor = getString(MPVOption.Subtitles.subColor) else { break }
      player.log.verbose("Δ mpv prop: 'sub-color' = \(subColor)")
      player.info.subColor = subColor
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subBackColor:
      guard let subBackColor = getString(MPVOption.Subtitles.subBackColor) else { break }
      player.log.verbose("Δ mpv prop: 'sub-back-color' = \(subBackColor)")
      player.info.subBgColor = subBackColor
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subBorderColor:
      guard let subBorderColor = getString(MPVOption.Subtitles.subBorderColor) else { break }
      player.log.verbose("Δ mpv prop: 'sub-border-color' = \(subBorderColor)")
      player.info.subBorderColor = subBorderColor
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subBorderSize:
      let subBorderSize = getDouble(MPVOption.Subtitles.subBorderSize)
      player.log.verbose("Δ mpv prop: 'sub-border-size' = \(subBorderSize)")
      player.info.subBorderSize = subBorderSize
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Subtitles.subBold:
      player.saveState()
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Equalizer.contrast:
      guard let intData = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: 'contrast' = \(intData)")
      player.info.contrast = intData
      player.sendOSD(.contrast(intData))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Equalizer.hue:
      guard let intData = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: 'hue' = \(intData)")
      player.info.hue = intData
      player.sendOSD(.hue(intData))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Equalizer.brightness:
      guard let intData = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: 'brightness' = \(intData)")
      player.info.brightness = intData
      player.sendOSD(.brightness(intData))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Equalizer.gamma:
      guard let intData = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: 'gamma' = \(intData)")
      player.info.gamma = intData
      player.sendOSD(.gamma(intData))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVOption.Equalizer.saturation:
      guard let intData = property.intData(log) else { break }
      player.log.verbose("Δ mpv prop: 'saturation' = \(intData)")
      player.info.saturation = intData
      player.sendOSD(.saturation(intData))
      player.setQuickSettingsViewNeedsUpdate()

    case MPVProperty.playlistCount:
      player.log.verbose("Δ mpv prop: 'playlist-count'")
      player.reloadPlaylist()

    case MPVProperty.trackList:
      guard !player.miniPlayerShowVideoTimer.isValid else { break }
      player.log.verbose("Δ mpv prop: 'track-list'")
      _ = player.reloadTrackInfo()

    case MPVProperty.vf:
      player.log.verbose("Δ mpv prop: 'vf'")
      player.vfChanged()

    case MPVProperty.af:
      player.log.verbose("Δ mpv prop: 'af'")
      player.afChanged()

    case MPVOption.Video.videoAspectOverride:
      guard let pwc = player.pwc, pwc.loaded, !player.isShuttingDown else { break }
      guard let aspect = getString(MPVOption.Video.videoAspectOverride) else { break }
      player.log.verbose("Δ mpv prop: 'video-aspect-override' = \(aspect.quoted)")
      DispatchQueue.main.async { [self] in
        player.setVideoAspectOverride(aspect)
      }

    case MPVProperty.videoParamsAspect:
      guard player.isActive else { break }
      guard let aspectName = getString(MPVProperty.videoParamsAspect) else { break }
      player.log.verbose("Δ mpv prop: 'video-params/aspect' = \(aspectName.quoted)")

    case MPVOption.Window.keepaspectWindow:
      let keepAspectWindow = getFlag(MPVOption.Window.keepaspectWindow)
      player.log.verbose("Δ mpv prop: 'keepaspect-window' = \(keepAspectWindow.yn)")
      guard player.info.mpvKeepaspectWindow != keepAspectWindow else { break }
      player.info.mpvKeepaspectWindow = keepAspectWindow

    case MPVOption.Window.fullscreen:
      player.syncFullScreenState()

    case MPVOption.Window.ontop:
      player.syncOntopState()

    case MPVOption.Window.cursorAutohide:
      guard let pwc = player.pwc, pwc.loaded else { break }
      guard let cursorAutohide = getString(MPVOption.Window.cursorAutohide) else { break }
      log.verbose("Δ mpv prop: 'cursor-autohide' ≔ \(cursorAutohide)")
      player.updateCursorAutohideState()
      player.pwc.hideCursorTimer.restart()

    case MPVOption.Window.cursorAutohideFsOnly:
      guard let pwc = player.pwc, pwc.loaded else { break }
      let cursorAutohideFS = getFlag(MPVOption.Window.cursorAutohideFsOnly)
      log.verbose("Δ mpv prop: 'cursor-autohide-fs-only' ≔ \(cursorAutohideFS.yn)")
      player.updateCursorAutohideState()
      player.pwc.hideCursorTimer.restart()

    case MPVProperty.windowScale:
      guard let pwc = player.pwc, pwc.loaded else { break }
      guard let windowScaleRaw = property.doubleData(log) else { break }
      let windowScale = windowScaleRaw.roundedTo6()
      if let nextScaleExpected = windowScalesExpected.first, windowScale == nextScaleExpected {
        windowScalesExpected.removeFirst()
        log.verbose("[mpv-window-scale] Received expected 'window-scale'=\(windowScale), discarded from list (now size=\(windowScalesExpected.count))")
        return
      }

      if !windowScalesExpected.isEmpty {
        log.error("[mpv-window-scale] Received unexpected 'window-scale' from mpv with \(windowScalesExpected.count) updates still expected!")
      }

      log.verbose("Δ mpv prop: 'window-scale' ≔ \(windowScale)")
      player.pwc.animationPipeline.submitInstantTask{ [self] in
        player.pwc.mpvWindowScaleDidUpdate(to: windowScale)
      }

    case MPVProperty.mediaTitle:
      player.mediaTitleChanged()

    case MPVProperty.idleActive:
      guard let idleActive = property.boolData(log) else { break }
      guard idleActive else { break }
      player.idleActiveChanged()

    case MPVProperty.currentAo:
      player.currentAoChanged()

    case MPVProperty.inputBindings:
      do {
        let dataNode = UnsafeMutablePointer<mpv_node>(OpaquePointer(property.data))?.pointee
        let inputBindingArray = try MPVNode.parse(dataNode!)
        let keyMappingList = toKeyMappings(inputBindingArray, filterCommandsBy: { s in true} )

        let mappingListStr = keyMappingList.enumerated().map { (index, mapping) in
          "\t\(String(format: "%03d", index))   \(mapping.confFileFormat)"
        }.joined(separator: "\n")

        player.log.verbose("Δ mpv prop: \(MPVProperty.inputBindings.quoted) ≔\n\(mappingListStr)")
      } catch {
        player.log.error("Failed to parse property data for \(MPVProperty.inputBindings.quoted)!")
      }

    default:
      player.log.verbose("Unhandled mpv prop: \(name.quoted)")
      break
    }

    if Preference.bool(for: .iinaEnablePluginSystem) {
      let listeners = player.events.listeners
      guard !listeners.isEmpty else { return }  // optimization: don't enqueue anything if there are no listeners

      // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
      // plugins from a task in this queue. Accessing EventController data from a thread in this queue
      // results in data races that can cause a crash. See issue 3986.
      DispatchQueue.main.async { [self] in
        let eventName = EventController.Name("mpv.\(name).changed")
        if player.events.hasListener(for: eventName) {
          // FIXME: better convert to JSValue before passing to call()
          let data: Any
          switch property.format {
          case MPV_FORMAT_FLAG:
            data = property.data.bindMemory(to: Bool.self, capacity: 1).pointee
          case MPV_FORMAT_INT64:
            data = property.data.bindMemory(to: Int64.self, capacity: 1).pointee
          case MPV_FORMAT_DOUBLE:
            data = property.data.bindMemory(to: Double.self, capacity: 1).pointee
          case MPV_FORMAT_STRING:
            data = property.data.bindMemory(to: String.self, capacity: 1).pointee
          default:
            data = 0
          }
          player.events.emit(eventName, data: data)
        }
      }
    }
  }

  // MARK: - Option & observer utils

  /// Remove observers for IINA preferences.
  func removeOptionObservers() {
    player.log.verbose("Removing mpv option observers")
    ObjcUtils.silenced { [self] in
      for (k, _) in optionObservers {
        UserDefaults.standard.removeObserver(self, forKeyPath: k)
      }
      optionObservers = [:]
    }
  }

  /// Set the given mpv option to the value of the given IINA setting.
  ///
  /// To reduce the amount of logging that occurs when `MPVController` initializes a mpv core this method provides a
  /// `verboseIfDefault` parameter. If this parameter is set to `true` then the value to set the mpv option to is compared to the
  /// default value for the mpv option and if the values match then the value of the `level` parameter will be ignored and the
  /// message will be logged using the `verbose` level.
  /// - Parameters:
  ///   - key: Key for the IINA setting.
  ///   - type: Type of the value of the mpv option.
  ///   - name: Name of the mpv option.
  ///   - sync: Whether to add an observer for the IINA setting that updates the mpv option when the IINA setting changes.
  ///   - level: Log level to use when logging the setting of the option.
  ///   - verboseIfDefault: Whether to use log level `verbose` if the value matches the default for the mpv option.
  ///   - transformer: Optional transformer that changes the IINA setting value to be usable as the mpv option value.
  func setUserOption(_ key: Preference.Key, type: UserOptionType, forName name: String,
                     sync: Bool = true, level: Logger.Level = .debug,
                     verboseIfDefault: Bool = false,
                     transformer: OptionObserverInfo.Transformer? = nil) {
    var code: Int32 = 0

    let keyRawValue = key.rawValue

    switch type {
    case .int:
      code = setOptionInt(name, Preference.integer(for: key), level: level,
                          verboseIfDefault: verboseIfDefault)

    case .float:
      code = setOptionFloat(name, Preference.float(for: key), level: level,
                            verboseIfDefault: verboseIfDefault)

    case .bool:
      code = setOptionFlag(name, Preference.bool(for: key), level: level,
                           verboseIfDefault: verboseIfDefault)

    case .string:
      code = setOptionalOptionString(name, Preference.string(for: key), level: level,
                                     verboseIfDefault: verboseIfDefault)

    case .color:
      let value = Preference.string(for: key)
      code = setOptionalOptionColor(name, value, level: level, verboseIfDefault: verboseIfDefault)
      // Random error here (perhaps a Swift or mpv one), so set it twice
      // 「没有什么是 set 不了的；如果有，那就 set 两次」
      if code < 0 {
        code = setOptionalOptionColor(name, value, level: level, verboseIfDefault: verboseIfDefault)
      }

    case .other:
      guard let tr = transformer else {
        log.error("setUserOption: no transformer!")
        return
      }
      if let value = tr(key) {
        code = setOptionString(name, value, level: level, verboseIfDefault: verboseIfDefault)
      } else {
        code = 0
      }
    }

    if code < 0 {
      let message = errorString(code)
      /// We may be on the main DQ already. Must async out of it to avoid deadlocking!
      DispatchQueue.main.async {
        Utility.showAlert("mpv_error", arguments: [message, "\(code)", name], disableMenus: true)
      }
    }

    if sync {
      UserDefaults.standard.addObserver(self, forKeyPath: keyRawValue, options: [.new, .old], context: nil)
      if optionObservers[keyRawValue] == nil {
        optionObservers[keyRawValue] = []
      }
      optionObservers[keyRawValue]!.append(OptionObserverInfo(key, name, type, transformer))
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard !(change?[NSKeyValueChangeKey.oldKey] is NSNull) else { return }

    guard let keyPath = keyPath else { return }
    guard let infos = optionObservers[keyPath] else { return }

    for info in infos {
      switch info.valueType {
      case .int:
        let value = Preference.integer(for: info.prefKey)
        setInt(info.optionName, value)

      case .float:
        let value = Preference.float(for: info.prefKey)
        setDouble(info.optionName, Double(value))

      case .bool:
        let value = Preference.bool(for: info.prefKey)
        setFlag(info.optionName, value)

      case .string:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .color:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .other:
        guard let tr = info.transformer else {
          log.error("observeValue: no transformer!")
          return
        }
        if let value = tr(info.prefKey) {
          setString(info.optionName, value)
        }
      }
    }
  }

}  /// end `extension MPVController`

extension mpv_event_property {
  func intData(_ log: (any Logger.Subsystem)?) -> Int? {
    guard let int64 = UnsafePointer<Int64>(OpaquePointer(data))?.pointee else {
      if let log {
        logPropertyValueError(log)
      }
      return nil
    }
    return Int(int64)
  }

  func doubleData(_ log: (any Logger.Subsystem)?) -> Double? {
    guard let double = UnsafePointer<Double>(OpaquePointer(data))?.pointee else {
      if let log {
        logPropertyValueError(log)
      }
      return nil
    }
    return Double(double)
  }

  func boolData(_ log: (any Logger.Subsystem)?) -> Bool? {
    guard let boolData = UnsafePointer<Bool>(OpaquePointer(data))?.pointee else {
      if let log {
        logPropertyValueError(log)
      }
      return nil
    }
    return Bool(boolData)
  }

  /// Log an error when a `mpv` property change event can't be processed because a property value could not be converted to the
  /// expected type.
  ///
  /// A [MPV_EVENT_PROPERTY_CHANGE](https://mpv.io/manual/stable/#command-interface-mpv-event-property-change)
  /// event contains the new value of the property. If that value could not be converted to the expected type then this method is called
  /// to log the problem.
  ///
  /// _However_ the situation is not that simple. The documentation for [mpv_observe_property](https://github.com/mpv-player/mpv/blob/023d02c9504e308ba5a295cd1846f2508b3dd9c2/libmpv/client.h#L1192-L1195)
  /// contains the following warning:
  ///
  /// "if a property is unavailable or retrieving it caused an error, `MPV_FORMAT_NONE` will be set in `mpv_event_property`, even
  /// if the format parameter was set to a different value. In this case, the `mpv_event_property.data` field is invalid"
  ///
  /// With mpv 0.35.0 we are receiving some property change events for the video-params/rotate property that do not contain the
  /// property value. This happens when the core starts before a file is loaded and when the core is stopping. At some point this needs
  /// to be investigated. For now we suppress logging an error for this known case.
  /// - Parameter property: Name of the property whose value changed.
  /// - Parameter format: Format of the value contained in the property change event.
  private func logPropertyValueError(_ log: any Logger.Subsystem) {
    let propName = String(cString: name)
    guard propName != MPVProperty.videoParamsRotate || format != MPV_FORMAT_NONE else { return }
    log.error("""
    Value of property \(propName) in the property change event could not be converted from
    \(format) to the expected type
    """)
  }
}
