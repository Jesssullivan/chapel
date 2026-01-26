{
  description = "Chapel - A Productive Parallel Programming Language";

  nixConfig = {
    extra-experimental-features = "nix-command flakes";
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Chapel version
        version = "2.7.0";

        # LLVM version configuration
        # Chapel 2.7 supports LLVM 14-21 (21 is the newest supported version)
        #
        # Default: Use bundled LLVM for LLVM 21 support (Chapel bundles LLVM 19.1.3,
        # but this branch adds LLVM 21 support which can be used with system LLVM 21)
        #
        # For system LLVM builds, available nixpkgs options:
        #   llvmPackages_14 through llvmPackages_19
        # LLVM 20/21 packages will be added to nixpkgs when released
        llvmPackages = pkgs.llvmPackages_19;

        # Default to bundled LLVM for maximum compatibility and LLVM 21 testing
        defaultChplLlvm = "bundled";

        # Common build inputs for Chapel
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
          autoPatchelfHook
        ];

        # LLVM-specific inputs
        llvmInputs = [
          llvmPackages.llvm
          llvmPackages.llvm.dev
          llvmPackages.clang
          llvmPackages.libclang
          llvmPackages.libclang.dev
        ];

        # Source filtering to exclude build artifacts and .git
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              baseName = baseNameOf path;
              relPath = pkgs.lib.removePrefix (toString ./. + "/") path;
            in
            # Exclude build artifacts and large directories
            !(baseName == ".git" ||
              baseName == "build" ||
              baseName == "third-party/llvm/llvm-src" ||
              pkgs.lib.hasSuffix ".o" baseName ||
              pkgs.lib.hasSuffix ".a" baseName ||
              baseName == "__pycache__" ||
              baseName == ".nix-profile" ||
              baseName == "result");
        };

        # Base Chapel derivation builder
        mkChapel = { chplLlvm ? "system", chplComm ? "none", extraBuildInputs ? [] }:
          pkgs.stdenv.mkDerivation rec {
            pname = "chapel";
            inherit version src;

            nativeBuildInputs = commonBuildInputs ++
              (if chplLlvm == "system" then llvmInputs else []) ++
              extraBuildInputs;

            buildInputs = with pkgs; [
              gmp
              libedit
              protobuf
            ];

            # Critical Chapel environment variables
            CHPL_HOME = ".";
            CHPL_LLVM = chplLlvm;
            CHPL_COMM = chplComm;
            CHPL_GMP = "system";
            CHPL_TARGET_CPU = "none";  # Important for portability

            # LLVM-specific environment (only when using system LLVM)
            CHPL_LLVM_CONFIG = if chplLlvm == "system"
              then "${llvmPackages.llvm.dev}/bin/llvm-config"
              else "";
            CHPL_HOST_COMPILER = if chplLlvm == "system" then "llvm" else "gnu";
            CHPL_HOST_CC = if chplLlvm == "system"
              then "${llvmPackages.clang}/bin/clang"
              else "${pkgs.gcc}/bin/gcc";
            CHPL_HOST_CXX = if chplLlvm == "system"
              then "${llvmPackages.clang}/bin/clang++"
              else "${pkgs.gcc}/bin/g++";
            CHPL_TARGET_CC = CHPL_HOST_CC;
            CHPL_TARGET_CXX = CHPL_HOST_CXX;

            # Clang include paths for system LLVM
            CHPL_CLANG_INCLUDES = if chplLlvm == "system"
              then "-I${llvmPackages.libclang.dev}/include -I${pkgs.glibc.dev}/include"
              else "";

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

            # Remove broken symlinks before fixup phase runs its checks
            preFixup = ''
              # Remove broken symlinks that point to /build directory
              # These are test files from hwloc and are not needed at runtime
              find $out -xtype l -delete 2>/dev/null || true
            '';

            # Wrap binaries to set CHPL_HOME environment variable
            postFixup = ''
              for prog in $out/bin/*; do
                if [ -f "$prog" ] && [ -x "$prog" ]; then
                  wrapProgram "$prog" \
                    --set CHPL_HOME "$out/share/chapel"
                fi
              done
            '';

            # Also disable the broken symlinks check as a fallback
            # (hwloc build directory contains symlinks that are only valid during build)
            dontCheckForBrokenSymlinks = true;

            meta = with pkgs.lib; {
              description = "A productive parallel programming language";
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
          };

        # Language server derivation (uses local source)
        mkChplLsp = pkgs.python312Packages.buildPythonApplication {
          pname = "chpl-language-server";
          inherit version;
          pyproject = true;

          # Use local source with filtering
          src = ./tools/chpl-language-server;

          build-system = with pkgs.python312Packages; [
            setuptools
          ];

          propagatedBuildInputs = with pkgs.python312Packages; [
            pygls
            lsprotocol
          ];

          # Skip tests that require the full Chapel environment
          doCheck = false;

          meta = with pkgs.lib; {
            description = "Chapel Language Server Protocol implementation";
            homepage = "https://chapel-lang.org";
            license = licenses.asl20;
          };
        };

      in {
        # ===================
        # Packages
        # ===================
        packages = {
          default = self.packages.${system}.chapel;

          # Full Chapel with bundled LLVM (default for LLVM 21 support)
          # Uses Chapel's included LLVM which supports versions 14-21
          # Note: Requires ~4GB memory to build
          chapel = mkChapel {
            chplLlvm = "bundled";
          };

          # Chapel with system LLVM backend (LLVM 19 from nixpkgs)
          # Faster to build if you have system LLVM available
          chapel-system-llvm = mkChapel {
            chplLlvm = "system";
          };

          # Chapel with GNU backend only (fastest build, no LLVM dependency)
          chapel-gnu = mkChapel {
            chplLlvm = "none";
          };

          # Chapel with GASNet for multi-locale
          # NOTE: GASNet not in nixpkgs, would need custom derivation
          # chapel-gasnet = mkChapel {
          #   chplComm = "gasnet";
          #   extraBuildInputs = [ gasnet ];  # Custom derivation needed
          # };

          # Language server (standalone)
          chpl-language-server = mkChplLsp;
        };

        # ===================
        # Development Shells
        # ===================
        devShells = {
          # Default development shell with full Chapel
          default = pkgs.mkShell {
            buildInputs = commonBuildInputs ++ llvmInputs ++ [
              pkgs.gmp
              pkgs.libedit
              pkgs.protobuf
            ];

            shellHook = ''
              export CHPL_HOME=${self.packages.${system}.chapel}/share/chapel
              export PATH=${self.packages.${system}.chapel}/bin:$PATH
              echo "Chapel development environment loaded"
              echo "Run 'chpl --version' to verify installation"
            '';
          };

          # Minimal shell for running Chapel programs
          minimal = pkgs.mkShell {
            buildInputs = [
              self.packages.${system}.chapel-gnu
            ];

            shellHook = ''
              echo "Minimal Chapel environment (GNU backend only)"
            '';
          };

          # Full development with all tools
          full = pkgs.mkShell {
            buildInputs = commonBuildInputs ++ llvmInputs ++ [
              self.packages.${system}.chapel
              self.packages.${system}.chpl-language-server
              pkgs.fltk  # for chplvis
              pkgs.doxygen
              pkgs.sphinx
            ];

            shellHook = ''
              export CHPL_HOME=${self.packages.${system}.chapel}/share/chapel
              export PATH=${self.packages.${system}.chapel}/bin:$PATH
              echo "Full Chapel development environment"
              echo "Includes: chpl, chpldoc, mason, chpl-language-server"
            '';
          };

          # Shell for Chapel development (building Chapel itself)
          # This sets up all the LLVM environment variables correctly
          chapel-dev = (pkgs.mkShell.override { stdenv = llvmPackages.stdenv; }) {
            nativeBuildInputs = commonBuildInputs ++ llvmInputs ++ [
              pkgs.gmp
              pkgs.libedit
              pkgs.protobuf
              pkgs.doxygen
              pkgs.sphinx
            ];

            shellHook = ''
              # Critical LLVM environment variables for Chapel development
              export CHPL_LLVM=system
              export CHPL_LLVM_CONFIG=${llvmPackages.llvm.dev}/bin/llvm-config
              export CHPL_HOST_COMPILER=llvm
              export CHPL_HOST_CC=${llvmPackages.clang}/bin/clang
              export CHPL_HOST_CXX=${llvmPackages.clang}/bin/clang++
              export CHPL_TARGET_CC=${llvmPackages.clang}/bin/clang
              export CHPL_TARGET_CXX=${llvmPackages.clang}/bin/clang++
              export CHPL_CLANG_INCLUDES="-I${llvmPackages.libclang.dev}/include -I${pkgs.glibc.dev}/include"

              # Reproducibility settings
              export CHPL_GMP=system
              export CHPL_TARGET_CPU=none

              echo "Chapel compiler development environment"
              echo "LLVM ${llvmPackages.llvm.version} configured"
              echo ""
              echo "Set CHPL_HOME to your Chapel source directory:"
              echo "  export CHPL_HOME=\$PWD"
              echo "  source util/setchplenv.bash"
              echo "  make"
            '';
          };
        };

        # ===================
        # Apps (nix run)
        # ===================
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.chapel}/bin/chpl";
          };

          chpl = self.apps.${system}.default;

          chpl-language-server = {
            type = "app";
            program = "${self.packages.${system}.chpl-language-server}/bin/chpl-language-server";
          };
        };

      }
    ) // {
      # ===================
      # Overlay (system-independent)
      # ===================
      overlays.default = final: prev: {
        chapel = self.packages.${prev.system}.chapel;
        chapel-system-llvm = self.packages.${prev.system}.chapel-system-llvm;
        chapel-gnu = self.packages.${prev.system}.chapel-gnu;
        chpl-language-server = self.packages.${prev.system}.chpl-language-server;
      };
    };
}
