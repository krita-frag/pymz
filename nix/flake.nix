{ self, nixpkgs, nixpkgs-legacy, flake-utils, ... }:
let
  inherit (nixpkgs) lib;
  supportedSystems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];
in
flake-utils.lib.eachSystem supportedSystems (
  system:
  let
    pkgs = import nixpkgs { inherit system; };
    pkgsLegacy = import nixpkgs-legacy { inherit system; };
    source = builtins.path { path = ../.; name = "pymz-src"; };

    common = import ./common.nix {
      inherit pkgs pkgsLegacy source;
    };
  in
  {
    devShells = import ./dev-shells.nix common;
    packages = import ./packages.nix common;
    checks = import ./checks.nix common;
    formatter = pkgs.alejandra;
  }
)
