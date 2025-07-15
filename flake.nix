{
  description = "zon2nix helps you package Zig project with Nix, by converting the dependencies in a build.zig.zon to a Nix expression.";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    self.submodules = true;
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
            default_0_14 = callPackage ./nix/package.nix {
              zig = zig_0_14;
            };
            default_narser = callPackage ./nix/package.nix {
              no-nix = true;
              zig = zigpkgs.master.overrideAttrs (
                f: p: {
                  inherit (zig_0_14) meta;

                  passthru.hook = callPackage "${inputs.nixpkgs}/pkgs/development/compilers/zig/hook.nix" {
                    zig = f.finalPackage;
                  };
                }
              );
            };
            default_0_14_narser = callPackage ./nix/package.nix {
              zig = zig_0_14;
              no-nix = true;
            };
          };
        };
    };
}
