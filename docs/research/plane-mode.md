# Plane mode: listening quieter over engine noise

Research date: 2026-11-08. Written for a listener with passive wired in-ear buds (no noise cancelling) who turns the volume up high on flights. Implemented on the same date; see the implementation status at the end.

## Recommendation

Ship three things, in this order of benefit:

1. **Tell the listener about fit.** In the model, a good seal let the music play about 7 dB (6–9 dB) quieter than a poor one, more than any processing. A poor seal was assumed to give half the isolation. Plane mode shows this once, the first time it is switched on.
2. **Even out loudness between songs**, measured once per file on the phone. Without it, the volume ends up set for the quietest song, and every louder song plays too loud. Plane mode levels songs by integrated loudness plus a correction for bass the rumble masks ("cabin loudness", capped at −3/+5 dB). In a playlist simulation that cut music exposure by about 6.5 dB, against about 0 dB for plain loudness levelling.
3. **Compress gently inside mpv**: lift quiet passages, add a small low-mid lift, and stop clipping with a limiter.
   - About 2.5 dB of exposure on a typical song, and about 5 dB in its quiet passages.
   - Classical and piano: 2–3.5 dB overall and 5–6.5 dB in quiet passages.

Do not ship bass boost, presence boost, EQ-only presets, Android's `LoudnessEnhancer`, `dynaudnorm`, or microphone-adaptive EQ (reasons below).

Every 3 dB less doubles the safe listening time under the WHO/ITU H.870 rule (80 dBA for 40 h a week, 3 dB exchange rate). A 6 dB reduction quadruples it.

## What the listener is up against

- **Cabin noise at cruise** is about 70–85 dBA, with C-weighted levels 10–14 dB higher, because most of the energy is below 250 Hz ([wide-body measurements](https://pmc.ncbi.nlm.nih.gov/articles/PMC9074885/), [Özcan & Nemlioğlu](https://jcaa.caa-aca.ca/index.php/jcaa/article/view/1854), [200-flight study](https://pubmed.ncbi.nlm.nih.gov/29545611/)). Turboprops are louder, with tones at 63–125 Hz.
- **Passive in-ear buds** block 20–30 dB above 1–2 kHz but little below 500 Hz, and almost nothing with a poor seal ([earpiece database](https://arxiv.org/pdf/2004.06579), [RTINGS on isolation](https://rtings.com/headphones/learn/research/noise-isolation)). The noise that reaches the eardrum is a 60–75 dBA rumble, almost all of it below 500 Hz.
- **What gets lost:** in a third-octave masking model, music below about 250 Hz sat 15–30 dB under that rumble, so no reasonable bass boost brings it back. The 250–600 Hz region is marginal, and above 2 kHz the music has 15–25 dB to spare. Quiet passages drop under the noise first, which is why listeners turn the volume up for them and then get blasted by the loud parts and the next loud song.

## Simulation

Inference from a model, not a listening test. Seven CC-licensed music clips (classical, piano, pop, electronic, drum & bass; [librosa example data](https://github.com/librosa/data)) and a wide-dynamics variant were rendered through candidate chains with FFmpeg 6.1. The model:

- Noise: 80 dBA cabin spectrum minus silicone-tip isolation (good and poor seal).
- Audibility: a band-frame of the music is audible when it is above the hearing threshold and above the noise's spread masking threshold (Terhardt slopes), in 25 third-octave bands and 100 ms frames.
- Required level: the lowest gain at which 85% of the music's loudness-weighted band-frames are audible.
- **Exposure:** the music's A-weighted level at the ear at that gain. This is the hearing-damage number. The volume-knob change is not: make-up gain moves the knob without lowering the sound at the ear.

| Processing | Exposure change, median [range] | Quiet passages | Pumping (fast gain modulation, dB RMS) |
|---|---|---|---|
| Compressor −28 dB, 2.5:1, 15/300 ms + 350 Hz +4 dB (**Standard**) | −2.5 dB [−5.4..+0.1] | −4.9 dB | 1.4 |
| Compressor −32 dB, 3:1, 10/250 ms + 350 Hz +6 dB (**Strong**) | −2.9 dB [−7.0..+0.4] | −5.6 dB | 1.8 |
| Same without the 350 Hz lift (−28 dB, 3:1) | −2.0 dB | −4.6 dB | 1.6 |
| Two-stage (slow leveller + fast compressor) | −2.0 to −2.2 dB | −3.4 to −4.1 dB | 0.9–1.3 |
| 4-band compressor (like Android `DynamicsProcessing`) | −0.7 to −1.4 dB | | 0.5–1.2 |
| Bass shelf +5/+8 dB on top of compression | +0.1 dB (no help) | | |
| Presence +3 dB at 2.5 kHz on top of compression | +0.8 dB (worse) | | |
| `LoudnessEnhancer`-style +10 dB into a limiter | −0.6 dB (the knob drops 9.6 dB) | | |
| `dynaudnorm` | −0.1 to +0.1 dB, +2.6 dB on piano | | |
| EQ only, possible with the stock libmpv build | −0.2 to −0.3 dB | | |
| Good seal instead of a poor one (music level needed) | **−7.4 dB** [−6.1..−8.8] | | |

Already loud, compressed pop and electronic music gains 0–1 dB from compression. Classical and piano gain 2–3.5 dB. Compression helps mainly with dynamic recordings ([Taylor & Miranda](https://www.aes.org/e-lib/browse.cfm?elib=18461) found no benefit of hyper-compressed pop for earbuds in noise).

**Levelling across a playlist** (one fixed volume for all songs):

| Levelling measure | Exposure change |
|---|---|
| None | 0 dB |
| Integrated loudness (EBU R128, LUFS) | −0.1 dB |
| **Loudness above 300 Hz ("cabin loudness")** | **−6.3 dB** (about −7 dB with compression) |
| Integrated loudness + cabin correction capped at ±3 dB | −4.7 dB |
| Integrated loudness + cabin correction capped at −3/+5 dB (shipped) | −6.5 dB |

Bass-heavy mixes need up to 10 dB more level in the cabin than LUFS predicts, because LUFS counts bass that cannot be heard there. After LUFS levelling the needed gain still differed by 10.9 dB between songs; after cabin levelling, by 4.6 dB. This result comes from 7 clips and from a model whose audibility is itself driven by the bands above 250 Hz, so it needs a listening check on a real flight.

Measured gaps between integrated and cabin loudness: 0.6 dB for piano and classical, 3 dB for vocal pop, 7–9 dB for bass-heavy electronic music.

## Prior art

- **Spotify** offers Quiet −19, Normal −14 and Loud −11 LUFS; Loud uses a limiter and is meant "to compensate for a noisy or quiet environment" ([Spotify](https://support.spotify.com/artists/article/loudness-normalization/)).
- **YouTube** plays music at about −14 LUFS and only turns loud uploads down ([MeterPlugs](https://www.meterplugs.com/blog/2019/09/18/youtube-changes-loudness-reference-to-14-lufs.html)). yt-dlp downloads the unnormalized originals, so in WoolyTube loud masters played 6–7 dB hotter than in the YouTube app.
- **Apple Music** has Sound Check (per-song gain) and the Late Night EQ (compression).
- **Car audio**: Bose AudioPilot boosts what the noise masks, using a microphone ([GM Authority](https://gmauthority.com/blog/2014/11/bose-audiopilot-noise-compensation-technology-feature-spotlight/)). Cruise noise is steady, so a fixed preset captures most of that benefit without asking for microphone permission.
- **Poweramp EQ and Wavelet** build their limiter and compressor on Android's [`DynamicsProcessing`](https://developer.android.com/reference/android/media/audiofx/DynamicsProcessing).

## How it can run in this app

WoolyTube plays through media_kit's libmpv. Three routes were checked in source:

1. **mpv's own filters (`af=lavfi=[...]`). Chosen.**
   - media_kit_libs_android_video 1.3.8 ships the [libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) "default" jars (v1.1.7). Their FFmpeg is configured with `--disable-filters --enable-filter=overlay --enable-filter=equalizer`, so there is no compressor, limiter or volume filter, and no `aresample` to convert formats.
   - The same project publishes "encoders-gpl" jars (v1.1.11) with every filter. They use the same mpv commit (`78d43740`), the same FFmpeg 6.0, identical `mpv_*` exports and a byte-identical `libmediakitandroidhelper.so`.
   - The cost is about 6 MB per split APK (24 MB for the universal one) and a GPLv3 libmpv, which is fine for this GPLv3 app.
   - The filters run on every Android version, change live without a gap, cost about 2–6% of one phone core, and can be tuned on a desktop with the same FFmpeg filters.
2. **Android audio effects** (`DynamicsProcessing`, Android 9+). Rejected.
   - It needs mpv's AudioTrack output with a session we generate (`audiotrack-session-id`). media_kit forces OpenSL ES because the AudioTrack output in this mpv build crashes when two players use it (the chapter editor has a second player).
   - It is missing on some ROMs. Its multiband compressor did no better than one band in the simulation, and `LoudnessEnhancer` (Android 4.4+) is close to useless here.
3. **Offline rendering** of processed copies with the bundled ffmpeg. Rejected: double the storage, and nothing changes until a file is re-rendered.

**Measuring loudness:**
- A new Kotlin decoder (MediaExtractor and MediaCodec at full rate, float output where possible) feeds an ITU-R BS.1770-4 meter. The meter's K-weighting follows libebur128, with 400 ms blocks and −70 LUFS / −10 LU gates. It also measures cabin loudness: the same meter after a 2nd-order 300 Hz high-pass, gated on its own.
- It matches FFmpeg's `ebur128` within 0.006 LU on music, noise, mono and 5.1 at 22.05–48 kHz.
- Mono is measured as one channel, as BS.1770 defines it. mpv plays mono on both ears at −3 dB each, which has the same loudness.
- WAV files, and FLAC files through Android's own extractor, arrive as raw PCM. They are read in the extractor's encoding, because asking the raw decoder for float only relabels 16-bit samples.
- The meter runs at about 1000× real time on a desktop JVM. On a phone, decoding dominates: an estimated 1.5–3 s per 4-minute song on a mid-range phone, not yet measured.
- The existing 16 kHz mono decoder for song recognition reads 3–5 dB low, so it is not used.

**Applying it:**
- mpv applies `replaygain-fallback` (dB) at the output, after the filters, with a hard clip and no limiter. "Even out volume" uses it, cutting loud songs and raising quiet ones only within their peak headroom.
- Plane mode puts everything inside the filter chain instead.
- The filters and gain are set between pausing and `open()` for each song, so a song never starts at the previous song's level.

## Proposed and implemented behavior

**Plane mode** (a switch under Settings > Sound) sets mpv's `af` to:

```
@plane:lavfi=[volume=<L>dB,
  acompressor=threshold=-28dB:ratio=2.5:attack=15:release=300:knee=2.83:detection=rms:link=maximum,
  equalizer=f=350:t=o:w=2:g=4,
  volume=<9.5 + C>dB,
  alimiter=limit=-1.5dB:attack=5:release=50:level=disabled]
```

- `L = -20 - integrated LUFS`, clamped to −24…+12 dB. It brings every song to the same level at the compressor, so its threshold means the same on every song.
- `C = (integrated − cabin loudness) − 3`, clamped to −3…+5 dB. Songs with more masked bass get more level, and bass-light songs a little less. At +5 dB the limiter took at most 0.4 LU off drum & bass.
- An unmeasured song is planned as if at −14 LUFS with C = 0. The limiter keeps it safe.
- **Strong** uses −32 dB, 3:1, 10/250 ms, a +6 dB low-mid lift and 13 dB of output gain.
- **Output level:** a typical song comes out at about −15 LUFS (Standard) or −14 LUFS (Strong). Loud recent masters (−7 to −10 LUFS) therefore get quieter when plane mode is switched on and may need the volume a little higher, while quiet recordings get louder. The first-time tips ask the listener to set the volume so the quiet parts are just clear, and no louder.
- The limiter ceiling is −1.5 dBFS, because the sample-peak limiter misses up to about 1 dB of inter-sample peaks.

**Even out volume** (Settings > Sound) brings songs to −14 LUFS with `replaygain-fallback`:
- Cuts are at most 20 dB.
- Boosts are at most 6 dB and never past the song's peak minus 1 dB.
- An unmeasured song stays as it is.

**Measuring:**
- Measuring runs only while plane mode or Even out volume is on.
- The player switches measuring on and off with its settings, then asks for the playing song and the next three. Those are measured right away, even on battery.
- The rest of the library is measured one song at a time, and only while the phone is charging. A one-time pass is about 1.5–3 s of decoding per song (estimated), which is hours of CPU for a large library. The player's look-ahead covers what is actually played.
- The library scan runs in a background isolate.
- Measuring waits while the library moves or deletes files, and scans again afterwards, since paths may have changed. It looks for new songs whenever a download run ends.
- A song is never re-levelled while it plays. One that was not measured yet keeps the typical level until its next play.
- Results are stored in a `loudness_measurements` table with the file's path, size and modification time. A replaced file is measured again, and measurements are deleted with their track.

**Unchanged:**
- The chapter editor's preview player stays unprocessed.
- mpv keeps OpenSL ES output.
- Nothing is written into media files.

## Risks and what to check on a flight

- **No listening test yet.** The benefit numbers come from two energetic-masking models with assumed cabin and isolation spectra. Check by ear: switch plane mode on and off on a flight (or against a recording of cabin noise), and note the phone volume step needed in each case.
- **Pumping:** Standard's modulation (1.4 dB RMS) should be inaudible on most music. Strong may audibly pump on drum & bass and solo piano.
- **The `alimiter` in FFmpeg 6.0** lacks a bounds check added in 6.1, which can, rarely, cause a brief extra gain dip. Output is still hard-limited.
- **A missing filter means silence:** if a build ever went back to the default libmpv, mpv would accept the filter string and then play the next song with no sound. `test/plane_mode_build_test.dart` fails if the vendored libmpv override is removed.
- **Compressor state resets on every seek** (mpv rebuilds the lavfi graph). The first 15 ms after a seek play at full make-up gain, caught by the limiter.
- **Measuring without a charger** covers only the playing and next songs. A song chosen out of order, for example by tapping it, plays at the typical level the first time.
- **Vendor effects** (Samsung SoundAlive, Dolby) still run after plane mode.

## Implementation order and verification

1. Kotlin loudness meter and `analyzeLoudness` channel method (`plugins/woolytube_ytdlp`).
   - JUnit tests check sine, gating, mono, 5.1, cabin filter and format changes.
   - Parity with FFmpeg was checked on 11 signals.
   - The code was compiled against Android 14 API stubs and the Flutter embedding.
2. The vendored `plugins/media_kit_libs_android_video` with the v1.1.11 encoders-gpl jars.
   - MD5s, symbols (`ff_af_acompressor`, `ff_af_alimiter`, `ff_af_aresample`, `ff_af_volume`), `mpv_*` exports and the helper library were compared with the default jars.
   - The exact filter strings were played through desktop mpv 0.37. The output is bit-identical to FFmpeg rendering the same graph, and `replaygain-fallback=-4.5` measured exactly −4.5 dB.
3. Dart: `audio_processing.dart` (pure planning), `loudness_service.dart` (measuring and storage), the player integration, settings, UI and tests.

## Implementation status

Implemented on branch `claude/airplane-noise-audio-solution-g9gd51`. Host tests pass (`flutter test`). Not yet done in this environment:
- No APK build: this sandbox has no Android SDK.
- No run on a phone, so there are no on-device timings for the decoder and no check that every phone decoder accepts float output.
- No flight test.
