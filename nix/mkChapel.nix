# Chapel Nix Derivation Builder
#
# Parameterized builder for Chapel with support for:
# - Multiple LLVM backends (bundled, system, none)
# - LLVM versions 14-21
# - GPU support (NVIDIA CUDA, AMD ROCm)
# - Communication layers (none, gasnet-udp, gasnet-smp, gasnet-ofi)
# - Multiple Chapel versions
#
{ pkgs
, lib
, llvmMatrix
, versions
}:

{
  # Chapel version to build
  version ? versions.latest
, # Source to use (defaults to self for current repo)
  src
, # LLVM backend: "bundled" | "system" | "none"
  llvmBackend ? "bundled"
, # LLVM version when using system LLVM (14-21)
  llvmVersion ? 19
, # Enable GPU support
  enableGPU ? false
, # GPU type: "nvidia" | "amd" | "cpu"
  gpuType ? "cpu"
, # Communication layer: "none" | "gasnet-udp" | "gasnet-smp" | "gasnet-ofi"
  commLayer ? "none"
, # Extra build inputs
  extraBuildInputs ? []
, # Extra native build inputs
  extraNativeBuildInputs ? []
}:

let
  # Get version info
  versionInfo = versions.versions.${version} or (throw "Unknown Chapel version: ${version}");

  # Validate LLVM version compatibility
  llvmVersionStr = toString llvmVersion;
  isLlvmSupported = llvmBackend != "system" ||
    builtins.elem llvmVersion (versionInfo.llvmSupport or llvmMatrix.defaultSupport);

  # Get LLVM packages for the specified version
  llvmPackages =
    if llvmBackend == "system" then
      pkgs."llvmPackages_${llvmVersionStr}" or
        (throw "LLVM ${llvmVersionStr} not available in nixpkgs")
    else
      pkgs.llvmPackages_19;  # Fallback for type checking, not used

  # Common build inputs required for all Chapel builds
  commonBuildInputs = with pkgs; [
    cmake
    gnumake
    gcc
    gmp
    libedit
    perl
    m4
    pkg-config
    git
    file
    which
    python312
    python312Packages.pip
    python312Packages.virtualenv
    python312Packages.setuptools
    makeWrapper
  ] ++ lib.optionals stdenv.isLinux [
    autoPatchelfHook  # Linux-only: ELF binary patching (macOS uses Mach-O)
  ];

  # LLVM-specific inputs
  # For system LLVM: use the specified llvmPackages
  # For bundled LLVM: use bootstrap clang to build Chapel's bundled LLVM
  llvmInputs =
    if llvmBackend == "system" then [
      llvmPackages.llvm
      llvmPackages.llvm.dev
      llvmPackages.clang
      llvmPackages.libclang
      llvmPackages.libclang.dev
    ]
    else if llvmBackend == "bundled" then [
      bootstrapLlvm.clang
      bootstrapLlvm.llvm
      bootstrapLlvm.llvm.dev
    ]
    else [];

  # GPU-specific inputs
  gpuInputs = lib.optionals enableGPU (
    if gpuType == "nvidia" then
      [ pkgs.cudaPackages.cudatoolkit pkgs.cudaPackages.cuda_cudart ]
    else if gpuType == "amd" then
      [ pkgs.rocmPackages.rocm-runtime pkgs.rocmPackages.clr ]
    else
      []
  );

  # Communication layer settings
  useGasnet = commLayer != "none";
  gasnetSubstrate = if useGasnet then lib.removePrefix "gasnet-" commLayer else "";

  # GASNet-specific inputs
  gasnetInputs = lib.optionals useGasnet (
    [
      pkgs.autoconf
      pkgs.automake
      pkgs.libtool
    ] ++ lib.optionals (commLayer == "gasnet-ofi") [
      pkgs.libfabric
    ] ++ lib.optionals (commLayer == "gasnet-ibv") [
      pkgs.rdma-core
    ]
  );

  # Package name based on configuration
  commSuffix = lib.optionalString useGasnet "-${commLayer}";
  pname =
    if enableGPU && gpuType == "nvidia" then "chapel-gpu-nvidia${commSuffix}"
    else if enableGPU && gpuType == "amd" then "chapel-gpu-amd${commSuffix}"
    else if llvmBackend == "none" then "chapel-gnu${commSuffix}"
    else if llvmBackend == "system" then "chapel-llvm${llvmVersionStr}${commSuffix}"
    else "chapel${commSuffix}";

  # Determine host compiler based on LLVM backend
  # Chapel's CHPL_HOST_COMPILER options:
  #   "gnu"   - uses gcc/g++
  #   "clang" - uses clang/clang++ without requiring LLVM backend
  #   "llvm"  - uses clang with LLVM integration (requires LLVM already built)
  #
  # For "system" LLVM: use llvm host compiler (LLVM backend already available)
  # For "bundled" LLVM: use clang host compiler (clang without LLVM integration)
  # For "none" (GNU): use gnu host compiler with gcc

  # For bundled LLVM, we need clang from nixpkgs to bootstrap the build
  bootstrapLlvm = pkgs.llvmPackages_19;

  # Host compiler setting for Chapel's build system
  hostCompiler =
    if llvmBackend == "system" then "llvm"
    else if llvmBackend == "bundled" then "clang"
    else "gnu";

  # Actual CC/CXX compilers to use
  hostCC = if llvmBackend == "system"
    then "${llvmPackages.clang}/bin/clang"
    else if llvmBackend == "bundled"
      then "${bootstrapLlvm.clang}/bin/clang"
      else "${pkgs.gcc}/bin/gcc";
  hostCXX = if llvmBackend == "system"
    then "${llvmPackages.clang}/bin/clang++"
    else if llvmBackend == "bundled"
      then "${bootstrapLlvm.clang}/bin/clang++"
      else "${pkgs.gcc}/bin/g++";

in

assert isLlvmSupported || throw
  "LLVM ${llvmVersionStr} is not supported by Chapel ${version}. Supported versions: ${builtins.toString (versionInfo.llvmSupport or llvmMatrix.defaultSupport)}";

pkgs.stdenv.mkDerivation rec {
  inherit pname version src;

  nativeBuildInputs = commonBuildInputs
    ++ llvmInputs
    ++ gpuInputs
    ++ gasnetInputs
    ++ extraNativeBuildInputs;

  buildInputs = with pkgs; [
    gmp
    libedit
    protobuf
  ] ++ extraBuildInputs;

  # Critical Chapel environment variables
  CHPL_HOME = ".";
  CHPL_LLVM = llvmBackend;
  CHPL_COMM = if useGasnet then "gasnet" else "none";
  CHPL_COMM_SUBSTRATE = lib.optionalString useGasnet gasnetSubstrate;
  CHPL_GMP = "system";
  CHPL_TARGET_CPU = "none";  # Important for portability

  # GPU environment variables
  CHPL_GPU = lib.optionalString enableGPU (
    if gpuType == "nvidia" then "nvidia"
    else if gpuType == "amd" then "amd"
    else "cpu"
  );
  CHPL_LOCALE_MODEL = lib.optionalString (enableGPU && gpuType != "cpu") "gpu";

  # LLVM-specific environment (only when using system LLVM)
  CHPL_LLVM_CONFIG = lib.optionalString (llvmBackend == "system")
    "${llvmPackages.llvm.dev}/bin/llvm-config";
  CHPL_HOST_COMPILER = hostCompiler;
  CHPL_HOST_CC = hostCC;
  CHPL_HOST_CXX = hostCXX;
  CHPL_TARGET_CC = hostCC;
  CHPL_TARGET_CXX = hostCXX;

  # Clang include paths for system LLVM
  # Note: glibc.dev is Linux-only; on macOS the system headers are used automatically
  CHPL_CLANG_INCLUDES = lib.optionalString (llvmBackend == "system") (
    if pkgs.stdenv.isLinux then
      "-I${llvmPackages.libclang.dev}/include -I${pkgs.glibc.dev}/include"
    else
      "-I${llvmPackages.libclang.dev}/include"
  );

  # Fix shebangs that use /usr/bin/env (doesn't exist in Nix sandbox)
  postPatch = ''
    patchShebangs util/
    patchShebangs compiler/
    patchShebangs tools/
    patchShebangs make/
  '';

  configurePhase = ''
    runHook preConfigure

    export CHPL_HOME=$PWD

    # Set up the Chapel environment
    source util/setchplenv.bash

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Build Chapel compiler
    # Note: chpldoc and mason require network access (pip install) which
    # is blocked in the Nix sandbox, so we only build the core compiler
    make -j$NIX_BUILD_CORES

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Use Chapel's install mechanism
    mkdir -p $out

    # Install binaries
    mkdir -p $out/bin
    cp -r bin/*/* $out/bin/ 2>/dev/null || true

    # Install libraries
    mkdir -p $out/lib
    cp -r lib/* $out/lib/ 2>/dev/null || true

    # Install CHPL_HOME structure for runtime compilation
    mkdir -p $out/share/chapel
    cp -r runtime $out/share/chapel/
    cp -r modules $out/share/chapel/
    cp -r make $out/share/chapel/
    cp -r util $out/share/chapel/
    cp -r compiler $out/share/chapel/ 2>/dev/null || true
    cp -r third-party $out/share/chapel/ 2>/dev/null || true

    # Copy Makefiles needed for compilation
    cp Makefile* $out/share/chapel/ 2>/dev/null || true

    runHook postInstall
  '';

  # Remove broken symlinks and fix bundled LLVM RPATH issues before fixup
  preFixup = ''
    # Remove broken symlinks that point to /build directory
    # These are test files from hwloc and are not needed at runtime
    find $out -xtype l -delete 2>/dev/null || true

    # For bundled LLVM: remove LLVM test/development binaries that have
    # hardcoded RPATH pointing to /build/ (the Nix sandbox). These binaries
    # (like c-index-test) are not needed for Chapel runtime operation.
    # IMPORTANT: Only remove binaries in third-party directories, NOT the main
    # chpl binary in $out/bin which also has /build/ RPATH but needs to be fixed
    # by patchelf during the fixup phase.
    if [ -d "$out/share/chapel/third-party/llvm/build" ]; then
      echo "Cleaning up bundled LLVM build artifacts..."
      # Remove LLVM bin directories - these contain test tools not needed at runtime
      find $out/share/chapel/third-party/llvm/build -type d -name "bin" -exec rm -rf {} + 2>/dev/null || true
    fi
  '' + lib.optionalString pkgs.stdenv.isLinux ''
    # Linux: Fix RPATH for main binaries using patchelf
    # The /build/ references need to be stripped from RPATH
    for f in $out/bin/*; do
      if [ -f "$f" ] && [ -x "$f" ]; then
        current_rpath=$(patchelf --print-rpath "$f" 2>/dev/null || true)
        if echo "$current_rpath" | grep -q "/build/"; then
          # Remove /build/ paths from RPATH, keeping valid paths
          new_rpath=$(echo "$current_rpath" | tr ':' '\n' | grep -v "^/build" | tr '\n' ':' | sed 's/:$//')
          echo "Fixing RPATH for $f: removing /build/ references"
          patchelf --set-rpath "$new_rpath" "$f" 2>/dev/null || true
        fi
      fi
    done
  '';
    # Note: macOS dylib path fixing is done in postFixup after standard fixup runs

  # Wrap binaries and fix dylib paths
  postFixup = ''
  '' + lib.optionalString pkgs.stdenv.isDarwin ''
    # macOS: Fix dylib paths AFTER standard fixup and BEFORE wrapping
    # The standard fixup may leave bad rpath entries that point to /nix/store/lib/...
    # instead of the full store path

    echo "=== macOS postFixup dylib repair ==="

    # Find the actual dylib file
    FRONTEND_DYLIB=$(find $out -name "libChplFrontend.dylib" -type f 2>/dev/null | head -1)

    if [ -n "$FRONTEND_DYLIB" ]; then
      LIB_DIR=$(dirname "$FRONTEND_DYLIB")
      echo "Found libChplFrontend.dylib at: $FRONTEND_DYLIB"
      echo "Library directory: $LIB_DIR"

      # Fix the dylib's install name to use @rpath
      echo "Setting install name for libChplFrontend.dylib"
      install_name_tool -id "@rpath/libChplFrontend.dylib" "$FRONTEND_DYLIB" || true

      # Fix all Mach-O binaries
      for f in $out/bin/*; do
        if [ -f "$f" ] && [ -x "$f" ]; then
          # Check if it's a Mach-O binary (not a script)
          if file "$f" | grep -q "Mach-O"; then
            echo "Fixing rpath for: $f"

            # Get current rpaths and remove any broken ones (those with /nix/store/lib without full hash)
            current_rpaths=$(otool -l "$f" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path " | awk '{print $2}' || true)
            for rp in $current_rpaths; do
              # Remove rpath entries that look like /nix/store/lib/... (missing hash) or /build/...
              if echo "$rp" | grep -qE "^/nix/store/lib|^/build"; then
                echo "  Removing bad rpath: $rp"
                install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
              fi
            done

            # Add the correct rpath pointing to the library directory
            echo "  Adding rpath: $LIB_DIR"
            install_name_tool -add_rpath "$LIB_DIR" "$f" 2>/dev/null || true
          fi
        fi
      done

      echo "=== dylib repair complete ==="
    else
      echo "WARNING: libChplFrontend.dylib not found!"
      echo "Full lib contents:"
      find $out/lib -type f 2>/dev/null || echo "  (empty)"
    fi
  '' + ''
    # Wrap binaries to set CHPL_HOME and ensure python3 + compiler are on PATH
    # Chapel's chpl compiler calls util/printchplenv at runtime which requires python3
    # and probes for the backend compiler (gcc for GNU, clang for LLVM)
    for prog in $out/bin/*; do
      if [ -f "$prog" ] && [ -x "$prog" ]; then
        wrapProgram "$prog" \
          --set CHPL_HOME "$out/share/chapel" \
          --prefix PATH : "${pkgs.python312}/bin" \
          --prefix PATH : "${if llvmBackend == "none" then "${pkgs.gcc}/bin" else if llvmBackend == "system" then "${llvmPackages.clang}/bin" else "${bootstrapLlvm.clang}/bin"}"
      fi
    done
  '';

  # Disable the broken symlinks check as a fallback
  dontCheckForBrokenSymlinks = true;

  meta = with lib; {
    description = "A productive parallel programming language" +
      lib.optionalString (llvmBackend == "system") " (LLVM ${llvmVersionStr})" +
      lib.optionalString (llvmBackend == "none") " (GNU backend)" +
      lib.optionalString enableGPU " (GPU: ${gpuType})" +
      lib.optionalString useGasnet " (${commLayer})";
    longDescription = ''
      Chapel is a programming language designed for productive parallel
      computing at scale. It simplifies parallel programming through
      high-level abstractions for data parallelism and task parallelism,
      while still allowing low-level control when needed.
    '';
    homepage = "https://chapel-lang.org";
    license = licenses.asl20;
    platforms = platforms.unix;
    maintainers = [ ];
  };
}
