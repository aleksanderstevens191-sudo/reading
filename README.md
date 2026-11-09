# Reading

A tiny Apple Books–style PDF reader. Drop in a PDF, read it as dark two-page spreads,
and it remembers where you left off. Works offline once installed.

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
