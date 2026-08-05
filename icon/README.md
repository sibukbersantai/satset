# Satset icon

Generated, not hand-drawn — re-render any time with:

```bash
swiftc -O make-icon.swift -o make-icon && ./make-icon ./out
```

`make-icon.swift` draws everything with CoreGraphics:

- **App icon** — white lightning bolt on a violet→magenta gradient, inside a true
  superellipse (`n=5`) rather than a plain rounded rect, on Apple's macOS icon grid
  (824/1024 body, centred, soft contact shadow).
- **Menu bar icon** — the same bolt as a black template image; macOS recolours it for
  light and dark menu bars.

Sizes emitted: `app-{16,32,64,128,256,512,1024}.png`, `menubar-{1x,2x}.png`.

To install into the asset catalog, copy them over `Satset/Assets.xcassets/AppIcon.appiconset/`
following that catalog's `Contents.json` filename mapping (note the `"32 1.png"` /
`"256 1.png"` / `"512 1.png"` entries, which are the @1x duplicates).
