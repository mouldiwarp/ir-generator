# IR Generator

A native Apple silicon app for capturing speaker-cab impulse responses with the IK Multimedia AXE I/O. It exports
WAV files for **TONEX / AmpliTube** and **Fractal** (Axe-Fx III, FM9, FM3). It uses the same GM Guitars look as
Axeio Silicon and Mixdeck.

## Build

    ./scripts/build-app.sh            # -> build/IR Generator.app
    ./scripts/build-app.sh --install  # also copies it to /Applications and opens it
    swift run -c release ircore-tests # offline DSP tests (no hardware)

Allow microphone access the first time you run it: macOS needs that permission before an app can read the
interface's inputs. `IRGenerator --demo` opens the app with simulated captures.

## Wiring

    AXE I/O AMP OUT (outputs 5/6) ─► power amp ─► cab ─► mic ─► AXE I/O INPUT 1 (XLR)

Before capturing, set up the AXE I/O (Axeio Silicon's panel, for example):
- **To Amp Out OFF.** Otherwise Input 1 is routed to Amp Out, and the mic feeds back through the cab.
- **Direct monitoring** turned away from the mic input.
- **Phantom power** only for condenser mics.

The app asks you to tick a safety checklist before the first capture of each session.

## Capturing

1. Choose the route (**Amp Out**, or Out 1/2 or 3/4 for a line-level amp) and the mic input.
2. Click **Level check** (looped pink noise or a 1 kHz tone). Bring the power amp up to a moderate volume and set the
   mic gain so the input peaks around −12 dBFS. The output level is capped at −12 dBFS until you unlock it.
3. Click **Capture** (⌘R). Esc fades out and stops the capture.

Each capture plays the test signal, records the mic, deconvolves and trims the result. It's saved to
`~/Library/Application Support/IR Generator/Captures/` as a 1 s, 32-bit float master IR plus the raw recording, so
you can re-export it later at any length.

**Latency calibration (optional):** patch Out 1 into Input 2 (LINE), select OUT 1/2 and IN 2, then click
**Calibrate**. With **Keep mic distance delay** ticked, IRs then keep the mic's time of flight, so several mics on one
cab stay phase-aligned. Otherwise each IR starts at the direct sound, which is the usual choice for a single-mic IR.

## How it works

- **Signal.** The default is an exponential sine sweep (Farina; 20 Hz–20 kHz, 2–10 s, averaged 1–8×). Power-amp
  harmonic distortion appears *before* the impulse, so trimming removes it. Periodic pink or white noise is the
  alternative: one 2¹⁶-sample period, repeated and synchronously averaged, then deconvolved circularly.
- **Deconvolution.** H = Y·X* / (|X|² + ε(f)), computed with a double-precision FFT. ε is tiny inside the swept band
  and rises over a third of an octave outside it, so out-of-band noise isn't amplified.
- **Trimming.** The onset is the first sample within −20 dB of the peak, with 0.2 ms kept before it and faded in.
  An optional 20 Hz high-pass (2nd-order Butterworth) follows.
- **Playback and recording.** A single Core Audio IOProc on the AXE I/O plays and records in the same callback, so
  the recording is sample-aligned to the playback and latency stays constant. This engine is written in C, so the
  audio thread never runs Swift.
- **Export.** Optional minimum phase (real cepstrum), then windowed-sinc resampling with the gain preserved, a
  half-Hann fade-out (5/10/20 %), and normalisation (peak −0.1 dBFS, matched RMS, or none).

| Preset | Rate | Length | Format |
|---|---|---|---|
| Fractal Standard | 48 kHz | 1024 (21 ms) | 24-bit mono WAV |
| Fractal | 48 kHz | 2048 (43 ms) | 24-bit mono WAV |
| Fractal UltraRes | 48 kHz | 8192 (171 ms) | 24-bit mono WAV |
| TONEX / AmpliTube | 48 kHz | 2048 / 4096 / 8192 / 500 ms | 24-bit mono WAV |
| TONEX / AmpliTube | 44.1 kHz | 4096 | 24-bit mono WAV |

Fractal-Bot and Axe-Edit III convert the WAVs to the unit's format on import. TONEX and AmpliTube load the WAVs
directly. Files are named `<name>_<Fractal|TONEX>_<rate>_<length>.wav`.

## Views

- **Frequency:** log 20 Hz–20 kHz, with off, 1/12, 1/6 or 1/3-octave smoothing, a hover readout, and overlays of
  other captures or imported IRs. **Length** previews the response cut to an export length.
- **Impulse:** waveform or energy-time (dB), 5 ms to the full IR, with markers at 1024, 2048, 4096 and 8192 samples.
- **Recording:** the raw mic signal, with clip lines.
- **Spectrogram:** the recording on a log-frequency axis. Harmonic distortion shows up as faint lines above the sweep.

## Align & Blend (⌘B)

Shows the selected IR plus the ones you've added to the graph (eye buttons), choose a reference, and each other IR is:
- **Aligned** by band-limited cross-correlation (80 Hz–4 kHz, ±5 ms), to a fraction of a sample. Onset trimming
  alone can leave mics 0.1–0.3 ms apart, because they rise at different speeds.
- **Checked for polarity.** An inverted IR (for example, a ribbon or a rear mic) is detected and can be flipped.
- **Previewed as a blend**, with the curve as captured (red, dashed) against the aligned one (gold). With two IRs,
  a mix slider sets the balance.

Save the aligned IRs or the blend as new library entries, then export them as usual. The alignment comes from the
waveforms, so it gives the best-summing position, not the true distance between the mics.

## Mic Swap (⌘M)

Removes the capture mic's response from an IR (**speaker only**), or replaces it with another mic's. The correction
is a minimum-phase filter built from the ratio of the two mics' magnitude curves, including each pattern's proximity
bass at the chosen distance. It's limited to +6/12/18 dB of boost and fades to 0 dB below 35 Hz and above 16 kHz.

The built-in curves are smoothed approximations of published on-axis responses, not manufacturer data:
- Dynamic: SM57, MD 421, e906, i5, RE20, SM7B
- Ribbon: R-121, M 160
- Condenser: C414, U 87
- Reference: flat

For accuracy, use **Import curve…** to load a measured or official response ("frequency dB" lines, REW `.txt`,
`.frd` or `.csv`) and set its polar pattern. A swap is an estimate: off-axis colouration, comb filtering and
reflections in the original capture stay in.

## Layout

| Path | Contents |
|---|---|
| `Sources/CIRAudio` | Real-time duplex IOProc (C) |
| `Sources/IRCore` | Signals, deconvolution, processing, analysis, WAV I/O, presets, simulator |
| `Sources/IRGenerator` | SwiftUI app: `CaptureModel`, `CaptureEngine`, `Library`, `Views/` |
| `Sources/ircore-tests` | Offline tests: a simulated cab, plus noise and distortion, through the whole pipeline |

Diagnostics:
- `IRGenerator --snapshot <dir>` renders each graph tab to PNG.
- `IRGenerator --engine-test` runs the engine silently on the AXE I/O for one second.
