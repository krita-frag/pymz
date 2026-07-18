common:
let
  pkgs = common.pkgs;
  zig = common.zig;
  pythonEnv = common.pythonEnv;
  zigCacheSetup = common.zigCacheSetup;
  pythons = common.pythons;
in
rec {
  # Build the jsonz example extension for a specific python version.
  jsonz-py27 = pkgs.stdenvNoCC.mkDerivation {
    pname = "pymz-jsonz-py27";
    version = "0.1.0";
    src = common.source;
    nativeBuildInputs = [ zig pkgs.gnumake (pythonEnv "py27" pythons.py27) ];
    buildPhase = ''
      cd examples/jsonz
      ${zigCacheSetup}
      zig build example -Dpython-version=2.7 -Doptimize=ReleaseFast -p $out
    '';
    installPhase = "true";
  };

  jsonz-py3 = pkgs.stdenvNoCC.mkDerivation {
    pname = "pymz-jsonz-py3";
    version = "0.1.0";
    src = common.source;
    nativeBuildInputs = [ zig pkgs.gnumake (pythonEnv "py312" pythons.py312) ];
    buildPhase = ''
      cd examples/jsonz
      ${zigCacheSetup}
      zig build example -Dpython-version=3.12 -Doptimize=ReleaseFast -p $out
    '';
    installPhase = "true";
  };

  default = jsonz-py3;
}
