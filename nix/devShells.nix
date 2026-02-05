# Chapel Development Shells
#
# Provides development environments for:
# - default: Full Chapel development environment
# - minimal: GNU backend only (fastest)
# - gpu-nvidia: CUDA development
# - gpu-amd: ROCm development
# - chapel-dev: For hacking on Chapel itself
#
{ pkgs
, lib
, llvmMatrix
, packages
}:

let
  # Common development inputs
  commonDevInputs = with pkgs; [
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
  ];

  # Get default LLVM packages
  llvmPackages = pkgs.llvmPackages_19;

  # LLVM development inputs
  llvmDevInputs = [
    llvmPackages.llvm
    llvmPackages.llvm.dev
    llvmPackages.clang
    llvmPackages.libclang
    llvmPackages.libclang.dev
  ];

in {
  # Default development shell with full Chapel
  default = pkgs.mkShell {
    buildInputs = commonDevInputs ++ llvmDevInputs ++ [
      pkgs.gmp
      pkgs.libedit
      pkgs.protobuf
    ];

    shellHook = ''
      export CHPL_HOME=${packages.chapel}/share/chapel
      export PATH=${packages.chapel}/bin:$PATH
      echo "Chapel development environment loaded"
      echo "Run 'chpl --version' to verify installation"
    '';
  };

  # Minimal shell for running Chapel programs (GNU backend)
  minimal = pkgs.mkShell {
    buildInputs = [
      packages.chapel-gnu
    ];

    shellHook = ''
      echo "Minimal Chapel environment (GNU backend only)"
      echo "Run 'chpl --version' to verify installation"
    '';
  };

  # Full development with all tools
  full = pkgs.mkShell {
    buildInputs = commonDevInputs ++ llvmDevInputs ++ [
      packages.chapel
      # packages.chpl-language-server  # Disabled - requires CHPL_HOME and internal venv
      pkgs.fltk  # for chplvis
      pkgs.doxygen
      pkgs.sphinx
    ];

    shellHook = ''
      export CHPL_HOME=${packages.chapel}/share/chapel
      export PATH=${packages.chapel}/bin:$PATH
      echo "Full Chapel development environment"
      echo "Includes: chpl, fltk (chplvis), doxygen, sphinx"
    '';
  };

  # Shell for Chapel development (building Chapel itself)
  chapel-dev = (pkgs.mkShell.override { stdenv = llvmPackages.stdenv; }) {
    nativeBuildInputs = commonDevInputs ++ llvmDevInputs ++ [
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

  # NVIDIA GPU development shell
  gpu-nvidia = pkgs.mkShell {
    buildInputs = commonDevInputs ++ [
      packages.chapel-gpu-nvidia or packages.chapel
      pkgs.cudaPackages.cudatoolkit
      pkgs.cudaPackages.cuda_cudart
    ];

    shellHook = ''
      export CHPL_GPU=nvidia
      export CHPL_LOCALE_MODEL=gpu
      echo "Chapel GPU development environment (NVIDIA CUDA)"
      echo "CUDA toolkit available at: ${pkgs.cudaPackages.cudatoolkit}"
    '';
  };

  # AMD GPU development shell
  gpu-amd = pkgs.mkShell {
    buildInputs = commonDevInputs ++ [
      packages.chapel-gpu-amd or packages.chapel
      pkgs.rocmPackages.rocm-runtime
      pkgs.rocmPackages.clr
    ];

    shellHook = ''
      export CHPL_GPU=amd
      export CHPL_LOCALE_MODEL=gpu
      echo "Chapel GPU development environment (AMD ROCm)"
    '';
  };
}
