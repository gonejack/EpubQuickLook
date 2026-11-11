# EPUB Quick Look

A macOS Quick Look extension that lets you **press the space bar to read** an `.epub` file selected in Finder.
File icons display the book cover, too.

- 📖 **Content previews** — Show the cover, title, author, publisher, table of contents, and body in one continuous view
- 🖼 **Cover thumbnails** — Use book covers as file icons in Finder
- 📐 **Compact layout** — Shrink the cover and simplify metadata in narrow areas such as the Finder preview panel to leave more room for the body
- 🌗 **Dark mode support** — Adjust colors for EPUBs originally designed for light backgrounds
- 🔒 **Security** — Block JavaScript execution, external link navigation, and remote image requests
- 📦 **No third-party dependencies** — ZIP extraction and EPUB (OPF/NCX/nav) parsing are implemented directly, with support for EPUB 2 and EPUB 3
- 💤 **Quit on close** — The app quits when its last window closes, and hidden Quick Look previews release their WebView

<br>

## Install from a Release

1. Download `EPUB-Quick-Look.zip` from [Releases](../../releases/latest) and extract it.
2. Move `EPUB Quick Look.app` to your **Applications folder** (or `~/Applications`).
3. Remove the quarantine attribute in Terminal. This step is required because the app has not been notarized by Apple.

   ```bash
   xattr -dr com.apple.quarantine "/Applications/EPUB Quick Look.app"
   ```

4. **Launch the app once** to register the Quick Look extensions with the system.
   (You can quit the app afterward; the extensions will continue to work.)
5. Select an `.epub` file in Finder and press the **space bar**.

The app does not need to keep running for Finder previews or thumbnails to work. Closing the last app window quits it.
Closing a reader window releases its WebView and removes its temporary files. Quick Look also releases its WebView when
the preview disappears; macOS manages the lifetime of extension processes and may cache an idle process afterward.

If previews do not appear immediately:

```bash
qlmanage -r && qlmanage -r cache && killall Finder
```

Check that the extensions are enabled in **System Settings › General › Login Items & Extensions › Quick Look**.

> **If macOS reports that the app “is damaged and can't be opened,”** try the `xattr` command in step 3.
> macOS adds a quarantine attribute to files downloaded through a browser, which can cause this message.

<br>

## Build from Source

Only the Xcode Command Line Tools are required. No separate project file or package manager is needed.

```bash
git clone https://github.com/gonejack/EpubQuickLook.git
cd EpubQuickLook

./build.sh            # Create build/EPUB Quick Look.app
./build.sh install    # Build, install to ~/Applications, and refresh the Quick Look cache
./build.sh uninstall  # Uninstall
```

The build produces arm64 + x86_64 universal binaries with ad-hoc signatures.

<br>

## Project Structure

```
Sources/
  EPUBKit/                    Core shared by all three targets (no third-party dependencies)
    ZipArchive.swift          ZIP reader using the Compression framework (store/deflate, ZIP64)
    EPUBDocument.swift        container.xml → OPF parsing, metadata, spine, cover, and table of contents
    PreviewHTMLBuilder.swift  Combines the spine into a single HTML preview document
  PreviewExtension/           QLPreviewingController — renders with WKWebView
  ThumbnailExtension/         QLThumbnailProvider — cover thumbnails
  App/                        Host app (extension registration + built-in viewer)
Resources/                    Three Info.plist files and two entitlements files
build.sh                      Build, signing, and installation script
```

### How It Works

The preview extension extracts the EPUB into a temporary directory within the sandbox, collects each XHTML document's `<body>`
in spine (reading) order, and combines them into a single HTML document. During this process, it:

- Rewrites relative image and stylesheet paths as absolute paths to the extracted files.
- Rewrites links to other included chapters as anchors within the combined document (`#ql-ch-N`).
- Removes `<script>`, `<iframe>`, and remote resource references.

### Implementation Notes

These notes record issues encountered during implementation for future reference.

- **`WKWebView` in a sandboxed app requires the `com.apple.security.network.client` entitlement.**
  Without it, even local `file://` documents fail to load, and the `didFail` callback is not invoked.
- **Pass a real path with symbolic links resolved to `allowingReadAccessTo:`.**
  `NSTemporaryDirectory()` returns `/var/folders/...`, while Foundation's
  `resolvingSymlinksInPath()` removes the `/private` prefix again, so this project uses `realpath(3)`.
- App extensions use `NSExtensionMain` as their entry point instead of `main`, so linking requires
  `-Xlinker -e -Xlinker _NSExtensionMain`.

<br>

## Limitations

- DRM-protected EPUBs cannot be opened.
- Previews display only the first 100 documents (approximately 3 million characters).
- Fixed-layout EPUBs may not preserve their original layout exactly.

<br>

## License

MIT
