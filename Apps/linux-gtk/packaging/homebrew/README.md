# Homebrew and the Linux app

Short answer: **yes, `middle-management/homebrew-tap` can carry the Linux app —
but as a _formula_, not a cask, and it isn't the channel most Linux users
should be pointed at.**

## Why it can't be a cask

The macOS app ships as a cask (`brew install middle-management/tap/tailscreen`).
**Casks are macOS-only** — `brew install --cask` refuses to run on Linux. So the
Linux app can't reuse that mechanism; a tap serving both platforms needs a cask
for macOS *and* a separate formula for Linux, gated on `OS.linux?`.

That's fine — one tap can hold both — but they are two recipes, not one with a
platform branch.

## Why it probably shouldn't be the main channel

Homebrew is a good fit for CLI tools and a poor one for GTK desktop apps:

- A formula that **builds from source** needs a Swift 6 toolchain, Go, and GTK4
  inside Homebrew's prefix. Homebrew's `gtk4` is a *different* GTK than the
  distro's, and mixing them is where GTK apps go wrong — icon themes, GSettings
  schema compilation, GDK backend selection, and portal integration all assume
  the system GTK.
- A formula that **installs a prebuilt binary** avoids the toolchain, but then
  Homebrew is just a downloader with a version pin, which is what the AppImage
  already is — self-contained, no package manager needed.
- Neither path installs a `.desktop` entry into the user's application menu the
  way a Flatpak or a distro package does, so the app won't appear in their
  launcher.

**Recommended order for Linux:** AppImage (shipped by the release workflow
today) → Flatpak (manifest already in `../flatpak`, needs a Swift SDK
extension) → distro packages. Homebrew as a convenience for people who already
live in `brew`, not as the headline instruction.

## If you want it anyway

`tailscreen.rb` in this directory is a ready formula for the least-bad shape: it
downloads the release AppImage, installs it, and links it onto `PATH`. Copy it
into the tap as `Formula/tailscreen-linux.rb` (a distinct name from the cask, so
`brew install …/tap/tailscreen` keeps meaning the macOS app).

**It has not been tested** — this container has no Homebrew installation, so
treat it as a starting point that is structurally right rather than a verified
recipe.

### Bumping the version

The release workflow (`.github/workflows/release-linux.yml`) prints the artifact
name and its **SHA-256** in the run summary, which is exactly the two fields the
formula needs:

```ruby
url "https://github.com/middle-management/tailscreen/releases/download/v1.2.3/Tailscreen-1.2.3-x86_64.AppImage"
sha256 "…"
```

So a version bump is: read the two values off the release run, edit them into
the formula, push to the tap. Automating that (a `repository_dispatch` from
this repo into the tap) is a reasonable follow-up once the artifact has shipped
at least once.

### The FUSE caveat

AppImages need FUSE to self-mount. Most desktop distros have it; minimal
containers often don't. Users hitting `dlopen(): error loading libfuse.so.2`
can either install `libfuse2` or run with `APPIMAGE_EXTRACT_AND_RUN=1`. Worth a
`caveats` line, which the formula includes.
