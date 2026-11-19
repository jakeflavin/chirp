# tidyshot

[![Build](https://img.shields.io/badge/build-passing-green)](https://example.com/ci) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

tidyshot is a small command-line tool that renames, sorts and compresses your screenshots. It watches a folder (your Desktop by default), gives each new screenshot a readable name based on the app it was taken in, moves it into a dated folder, and converts it to WebP to save space. It runs on macOS 14 or later and Linux.

## Why

Screenshots pile up. A typical Mac Desktop collects hundreds of files called "Screenshot 2026-11-03 at 14.22.17.png", each one 2 to 5 MB. tidyshot was written to fix that without changing how you take screenshots. In our own use it cut a 9 GB screenshots folder to 2.1 GB.

## Install

With Homebrew:

```sh
brew install tidyshot
```

Or with Cargo, if you have Rust 1.80 or later:

```sh
cargo install tidyshot
```

Prebuilt binaries for Apple silicon, Intel and Linux x86_64 are on the releases page.

## Usage

Start watching your Desktop:

```sh
tidyshot watch
```

Run it once over an existing folder and exit:

```sh
tidyshot sort ~/Desktop --dry-run
```

`--dry-run` prints what would change without touching any files. Remove it to apply the changes.

To start tidyshot when you log in on macOS:

```sh
tidyshot service install
```

## How names are chosen

On macOS, tidyshot reads the name of the app that was in front when the screenshot was taken, from the file's metadata. The new name is the app, the window title if there is one, and the time: `Safari - Release notes - 14.22.png`. On Linux the window title is not available, so names use the app only.

If the name already exists, a number is added. Names are limited to 80 characters.

## Configuration

tidyshot reads `~/.config/tidyshot/config.toml`. Every setting is optional.

```toml
watch = "~/Desktop"
destination = "~/Pictures/Screenshots"
format = "webp"        # webp, png or keep
quality = 85           # 1-100, for webp
folders = "monthly"    # daily, monthly or none
keep_original = false
```

Setting `format = "keep"` turns off conversion entirely. With `keep_original = true`, the original PNG is moved to a folder called `originals` next to the converted file.

## Privacy

tidyshot does not read the contents of your screenshots and never connects to the internet. It does not send usage data. The only information it reads is the file metadata described above.

## Known issues

- Screenshots taken with third-party tools such as CleanShot do not include the app name, so they are named by time only.
- Converting very large screenshots (over 8000 pixels wide) can take a few seconds each.
- On Linux, `tidyshot service install` only supports systemd.

## FAQ

**Will it touch other images on my Desktop?** No. It only acts on files that macOS or GNOME marks as screenshots.

**Can I undo a sort?** Each run writes a log to `~/.local/state/tidyshot/`. Run `tidyshot undo` to reverse the most recent run.

**Does WebP lose quality?** At the default quality of 85 the difference is very hard to see for text and interfaces. Set `format = "png"` if you need exact pixels.

## Contributing

Bug reports and pull requests are welcome. Please run `cargo fmt` and `cargo test` before opening a pull request. See CONTRIBUTING.md for details.

## License

MIT. See LICENSE.
