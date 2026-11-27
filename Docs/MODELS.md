# Models and tools

Everything Chirp downloads to run on the Mac, which helper runs it, and how to add or swap one. Nothing
here is bundled in the app: each model is fetched the first time a feature needs it, then runs offline.
See [ARCHITECTURE.md](ARCHITECTURE.md) for the helper processes and `ModelCenter`, and
[PRIVACY.md](PRIVACY.md) for what these downloads send.

## Table

Sizes are the download size, roughly. "Verify" means the value was not confirmed against the source
and must be checked before release.

| What | Used for | Source | Size | Licence | Runs in | Loads | Unloads | Stored in |
|---|---|---|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v2**, Q8_0 GGUF | Speech to text: dictation, voice notes, meetings, files and links | `huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf`, file `parakeet-tdt-0.6b-v2-Q8_0.gguf`, pinned to commit `07cee06…`; size and SHA-256 checked before the file is moved into place (`Transcriber.swift`) | 730 MB (729,574,912 bytes) | CC-BY-4.0 | Speech worker, `--transcribe-worker` (transcribe.cpp; GPU with processor fallback) | First dictation, recording or import; or Download in onboarding, which shows the size first | After 5 idle minutes (Settings › Dictation; `0` = after each use, `-1` = never), never while a recording holds it; when no switched-on feature needs it | `~/Library/Application Support/Chirp/Models/` |
| **Qwen3.5 2B**, MLX 4-bit | Rewrites (Proofread, Shorten, Rephrase, Write out), meeting notes, deeper writing checks, summaries on larger Macs | `mlx-community/Qwen3.5-2B-MLX-4bit` (Hugging Face hub), pinned to commit `93760be…` | 1.6 GB | Apache-2.0 | Language helper, `--language-worker` (MLX) | When a job needs it | After 4 idle minutes on Macs under 12 GB; to make room for the voice on those Macs; when no feature needs it; when the summary model takes its place | `~/.cache/huggingface/hub/models--mlx-community--…` |
| **Qwen3.5 4B**, MLX 4-bit | Same, default on Macs with 16 GB or more | `mlx-community/Qwen3.5-4B-MLX-4bit`, pinned to commit `32f3e8e…` | 3.1 GB | Apache-2.0 | Language helper | Same | Same | Same |
| **Qwen3.5 9B**, MLX 4-bit | Same, only when chosen by the user | `mlx-community/Qwen3.5-9B-4bit`, pinned to commit `8b2b98c…` | 6.0 GB | Apache-2.0 | Language helper | Same | Same | Same |
| **Qwen3 0.6B**, MLX 8-bit (summary model) | Summaries, on Macs whose language model is the 2B | `mlx-community/Qwen3-0.6B-8bit`, pinned to commit `11de968…` | 0.7 GB | Apache-2.0 | Language helper, in the language model's place | First summary | When the next non-summary job needs the general model; same idle rules | `~/.cache/huggingface/hub/` |
| **TLDR LoRA adapter** for Qwen3 0.6B | Fused into the summary model as it loads | `phh/Qwen3-0.6B-TLDR-Lora`, pinned to revision `0f39534…`; files `adapter_config.json`, `adapter_model.safetensors` | Small (verify) | Apache-2.0 (trained on `trl-lib/tldr`; verify that dataset's terms) | Language helper | With the summary model | With the summary model | `~/.cache/huggingface/hub/` |
| **bge-small-en-v1.5** | Search by meaning | `BAAI/bge-small-en-v1.5`, pinned to commit `5c38ec7…` | 130 MB | MIT | Language helper, search lane (MLX) | When the user turns on search by meaning, or searches after that | The helper is ended after 240 s unused if it holds nothing else; with the language model when that unloads; when every feature that saves items (all but Writing checks) is off | `~/.cache/huggingface/hub/` |
| **MiniCheck RoBERTa-Large** (sentence checker) | Checks each summary point against its source; a point it does not support is replaced by the closest source sentence | `jakeflavin/minicheck-roberta-large` on Hugging Face, each file checked by size and SHA-256 (`SummaryCheckerDownload.swift`) | About 710 MB as fp16 safetensors (verify) | MIT (upstream `lytang/MiniCheck-RoBERTa-Large`) | Language helper, search lane (MLX reranker API) | For each summary, after the summary model has written the points | Straight after scoring | `~/Library/Application Support/Chirp/Models/minicheck-roberta-large/` |
| **Kokoro 82M**, Core ML | Read aloud | FluidAudio's `FluidInference/kokoro-82m-coreml`, subfolder `ANE` (seven model stages plus `vocab.json`), fetched by FluidAudio | 95 MB | Apache-2.0 | Voice helper, `--voice-worker` (FluidAudio, processor only by default) | First read aloud | After 30 idle minutes on Macs under 12 GB; to make room for the language model on those Macs; when Read aloud is switched off. The helper stays 10 minutes more holding only the word list, then ends | `~/.cache/fluidaudio/Models/kokoro-82m-coreml/` |
| Kokoro voice packs | The 11 voices in Settings › Reading | Same repo, one `.bin` per voice | About 0.5 MB each | Apache-2.0 | Fetched by the voice helper | All missing ones are fetched in the background after the voice first loads | Never (files) | Same folder |
| Kokoro British word list | Saying words the British way in British voices | FluidAudio's English lexicon download for British English (`KokoroAneResourceDownloader.ensureEnglishLexicon`) | About 10 MB | Verify (Misaki lexicon, via FluidAudio) | Voice helper | First time a British voice speaks | Never (file) | `~/.cache/fluidaudio/Models/kokoro/` |
| **Silero VAD**, Core ML | Voice detection: where speech is, cutting long audio, the live "is anyone talking" check | FluidAudio's `FluidInference/silero-vad-coreml`, fetched by FluidAudio | Small (verify) | MIT | Listen helper, `--listen-worker voice-detection`, processor only | With the speech model | With the speech model | `~/Library/Application Support/FluidAudio/Models/silero-vad/` |
| **pyannote speaker labelling** (community-1 per the code comments), Core ML | Who spoke when, after a meeting | FluidAudio's offline diarizer models, `FluidInference/speaker-diarization-coreml` (verify which revision FluidAudio pins) | 100 MB | Chirp shows CC-BY-4.0; the repo card says "other / scoped-cc-by-4.0" (verify) | Listen helper, `--listen-worker speakers`, processor only | When a meeting is finished, if "tell speakers apart" is on | When the speakers' job ends or Meetings is switched off | `~/Library/Application Support/FluidAudio/Models/speaker-diarization/` (FluidAudio's default; verify) |
| **yt-dlp** (a tool, not a model) | Getting the sound from a video page link | `https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos`, checked against that release's `SHA2-256SUMS` before it is installed | About 35 MB (verify) | Unlicense for yt-dlp; the macOS binary bundles Python and other packages (verify their licences) | A plain child process of the app, not a model helper | First page link, or Download in Settings › Models › For links | Never; Remove in Settings deletes it | `~/Library/Application Support/Chirp/Tools/` |

Not downloaded and not a Chirp model: Apple's Vision text recognition, used to read the text of a
window picture kept during a recording (`ScreenReader.swift`). It is a system framework.

Not a model: Harper, the spelling and grammar checker. It is compiled into the app from
`Rust/chirp-harper` and runs in the app process. Its dictionary is part of harper-core.

## Where the names come from in code

| Model | Constant |
|---|---|
| Parakeet | `Transcriber.modelSource`, `modelFile`, `modelBytes`, `modelSHA256` (`ChirpML/Transcriber.swift`) |
| Language sizes | `LanguageModelSize.modelID`, `downloadGB`, `comfortableMemoryGB` (`ChirpCore/Engine/ModelChoice.swift`), the only place they are named. `LanguageModel.load(modelID:)` is always told which |
| Memory lines | `MacMemory` (same file): one heavy model at a time under 12 GB, and the deeper writing check in other apps on by default where the medium size is picked |
| Summary model + adapter | `ModelCenter.tldrSummaryModel` (`App/Sources/Services/ModelCenter.swift`) |
| Search | `Embedder.modelID`, `revision` (`ChirpML/Embedder.swift`) |
| Sentence checker folder | `ModelCenter.summaryCheckerFolder`, `summaryCheckerDirectory` |
| Kokoro, voices | `Voice.modelDirectory`, `Voice.voices`, `Voice.defaultID` (`ChirpML/Voice.swift`); the repo ids are inside FluidAudio |
| Silero, pyannote | Inside FluidAudio (`VadManager`, `OfflineDiarizerManager`) |
| yt-dlp | `LinkTool.asset` (`ChirpCore/Meetings/MediaLinks.swift`), `LinkImporter.releaseBase` |

The names, sizes and licences shown in Settings › Models come from `ModelKind` in `ModelCenter.swift`.
Keep that and this table in step.

## How each download is checked

| Download | Check |
|---|---|
| Parakeet | HTTP 200, then SHA-256 against the pinned hash, then moved into place. Pinned URL commit |
| Hub models (Qwen, bge, summary model and adapter) | Fetched by swift-huggingface's hub downloader, each pinned to a commit: `LanguageModelSize.revision`, `Embedder.revision`, `ModelCenter.tldrSummaryModel` |
| FluidAudio models | FluidAudio's own downloader. Chirp checks only that the files exist (`Voice.isDownloaded`, `SpeakerLabeler.isDownloaded`) |
| yt-dlp | Release `SHA2-256SUMS` fetched, file fetched, SHA-256 compared; installed only on a match |
| MiniCheck | Size and SHA-256 of each of its eight files (`SummaryCheckerDownload.files`) |

## The sentence checker (MiniCheck)

The checker is `lytang/MiniCheck-RoBERTa-Large` (MIT), converted from `pytorch_model.bin` to fp16
`model.safetensors` with `Scripts/minicheck-convert.py` and with `id2label` set to
`{"0":"unsupported","1":"entailment"}`. Nothing was retrained. The converted copy is published at
`huggingface.co/jakeflavin/minicheck-roberta-large`.

The first time a summary runs without it, `SummaryCheckerDownload` fetches its eight files in the background into
`~/Library/Application Support/Chirp/Models/minicheck-roberta-large/`. Each file's size and SHA-256 are checked
before the folder is moved into place. That summary, and any before the download finishes, use the rule check alone
and the log says so once. Reset Chirp deletes the folder with the other models.

## Adding or swapping a model

1. **Pick a helper.** MLX models join the language helper (`LanguageWorker.swift`): add ops to its
   `serve(streaming:)` table, a method on `LanguageSupervisor` on the right lane, and an engine actor
   beside `EmbedEngine` / `CheckEngine`. Anything else gets a role
   in a helper built on `ModelHelper`: write an engine that runs only in the helper, a `run()` that
   calls `HelperWorker.serve([...])`, and an app-side client that owns a `ModelHelper(arguments:what:)`.
   Add the flag check to `Main.main()` in `App/Sources/Shell/ChirpApp.swift`.
2. **Never load it in the app process.** The app-side client only talks to the helper.
3. **Register it with `ModelCenter`.** Add a `ModelKind` case with name, purpose, size and licence, and
   call `models.register(kind, onDisk:load:unload:)` from the feature that owns it. Decide whether it is
   `heavy` (gives way to other heavy models on small Macs).
4. **Tie it to features.** Add it to `FeatureModel` and `FeatureSet.needs` so it is unloaded when no
   feature needs it.
5. **Pin and check the download** where the source allows: a commit or revision, and a size or hash.
6. **Clean up on reset.** Add its folder to `DangerZone.downloads`.
7. **Document it.** Add a row here, list the download in [PRIVACY.md](PRIVACY.md), and add the licence
   to the third-party notices if any of its code or data ships in the app.

To **swap** a model for another of the same kind: change the constant in the table above. For the
search model, vectors from different models cannot be compared, so everything indexed must be embedded
again (clear the `chunk` table). For the speech model, update the size and hash together with the URL.
For a language size, check that the prompts in `ChirpCore/Engine/Prompts.swift` still pass the summary
and rewrite checks (`Scripts/e2e.sh`, `Fixtures/`).
