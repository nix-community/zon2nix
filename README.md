# zon2nix

Convert the dependencies in `build.zig.zon` to a Nix expression

## Usage

```bash
zon2nix > deps.nix
zon2nix zls > deps.nix
zon2nix zls/build.zig.zon > deps.nix
```

To use the generated file, add this to your Nix expression:

```nix
postPatch = ''
  ln -s ${callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
'';
```
