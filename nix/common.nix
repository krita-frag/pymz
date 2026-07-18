{ pkgs, pkgsLegacy, source }:
let
  pythons = {
    py27 = pkgsLegacy.python27;
    py38 = pkgsLegacy.python38;
    py39 = pkgsLegacy.python39;
    py310 = pkgsLegacy.python310;
    py311 = pkgsLegacy.python311;
    py312 = pkgsLegacy.python312;
  };

  py3Pythons = {
    py38 = pythons.py38;
    py39 = pythons.py39;
    py310 = pythons.py310;
    py311 = pythons.py311;
    py312 = pythons.py312;
  };
in
{
  inherit pkgs source pythons py3Pythons;

  zig = pkgs.zig;

  pythonDevEnv = py: py.withPackages (ps: [ ps.setuptools ps.pytest ]);

  zigCacheSetup = ''
    export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
  '';

  pythonEnv = name: py:
    pkgs.symlinkJoin {
      inherit name;
      paths = [ py ] ++ pkgs.lib.optional (py ? dev) py.dev;
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        # Provide a normalized config script used by build.zig.
        if [ -e $out/bin/${py.executable}-config ]; then
          ln -s ${py.executable}-config $out/bin/pymz-python-config || true
        fi
      '';
    };
}
