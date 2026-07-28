{
  description = "pymz: multi-version Python C API bindings in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixos-23.11 is the last release still shipping python27.
    nixpkgs-legacy.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-legacy, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgsLegacy = import nixpkgs-legacy {
          inherit system;
          config.permittedInsecurePackages = [ "python-2.7.18.7" ];
        };
        inherit (pkgs) lib;

        # Zig toolchain + language server.
        zig = pkgs.zig;
        zls = pkgs.zls;

        # Python interpreters spanning the target range (2.7 ~ 3.14).
        # py27 ships only in nixos-23.11; py311+ ship in unstable where pip's
        # checkPhase (sphinx -> babel) actually builds (23.11's babel 2.12.1
        # fails its f-string tests and would break every py3 dev shell).
        # py310 is absent from the pinned unstable nixpkgs.
        pythons = {
          py27 = pkgsLegacy.python27;
          py311 = pkgs.python311;
          py312 = pkgs.python312;
          py313 = pkgs.python313;
          py314 = pkgs.python314;
        };

        # Default interpreter loaded by `direnv allow` / `nix develop`.
        pyDefault = pythons.py312;

        # Python with the packages pymz needs to build wheels and run tests.
        pythonDevEnv = py:
          py.withPackages (ps: [ ps.setuptools ps.pytest ps.build ps.pip ps.wheel ]);

        # Wrap a Python derivation with a normalized `python-config` symlink so
        # pymz discovery (which looks up `python-config` on PATH) finds the
        # matching config script without deprecated env vars.
        pythonEnv = name: py:
          pkgs.symlinkJoin {
            inherit name;
            paths = [ py ] ++ lib.optional (py ? dev) py.dev;
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              if [ -e "$out/bin/${py.executable}-config" ]; then
                ln -sf "${py.executable}-config" "$out/bin/python-config"
              else
                echo "pymz pythonEnv: $out/bin/${py.executable}-config missing" >&2
                exit 1
              fi
            '';
          };

        # Isolate Zig's caches to the project dir so builds never touch the
        # user's global ~/.cache/zig.
        zigCacheSetup = ''
          export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
          export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR" 2>/dev/null || true
        '';

        # Make the `pymz-tool` CLI available without `pip install`: the nix
        # Python is read-only, so pymz_tool is put on PYTHONPATH and a thin
        # wrapper runs `python -m pymz_tool.cli`. Regenerated on every shell
        # entry so it tracks the active interpreter.
        pymzToolSetup = ''
          export PYTHONPATH="$PWD/pymz-tool/python''${PYTHONPATH:+:$PYTHONPATH}"
          mkdir -p "$PWD/.pymz-bin"
          printf '%s\n' '#!/bin/sh' 'exec "''${PYMZ_PYTHON}" -m pymz_tool.cli "$@"' > "$PWD/.pymz-bin/pymz-tool"
          chmod +x "$PWD/.pymz-bin/pymz-tool"
          export PATH="$PWD/.pymz-bin:$PATH"
        '';

        # Tooling shared by every dev shell so `direnv allow` is self-contained.
        commonTools = [ zig zls pkgs.gnumake pkgs.ripgrep pkgs.git ];

        # A per-interpreter dev shell.
        # - py27 omits pythonDevEnv (nixpkgs 23.11's python27 lacks setuptools/pytest)
        #   and the pymz-tool wrapper (the CLI is Python 3 only).
        # - Every shell gets zig cache isolation and the common CLI tooling.
        # - Use `./examples/jsonz/test.sh` to build and test the jsonz example
        #   against the active interpreter (see AGENTS.md or the example's
        #   README).
        mkShellFor = name: py:
          pkgs.mkShell {
            name = "pymz-${name}";
            packages = commonTools ++ [ (pythonEnv name py) ]
              ++ lib.optional (name != "py27") (pythonDevEnv py);
            shellHook = zigCacheSetup + ''
              export PYMZ_PYTHON="${py}/bin/${py.executable}"
            '' + lib.optionalString (name != "py27") pymzToolSetup + ''
              echo "[pymz] ${name}: zig $(zig version), python ${py.version}"
              echo "        run  ./examples/jsonz/test.sh  to build & test jsonz"
            '';
          };
      in
      {
        # `direnv allow` loads `default`; per-version shells are available via
        # `nix develop .#py27` / `.#py314` etc.
        devShells = (lib.mapAttrs mkShellFor pythons) // {
          default = mkShellFor "py312" pyDefault;
        };

        formatter = pkgs.alejandra;
      });

  nixConfig = {
    extra-substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store?priority=10"
      "https://mirrors.ustc.edu.cn/nix-channels/store?priority=11"
    ];
  };
}
