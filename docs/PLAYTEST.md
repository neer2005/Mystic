# Gaming-session validation

Use the rebuilt `.build/Mystic.app`. Start with a familiar game at your usual
resolution/frame rate. Record the controller model, USB or Bluetooth, host
software/version, and whether the Mac uses Wi-Fi or Ethernet.

## Audio output switching

1. Play recognizable game audio using the Mac's current speakers. While streaming,
   connect wired/USB headphones or choose another output in macOS Sound settings.
   Audio should resume on that output without reconnecting the stream. Inspect
   Audio settings for the device name, rate, output state and restart counter.
2. Disconnect the selected headphones/USB/HDMI device and check fallback to the
   Mac's new default output. Repeat with Bluetooth headphones. If possible, change
   the output's sample rate in Audio MIDI Setup; playback should recover without
   changing the stream's 48 kHz input format or accumulating delay.
3. Set a low Mystic volume and switch outputs. The volume should stay low. Repeat
   muted: there must be no brief audible burst on the new output, including its
   first samples. Unmute and confirm fresh game sound rather than buffered speech.
4. If an output becomes unavailable for longer than the retry window, video/input
   should continue. Restore a working output; device detection should recover
   playback. If still unavailable, choose Retry Audio in the stream toolbar or
   Audio settings. Each retry sequence is bounded, with a clear unavailable status.
5. Switch devices rapidly, then disconnect the stream while audio is recovering.
   Audio must stay stopped, with no delayed restart. Start a new stream and check
   old output notifications do not interrupt it. Repeat with the microphone enabled
   to check Bluetooth profile changes and separate microphone forwarding.

For a surround stream, the audio status should also follow changes between
discrete output and stereo fallback. Passthrough and microphone echo cancellation
are not part of these checks.

## Discrete surround

1. Connect an HDMI/USB multichannel output and configure its speakers in macOS
   Audio MIDI Setup. Select it as the Mac's default output. The host must also
   have a working surround output configuration. Mystic does not configure either
   system's speakers or transmit Dolby/DTS bitstreams.
2. Choose 5.1 in Mystic's Audio settings and start a new stream. Check the audio
   status for “5.1 discrete”, the expected device and sample rate. If it reports
   stereo fallback, record the reason and confirm the Mac's configured layout.
3. Play speaker-identification audio on the host with host/receiver spatial or
   upmix effects disabled. Check front left/right, center/dialogue, LFE and both
   surround speakers individually. Verify balance, missing channels, swapped
   speakers, distortion and audio/video alignment. Match the host's channel test;
   audible sound alone is not proof of correct mapping.
4. With a configured 7.1 output, repeat on a 7.1 stream. Check the side pair and
   rear pair separately; they must not be swapped or duplicated. Repeat a 5.1
   stream on the 7.1 output: it should not invent an extra rear pair.
5. Change to headphones or an ordinary stereo output midstream. The status should
   change to stereo downmix and retain center/surround content appropriately.
   Change back to the multichannel output: discrete routing should return without
   a host reconnect. A 7.1 stream on a 5.1 output deliberately falls back to stereo.
6. Repeat output changes with Mystic muted and with low volume. Every channel
   should retain mute/volume, with no startup burst. Change the output rate in
   Audio MIDI Setup, and recheck speaker identity after recovery.
7. Disconnect/reconnect the stream and repeat after app restart. Record host and
   Mac channel settings, speaker layout/device, stream channel request, actual
   output mode/fallback reason and which speaker failed. A generic interface with
   unlabeled channels or more than eight outputs uses stereo fallback.

## Controller input and rumble

1. Pair/connect the controller in macOS, start the stream, then click the video or
   choose Control Desktop/Capture Mouse to activate input.
2. Check face buttons, d-pad, shoulders, Menu/Options, stick clicks, both sticks and
   analog triggers. With two controllers, check that each controls its own player.
3. Trigger a familiar rumble effect. Check that it starts, changes strength and
   stops when the game stops the effect. Check trigger vibration only if macOS
   exposes trigger motors for this controller; adaptive trigger resistance and
   DualSense PCM haptics are not implemented yet.
4. While an effect is active, release input with Control–Option–Shift–Escape or
   switch to another Mac app. Input and vibration should stop. Reactivation must
   not replay the old effect.
5. Unplug/reconnect or turn the controller off/on. The game should regain input
   after activation, and no replacement controller should inherit an old effect.
6. Disconnect the stream while rumble is active. The controller must stop.
7. Check Guide/Home, the touchpad click and (on Xbox) Share and paddles reach the
   host, and that Guide does not open the Mac's game overlay while input is captured.
8. On a Sunshine-based host, check the host lists the controller as the right type
   (DualSense as a PlayStation pad), with motion and battery. In a game or tester
   with gyro aiming, check each axis turns the right way: Mystic sends GameController's
   axes unchanged, so a wrong axis needs a mapping fix. Check a light-bar colour the
   game sets.
9. With five or more controllers on a Sunshine-based host, check each gets its own
   player.

## Network changes, VPN and wake

1. Over Tailscale or another VPN, check the session log says "over a VPN … streaming as
   remote with 1024-byte packets", and that the picture holds at a high bitrate.
2. During a stream on Wi-Fi, plug in Ethernet (or switch Wi-Fi networks). With a
   roaming-capable host the stream should carry on; otherwise check the log names the
   change. Turn Wi-Fi off for a few seconds and on again: the stream should reconnect at
   once rather than after a timeout.
3. With a lossy or jittery link, listen for clicks: late audio should be filled, and the
   HUD's audio line should count "late skipped" packets.
4. Put the PC to sleep and press Wake in Home. The status should say "Waking…", then
   that the PC is awake once it answers, within 90 seconds.

## Display sleep

Stream with no input on the Mac, such as with a controller plugged into the PC, for longer
than the Mac's display-off time in System Settings → Lock Screen. The display should neither
dim nor sleep. After disconnecting, it should dim on schedule again.

## Automatic quality and launching

1. Set Automatic Quality to Favor Smooth Motion and stream to a Rubylight PC at a resolution
   this Mac decodes slowly, or over a link that loses packets with automatic bitrate already
   at its floor. Within about 15 seconds the stream panel should ask for a smaller size and the
   picture should follow it; it should climb back after things settle.
2. From Terminal, run the command a game's Copy Command Line gives, with `--quit-on-exit`.
   The game should start; disconnecting should quit Mystic, and `echo $?` should print 0.
3. Open a Copy Launch Link link in Safari. Mystic should ask before starting.

## Display luminance

On an HDR stream to a Rubylight host, check the session log says "Told host the
display". Move the window to another screen and check it is told again, once. On
another host, check the launch carries the luminance (the host's log shows the
client's brightness values).

## Interrupted-stream recovery

Reconnect Interrupted Streams is on in Settings → Network by default.

1. After playing normally, briefly interrupt the Mac's connection to the host,
   then restore it. After a transient termination, Mystic should display retry
   status and resume the same game with the same stream settings.
2. Check video, sound, controller input and rumble after recovery. Reactivate input
   in the video window. If using the Mac microphone, check it separately.
3. Interrupt again and choose Disconnect while retry status is visible. Restoring
   the network must not reopen the stream.
4. Leave the host unreachable for one recovery cycle. Mystic must stop after the
   retry budget/window and show an error. An app that stops or changes on the host
   must not be launched/replaced by recovery.

A stream that never displayed its first video does not automatically retry.

## Automatic bitrate

Enable Automatic Bitrate in Settings → Video before starting a new stream. The
selected bitrate is the ceiling. A host without live bitrate control should show
that adaptation is unavailable and continue at the fixed rate.

1. Show the Latency HUD (⌥⌘L) and note the initial rate it shows.
2. Play through a temporary period of network congestion. The rate should step
   down after sustained pressure rather than jump at every isolated hitch.
3. Restore a healthy connection and keep playing. The rate should rise gradually
   without exceeding the selected ceiling or a lower cap imposed by the host.
4. Compare picture stability and responsiveness with automatic bitrate off at the
   same resolution/frame rate. A larger number alone is not a success criterion.

## Clipboard text

1. From the Stream menu, send a new Mac text copy to the host, then paste
   it in a host text editor. Test accents, emoji and multiple lines.
2. Copy text on the host and use Copy Host Text to Mac. Check both permitted
   directions; disabled buttons should match the host's device permissions.
3. Enable Sync Clipboard Text in General before a new stream. Existing clipboard
   contents should not be sent at startup. New text copies in the active stream
   window should arrive without bouncing repeatedly between the two sides.
4. Switch to another Mac app and copy text. It must stay local when you return to
   the stream. A new host copy should not replace a copied file/image on the Mac.
5. Request host text, then immediately switch windows or copy something new
   locally. A late response must preserve the newer local clipboard. Disconnect
   should stop all automatic sharing; recovery should start a fresh baseline.

## Frame pacing

1. At 60 fps, compare Low Latency and Balanced in Settings → Video across separate
   streams. Use a repeatable camera pan or scrolling scene. Compare smoothness,
   control response and audio alignment; repeat at 120 fps if the Mac/host support it.
2. Enable the latency HUD. Presenter queue depth should stay at 0–2. Note late
   frames, superseded drops, renderer drops (when available), and decode/enqueue
   timings. An enqueued frame is not proof it reached the screen.
3. Switch focus away and back, briefly interrupt the network, and use Test Video
   Recovery. Video should resume without an accumulating delay or an old image
   returning. Reconnect should retain the selected pacing mode.
4. Disconnect and start a stream at the other frame rate. Check smoothness, correct
   sizing, continuing counters and image clearing when you disconnect again.

## Host and game profiles

1. Set global Video defaults to 1080p60. Connect a paired host and select a game.
   It should initially use host defaults, displaying the same global values.
2. Open Edit Host Defaults, turn off Use global defaults, and choose 1440p120.
   Close the editor and select another game. Both should inherit the host values.
3. Select Custom game settings for one game and choose a different resolution,
   bitrate or pacing mode. Switch games and return; only that game should have
   the custom values. Quit/reopen Mystic and reconnect to confirm persistence.
4. For another game choose Use global defaults. Change Settings → Video and
   check that game follows the change while the custom game remains fixed.
   Restore Global Defaults should preserve the custom host and game profiles.
5. Start a stream with the custom profile, verify host geometry/HDR and the HUD's
   pacing mode, then interrupt the network. Recovery should keep the same setup.
   Video profile controls should be locked until the stream stops.
6. Reset the custom game with Use host defaults. In the host editor enable Use
   global defaults. The game should now follow globals. Connect another host and
   confirm its games have separate choices, even if the apps have the same names.

## HDR / EDR

1. Enable HDR in Video settings and start an HDR-capable host app on an HDR/EDR
   screen. Confirm the host has HDR enabled too. In the HUD, expect PQ (or HLG),
   the source's color primaries, and “HDR output requested”. Record current and
   potential display headroom; current headroom alone is not a capability test.
2. Inspect a repeatable HDR scene or HDR calibration pattern. Check bright detail,
   dark gradients, neutral grays, saturated colors and readable host UI. Compare
   with the host image and an SDR stream of the same scene; avoid using a Mac
   screenshot as proof of HDR output. Note clipping, washed-out colors or a
   double-toned appearance. Try both pacing modes in separate sessions.
3. If available, move the window from an HDR to an SDR screen and back, then try
   fullscreen. The HUD should follow the destination, show “HDR mapped to SDR” on
   the SDR screen, and resume the HDR request on the HDR screen without reconnecting.
4. Change display brightness/reference mode or an external display's macOS HDR
   setting. Confirm headroom refreshes. Disconnect/reconnect the display and check
   the new destination. Temporary headroom changes must not trigger stream recovery.
5. Use Test Video Recovery and disconnect/resume. Old frames must not restore HDR
   after stop. Start an SDR stream afterward and check the HUD reports SDR output
   and ordinary UI brightness. Record display model, macOS HDR/reference settings,
   codec, resolution, frame rate and the HUD's color/headroom readings with results.

## Useful result notes

For a failure, note the action that triggered it, the stream status/bitrate text,
whether input or rumble remained active, and whether a manual reconnect fixed it.
HDR appearance, discrete surround, AV1 hardware support and controller feedback
still require their own physical checks; passing automated tests does not prove
those device-specific outcomes.
