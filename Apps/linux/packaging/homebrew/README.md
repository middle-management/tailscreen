# Homebrew and the Linux app

Short answer: **yes — and it's the *same* cask as macOS, not a second recipe.**
It still isn't the channel most Linux users should be pointed at.

## One cask, both platforms

Casks are not macOS-only. The Cask Cookbook is explicit:

> Not every artifact type is supported on every operating system and a cask
> does not need to support both macOS and Linux. The `appimage` stanza is
> Linux-only, macOS integration stanzas such as `app` and `pkg` are macOS-only
> and portable stanzas such as `binary` can be used on either operating system.

So `Casks/tailscreen.rb` in `middle-management/homebrew-tap` carries both
artifacts, branched on `on_macos` / `on_linux`: the notarized `.app` from the
release zip on a Mac, the release AppImage via the `appimage` stanza on Linux
(which links it into Homebrew's AppImage directory). One name, one version, one
command on either OS:

```sh
brew install --cask middle-management/tap/tailscreen
```

The macOS version floor lives *inside* the `on_macos` block — a top-level
`depends_on macos:` would make the whole cask macOS-only, which is exactly the
mistake this shape avoids.

The version is shared deliberately: both artifacts come from the same release
tag, and the tap's `update-shas.sh` reads the first `version` line in the file
and interpolates it into every URL, so a per-OS version would compute the wrong
URL for one platform.

## Why it probably still shouldn't be the main channel

Homebrew is a good fit for CLI tools and a mediocre one for GTK desktop apps:

- Homebrew installs no `.desktop` entry, so the app won't appear in the user's
  application launcher the way a Flatpak or distro package does.
- The AppImage needs FUSE to self-mount. Most desktop distros have it; minimal
  containers often don't. `dlopen(): error loading libfuse.so.2` means install
  `libfuse2` or run with `APPIMAGE_EXTRACT_AND_RUN=1`. The cask says so in its
  `caveats`.
- Through Homebrew the AppImage is what you get anyway — brew is acting as a
  downloader with a version pin, which is what the AppImage already is.

**Recommended order for Linux:** AppImage (shipped by the release workflow
today) → Flatpak (manifest in `../flatpak`, needs a Swift SDK extension) →
distro packages. Homebrew as a convenience for people who already live in
`brew`, not as the headline instruction.

x86_64 only for now — `linuxdeploy` and `appimagetool` are x86_64 binaries, so
the AppImage build is pinned to that arch. An aarch64 artifact would need an
arch conditional inside the cask's `on_linux` block.

## Bumping the version

The release workflow (`.github/workflows/release.yml`) prints the artifact
name and its **SHA-256** in the run summary — exactly the two fields the cask
needs. In practice the tap's own scripts do it:

```sh
./bump-versions.sh Casks/tailscreen.rb   # new tag → version + REPLACE_ME_ placeholders
./update-shas.sh   Casks/tailscreen.rb   # downloads each URL, fills in each hash
```

Two things had to change in the tap for that to work on this cask, both fixed
there:

- `bump-versions.sh` resolved a recipe's upstream repo from its `homepage`,
  which for Tailscreen is `tailscreen.dev`, not a github.com URL. It now honours
  a `# upstream: owner/repo` comment first.
- `update-shas.awk` paired the i-th URL with the i-th *placeholder*, so a
  partially-filled recipe — macOS hash already known, Linux one still a
  placeholder — paired the lone placeholder with the macOS URL and would have
  written the wrong file's hash. It now pairs against every `sha256` line.

Automating the bump end-to-end (a `repository_dispatch` from this repo into the
tap on release) is a reasonable follow-up once the artifact has shipped at least
once.

**Not verified against a real Homebrew installation** — this container has no
`brew`. The cask is syntax-checked (`ruby -c`) and structurally follows the
documented stanzas; the tap's own CI runs `brew test-bot --only-tap-syntax`.
