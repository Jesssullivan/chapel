# Chapel Version Definitions
#
# Contains metadata for each supported Chapel release including:
# - Version number
# - Source hash (for fetchFromGitHub)
# - LLVM support range
# - Bundled LLVM version
#
{ lib, llvmMatrix }:

rec {
  # Latest Chapel version (default)
  latest = "2.7.0";

  # Previous supported version
  previous = "2.6.0";

  # All supported versions (latest first)
  supported = [ "2.7.0" "2.6.0" ];

  # Version metadata
  versions = {
    # Development version (tracks upstream main)
    "2.8.0-dev" = {
      version = "2.8.0-dev";
      rev = "main";
      sha256 = lib.fakeSha256;
      llvmSupport = [ 18 19 20 21 ];
      bundledLlvm = "19.1.3";
      releaseDate = "development";
      cmakeMinVersion = "3.20";
      gccMinVersion = "7.4";
    };

    "2.7.0" = {
      version = "2.7.0";
      rev = "2.7.0";
      # Note: sha256 needs to be updated when fetching from upstream
      # For local builds from source, this is not used
      sha256 = lib.fakeSha256;
      llvmSupport = [ 14 15 16 17 18 19 20 21 ];
      bundledLlvm = "19.1.3";
      releaseDate = "2025-12-18";
      cmakeMinVersion = "3.20";
      gccMinVersion = "7.4";
    };

    "2.6.0" = {
      version = "2.6.0";
      rev = "2.6.0";
      sha256 = lib.fakeSha256;
      llvmSupport = [ 14 15 16 17 18 19 20 ];
      bundledLlvm = "19.1.3";
      releaseDate = "2025-09-18";
      cmakeMinVersion = "3.20";
      gccMinVersion = "7.4";
    };

    "2.5.0" = {
      version = "2.5.0";
      rev = "2.5.0";
      sha256 = lib.fakeSha256;
      llvmSupport = [ 11 12 13 14 15 16 17 18 19 20 ];
      bundledLlvm = "19.1.3";
      releaseDate = "2025-06-12";
      cmakeMinVersion = "3.20";
      gccMinVersion = "7.4";
    };
  };

  # Helper: Get version info with defaults
  getVersionInfo = version:
    versions.${version} or (throw "Unknown Chapel version: ${version}");

  # Helper: Check if a version is supported
  isSupported = version:
    builtins.hasAttr version versions;

  # Helper: Get the major.minor version string
  majorMinor = version:
    lib.versions.majorMinor version;

  # Helper: Compare versions
  versionAtLeast = v1: v2:
    builtins.compareVersions v1 v2 >= 0;

  # Helper: Get LLVM support for a version
  getLlvmSupport = version:
    (getVersionInfo version).llvmSupport;

  # Helper: Get release notes URL
  getReleaseNotesUrl = version:
    "https://chapel-lang.org/docs/${version}/usingchapel/CHANGES.html";
}
