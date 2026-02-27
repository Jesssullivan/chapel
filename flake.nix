{
  description = "Chapel - A Productive Parallel Programming Language";

  nixConfig = {
    extra-experimental-features = "nix-command flakes";
    # Attic binary cache at tinyland.dev
    extra-substituters = [
      "https://nix-cache.fuzzy-dev.tinyland.dev/main"
    ];
    extra-trusted-public-keys = [
      "main:PBDvqG8OP3W2XF4QzuqWwZD/RhLRsE7ONxwM09kqTtw="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Chapel source versions (for building older releases)
    # These are flake = false since we just need the source
    chapel-2-6 = {
      url = "github:chapel-lang/chapel/2.6.0";
      flake = false;
    };

    # Track upstream main for 2.8 development builds
    chapel-main = {
      url = "github:chapel-lang/chapel/main";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, chapel-2-6, chapel-main }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # Enable CUDA/ROCm support on Linux x86_64
          config = {
            allowUnfree = true;
            cudaSupport = system == "x86_64-linux";
            rocmSupport = system == "x86_64-linux";
          };
        };
        lib = pkgs.lib;

        # Import modular Nix files
        llvmMatrix = import ./nix/llvm-matrix.nix { inherit lib; };
        versions = import ./nix/versions.nix { inherit lib llvmMatrix; };

        # Chapel version
        version = versions.latest;

        # Source filtering to exclude build artifacts and .git
        cleanSrc = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              baseName = baseNameOf path;
            in
            !(baseName == ".git" ||
              baseName == "build" ||
              baseName == "third-party/llvm/llvm-src" ||
              pkgs.lib.hasSuffix ".o" baseName ||
              pkgs.lib.hasSuffix ".a" baseName ||
              baseName == "__pycache__" ||
              baseName == ".nix-profile" ||
              baseName == "result");
        };

        # Import the parameterized Chapel builder
        mkChapelFn = import ./nix/mkChapel.nix {
          inherit pkgs lib llvmMatrix versions;
        };

        # Helper to create Chapel with specific configuration
        mkChapel = args: mkChapelFn ({
          src = cleanSrc;
          inherit version;
        } // args);

        # LLVM versions to expose as system LLVM variants
        # Limited to what's available in nixpkgs
        llvmVersions = llvmMatrix.exposedVersions;

        # Generate LLVM version variant packages
        llvmVariants = lib.listToAttrs (map (v: {
          name = "chapel-llvm${toString v}";
          value = mkChapel {
            llvmBackend = "system";
            llvmVersion = v;
          };
        }) llvmVersions);

        # Check if GPU packages can be built on this system
        canBuildGPU = system == "x86_64-linux";

        # GPU variants (only on x86_64-linux)
        gpuVariants = lib.optionalAttrs canBuildGPU {
          chapel-gpu-nvidia = mkChapel {
            llvmBackend = "bundled";
            enableGPU = true;
            gpuType = "nvidia";
          };
          chapel-gpu-amd = mkChapel {
            llvmBackend = "bundled";
            enableGPU = true;
            gpuType = "amd";
          };
        };

        # GASNet/distributed variants (multi-locale support)
        gasnetVariants = {
          # UDP transport - works anywhere, good for development
          chapel-gasnet-udp = mkChapel {
            llvmBackend = "none";
            commLayer = "gasnet-udp";
          };

          # SMP transport - shared memory, single node
          chapel-gasnet-smp = mkChapel {
            llvmBackend = "none";
            commLayer = "gasnet-smp";
          };

          # OFI/libfabric transport - modern HPC networks
          chapel-gasnet-ofi = mkChapel {
            llvmBackend = "none";
            commLayer = "gasnet-ofi";
          };
        };

        # Language server derivation (DISABLED)
        # The Chapel language server is a shell script that requires CHPL_HOME
        # and Chapel's internal Python virtual environment. It cannot be packaged
        # as a standard buildPythonApplication. TODO: Create wrapper approach.
        # mkChplLsp = ...;

        # All packages
        allPackages = {
          # Default: latest with bundled LLVM
          default = self.packages.${system}.chapel;

          # Primary Chapel package (bundled LLVM for maximum compatibility)
          chapel = mkChapel {
            llvmBackend = "bundled";
          };

          # GNU backend (fastest build, no LLVM dependency)
          chapel-gnu = mkChapel {
            llvmBackend = "none";
          };

          # System LLVM default (LLVM 19)
          chapel-system-llvm = mkChapel {
            llvmBackend = "system";
            llvmVersion = llvmMatrix.defaultLlvmVersion;
          };

          # Previous Chapel version (2.6)
          chapel-2_6 = mkChapelFn {
            version = versions.previous;
            src = chapel-2-6;
            llvmBackend = "bundled";
          };

          # Chapel main/2.8 development (tracks upstream main)
          chapel-dev = mkChapelFn {
            version = "2.8.0-dev";
            src = chapel-main;
            llvmBackend = "system";
            llvmVersion = 19;
          };

          # Language server (disabled - requires CHPL_HOME and internal venv)
          # chpl-language-server = mkChplLsp;
        }
        # Add all LLVM version variants
        // llvmVariants
        # Add GPU variants (if supported)
        // gpuVariants
        # Add GASNet/distributed variants
        // gasnetVariants;

        # Import devShells
        devShellsModule = import ./nix/devShells.nix {
          inherit pkgs lib llvmMatrix;
          packages = allPackages;
        };

        # Import checks
        checksModule = import ./nix/checks.nix {
          inherit pkgs lib system;
          packages = allPackages;
        };

      in {
        # ===================
        # Packages
        # ===================
        packages = allPackages;

        # ===================
        # Development Shells
        # ===================
        devShells = devShellsModule;

        # ===================
        # Checks (for CI)
        # ===================
        checks = checksModule;

        # ===================
        # Apps (nix run)
        # ===================
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.chapel}/bin/chpl";
          };

          chpl = self.apps.${system}.default;

          # Language server disabled - requires CHPL_HOME and internal venv
          # chpl-language-server = {
          #   type = "app";
          #   program = "${self.packages.${system}.chpl-language-server}/bin/chpl-language-server";
          # };
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
        # chpl-language-server disabled - requires CHPL_HOME and internal venv
      } // builtins.listToAttrs (map (v: {
        name = "chapel-llvm${toString v}";
        value = self.packages.${prev.system}."chapel-llvm${toString v}";
      }) [ 18 19 20 21 ]);

      # ===================
      # Templates
      # ===================
      templates = {
        default = {
          path = ./templates/default;
          description = "Basic Chapel project template";
        };
      };
    };
}
