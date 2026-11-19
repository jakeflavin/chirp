# Site

The website at https://jakeflavin.github.io/chirp/. The `Site` workflow publishes this folder to GitHub Pages and writes `appcast.xml` (the update feed) into it at deploy time. Don't add `appcast.xml` here.

## Files

| File | What it is |
|---|---|
| `index.html` | The page. Plain HTML, no build step. Edit it directly. |
| `assets/site.css` | All the styles. Light by default; dark follows the Mac's appearance. Phone layouts use a container query at 720 px. |
| `assets/site.js` | Plays each scene only while it is on screen and lands the bird on each section's wire. The page still works without it. |
| `assets/bird.svg`, `favicon.svg`, `favicon-32.png`, `apple-touch-icon.png`, `icon.png` | The bird and the app icon. |
| `assets/og.png` | Link preview, 1200 × 630. The page's `og:image` and `twitter:image`. |
| `assets/social-preview.png` | GitHub social preview, 1280 × 640. Upload it in the repository settings. |
| `assets/readme-banner.png` | The README banner, 1440 × 480 at 2×. |
| `assets/feature-*.png` | One image per feature, 1200 × 630 at 2×, for the README and for sharing. |
| `source/` | The pages the PNGs are made from, and the script that renders them. Not linked from the site. |
| `.nojekyll` | Tells Pages to serve the folder as it is. |

## Rules

- Asset URLs are relative, because the site lives under `/chirp/`. Only the `og:image`, `twitter:image` and canonical URLs are absolute.
- Colours come from [Docs/DESIGN.md](../Docs/DESIGN.md): Paper, Ink, Quiet, Clay for what you click, Amber for the bird. Icons are Chirp's own set, inlined as SVG.
- Motion respects Reduce Motion: every scene shows its finished frame and nothing loops.
- No analytics, no web fonts, no third-party scripts. The page loads only its own files.
- Mockups use made-up names and content.

## Making the images

Edit the matching page in `source/` (each one links `../assets/site.css`), then from the repository root run:

```bash
swift Site/source/render.swift
```

It renders every page in `source/` with the Mac's own WebKit and writes the PNGs into `assets/`. Look at each image before you commit it.

## Checking a change

Serve the folder and open it in a browser:

```bash
python3 -m http.server --directory Site 8000
```

Check it at desktop and phone width, in light and dark, and with Reduce Motion on.
