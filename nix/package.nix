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

  postInstall = lib.optional stdenv.hostPlatform.isLinux ''
    patchelf --set-interpreter ${stdenv.cc.libc}/lib/ld-linux-${
      if stdenv.hostPlatform.isx86_64 then
        "x86-64.so.2"
      else
        "${stdenv.hostPlatform.parsed.cpu.name}.so.1"
    } $out/bin/zon2nix
  '';
}
