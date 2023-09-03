{
  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem = { lib, pkgs, ... }:
        let
          inherit (lib)
            getExe
            ;
          inherit (pkgs)
            nix
            stdenv
            zig
            ;
        in
        {
          packages.default = stdenv.mkDerivation {
            pname = "zon2nix";
            version = "0.1.2";

            src = ./.;

            nativeBuildInputs = [
              zig.hook
            ];

            zigBuildFlags = [
              "-Dnix=${getExe nix}"
            ];

            zigCheckFlags = [
              "-Dnix=${getExe nix}"
            ];
          };
        };
    };
}
