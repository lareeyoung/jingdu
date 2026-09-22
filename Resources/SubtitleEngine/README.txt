镜读本地字幕引擎

whisper.cpp v1.8.3, MIT
Source: https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.3
Source archive SHA-256: 870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a
Built with static whisper/ggml, embedded Metal shaders, Accelerate, arm64 macOS 14+.
All dynamic dependencies are Apple system frameworks/libraries; no Homebrew runtime dependency.

Model: upstream multilingual ggml-small.bin (not small.en)
Size: 487601967 bytes
Upstream SHA-1: 55356645c2b361a969dfd0ef2c5a50d530afd8d5
Upstream source: https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
Local model: ~/Library/Application Support/Jingdu/SubtitleModels/ggml-small.bin
Model weights are not bundled. Scripts/prepare-subtitle-engine.py explicitly installs and validates them.
Application runtime never downloads a model or sends audio to a service.

Automatic language identification runs independently for each 30-second window.
Supported product languages: zh, en, ja, ko, es, fr.
Short phrases/code-switching inside a window may require a user-selected language or correction.
Chinese translation is a separate step and is not produced by this ASR engine.

Validation (2026-09-21, macOS 26.6.2 / arm64):
- Six system-generated speech fixtures: automatic zh/en/ja/ko/es/fr detection and original-language output passed.
- Full Swift AVFoundation -> bundled CLI -> validated subtitle cues passed for all six languages.
- Two trimmed source clips preserved sequence timing while originalVolume=0 and an unrelated missing music file was ignored.
- English followed by Chinese at the 30-second window boundary produced separate correct cue languages and project offsets.
- Silent PCM and a video without audio produced explicit errors.
- In-flight cancellation terminated the child and removed temporary audio/output files.
- Invalid/unknown language and negative, reversed, overlapping or oversized timestamps are rejected.
- Decoder intervals are intersected with real source audio; small tail overruns do not abort a whole window.
- Natural segments are used without experimental max_len token timestamps; same-boundary point fragments retain their text in adjacent cues.
Fixtures were synthetic; no user audio/video was sent to a service or used for these tests.
