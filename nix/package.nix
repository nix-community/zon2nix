{
  lib,
  stdenv,
  zig,
  nix,
  no-nix ? false,
}:
stdenv.mkDerivation {
  pname = "zon2nix";
  version = "0.1.2";

  src = ../.;

  nativeBuildInputs = [
    zig.hook
  ];

  zigBuildFlags = [
    (if no-nix then "-Dno-nix" else "-Dnix=${lib.getExe nix}")
    "-Dlinkage=${if stdenv.hostPlatform.isStatic then "static" else "dynamic"}"
  ];

  zigCheckFlags = [
    (if no-nix then "-Dno-nix" else "-Dnix=${lib.getExe nix}")
    "-Dlinkage=${if stdenv.hostPlatform.isStatic then "static" else "dynamic"}"
  ];
}
