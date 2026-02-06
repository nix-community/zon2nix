{
  description = "zon2nix helps you package Zig project with Nix, by converting the dependencies in a build.zig.zon to a Nix expression.";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
            zigpkgs
            zig_0_13
            zig_0_14
            ;
          zig_0_16 = zigpkgs.master-2026-02-03;
          zig_0_16_for_overlay = zig_0_16.overrideAttrs (
            f: p: {
                passthru.hook = callPackage "${inputs.nixpkgs}/pkgs/development/compilers/zig/hook.nix" {
                  zig = pkgs.lib.recursiveUpdate f.finalPackage {
                    # Aparantly, `platforms` and `maintainers` are missing from the nightly. We use the ones
                    # from 0.14, assuming that the values are the same.
                    meta = { inherit (zig_0_14.meta) platforms maintainers; };
                  };
                };
              }
          );
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              inputs.zig-overlay.overlays.default
            ];
            config = { };
          };

          packages = {
            default = callPackage ./nix/package.nix {
              zig = zigpkgs.master.overrideAttrs (
                f: p: {
                  inherit (zig_0_14) meta;

                  passthru.hook = callPackage "${inputs.nixpkgs}/pkgs/development/compilers/zig/hook.nix" {
                    zig = f.finalPackage;
                  };
                }
              );
            };
            default_0_14 = callPackage ./nix/package.nix { zig = zig_0_14; };
            default_0_13 = callPackage ./nix/package.nix { zig = zig_0_13; };
            overlay_0_16 = callPackage ./nix/package.nix { zig = zig_0_16_for_overlay; };
            overlay_0_16_debug = callPackage ./nix/package.nix { zig = zig_0_16_for_overlay; debug = true; };
          };
        };
    };
}
