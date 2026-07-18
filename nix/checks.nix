common:
let
  pkgs = common.pkgs;
  zig = common.zig;
  pythonEnv = common.pythonEnv;
  pythonDevEnv = common.pythonDevEnv;
  zigCacheSetup = common.zigCacheSetup;
  pythons = common.pythons;
in
{
  jsonz-py3 = pkgs.runCommand "pymz-jsonz-py3-check" {
    nativeBuildInputs = [
      zig
      (pythonEnv "py312" pythons.py312)
      (pythonDevEnv pythons.py312)
    ];
    src = common.source;
  } ''
    cp -R "$src" source
    chmod -R u+w source
    cd source/examples/jsonz
    ${zigCacheSetup}
    export PYMZ_PYTHON="${pythons.py312}/bin/${pythons.py312.executable}"
    export PYMZ_PYTHON_CONFIG="${pythons.py312}/bin/${pythons.py312.executable}-config"
    zig build example -Dpython-version=3.12 -Doptimize=ReleaseFast
    PYTHONPATH=zig-out/lib ${pythonDevEnv pythons.py312}/bin/${pythons.py312.executable} -m pytest tests -q
    mkdir -p "$out"
    touch "$out/done"
  '';
}
