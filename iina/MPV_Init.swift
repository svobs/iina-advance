//
//  MPV_Init.swift
//  iina
//
//  Created by Matt Svoboda on 2025-03-27.
//  Copyright © 2025 lhc. All rights reserved.
//

import VideoToolbox

fileprivate let yes = Constants.String.mpvYes
fileprivate let no = Constants.String.mpvNo

extension MPVController {
  /// Init the mpv context, set options.
  ///
  /// This is expected to be executed in the main DispatchQueue because of: reasons.
  /// But race conditions should not be a problem because it is not reusing resources.
  /// But once returned, all libmpv API calls should only be made via tasks on `mpv.queue`.
  @MainActor
  func mpvInit() {
    player.log.verbose("Init mpv")
    // Create a new mpv instance and an associated client API handle to control the mpv instance.
    mpv = mpv_create()
    guard mpv != nil else {
      player.log.error("Failed to create mpv instance")
      return
    }

    mpvSetOptionsFromPrefs()
    mpvSetOptions(from: player.userOptions)

    mpvFinishInit()
    player.log.verbose("Init mpv: done")
  }

  /// This is designed to be called again if this mpv core is reused across player sessions.
  func mpvSetOptionsFromPrefs() {
    log.verbose("Setting mpv options from IINA settings")

    _updateUsingMpvOSDFromPrefs()  // will disable mpv OSD if demo player
    if player.isDemoPlayer || !player.isPresentInUserOptions(MPVOption.OSD.osc) {
      logError(mpv_set_option_string(mpv, MPVOption.OSD.osc, no))
    }

    // Disable mpv's media key system as it now uses the MediaPlayer Framework.
    // Dropped media key support in 10.11 and 10.12.
    chkErr(mpv_set_option_string(mpv, MPVOption.Input.inputMediaKeys, no))

    guard !player.isDemoPlayer else { return }

    if !player.isRestoring, !player.isPresentInUserOptions(MPVOption.Audio.volume) {
      if Preference.bool(for: .enableInitialVolume) {
        setUserOption(PK.initialVolume, type: .int, forName: MPVOption.Audio.volume, sync: false, level: .verbose)
      } else {
        setUserOption(PK.softVolume, type: .int, forName: MPVOption.Audio.volume, sync: false, level: .verbose)
      }
    }

    // - Advanced

    // Don't give Demo player its own log file
    // TODO: allow hot toggling of log
    if Logger.enabled {
      let path = Logger.logDirectory.appendingPathComponent("mpv-\(player.label).log").path
      player.log.debug("Path of mpv log: \(path.pii.quoted)")
      chkErr(setOptionString(MPVOption.ProgramBehavior.logFile, path, level: .verbose))
    }

    // - General

    if !player.isPresentInUserOptions(MPVOption.PlaybackControl.hrSeek) {
      // Use exact seeks by default
      mpv_set_option_string(mpv, MPVOption.PlaybackControl.hrSeek, yes)
    }

    if !player.isPresentInUserOptions(MPVOption.Screenshot.screenshotDir) {
      let setScreenshotPath = { (key: Preference.Key) -> String in
        if Preference.bool(for: .screenshotSaveToFile) {
          let screenshotPath = Preference.string(for: .screenshotFolder)!
          return NSString(string: screenshotPath).expandingTildeInPath
        }
        return Utility.screenshotCacheURL.path
      }

      setUserOption(PK.screenshotFolder, type: .other, forName: MPVOption.Screenshot.screenshotDir,
                    level: .verbose, transformer: setScreenshotPath)
      setUserOption(PK.screenshotSaveToFile, type: .other, forName: MPVOption.Screenshot.screenshotDir,
                    level: .verbose, transformer: setScreenshotPath)
    }

    if !player.isPresentInUserOptions(MPVOption.Screenshot.screenshotFormat) {
      setUserOption(PK.screenshotFormat, type: .other, forName: MPVOption.Screenshot.screenshotFormat,
                    verboseIfDefault: true) { key in
        let v = Preference.integer(for: key)
        let format = Preference.ScreenshotFormat(rawValue: v)
        // Workaround for mpv issue #15107, HDR screenshots are unimplemented (gpu/gpu-next).
        // If the screenshot format is set to JPEG XL then set the screenshot-sw option to yes. This
        // causes the screenshot to be rendered by software instead of the VO. If a HDR video is being
        // displayed in HDR then the resulting screenshot will be HDR.
        self.chkErr(self.setOptionFlag(MPVOption.Screenshot.screenshotSw, format == .jxl,
                                       verboseIfDefault: true))
        return format?.string
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Screenshot.screenshotTemplate) {
      setUserOption(PK.screenshotTemplate, type: .string,
                    forName: MPVOption.Screenshot.screenshotTemplate)
    }

    if !player.isPresentInUserOptions(MPVOption.Window.keepOpen) {
      updateKeepOpenOptionFromPrefs()
    }

    if !player.isPresentInUserOptions(MPVOption.WatchLater.watchLaterDir) {
      chkErr(setOptionString(MPVOption.WatchLater.watchLaterDir, Utility.watchLaterURL.path, level: .verbose))
    }
    if !player.isPresentInUserOptions(MPVOption.WatchLater.savePositionOnQuit) {
      setUserOption(PK.resumeLastPosition, type: .bool, forName: MPVOption.WatchLater.savePositionOnQuit,
                    verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.WatchLater.resumePlayback) {
      setUserOption(PK.resumeLastPosition, type: .bool, forName: MPVOption.WatchLater.resumePlayback, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Window.geometry) {
      // FIXME: set this strategically, based on when to resize.
      setUserOption(.initialWindowSizePosition, type: .string, forName: MPVOption.Window.geometry,
                    level: .verbose)
    }

    // - Codec

    if !player.isPresentInUserOptions(MPVOption.Video.vdLavcThreads) {
      setUserOption(PK.videoThreads, type: .int, forName: MPVOption.Video.vdLavcThreads, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Audio.adLavcThreads) {
      setUserOption(PK.audioThreads, type: .int, forName: MPVOption.Audio.adLavcThreads, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Video.hwdec) {
      setUserOption(PK.hardwareDecoder, type: .other, forName: MPVOption.Video.hwdec, verboseIfDefault: true) { key in
        let value = Preference.integer(for: key)
        return Preference.HardwareDecoderOption(rawValue: value)?.mpvString ?? "auto"
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Audio.volumeMax) {
      setUserOption(PK.maxVolume, type: .int, forName: MPVOption.Audio.volumeMax, level: .verbose)
    }

    if !player.isPresentInUserOptions(MPVOption.TrackSelection.alang) {
      setUserOption(PK.audioLanguage, type: .string, forName: MPVOption.TrackSelection.alang, level: .verbose)
    }

    if !player.isPresentInUserOptions(MPVOption.Audio.audioSpdif) {
      var spdif: [String] = []
      if Preference.bool(for: PK.spdifAC3) { spdif.append("ac3") }
      if Preference.bool(for: PK.spdifDTS){ spdif.append("dts") }
      if Preference.bool(for: PK.spdifDTSHD) { spdif.append("dts-hd") }
      chkErr(setOptionString(MPVOption.Audio.audioSpdif, spdif.joined(separator: ","), verboseIfDefault: true))
    }

    if !player.isPresentInUserOptions(MPVOption.Audio.audioDevice) {
      setUserOption(PK.audioDevice, type: .string, forName: MPVOption.Audio.audioDevice, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Audio.replaygain) {
      setUserOption(PK.replayGain, type: .other, forName: MPVOption.Audio.replaygain, verboseIfDefault: true) { key in
        let value = Preference.integer(for: key)
        return Preference.ReplayGainOption(rawValue: value)?.mpvString ?? no
      }
    }
    if !player.isPresentInUserOptions(MPVOption.Audio.replaygainPreamp) {
      setUserOption(PK.replayGainPreamp, type: .float, forName: MPVOption.Audio.replaygainPreamp, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Audio.replaygainClip) {
      setUserOption(PK.replayGainClip, type: .bool, forName: MPVOption.Audio.replaygainClip, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Audio.replaygainFallback) {
      setUserOption(PK.replayGainFallback, type: .float, forName: MPVOption.Audio.replaygainFallback, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Audio.gaplessAudio) {
      setUserOption(PK.gaplessAudio, type: .other, forName: MPVOption.Audio.gaplessAudio, verboseIfDefault: true) { key in
        let value = Preference.integer(for: key)
        return Preference.GaplessAudioOption(rawValue: value)?.mpvString ?? "weak"
      }
    }

    // - Sub

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAuto) {
      chkErr(setOptionString(MPVOption.Subtitles.subAuto, no, level: .verbose))
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subCodepage) {
      chkErr(setOptionalOptionString(MPVOption.Subtitles.subCodepage,
                                     Preference.string(for: .defaultEncoding), verboseIfDefault: true))
      player.info.subEncoding = Preference.string(for: .defaultEncoding)
    }

    let subOverrideHandler: OptionObserverInfo.Transformer = { key in
      (Preference.enum(for: key) as Preference.SubOverrideLevel).string
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAssOverride) {
      setUserOption(PK.subOverrideLevel, type: .other, forName: MPVOption.Subtitles.subAssOverride,
                    verboseIfDefault: true, transformer: subOverrideHandler)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAssOverride) {
      setUserOption(PK.secondarySubOverrideLevel, type: .other,
                    forName: MPVOption.Subtitles.subAssOverride, verboseIfDefault: true,
                    transformer: subOverrideHandler)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subFont) {
      setUserOption(PK.subTextFont, type: .string, forName: MPVOption.Subtitles.subFont, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subFontSize) {
      setUserOption(PK.subTextSize, type: .float, forName: MPVOption.Subtitles.subFontSize, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subColor) {
      setUserOption(PK.subTextColorString, type: .color, forName: MPVOption.Subtitles.subColor, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subBackColor) {
      setUserOption(PK.subBgColorString, type: .color, forName: MPVOption.Subtitles.subBackColor, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAssOverride) {
      setUserOption(PK.subBold, type: .bool, forName: MPVOption.Subtitles.subBold, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subItalic) {
      setUserOption(PK.subItalic, type: .bool, forName: MPVOption.Subtitles.subItalic, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subBlur) {
      setUserOption(PK.subBlur, type: .float, forName: MPVOption.Subtitles.subBlur, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subSpacing) {
      setUserOption(PK.subSpacing, type: .float, forName: MPVOption.Subtitles.subSpacing, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subBorderSize) {
      setUserOption(PK.subBorderSize, type: .float, forName: MPVOption.Subtitles.subBorderSize, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subBorderColor) {
      setUserOption(PK.subBorderColorString, type: .color, forName: MPVOption.Subtitles.subBorderColor, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subShadowOffset) {
      setUserOption(PK.subShadowSize, type: .float, forName: MPVOption.Subtitles.subShadowOffset, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subShadowColor) {
      setUserOption(PK.subShadowColorString, type: .color, forName: MPVOption.Subtitles.subShadowColor,
                    verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAlignX) {
      setUserOption(PK.subAlignX, type: .other, forName: MPVOption.Subtitles.subAlignX, verboseIfDefault: true) { key in
        let v = Preference.integer(for: key)
        return Preference.SubAlign(rawValue: v)?.stringForX
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAlignY) {
      setUserOption(PK.subAlignY, type: .other, forName: MPVOption.Subtitles.subAlignY, verboseIfDefault: true) { key in
        let v = Preference.integer(for: key)
        return Preference.SubAlign(rawValue: v)?.stringForY
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subMarginX) {
      setUserOption(PK.subMarginX, type: .int, forName: MPVOption.Subtitles.subMarginX, verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subMarginY) {
      setUserOption(PK.subMarginY, type: .int, forName: MPVOption.Subtitles.subMarginY, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subPos) {
      setUserOption(PK.subPos, type: .float, forName: MPVOption.Subtitles.subPos, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.TrackSelection.slang) {
      setUserOption(PK.subLang, type: .string, forName: MPVOption.TrackSelection.slang, level: .verbose)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subUseMargins) {
      setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subUseMargins,
                    verboseIfDefault: true)
    }
    if !player.isPresentInUserOptions(MPVOption.Subtitles.subAssForceMargins) {
      setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subAssForceMargins,
                    verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Subtitles.subScaleByWindow) {
      setUserOption(PK.subScaleWithWindow, type: .bool, forName: MPVOption.Subtitles.subScaleByWindow,
                    verboseIfDefault: true)
    }

    // - Network / cache settings

    if !player.isPresentInUserOptions(MPVOption.Cache.cache) {
      setUserOption(PK.enableCache, type: .other, forName: MPVOption.Cache.cache,
                    verboseIfDefault: true) { key in
        return Preference.bool(for: key) ? nil : no
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Demuxer.demuxerMaxBytes) {
      setUserOption(PK.defaultCacheSize, type: .other, forName: MPVOption.Demuxer.demuxerMaxBytes,
                    verboseIfDefault: true) { key in
        return "\(Preference.integer(for: key))KiB"
      }
    }
    if !player.isPresentInUserOptions(MPVOption.Cache.cacheSecs) {
      setUserOption(PK.secPrefech, type: .int, forName: MPVOption.Cache.cacheSecs, verboseIfDefault: true)
    }

    if !player.isPresentInUserOptions(MPVOption.Network.userAgent) {
      setUserOption(PK.userAgent, type: .other, forName: MPVOption.Network.userAgent,
                    verboseIfDefault: true) { key in
        let ua = Preference.string(for: key)!
        return ua.isEmpty ? nil : ua
      }
    }

    if !player.isPresentInUserOptions(MPVOption.Network.rtspTransport) {
      setUserOption(PK.transportRTSPThrough, type: .other, forName: MPVOption.Network.rtspTransport,
                    verboseIfDefault: true) { key in
        let v: Preference.RTSPTransportation = Preference.enum(for: .transportRTSPThrough)
        return v.string
      }
    }

    if !player.isPresentInUserOptions(MPVOption.ProgramBehavior.ytdl) {
      setUserOption(PK.ytdlEnabled, type: .other, forName: MPVOption.ProgramBehavior.ytdl,
                    verboseIfDefault: true) { key in
        let v = Preference.bool(for: .ytdlEnabled)
        if JavascriptPlugin.hasYTDL {
          return no
        }
        return v ? yes : no
      }
    }
    if !player.isPresentInUserOptions(MPVOption.ProgramBehavior.ytdlRawOptions) {
      setUserOption(PK.ytdlRawOptions, type: .string, forName: MPVOption.ProgramBehavior.ytdlRawOptions,
                    verboseIfDefault: true)
    }

    let propertiesToReset = [MPVOption.PlaybackControl.abLoopA, MPVOption.PlaybackControl.abLoopB]
    chkErr(setOptionString(MPVOption.ProgramBehavior.resetOnNextFile,
                           propertiesToReset.joined(separator: ","), level: .verbose))

    if !player.isPresentInUserOptions(MPVOption.Audio.ao) {
      setUserOption(PK.audioDriverEnableAVFoundation, type: .other, forName: MPVOption.Audio.ao,
                    verboseIfDefault: true) { key in
        Preference.bool(for: key) ? "avfoundation" : "coreaudio"
      }
    }

    if !player.isPresentInUserOptions(MPVOption.ProgramBehavior.noConfig),
       !player.isPresentInUserOptions("config"),
       !player.isPresentInUserOptions(MPVOption.ProgramBehavior.configDir) {
      // Set user defined conf dir.
      if Preference.bool(for: .enableAdvancedSettings),
         Preference.bool(for: .useUserDefinedConfDir),
         var userConfDir = Preference.string(for: .userDefinedConfDir) {
        userConfDir = NSString(string: userConfDir).standardizingPath
        setOptionString("config", yes)
        let status = setOptionString(MPVOption.ProgramBehavior.configDir, userConfDir)
        if status < 0 {
          // `Utility.showAlert` will deadlock if not called async because we are already running on the main thread
          DispatchQueue.main.async {
            Utility.showAlert("extra_option.config_folder", arguments: [userConfDir], disableMenus: true)
          }
        }
      }
    }

    // Load external scripts
    loadSelectedInputConf(mpvQueue: false)
  }

  /// Send a bunch of options to mpv. This can include command-line arguments and/or entries from
  /// the Additional mpv options table, or may be empty.
  func mpvSetOptions(from opList: [MPVOptPair]) {
    guard !opList.isEmpty else {
      log.debug("No user-configured mpv options to set")
      return
    }
    log.debug("Setting \(opList.count) user-configured mpv options")
    for op in opList.map(\.normalizedPair) {
      let opName = op.key
      // Ignore these options if specified; they are hard-coded above & will result in visual bugs if overridden
      guard opName != MPVOption.Window.keepaspect,
            opName != MPVOption.Window.keepaspectWindow else {
        log.debug("Ignoring user option: \(opName.quoted)")
        continue
      }

      let status = setOptionString(opName, op.val)
      if status < 0 {
        let errorString = errorString(status)
        let errorKey = "extra_option.error"
        let errorFormat = NSLocalizedString("alert." + errorKey, comment: errorKey)
        let errorStringArgs: [CVarArg] = [opName, op.val, status, errorString]
        log.error(String(format: errorFormat, arguments: errorStringArgs).replacingOccurrences(of: "\n", with: " | "))

        // `Utility.showAlert` will deadlock if not called async because we are already running on the main thread
        DispatchQueue.main.async {
          Utility.showAlert(errorKey, arguments: errorStringArgs, logAlert: false)
        }
      }
    }
  }

  /// This should only ever be called once per player.
  @MainActor
  private func mpvFinishInit() {
    player.log.verbose("Finshing mpv init")

    if player.isDemoPlayer {
      // Do the minimum needed for demo player
      setFlag(MPVOption.ProgramBehavior.loadAutoProfiles, false, level: .verbose)
      setFlag(MPVOption.ProgramBehavior.loadOsdConsole, false, level: .verbose)
      setFlag(MPVOption.ProgramBehavior.loadScripts, false, level: .verbose)
      setFlag(MPVOption.ProgramBehavior.loadStatsOverlay, false, level: .verbose)
      setString("config", no)

      setFlag(MPVOption.WatchLater.savePositionOnQuit, false, level: .verbose)
      setFlag(MPVOption.WatchLater.resumePlayback, false, level: .verbose)
      setFlag(MPVOption.Window.keepOpen, false, level: .verbose)
      setFlag(MPVOption.ProgramBehavior.ytdl, false, level: .verbose)

      setInt(MPVOption.Demuxer.demuxerReadaheadSecs, 0, level: .verbose)
      setString(MPVOption.Demuxer.demuxerMaxBytes, "128KiB", level: .verbose)
      setString(MPVOption.TrackSelection.aid, no, level: .verbose)

      setString(MPVOption.Video.hwdec, no, level: .verbose)

      logError(mpv_request_log_messages(mpv, MPVLogLevel.warn.description))
      logError(mpv_initialize(mpv))

      mpvVersion = getString(MPVProperty.mpvVersion)
      return
    }

    // Set up event callback
    setMpvEventLogSubscription()

    if !player.isPresentInUserOptions(MPVEncoding.o) {
      addEventCallbacks()
    }

    log.verbose("Calling mpv_initialize")
    // Initialize an uninitialized mpv instance. If the mpv instance is already running, an error is returned.
    chkErr(mpv_initialize(mpv))

    // The option watch-later-options is not available until after the mpv instance is initialized.
    // Workaround for mpv issue #14417, watch-later-options missing secondary subtitle delay and sid.
    // Allow the user to override this workaround by setting this mpv option in advanced settings.
    if !player.isPresentInUserOptions(MPVOption.WatchLater.watchLaterOptions),
       var watchLaterOptions = getString(MPVOption.WatchLater.watchLaterOptions) {

      // In mpv 0.38.0 the default value for the watch-later-options property contains the options
      // sid and sub-delay, but not the corresponding options for the secondary subtitle. This
      // inconsistency is likely to confuse users, so insure the secondary options are also saved in
      // watch later files. Issue #14417 has been fixed, so this workaround will not be needed after
      // the next mpv upgrade.
      var needsUpdate = false
      if watchLaterOptions.contains(MPVOption.TrackSelection.sid),
         !watchLaterOptions.contains(MPVOption.Subtitles.secondarySid) {
        log.debug("Adding \(MPVOption.Subtitles.secondarySid) to \(MPVOption.WatchLater.watchLaterOptions)")
        watchLaterOptions += "," + MPVOption.Subtitles.secondarySid
        needsUpdate = true
      }
      if watchLaterOptions.contains(MPVOption.Subtitles.subDelay),
         !watchLaterOptions.contains(MPVOption.Subtitles.secondarySubDelay) {
        log.debug("Adding \(MPVOption.Subtitles.secondarySubDelay) to \(MPVOption.WatchLater.watchLaterOptions)")
        watchLaterOptions += "," + MPVOption.Subtitles.secondarySubDelay
        needsUpdate = true
      }
      if needsUpdate {
        chkErr(setOptionString(MPVOption.WatchLater.watchLaterOptions, watchLaterOptions, level: .verbose))
      }
    }
    
    if let watchLaterOptions = getString(MPVOption.WatchLater.watchLaterOptions) {
      player.log.debug("Options mpv is configured to save in watch later files: \(watchLaterOptions)")
      MPVController.watchLaterOptions = watchLaterOptions
      DispatchQueue.main.async { [self] in
        NotificationCenter.default.post(name: .watchLaterOptionsDidChange, object: player)
      }
    }

    // Must be called after mpv_initialize which sets the default value for hwdec-codecs.
    adjustCodecWhiteList()

    // If --o is specified, encoding mode is being used. If so, skip setting --vo as it will lead to error
    if !player.isPresentInUserOptions(MPVEncoding.o) {
      applyHardwareAccelerationWorkaround()

      if DebugConfig.useMpvKeepaspectWindow {
        chkErr(setString(MPVOption.Window.keepaspect, yes, level: .verbose))
        chkErr(setString(MPVOption.Window.keepaspectWindow, no, level: .verbose))
      } else {
        chkErr(setString(MPVOption.Window.keepaspect, no, level: .verbose))
      }

      if player.videoView.useOpenGL {
        if !player.isPresentInUserOptions(MPVOption.Video.vo) {
          log.verbose("Using legacy libmpv + OpenGEL rendering")
          // Set options that can be override by user's config. mpv will log user config when initialize,
          // so we put them here.
          chkErr(setString(MPVOption.Video.vo, "libmpv", level: .debug))
        }

      } else {
        log.verbose("Using gpu-next + Vulkan rendering")
        let widPtr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        widPtr.pointee = unsafeBitCast(player.window, to: Int64.self)
        mpv_set_option(mpv, MPVOption.Window.wid, MPV_FORMAT_INT64, widPtr)

        if !player.isPresentInUserOptions(MPVOption.Video.vo) {
          chkErr(setString(MPVOption.Video.vo, "gpu-next", level: .debug))
        }
        if !player.isPresentInUserOptions(MPVOption.GPURendererOptions.gpuApi) {
          chkErr(setString(MPVOption.GPURendererOptions.gpuApi, "vulkan", level: .debug))
        }
        if !player.isPresentInUserOptions(MPVOption.Video.hwdec) {
          chkErr(setString(MPVOption.Video.hwdec, "vulkan", level: .debug))
        }
      }
      if !player.isPresentInUserOptions(MPVOption.Video.gpuHwdecInterop) {
        chkErr(setString(MPVOption.Video.gpuHwdecInterop, "auto", level: .verbose))
      }
    }

    player.updateCursorAutohideState()

    // get version
    mpvVersion = getString(MPVProperty.mpvVersion)

    // Unlike upstream IINA, we do not start any mpv cores until a window has been opened.
    // So we must wait until now to log this info, instead of at app start.
    // Should be fine to log this for every mpv core - it may be useful to have it in every mpv log file.
    player.log.verbose("Configuration when building mpv: \(getString(MPVProperty.mpvConfiguration)!)")
  }

  /// Remove codecs from the hardware decoding white list that this Mac does not support.
  ///
  /// As explained in [HWAccelIntro](https://trac.ffmpeg.org/wiki/HWAccelIntro),  [FFmpeg](https://ffmpeg.org/)
  /// will automatically fall back to software decoding. _However_ when it does so `FFmpeg` emits an error level log message
  /// referring to "Failed setup". This has confused users debugging problems. To eliminate the overhead of setting up for hardware
  /// decoding only to have it fail, this method removes codecs from the mpv
  /// [hwdec-codecs](https://mpv.io/manual/stable/#options-hwdec-codecs) option that are known to not have
  /// hardware decoding support on this Mac. This is not comprehensive. This method only covers the recent codecs whose support
  /// for hardware decoding varies among Macs. This merely reduces the dependence upon the FFmpeg fallback to software decoding
  /// feature in some cases.
  /// - ToDo: **REMOVE** workaround for FFmpeg not supporting AV1 hardware decoding when upgrading to a FFmpeg version
  ///         that supports it.
  private func adjustCodecWhiteList() {
    // Allow the user to override this behavior.
    guard !player.isPresentInUserOptions(MPVOption.Video.hwdecCodecs) else {
      log.debug("""
        Option \(MPVOption.Video.hwdecCodecs) has been set in advanced settings, \
        will not adjust white list
        """)
      return
    }
    guard let whitelist = getString(MPVOption.Video.hwdecCodecs) else {
      // Internal error. Make certain this method is called after mpv_initialize which sets the
      // default value.
      log.error("Failed to obtain the value of option \(MPVOption.Video.hwdecCodecs)")
      return
    }
    log.debug("Hardware decoding whitelist (\(MPVOption.Video.hwdecCodecs)) is set to \(whitelist)")
    var adjusted: [String] = []
    var needsAdjustment = false
    codecLoop: for codec in whitelist.components(separatedBy: ",") {
      guard let codecTypes = mpvCodecToCodecTypes[codec] else {
        // Not a codec this method supports removing. Retain it in the option value.
        adjusted.append(codec)
        continue
      }
      // The mpv codec name can map to multiple codec types. If hardware decoding is supported for
      // any of them retain the codec in the option value.
      for codecType in codecTypes {
        if HardwareDecodeCapabilities.shared.isSupported(codecType) {
          if codecType == kCMVideoCodecType_AV1 {
            // WORKAROUND missing support for AV1 hardware decoding.
            // This Mac supports AV1 hardware decoding, but the version of FFmpeg IINA is using does
            // not. FFmpeg will try to use hardware decoding, which will fail. FFmpeg will then fall
            // back to software decoding. When FFmpeg does this it logs the warning message "Error
            // while decoding frame (hardware decoding)!" which is alarming to users. Prevent this
            // by removing AV1 from the codecs whitelist.
            needsAdjustment = true
            log.debug("FFmpeg does not support av1 hardware decoding")
            continue codecLoop
          }
          adjusted.append(codec)
          continue codecLoop
        }
      }
      needsAdjustment = true
      log.debug("This Mac does not support \(codec) hardware decoding")
    }
    // Only set the option if a change is needed to avoid logging when nothing has changed.
    if needsAdjustment {
      chkErr(setOptionString(MPVOption.Video.hwdecCodecs, adjusted.joined(separator: ",")))
    }
  }

  /// Determine if this Mac has an Apple Silicon chip.
  /// - Returns: `true` if running on a Mac with an Apple Silicon chip, `false` otherwise.
  private func runningOnAppleSilicon() -> Bool {
    // Old versions of macOS do not support Apple Silicon.
    if #unavailable(macOS 11.0) {
      return false
    }
    var sysinfo = utsname()
    let result = uname(&sysinfo)
    guard result == EXIT_SUCCESS else {
      player.log.error("uname failed returning \(result)")
      return false
    }
    let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
    guard let machine = String(bytes: data, encoding: .ascii) else {
      player.log.error("Failed to construct string for sysinfo.machine")
      return false
    }
    return machine.starts(with: "arm64")
  }

  /// Apply a workaround for issue [#4486](https://github.com/iina/iina/issues/4486), if needed.
  ///
  /// On Macs with an Intel chip VP9 hardware acceleration is causing a hang in
  ///[VTDecompressionSessionWaitForAsynchronousFrames](https://developer.apple.com/documentation/videotoolbox/1536066-vtdecompressionsessionwaitforasy).
  /// This has been reproduced with FFmpeg and has been reported in ticket [9599](https://trac.ffmpeg.org/ticket/9599).
  ///
  /// The workaround removes VP9 from the value of the mpv [hwdec-codecs](https://mpv.io/manual/master/#options-hwdec-codecs) option,
  /// the list of codecs eligible for hardware acceleration.
  private func applyHardwareAccelerationWorkaround() {
    // The problem is not reproducible under Apple Silicon.
    guard !runningOnAppleSilicon() else {
      log.debug("Running on Apple Silicon, not applying FFmpeg 9599 workaround")
      return
    }
    // Allow the user to override this behavior.
    guard !player.isPresentInUserOptions(MPVOption.Video.hwdecCodecs) else {
      log.debug("""
        Option \(MPVOption.Video.hwdecCodecs) has been set in advanced settings, \
        not applying FFmpeg 9599 workaround
        """)
      return
    }
    guard let whitelist = getString(MPVOption.Video.hwdecCodecs) else {
      // Internal error. Make certain this method is called after mpv_initialize which sets the
      // default value.
      log.error("Failed to obtain the value of option \(MPVOption.Video.hwdecCodecs)")
      return
    }
    var adjusted: [String] = []
    var needsWorkaround = false
    codecLoop: for codec in whitelist.components(separatedBy: ",") {
      guard codec == "vp9" else {
        adjusted.append(codec)
        continue
      }
      needsWorkaround = true
    }
    if needsWorkaround {
      log.debug("Disabling hardware acceleration for VP9 encoded videos to workaround FFmpeg 9599")
      chkErr(setOptionString(MPVOption.Video.hwdecCodecs, adjusted.joined(separator: ",")))
    }
  }

}

/// Map from mpv codec name to core media video codec types.
///
/// This map only contains the mpv codecs `adjustCodecWhiteList` can remove from the mpv `hwdec-codecs` option.
/// If any codec types are added then `HardwareDecodeCapabilities` will need to be updated to support them.
fileprivate let mpvCodecToCodecTypes: [String: [CMVideoCodecType]] = [
  "av1": [kCMVideoCodecType_AV1],
  "prores": [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
             kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ],
  "vp9": [kCMVideoCodecType_VP9]
]
