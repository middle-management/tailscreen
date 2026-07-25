# Template Homebrew formula for the Linux desktop app.
#
# Copy into middle-management/homebrew-tap as `Formula/tailscreen-linux.rb`.
# The name is deliberately distinct from the macOS cask so
# `brew install middle-management/tap/tailscreen` keeps meaning the .app.
#
# See README.md in this directory for why this is a formula rather than a cask
# (casks are macOS-only) and why the AppImage — not Homebrew — is the channel
# most Linux users should be pointed at.
#
# UNTESTED: written from the release artifact's shape, not verified against a
# real Homebrew installation.
class TailscreenLinux < Formula
  desc "Share and view screens peer-to-peer over Tailscale"
  homepage "https://tailscreen.dev"
  license "MIT"

  # Bump both together — the release-linux workflow prints the file name and its
  # SHA-256 in the run summary for exactly this purpose.
  version "0.0.0"
  url "https://github.com/middle-management/tailscreen/releases/download/v#{version}/Tailscreen-#{version}-x86_64.AppImage"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # Linux only. The macOS build is the cask in this same tap; installing the
  # AppImage on a Mac would produce a binary that cannot run.
  depends_on :linux

  def install
    # The download has no extension Homebrew recognises, so it arrives as the
    # cached file name; rename it and mark it executable.
    appimage = "Tailscreen-#{version}-x86_64.AppImage"
    mv cached_download, appimage
    chmod 0755, appimage
    libexec.install appimage
    bin.write_exec_script libexec/appimage
    # `brew` links the script under the AppImage's own name; give it the plain
    # command users expect as well.
    bin.install_symlink libexec/appimage => "tailscreen"
  end

  def caveats
    <<~EOS
      Tailscreen ships as an AppImage, which needs FUSE to self-mount. If it
      fails with a libfuse error, either install your distro's `fuse`/`libfuse2`
      package or run it as:

        APPIMAGE_EXTRACT_AND_RUN=1 tailscreen

      Sharing your screen requires X11. Wayland sessions can view but not yet
      share (that needs the ScreenCast portal backend).

      Homebrew does not register a desktop entry, so Tailscreen will not appear
      in your application launcher. For that, prefer the AppImage with an
      integration tool, or the Flatpak once published.
    EOS
  end

  test do
    # The app needs a display and a tailnet, so there's nothing meaningful to
    # run headlessly; assert the artifact is present and executable.
    assert_predicate libexec/"Tailscreen-#{version}-x86_64.AppImage", :executable?
  end
end
