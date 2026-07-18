common:
let
  pkgs = common.pkgs;
  zig = common.zig;
  pythonEnv = common.pythonEnv;
  pythonDevEnv = common.pythonDevEnv;
  pythons = common.pythons;
  py3Pythons = common.py3Pythons;

  mkShellFor = name: py: pkgs.mkShell {
    name = "pymz-${name}";
    packages = [ zig (pythonEnv name py) ]
      ++ pkgs.lib.optional (name != "py27") (pythonDevEnv py)
      ++ [ pkgs.gnumake pkgs.ripgrep ];
    shellHook = ''
      export PYMZ_PYTHON="${py}/bin/${py.executable}"
      export PYMZ_PYTHON_CONFIG="${py}/bin/${py.executable}-config"
      echo "[pymz-tool] ${name} ready: $PYMZ_PYTHON"
    '';
  };

  allPythonsShell = pkgs.mkShell {
    name = "pymz-all";
    packages = [
      zig
      pkgs.gnumake
      pkgs.ripgrep
      (pkgs.python3.withPackages (ps: [ ps.setuptools ps.pytest ]))
    ];
    shellHook = ''
      export PATH="${pkgs.python3.withPackages (ps: [ ps.setuptools ps.pytest ])}/bin:$PATH"
      ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: py: ''
        export PYMZ_PYTHON_${name}="${py}/bin/${py.executable}"
      '') py3Pythons)}
      echo "[pymz-tool] all pythons available: ${pkgs.lib.concatStringsSep ", " (pkgs.lib.attrNames py3Pythons)}"
    '';
  };
in
{
  default = allPythonsShell;
  all = allPythonsShell;
} // (pkgs.lib.mapAttrs mkShellFor pythons)
