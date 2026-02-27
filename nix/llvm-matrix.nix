# Chapel LLVM Compatibility Matrix
#
# Defines which LLVM versions are supported by each Chapel release.
# This allows the build system to validate configurations and generate
# the appropriate package variants.
#
{ lib }:

rec {
  # Default LLVM support range (used when version-specific info not available)
  defaultSupport = [ 14 15 16 17 18 19 ];

  # LLVM versions available in different nixpkgs channels
  nixpkgsLlvmVersions = {
    # nixos-24.11 (stable)
    stable = [ 14 15 16 17 18 19 ];
    # nixpkgs-unstable
    unstable = [ 14 15 16 17 18 19 20 21 ];
  };

  # All LLVM versions we want to expose as package variants
  # Limited to what's currently available in nixpkgs-unstable
  # LLVM 14-17 have been removed from nixpkgs as obsolete
  exposedVersions = [ 18 19 20 21 ];

  # Chapel version to LLVM support mapping
  chapelLlvmSupport = {
    "2.7" = [ 14 15 16 17 18 19 20 21 ];
    "2.6" = [ 14 15 16 17 18 19 20 ];
    "2.5" = [ 11 12 13 14 15 16 17 18 19 20 ];
    "2.4" = [ 11 12 13 14 15 16 17 18 19 ];
    "2.3" = [ 11 12 13 14 15 16 17 18 19 ];
  };

  # Helper: Check if an LLVM version is supported by a Chapel version
  isLlvmSupported = chapelVersion: llvmVersion:
    let
      majorMinor = lib.versions.majorMinor chapelVersion;
      supported = chapelLlvmSupport.${majorMinor} or defaultSupport;
    in
    builtins.elem llvmVersion supported;

  # Helper: Get supported LLVM versions for a Chapel version
  getSupportedLlvm = chapelVersion:
    let
      majorMinor = lib.versions.majorMinor chapelVersion;
    in
    chapelLlvmSupport.${majorMinor} or defaultSupport;

  # Helper: Get LLVM versions available in nixpkgs for a Chapel version
  getAvailableLlvm = chapelVersion:
    let
      supported = getSupportedLlvm chapelVersion;
      available = nixpkgsLlvmVersions.unstable;
    in
    lib.filter (v: builtins.elem v available) supported;

  # Default LLVM version to use for system LLVM builds
  defaultLlvmVersion = 19;

  # Bundled LLVM version in Chapel releases
  bundledLlvmVersions = {
    "2.7.0" = "19.1.3";
    "2.6.0" = "19.1.3";
    "2.5.0" = "19.1.3";
    "2.4.0" = "19.1.0";
    "2.3.0" = "19.1.0";
  };

  # Helper: Get bundled LLVM version for a Chapel version
  getBundledLlvm = chapelVersion:
    bundledLlvmVersions.${chapelVersion} or "19.1.3";
}
