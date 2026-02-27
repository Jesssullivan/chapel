{
  description = "Chapel project template";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    chapel.url = "github:chapel-lang/chapel";
  };

  outputs = { self, nixpkgs, flake-utils, chapel }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        chapelPkgs = chapel.packages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            chapelPkgs.chapel-gnu
          ];

          shellHook = ''
            echo "Chapel development environment"
            chpl --version
          '';
        };
      }
    );
}
