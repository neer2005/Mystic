# Gaming-session validation

Use the rebuilt `.build/Mystic.app`. Start with a familiar game at your usual
resolution/frame rate. Record the controller model, USB or Bluetooth, host
software/version, and whether the Mac uses Wi-Fi or Ethernet.

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

1. Note the initial rate shown in the stream toolbar.
2. Play through a temporary period of network congestion. The rate should step
   down after sustained pressure rather than jump at every isolated hitch.
3. Restore a healthy connection and keep playing. The rate should rise gradually
   without exceeding the selected ceiling or a lower cap imposed by the host.
4. Compare picture stability and responsiveness with automatic bitrate off at the
   same resolution/frame rate. A larger number alone is not a success criterion.

## Clipboard text

1. In the stream's Clipboard menu, send a new Mac text copy to the host, then paste
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
