# =============================================================================
# SAMPLE / TEMPLATE FORMULA — NOT A WORKING OR OFFICIAL HOMEBREW FORMULA.
#
# This file exists ONLY to show the intended shape of a future Homebrew formula
# for SpecRelay (spec 0008, section 7). It is NOT published, NOT tapped, and NOT
# validated against a real release tarball:
#
#   * `url` points at a release tag/tarball that DOES NOT EXIST YET.
#   * `sha256` is a PLACEHOLDER, not the checksum of any real archive.
#   * No `SpecRelay/tap` repository exists, so `brew install specrelay` will
#     NOT work.
#
# Do not treat this as installable. See docs/homebrew.md for the phased plan,
# how to compute a real sha256, and how to test a formula locally once a real
# tag + release archive exist. Until then, install from source with
# install/install.sh (see docs/installation.md).
# =============================================================================
class Specrelay < Formula
  desc "From spec to reviewed change: an executor -> reviewer -> human workflow CLI"
  homepage "https://github.com/SpecRelay/SpecRelay"

  # PLACEHOLDER: no such tag/tarball is published yet. Replace vX.Y.Z with the
  # first real published tag before this formula could ever work.
  url "https://github.com/SpecRelay/SpecRelay/archive/refs/tags/vX.Y.Z.tar.gz"
  version "X.Y.Z"
  # PLACEHOLDER: replace with `shasum -a 256` of the REAL tarball above.
  # This is intentionally not a valid checksum for any real archive.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  license "TBD" # SpecRelay's license is still pending a human decision (LICENSE.TODO).

  # SpecRelay is a Bash CLI; git is required at runtime, and ruby/python3 are
  # needed to run workflows (config parsing and task state). On macOS ruby and
  # python3 are commonly already present; a real formula would declare whatever
  # runtime dependencies the final release requires.
  depends_on "git"

  def install
    # SpecRelay's own installer performs a copy-based, relocatable install into
    # a prefix (<prefix>/bin + <prefix>/share/specrelay). Under Homebrew the
    # natural mapping is to install the resources into libexec and link the
    # executable onto Homebrew's bin. A real formula would either call
    # install/install.sh with --prefix, or lay out the files directly, e.g.:
    #
    #   system "./install/install.sh", "--prefix", libexec
    #   bin.install_symlink libexec/"bin/specrelay"
    #
    # Left illustrative here because there is no real archive to install from.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/specrelay"
  end

  test do
    # A real formula would assert the reported version matches the tag.
    assert_match "specrelay", shell_output("#{bin}/specrelay version")
  end
end
