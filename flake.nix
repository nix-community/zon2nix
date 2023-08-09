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
            makeBinPath
            ;
          inherit (pkgs)
            makeBinaryWrapper
            nix
            stdenv
            zigHook
            zig_0_11
            ;
        in
        {
          packages.default = stdenv.mkDerivation {
            pname = "zon2nix";
            version = "0.1.1";

            src = ./.;

            nativeBuildInputs = [
              makeBinaryWrapper
              (zigHook.override {
                zig = zig_0_11;
              })
            ];

            postInstall = ''
              wrapProgram $out/bin/zon2nix \
                --prefix PATH : ${makeBinPath [ nix ]}
            '';
          };
        };
    };
}
