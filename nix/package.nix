{
  lib,
  stdenv,
  zig,
  nix,
  debug ? false
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
  ] ++ (if debug then ["-Doptimize=Debug"] else []);

  zigCheckFlags = [
    "-Dnix=${lib.getExe nix}"
  ] ++ (if debug then ["-Doptimize=Debug"] else []);
}
