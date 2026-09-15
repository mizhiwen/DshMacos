# Architecture

`DshMacos` is an original, macOS-only desktop host for DeepSeek Harness. It does not fork or modify the Harness frontend.

## Boundaries

```text
SwiftUI window
├── Native wallpaper layer
├── Native runtime/settings toolbar
└── Transparent WKWebView
        │ loopback HTTP only
        ▼
HarnessRuntimeController
└── dsh web --no-open --port <ephemeral>
```

- The managed process is spawned with `Process`; arguments never pass through a shell.
- The app assigns the child to its own process group and terminates only that group.
- `DSH_HOME` is isolated under the app's Application Support directory.
- An unconfigured workspace falls back to an app-owned directory instead of `$HOME`.
- The embedded web view accepts navigation only within its initial loopback origin. External HTTP links open in the default browser.
- No JavaScript bridge exposes native command execution to Harness content.
- Wallpaper bytes remain in the native layer. A small CSS adapter only makes supported Harness background tokens transparent.

## Release runtime

The current MVP resolves a user-installed `dsh` without invoking a login shell. In addition to normal executable directories, it recognizes existing npm `_npx` executable caches, so a previously downloaded Harness does not require another registry lookup. The runtime boundary intentionally leaves room for a later `BundledRuntimeProvider`, which will ship pinned Node and Harness artifacts after license and integrity manifests are added.
