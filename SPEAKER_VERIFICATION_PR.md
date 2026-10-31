# Microphone speaker verification

## Phase 1 — answer protection and heuristics

- Locks a speech-triggered answer after the first streamed token. Later microphone transcripts no longer cancel it; they appear as **New question detected · Tap to answer** unless a strong question signal is present.
- Drops transcripts whose Chinese character-bigram or English word containment overlap with the visible answer is at least `0.35`.
- A strong question requires interrogative wording or a question mark **and** at least `1.5 s` since the preceding utterance ended.
- Apple speech segments now carry mean/peak voice RMS and duration in `RecognizedUtterance` while preserving the legacy text callback.
- Phase-one heuristics can be disabled with the `speech_heuristics_enabled` preference. Answer locking remains enabled as the safety baseline.

## Phase 2 — on-device voiceprint

### Library and model

- `sherpa-onnx 1.13.6` via Swift Package Manager, Apache-2.0.
- `onnxruntime-libs 1.27.1`, transitive runtime dependency; upstream ONNX Runtime is MIT.
- `3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx`, 28.3 MB, from the Apache-2.0 3D-Speaker project, downloaded only when requested and verified with SHA-256 `f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11`.
- The newer sherpa-onnx 1.13.8 was evaluated, but its current macOS ONNX Runtime archive contains framework symlinks rejected by Xcode's archive safety validation. Pinning 1.13.6 keeps both iOS and macOS buildable.

This is a 1:1 verification problem, so a direct speaker-embedding extractor is smaller and more focused than FluidAudio's full diarization pipeline. All inference is local.

### Enrollment and classification

- Enrollment records about 15 seconds with the current input node, divides it into four samples, averages their embeddings, and L2-normalizes the centroid.
- The profile stores the centroid, RMS baseline, thresholds, model ID, and model version in Apple Keychain. Raw enrollment audio is discarded.
- Self-check sets the high threshold to `clamp(score - 0.10, 0.55...0.90)` and the low threshold to `max(0.35, high - 0.20)`. Defaults are high `0.72`, low `0.48`.
- Fusion is `0.60 × embedding similarity + 0.25 × RMS closeness + 0.15 × answer overlap`.
- Segments under `1.2 s` do not use an embedding decision and remain `unknown`.
- Apple ASR verifies before transcription. Candidate-only audio is dropped; detected speaker-change regions are divided and candidate regions are removed before ASR.
- Doubao keeps a 30-second 16 kHz PCM ring buffer. Definite utterance `start_time`/`end_time` ranges are verified locally; local VAD audio is the fallback when timestamps are absent.

### Privacy

Voiceprints are biometric data. The embedding is encrypted by Keychain, raw enrollment audio is not persisted, and no speaker-verification audio is sent to a new network service. Doubao ASR continues sending microphone audio to the already configured Doubao service when that ASR provider is selected.

### Known limitations

- Similar voices, microphone/room changes, strong reverberation, or very short interjections can produce `unknown` or false matches.
- Energy is a supporting signal rather than identity proof; it is intentionally weighted below the embedding.
- Overlapping simultaneous speech cannot be perfectly separated by the sliding-window approach.
- The model download requires network access once; use remains offline afterward.

## Verification

Automated tests cover strong-question detection, Chinese/English overlap, fusion weights, double thresholds, and synthetic embedding change points.

Manual microphone acceptance remains device/environment dependent and should be recorded on the release hardware:

1. Interviewer question → candidate answers for 30 seconds → no answer refresh or new question.
2. Interviewer finishes and candidate starts immediately → only interviewer region is transcribed.
3. Interviewer asks a follow-up during the answer → pending prompt or automatic switch according to label.
4. Unenrolled/disabled → legacy behavior, apart from the phase-one answer lock.
5. Two similar same-gender voices → record false-accept and false-reject counts and note reliance on the RMS fallback.
