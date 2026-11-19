# Third-party notices

Chirp is released under the GPL-3.0 ([LICENSE](LICENSE)). It's built on the open-source projects below, and their licences apply to their code. Every licence here is compatible with the GPL-3.0.

## Libraries in the app

| Project | Licence | Copyright |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | 2015-2025 Gwendal Roué |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | Sindre Sorhus |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT | 2006-2013 Andy Matuschak, and the Sparkle Project contributors |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | FluidInference |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) (with MLX and mlx-c) | MIT | 2023 ml-explore |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | MIT | 2024 ml-explore |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | 2022 Hugging Face SAS |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache-2.0 | 2025 Hugging Face SAS |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 | 2022 Hugging Face SAS |
| [EventSource](https://github.com/mattt/EventSource) | MIT | 2025 Mattt |
| [yyjson](https://github.com/ibireme/yyjson) | MIT | 2020 YaoYuan |
| [swift-collections, swift-numerics, swift-crypto, swift-asn1](https://github.com/apple) | Apache-2.0 | Apple Inc. and the Swift project authors |
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) (the speech engine, and its Swift bindings in `Packages/TranscribeCpp`) | MIT | 2026 The transcribe.cpp authors |
| ggml, miniz and the Silero VAD segment policy, inside transcribe.cpp | MIT | See [Packages/TranscribeCpp/THIRD-PARTY-LICENSES.md](Packages/TranscribeCpp/THIRD-PARTY-LICENSES.md) |
| [Harper](https://github.com/Automattic/harper) (grammar and spelling, with its dictionary) | Apache-2.0 | 2024 Automattic Inc. |
| Rust crates built into the Harper library | Permissive or MPL-2.0 | See [Rust crates](#rust-crates) below |

## Adapted from

| Project | Licence | What Chirp uses |
|---|---|---|
| [Defuddle](https://github.com/kepano/defuddle) | MIT | The patterns that recognise boilerplate in pages and newsletters (sponsor blocks, footers, social counters, related links), in `Packages/ChirpCore/Sources/ChirpCore/Text/Boilerplate.swift` |
| [Handy](https://github.com/cjpais/Handy) | MIT | The approach to matching dictation against the personal dictionary, and how the speech model is loaded and run in a worker |

## Models Chirp downloads

These aren't part of this repository or the app download. Chirp fetches them the first time a feature needs them. [Docs/MODELS.md](Docs/MODELS.md) has the details.

| Model | Licence | By |
|---|---|---|
| Parakeet TDT 0.6B v2 (speech to text, GGUF) | CC-BY-4.0 | NVIDIA |
| Qwen3.5 2B, 4B and 9B (MLX) | Apache-2.0 | Alibaba Cloud (Qwen team) |
| Qwen3 0.6B (MLX), with the TLDR LoRA adapter by phh | Apache-2.0 | Alibaba Cloud (Qwen team); phh |
| bge-small-en-v1.5 (search) | MIT | BAAI |
| MiniCheck RoBERTa-Large (summary checking) | MIT | Liyan Tang, Philippe Laban, Greg Durrett |
| Kokoro 82M (voice) | Apache-2.0 | hexgrad |
| Silero VAD (voice detection) | MIT | Silero Team |
| Speaker diarization (Core ML, via FluidAudio) | CC-BY-4.0 | pyannote, converted by FluidInference |

Chirp can also download the [yt-dlp](https://github.com/yt-dlp/yt-dlp) tool (Unlicense) to get the sound from a video link, if you ask it to.

## Rust crates

The Harper library (`Rust/chirp-harper`) is built from these crates, as locked in `Cargo.lock`. A crate with two licences joined by OR is used under either one.

| Crate | Version | Licence |
|---|---|---|
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 |
| ahash | 0.8.12 | MIT OR Apache-2.0 |
| aho-corasick | 1.1.5 | Unlicense OR MIT |
| allocator-api2 | 0.2.21 | MIT OR Apache-2.0 |
| ammonia | 4.2.4 | MIT OR Apache-2.0 |
| android_system_properties | 0.1.6 | MIT OR Apache-2.0 |
| anstream | 1.0.0 | MIT OR Apache-2.0 |
| anstyle | 1.0.14 | MIT OR Apache-2.0 |
| anstyle-parse | 1.0.0 | MIT OR Apache-2.0 |
| anstyle-query | 1.1.5 | MIT OR Apache-2.0 |
| anstyle-wincon | 3.0.11 | MIT OR Apache-2.0 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 |
| arrayvec | 0.7.8 | MIT OR Apache-2.0 |
| ash | 0.38.0+1.3.281 | MIT OR Apache-2.0 |
| async-channel | 2.5.0 | Apache-2.0 OR MIT |
| atomic-waker | 1.1.2 | Apache-2.0 OR MIT |
| atomic_float | 1.1.0 | Apache-2.0 OR MIT OR Unlicense |
| autocfg | 1.5.1 | Apache-2.0 OR MIT |
| base64 | 0.22.1 | MIT OR Apache-2.0 |
| base64 | 0.23.1 | MIT OR Apache-2.0 |
| bincode | 2.0.1 | MIT |
| bindgen | 0.71.1 | BSD-3-Clause |
| bit-set | 0.8.0 | Apache-2.0 OR MIT |
| bit-vec | 0.8.0 | Apache-2.0 OR MIT |
| bitflags | 2.13.2 | MIT OR Apache-2.0 |
| blanket | 0.4.0 | MIT |
| block | 0.1.6 | MIT |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 |
| boxcar | 0.2.14 | MIT |
| bumpalo | 3.20.3 | MIT OR Apache-2.0 |
| burn | 0.19.1 | MIT OR Apache-2.0 |
| burn-autodiff | 0.19.1 | MIT OR Apache-2.0 |
| burn-candle | 0.19.1 | MIT OR Apache-2.0 |
| burn-common | 0.19.1 | MIT OR Apache-2.0 |
| burn-core | 0.19.1 | MIT OR Apache-2.0 |
| burn-cubecl | 0.19.1 | MIT OR Apache-2.0 |
| burn-cubecl-fusion | 0.19.1 | MIT OR Apache-2.0 |
| burn-cuda | 0.19.1 | MIT OR Apache-2.0 |
| burn-derive | 0.19.1 | MIT OR Apache-2.0 |
| burn-fusion | 0.19.1 | MIT OR Apache-2.0 |
| burn-ir | 0.19.1 | MIT OR Apache-2.0 |
| burn-ndarray | 0.19.1 | MIT OR Apache-2.0 |
| burn-nn | 0.19.1 | MIT OR Apache-2.0 |
| burn-optim | 0.19.1 | MIT OR Apache-2.0 |
| burn-rocm | 0.19.1 | MIT OR Apache-2.0 |
| burn-router | 0.19.1 | MIT OR Apache-2.0 |
| burn-store | 0.19.1 | MIT OR Apache-2.0 |
| burn-tensor | 0.19.1 | MIT OR Apache-2.0 |
| burn-wgpu | 0.19.1 | MIT OR Apache-2.0 |
| bytemuck | 1.25.2 | Zlib OR Apache-2.0 OR MIT |
| bytemuck_derive | 1.12.1 | Zlib OR Apache-2.0 OR MIT |
| byteorder | 1.5.0 | Unlicense OR MIT |
| bytes | 1.12.1 | MIT |
| cached | 2.0.2 | MIT |
| cached_proc_macro | 2.0.0 | MIT |
| cached_proc_macro_types | 1.0.0 | MIT |
| candle-core | 0.9.2 | MIT OR Apache-2.0 |
| caseless | 0.2.2 | MIT |
| cc | 1.11.1 | MIT OR Apache-2.0 |
| cexpr | 0.6.0 | Apache-2.0/MIT |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 |
| cfg_aliases | 0.2.2 | MIT |
| chacha20 | 0.10.2 | MIT OR Apache-2.0 |
| clang-sys | 1.9.1 | Apache-2.0 |
| clap | 4.6.7 | MIT OR Apache-2.0 |
| clap_builder | 4.6.7 | MIT OR Apache-2.0 |
| clap_derive | 4.6.7 | MIT OR Apache-2.0 |
| clap_lex | 1.1.1 | MIT OR Apache-2.0 |
| codespan-reporting | 0.12.0 | Apache-2.0 |
| colorchoice | 1.0.5 | MIT OR Apache-2.0 |
| colored | 3.1.1 | MPL-2.0 |
| comrak | 0.39.1 | BSD-2-Clause |
| concurrent-queue | 2.5.0 | Apache-2.0 OR MIT |
| const-random | 0.1.18 | MIT OR Apache-2.0 |
| const-random-macro | 0.1.16 | MIT OR Apache-2.0 |
| constcat | 0.6.1 | MIT OR Apache-2.0 |
| convert_case | 0.10.0 | MIT |
| convert_case | 0.8.0 | MIT |
| core-foundation | 0.10.1 | MIT OR Apache-2.0 |
| core-foundation-sys | 0.8.7 | MIT OR Apache-2.0 |
| core-graphics-types | 0.2.0 | MIT OR Apache-2.0 |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 |
| cpufeatures | 0.3.1 | MIT OR Apache-2.0 |
| crc32fast | 1.5.5 | MIT OR Apache-2.0 |
| critical-section | 1.2.0 | MIT OR Apache-2.0 |
| crossbeam-deque | 0.8.8 | MIT OR Apache-2.0 |
| crossbeam-epoch | 0.9.21 | MIT OR Apache-2.0 |
| crossbeam-utils | 0.8.23 | MIT OR Apache-2.0 |
| crunchy | 0.2.4 | MIT |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 |
| cssparser | 0.38.0 | MPL-2.0 |
| cubecl | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-common | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-convolution | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-core | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-cpp | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-cpu | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-cuda | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-hip | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-hip-sys | 7.14.6085001 | MIT OR Apache-2.0 |
| cubecl-ir | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-macros | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-macros-internal | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-matmul | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-opt | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-quant | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-random | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-reduce | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-runtime | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-std | 0.8.1 | MIT OR Apache-2.0 |
| cubecl-wgpu | 0.8.1 | MIT OR Apache-2.0 |
| cudarc | 0.17.8 | MIT OR Apache-2.0 |
| darling | 0.20.11 | MIT |
| darling | 0.21.3 | MIT |
| darling_core | 0.20.11 | MIT |
| darling_core | 0.21.3 | MIT |
| darling_macro | 0.20.11 | MIT |
| darling_macro | 0.21.3 | MIT |
| data-encoding | 2.11.1 | MIT |
| derive-new | 0.7.0 | MIT |
| derive_more | 1.0.0 | MIT |
| derive_more | 2.1.1 | MIT |
| derive_more-impl | 1.0.0 | MIT |
| derive_more-impl | 2.1.1 | MIT |
| deunicode | 1.6.2 | BSD-3-Clause |
| diff | 0.1.13 | MIT OR Apache-2.0 |
| digest | 0.10.7 | MIT OR Apache-2.0 |
| dirs | 6.0.0 | MIT OR Apache-2.0 |
| dirs-sys | 0.5.0 | MIT OR Apache-2.0 |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 |
| document-features | 0.2.12 | MIT OR Apache-2.0 |
| dtoa | 1.0.11 | MIT OR Apache-2.0 |
| dtoa-short | 0.3.5 | MPL-2.0 |
| dyn-stack | 0.13.2 | MIT |
| dyn-stack-macros | 0.1.3 | MIT |
| either | 1.19.0 | MIT OR Apache-2.0 |
| embassy-futures | 0.1.2 | MIT OR Apache-2.0 |
| embassy-time | 0.4.0 | MIT OR Apache-2.0 |
| embassy-time-driver | 0.2.2 | MIT OR Apache-2.0 |
| embedded-hal | 0.2.7 | MIT OR Apache-2.0 |
| embedded-hal | 1.0.0 | MIT OR Apache-2.0 |
| embedded-hal-async | 1.0.0 | MIT OR Apache-2.0 |
| entities | 1.0.1 | MIT |
| enum-as-inner | 0.6.1 | MIT/Apache-2.0 |
| enumset | 1.1.15 | MIT/Apache-2.0 |
| enumset_derive | 0.15.1 | MIT/Apache-2.0 |
| equivalent | 1.0.3 | Apache-2.0 OR MIT |
| errno | 0.3.14 | MIT OR Apache-2.0 |
| event-listener | 5.4.2 | Apache-2.0 OR MIT |
| event-listener-strategy | 0.5.4 | Apache-2.0 OR MIT |
| fastrand | 2.5.0 | Apache-2.0 OR MIT |
| fid-rs | 0.2.0 | MIT OR Apache-2.0 |
| filetime | 0.2.29 | MIT/Apache-2.0 |
| find-msvc-tools | 0.1.15 | MIT OR Apache-2.0 |
| fixedbitset | 0.4.2 | MIT/Apache-2.0 |
| flate2 | 1.1.11 | MIT OR Apache-2.0 |
| float-ord | 0.3.2 | MIT / Apache-2.0 |
| float4 | 0.1.0 | MIT |
| float8 | 0.4.2 | MIT |
| float8 | 0.6.1 | MIT |
| fnv | 1.0.7 | Apache-2.0 / MIT |
| foldhash | 0.1.5 | Zlib |
| foldhash | 0.2.0 | Zlib |
| foreign-types | 0.5.0 | MIT/Apache-2.0 |
| foreign-types-macros | 0.2.4 | MIT/Apache-2.0 |
| foreign-types-shared | 0.3.1 | MIT/Apache-2.0 |
| form_urlencoded | 1.2.2 | MIT OR Apache-2.0 |
| fst | 0.4.7 | Unlicense/MIT |
| futures-channel | 0.3.34 | MIT OR Apache-2.0 |
| futures-core | 0.3.34 | MIT OR Apache-2.0 |
| futures-io | 0.3.34 | MIT OR Apache-2.0 |
| futures-lite | 2.6.1 | Apache-2.0 OR MIT |
| futures-sink | 0.3.34 | MIT OR Apache-2.0 |
| futures-task | 0.3.34 | MIT OR Apache-2.0 |
| futures-util | 0.3.34 | MIT OR Apache-2.0 |
| gemm | 0.19.0 | MIT |
| gemm-c32 | 0.19.0 | MIT |
| gemm-c64 | 0.19.0 | MIT |
| gemm-common | 0.19.0 | MIT |
| gemm-f16 | 0.19.0 | MIT |
| gemm-f32 | 0.19.0 | MIT |
| gemm-f64 | 0.19.0 | MIT |
| generic-array | 0.14.7 | MIT |
| getopts | 0.2.24 | MIT OR Apache-2.0 |
| getrandom | 0.2.17 | MIT OR Apache-2.0 |
| getrandom | 0.3.4 | MIT OR Apache-2.0 |
| getrandom | 0.4.3 | MIT OR Apache-2.0 |
| gl_generator | 0.14.0 | Apache-2.0 |
| glob | 0.3.4 | MIT OR Apache-2.0 |
| glow | 0.16.0 | MIT OR Apache-2.0 OR Zlib |
| glutin_wgl_sys | 0.6.1 | Apache-2.0 |
| gpu-alloc | 0.6.2 | MIT OR Apache-2.0 |
| gpu-alloc-types | 0.3.1 | MIT OR Apache-2.0 |
| gpu-allocator | 0.27.0 | MIT OR Apache-2.0 |
| gpu-descriptor | 0.3.2 | MIT OR Apache-2.0 |
| gpu-descriptor-types | 0.2.0 | MIT OR Apache-2.0 |
| h2 | 0.4.20 | MIT |
| half | 2.7.1 | MIT OR Apache-2.0 |
| harper-brill | 3.0.0 | Apache-2.0 |
| harper-core | 3.2.0 | Apache-2.0 |
| harper-pos-utils | 3.0.0 | Apache-2.0 |
| hashbrown | 0.13.2 | MIT OR Apache-2.0 |
| hashbrown | 0.15.5 | MIT OR Apache-2.0 |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 |
| heck | 0.5.0 | MIT OR Apache-2.0 |
| hermit-abi | 0.5.3 | MIT OR Apache-2.0 |
| hexf-parse | 0.2.1 | CC0-1.0 |
| html5ever | 0.40.1 | MIT OR Apache-2.0 |
| http | 1.5.0 | MIT OR Apache-2.0 |
| http-body | 1.1.0 | MIT |
| http-body-util | 0.1.5 | MIT |
| httparse | 1.10.1 | MIT OR Apache-2.0 |
| hyper | 1.12.0 | MIT |
| hyper-rustls | 0.27.10 | Apache-2.0 OR ISC OR MIT |
| hyper-util | 0.1.21 | MIT |
| icu_collections | 2.4.0 | Unicode-3.0 |
| icu_locale_core | 2.4.0 | Unicode-3.0 |
| icu_normalizer | 2.4.0 | Unicode-3.0 |
| icu_normalizer_data | 2.4.0 | Unicode-3.0 |
| icu_properties | 2.4.0 | Unicode-3.0 |
| icu_properties_data | 2.4.0 | Unicode-3.0 |
| icu_provider | 2.4.0 | Unicode-3.0 |
| ident_case | 1.0.1 | MIT/Apache-2.0 |
| idna | 1.1.0 | MIT OR Apache-2.0 |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT |
| indexmap | 2.14.2 | Apache-2.0 OR MIT |
| ipnet | 2.12.2 | MIT OR Apache-2.0 |
| is-macro | 0.3.8 | Apache-2.0 |
| is_terminal_polyfill | 1.70.2 | MIT OR Apache-2.0 |
| itertools | 0.13.0 | MIT OR Apache-2.0 |
| itertools | 0.14.0 | MIT OR Apache-2.0 |
| itertools | 0.15.0 | MIT OR Apache-2.0 |
| itoa | 1.0.19 | MIT OR Apache-2.0 |
| jni-sys | 0.3.1 | MIT OR Apache-2.0 |
| jni-sys | 0.4.1 | MIT OR Apache-2.0 |
| jni-sys-macros | 0.4.1 | MIT OR Apache-2.0 |
| jobserver | 0.1.35 | MIT OR Apache-2.0 |
| js-sys | 0.3.107 | MIT OR Apache-2.0 |
| khronos-egl | 6.0.0 | MIT/Apache-2.0 |
| khronos_api | 3.1.0 | Apache-2.0 |
| levenshtein_automata | 0.2.1 | MIT |
| libc | 0.2.191 | MIT OR Apache-2.0 |
| libloading | 0.8.9 | ISC |
| liblzma | 0.4.9 | MIT OR Apache-2.0 |
| liblzma-sys | 0.4.9 | MIT OR Apache-2.0 |
| libm | 0.2.16 | MIT |
| libredox | 0.1.25 | MIT |
| linux-raw-sys | 0.12.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| litemap | 0.8.3 | Unicode-3.0 |
| litrs | 1.0.1 | MIT OR Apache-2.0 |
| lock_api | 0.4.14 | MIT OR Apache-2.0 |
| log | 0.4.35 | MIT OR Apache-2.0 |
| louds-rs | 0.7.0 | MIT OR Apache-2.0 |
| lru | 0.18.5 | MIT |
| lru-slab | 0.1.3 | MIT OR Apache-2.0 OR Zlib |
| macerator | 0.2.10 | MIT OR Apache-2.0 |
| macerator-macros | 0.1.5 | MIT OR Apache-2.0 |
| malloc_buf | 0.0.6 | MIT |
| maplit | 1.0.2 | MIT/Apache-2.0 |
| markup5ever | 0.40.0 | MIT OR Apache-2.0 |
| matrixmultiply | 0.3.11 | MIT/Apache-2.0 |
| md5 | 0.8.1 | Apache-2.0 OR MIT |
| memchr | 2.8.3 | Unlicense OR MIT |
| memmap2 | 0.9.12 | MIT OR Apache-2.0 |
| metal | 0.32.0 | MIT OR Apache-2.0 |
| minimal-lexical | 0.2.1 | MIT/Apache-2.0 |
| miniz_oxide | 0.9.1 | MIT OR Zlib OR Apache-2.0 |
| mio | 1.2.4 | MIT |
| moddef | 0.3.0 | MIT |
| naga | 26.0.0 | MIT OR Apache-2.0 |
| nb | 0.1.3 | MIT OR Apache-2.0 |
| nb | 1.1.0 | MIT OR Apache-2.0 |
| ndarray | 0.16.1 | MIT OR Apache-2.0 |
| ndk-sys | 0.6.0+11769913 | MIT OR Apache-2.0 |
| new_debug_unreachable | 1.0.6 | MIT |
| nom | 7.1.3 | MIT |
| ntapi | 0.4.3 | Apache-2.0 OR MIT |
| num | 0.4.3 | MIT OR Apache-2.0 |
| num-bigint | 0.4.8 | MIT OR Apache-2.0 |
| num-complex | 0.4.6 | MIT OR Apache-2.0 |
| num-integer | 0.1.47 | MIT OR Apache-2.0 |
| num-iter | 0.1.46 | MIT OR Apache-2.0 |
| num-rational | 0.4.2 | MIT OR Apache-2.0 |
| num-traits | 0.2.19 | MIT OR Apache-2.0 |
| num_cpus | 1.17.0 | MIT OR Apache-2.0 |
| objc | 0.2.7 | MIT |
| objc2-core-foundation | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| objc2-io-kit | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| once_cell | 1.21.4 | MIT OR Apache-2.0 |
| once_cell_polyfill | 1.70.2 | MIT OR Apache-2.0 |
| option-ext | 0.2.0 | MPL-2.0 |
| ordered-float | 4.6.0 | MIT |
| ordered-float | 5.5.1 | MIT |
| parking | 2.2.1 | Apache-2.0 OR MIT |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 |
| paste | 1.0.15 | MIT OR Apache-2.0 |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 |
| petgraph | 0.6.5 | MIT OR Apache-2.0 |
| phf | 0.14.0 | MIT |
| phf_codegen | 0.14.0 | MIT |
| phf_generator | 0.14.0 | MIT |
| phf_shared | 0.14.0 | MIT |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT |
| pkg-config | 0.3.34 | MIT OR Apache-2.0 |
| portable-atomic | 1.15.0 | Apache-2.0 OR MIT |
| portable-atomic-util | 0.2.8 | Apache-2.0 OR MIT |
| potential_utf | 0.1.6 | Unicode-3.0 |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 |
| precomputed-hash | 0.1.1 | MIT |
| presser | 0.3.1 | MIT OR Apache-2.0 |
| pretty_assertions | 1.4.1 | MIT OR Apache-2.0 |
| prettyplease | 0.2.37 | MIT OR Apache-2.0 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| profiling | 1.0.18 | MIT OR Apache-2.0 |
| pulldown-cmark | 0.13.6 | MIT |
| pulldown-cmark-escape | 0.11.0 | MIT |
| pulp | 0.22.3 | MIT |
| pulp-wasm-simd-flag | 0.1.1 | MIT |
| quinn | 0.11.12 | MIT OR Apache-2.0 |
| quinn-proto | 0.11.19 | MIT OR Apache-2.0 |
| quinn-udp | 0.5.16 | MIT OR Apache-2.0 |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| r-efi | 5.3.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later |
| r-efi | 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later |
| rand | 0.10.3 | MIT OR Apache-2.0 |
| rand | 0.8.8 | MIT OR Apache-2.0 |
| rand | 0.9.5 | MIT OR Apache-2.0 |
| rand_chacha | 0.9.0 | MIT OR Apache-2.0 |
| rand_core | 0.10.1 | MIT OR Apache-2.0 |
| rand_core | 0.6.4 | MIT OR Apache-2.0 |
| rand_core | 0.9.5 | MIT OR Apache-2.0 |
| rand_distr | 0.5.1 | MIT OR Apache-2.0 |
| rand_pcg | 0.10.2 | MIT OR Apache-2.0 |
| range-alloc | 0.1.5 | MIT OR Apache-2.0 |
| raw-cpuid | 11.6.0 | MIT |
| raw-window-handle | 0.6.2 | MIT OR Apache-2.0 OR Zlib |
| rawpointer | 0.2.1 | MIT/Apache-2.0 |
| rayon | 1.12.0 | MIT OR Apache-2.0 |
| rayon-core | 1.13.0 | MIT OR Apache-2.0 |
| reborrow | 0.5.5 | MIT |
| redox_syscall | 0.5.18 | MIT |
| redox_users | 0.5.3 | MIT |
| regex | 1.13.1 | MIT OR Apache-2.0 |
| regex-automata | 0.4.18 | MIT OR Apache-2.0 |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 |
| renderdoc-sys | 1.1.0 | MIT OR Apache-2.0 |
| reqwest | 0.12.28 | MIT OR Apache-2.0 |
| ring | 0.17.14 | Apache-2.0 AND ISC |
| rmp | 0.8.15 | MIT |
| rmp-serde | 1.3.1 | MIT |
| rs-conllu | 0.3.0 | MIT OR Apache-2.0 |
| rustc-hash | 1.1.0 | Apache-2.0/MIT |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT |
| rustc_version | 0.4.1 | MIT OR Apache-2.0 |
| rustix | 1.1.6 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| rustls | 0.23.46 | Apache-2.0 OR ISC OR MIT |
| rustls-pki-types | 1.16.0 | MIT OR Apache-2.0 |
| rustls-webpki | 0.103.16 | ISC |
| rustversion | 1.0.23 | MIT OR Apache-2.0 |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 |
| safetensors | 0.6.2 | Apache-2.0 |
| safetensors | 0.7.0 | Apache-2.0 |
| same-file | 1.0.6 | Unlicense/MIT |
| sanitize-filename | 0.6.0 | MIT |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 |
| semver | 1.0.28 | MIT OR Apache-2.0 |
| seq-macro | 0.3.6 | MIT OR Apache-2.0 |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde_bytes | 0.11.19 | MIT OR Apache-2.0 |
| serde_core | 1.0.229 | MIT OR Apache-2.0 |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |
| serde_spanned | 1.1.3 | MIT OR Apache-2.0 |
| serde_urlencoded | 0.7.1 | MIT/Apache-2.0 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 |
| shlex | 1.3.0 | MIT OR Apache-2.0 |
| shlex | 2.0.1 | MIT OR Apache-2.0 |
| simd-adler32 | 0.3.10 | MIT |
| siphasher | 1.0.4 | MIT OR Apache-2.0 |
| slab | 0.4.12 | MIT |
| slotmap | 1.1.1 | Zlib |
| slug | 0.1.6 | MIT/Apache-2.0 |
| smallvec | 1.16.5 | MIT OR Apache-2.0 |
| socket2 | 0.6.5 | MIT OR Apache-2.0 |
| spin | 0.10.1 | MIT |
| spirv | 0.3.0+sdk-1.3.268.0 | Apache-2.0 |
| stable-vec | 0.4.3 | MIT/Apache-2.0 |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 |
| static_assertions | 1.1.0 | MIT OR Apache-2.0 |
| string_cache | 0.11.0 | MIT OR Apache-2.0 |
| string_cache_codegen | 0.11.2 | MIT OR Apache-2.0 |
| strsim | 0.11.1 | MIT |
| strum | 0.28.0 | MIT |
| strum_macros | 0.28.0 | MIT |
| subtle | 2.6.1 | BSD-3-Clause |
| syn | 2.0.119 | MIT OR Apache-2.0 |
| syn | 3.0.10 | MIT OR Apache-2.0 |
| sync_wrapper | 1.0.2 | Apache-2.0 |
| synstructure | 0.14.0 | MIT |
| sysctl | 0.6.0 | MIT |
| sysinfo | 0.36.1 | MIT |
| tar | 0.4.46 | MIT OR Apache-2.0 |
| tendril | 0.5.1 | MIT OR Apache-2.0 |
| termcolor | 1.4.1 | Unlicense OR MIT |
| text_placeholder | 0.5.1 | MIT |
| thiserror | 1.0.69 | MIT OR Apache-2.0 |
| thiserror | 2.0.21 | MIT OR Apache-2.0 |
| thiserror-impl | 1.0.69 | MIT OR Apache-2.0 |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 |
| tiny-keccak | 2.0.2 | CC0-1.0 |
| tinystr | 0.8.5 | Unicode-3.0 |
| tinyvec | 1.13.3 | Zlib OR Apache-2.0 OR MIT |
| tokio | 1.54.1 | MIT |
| tokio-rustls | 0.26.6 | MIT OR Apache-2.0 |
| tokio-util | 0.7.20 | MIT |
| toml | 0.9.12+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_datetime | 0.7.5+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_parser | 1.1.5+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_writer | 1.2.0+spec-1.1.0 | MIT OR Apache-2.0 |
| tower | 0.5.3 | MIT |
| tower-http | 0.6.11 | MIT |
| tower-layer | 0.3.3 | MIT |
| tower-service | 0.3.3 | MIT |
| tracel-llvm | 20.1.4-7 | MIT OR Apache-2.0 |
| tracel-llvm-bundler | 20.1.4-7 | MIT OR Apache-2.0 |
| tracel-mlir-rs | 20.1.4-7 | Apache-2.0 |
| tracel-mlir-rs-macros | 20.1.4-7 | Apache-2.0 |
| tracel-mlir-sys | 20.1.4-7 | MIT |
| tracel-tblgen-rs | 20.1.4-7 | MIT OR Apache-2.0 |
| tracing | 0.1.44 | MIT |
| tracing-core | 0.1.36 | MIT |
| trie-rs | 0.4.2 | MIT OR Apache-2.0 |
| try-lock | 0.2.5 | MIT |
| type-map | 0.5.1 | MIT/Apache-2.0 |
| typed-arena | 2.0.2 | MIT |
| typed-path | 0.12.4 | MIT OR Apache-2.0 |
| typenum | 1.20.1 | MIT OR Apache-2.0 |
| unicase | 2.10.0 | MIT OR Apache-2.0 |
| unicode-blocks | 0.1.11 | MIT |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| unicode-normalization | 0.1.26 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| unicode-script | 0.5.9 | MIT OR Apache-2.0 |
| unicode-segmentation | 1.13.3 | MIT OR Apache-2.0 |
| unicode-width | 0.2.3 | MIT OR Apache-2.0 |
| unicode-xid | 0.2.6 | MIT OR Apache-2.0 |
| unicode_categories | 0.1.1 | MIT OR Apache-2.0 |
| unindent | 0.2.4 | MIT OR Apache-2.0 |
| untrusted | 0.9.0 | ISC |
| unty | 0.0.4 | MIT OR Apache-2.0 |
| url | 2.5.8 | MIT OR Apache-2.0 |
| utf8_iter | 1.1.0 | Apache-2.0 OR MIT |
| utf8parse | 0.2.2 | Apache-2.0 OR MIT |
| utf_types | 1.0.0 | Apache-2.0 OR MIT |
| uuid | 1.29.2 | Apache-2.0 OR MIT |
| variadics_please | 1.1.0 | MIT OR Apache-2.0 |
| version_check | 0.9.5 | MIT/Apache-2.0 |
| void | 1.0.2 | MIT |
| walkdir | 2.5.0 | Unlicense/MIT |
| want | 0.3.2 | MIT |
| wasi | 0.11.1+wasi-snapshot-preview1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| wasip2 | 1.0.4+wasi-0.2.12 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| wasm-bindgen | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-futures | 0.4.80 | MIT OR Apache-2.0 |
| wasm-bindgen-macro | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-macro-support | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-shared | 0.2.130 | MIT OR Apache-2.0 |
| web-sys | 0.3.107 | MIT OR Apache-2.0 |
| web-time | 1.1.0 | MIT OR Apache-2.0 |
| web_atoms | 0.3.0 | MIT OR Apache-2.0 |
| webpki-roots | 1.0.12 | CDLA-Permissive-2.0 |
| wgpu | 26.0.1 | MIT OR Apache-2.0 |
| wgpu-core | 26.0.1 | MIT OR Apache-2.0 |
| wgpu-core-deps-apple | 26.0.0 | MIT OR Apache-2.0 |
| wgpu-core-deps-emscripten | 26.0.0 | MIT OR Apache-2.0 |
| wgpu-core-deps-windows-linux-android | 26.0.0 | MIT OR Apache-2.0 |
| wgpu-hal | 26.0.6 | MIT OR Apache-2.0 |
| wgpu-types | 26.0.0 | MIT OR Apache-2.0 |
| winapi | 0.3.9 | MIT/Apache-2.0 |
| winapi-i686-pc-windows-gnu | 0.4.0 | MIT/Apache-2.0 |
| winapi-util | 0.1.11 | Unlicense OR MIT |
| winapi-x86_64-pc-windows-gnu | 0.4.0 | MIT/Apache-2.0 |
| windows | 0.58.0 | MIT OR Apache-2.0 |
| windows | 0.61.3 | MIT OR Apache-2.0 |
| windows-collections | 0.2.0 | MIT OR Apache-2.0 |
| windows-core | 0.58.0 | MIT OR Apache-2.0 |
| windows-core | 0.61.2 | MIT OR Apache-2.0 |
| windows-future | 0.2.1 | MIT OR Apache-2.0 |
| windows-implement | 0.58.0 | MIT OR Apache-2.0 |
| windows-implement | 0.60.2 | MIT OR Apache-2.0 |
| windows-interface | 0.58.0 | MIT OR Apache-2.0 |
| windows-interface | 0.59.3 | MIT OR Apache-2.0 |
| windows-link | 0.1.3 | MIT OR Apache-2.0 |
| windows-link | 0.2.1 | MIT OR Apache-2.0 |
| windows-numerics | 0.2.0 | MIT OR Apache-2.0 |
| windows-result | 0.2.0 | MIT OR Apache-2.0 |
| windows-result | 0.3.4 | MIT OR Apache-2.0 |
| windows-strings | 0.1.0 | MIT OR Apache-2.0 |
| windows-strings | 0.4.2 | MIT OR Apache-2.0 |
| windows-sys | 0.52.0 | MIT OR Apache-2.0 |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 |
| windows-targets | 0.52.6 | MIT OR Apache-2.0 |
| windows-threading | 0.1.0 | MIT OR Apache-2.0 |
| windows_aarch64_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_aarch64_msvc | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_gnu | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_msvc | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_gnu | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_msvc | 0.52.6 | MIT OR Apache-2.0 |
| winnow | 0.7.15 | MIT |
| winnow | 1.0.5 | MIT |
| wit-bindgen | 0.57.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| writeable | 0.6.4 | Unicode-3.0 |
| xattr | 1.7.0 | MIT OR Apache-2.0 |
| xml-rs | 0.8.29 | MIT |
| yansi | 1.0.1 | MIT OR Apache-2.0 |
| yoke | 0.8.4 | Unicode-3.0 |
| yoke-derive | 0.8.4 | Unicode-3.0 |
| zerocopy | 0.8.63 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zerocopy-derive | 0.8.63 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zerofrom | 0.1.8 | Unicode-3.0 |
| zerofrom-derive | 0.1.8 | Unicode-3.0 |
| zeroize | 1.9.1 | Apache-2.0 OR MIT |
| zerotrie | 0.2.5 | Unicode-3.0 |
| zerovec | 0.11.9 | Unicode-3.0 |
| zerovec-derive | 0.11.7 | Unicode-3.0 |
| zip | 7.4.0 | MIT |
| zip | 8.6.0 | MIT |
| zlib-rs | 0.6.8 | Zlib |
| zmij | 1.0.23 | MIT |
| zopfli | 0.8.4 | Apache-2.0 |

## Licence texts

### MIT

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Apache License 2.0

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

```
