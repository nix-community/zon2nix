{
  description = "zon2nix helps you package Zig project with Nix, by converting the dependencies in a build.zig.zon to a Nix expression.";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      flake.herculesCI.ciSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        {
          system,
          lib,
          pkgs,
          ...
        }:
        let
          inherit (pkgs)
            callPackage
            zig_0_13
            zig_0_14
            zig_0_15
            zig_0_16
            ;
        in
        {
          packages = {
            default = callPackage ./nix/package.nix { zig = zig_0_16; };
            default_0_13 = callPackage ./nix/package.nix { zig = zig_0_13; };
            default_0_14 = callPackage ./nix/package.nix { zig = zig_0_14; };
            default_0_15 = callPackage ./nix/package.nix { zig = zig_0_15; };
          };
        };
    };
}
