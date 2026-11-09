# Reading

A tiny Apple Books–style PDF reader. Drop in a PDF, read it as dark two-page spreads,
and it remembers where you left off. Works offline once installed.

Two versions live here:

- **Web app** (this folder): a PWA you can add to any iPad's Home Screen.
  Live at https://aleksanderstevens191-sudo.github.io/reading/
- **Native iPad app** ([`ios/`](ios/)): page-curl turns, pinch zoom, manga (right-to-left) mode,
  and an on-device AI (Gemma 4 E2B via llama.cpp) that explains the page you're on, with no internet.
  See [`ios/README.md`](ios/README.md) to build it.

- **Add a book:** drag a PDF onto the page, or tap **Add PDF**.
- **Turn pages:** arrow keys / space, click or tap the left/right side, swipe, or two-finger swipe on a trackpad.
- **Toolbar:** move the mouse or tap the middle of the page → Library, Contents, dark/light pages, page slider.
- Progress saves automatically, per device.

## Run locally
    python3 -m http.server 5173

Then open http://localhost:5173.

## On iPad
Host this folder anywhere with HTTPS (GitHub Pages, Vercel, Netlify), open it in Safari,
Share → **Add to Home Screen**, then add your PDF from the Files app. Books are stored on
the iPad itself, so they open with no internet.

When you change the app, bump `CACHE` in `sw.js` so installed copies pick up the update.

## License
MIT, see [LICENSE](LICENSE). Bundled third-party code keeps its own license:
[pdf.js](https://github.com/mozilla/pdf.js) (Apache 2.0) in `vendor/`, with its font and CMap licenses alongside.
The iPad app uses [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and the
[Gemma](https://ai.google.dev/gemma/terms) model, which you download separately under Google's terms.
