{
  lib,
  stdenv,
  zig,
  nix,
}:
stdenv.mkDerivation {
  pname = "zon2nix";
  version = "0.1.2";

  src = ../.;

  nativeBuildInputs = [
    zig.hook
  ];

  zigBuildFlags = [
    "-Dnix=${lib.getExe nix}"
  ];

  zigCheckFlags = [
    "-Dnix=${lib.getExe nix}"
  ];
}
