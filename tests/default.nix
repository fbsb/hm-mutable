{
  pkgs,
  home-manager,
  module,
}:
let
  inherit (pkgs) lib;
  dag = import "${home-manager}/modules/lib/dag.nix" {
    lib = lib // {
      hm.dag = dag;
    };
  };
  tree = pkgs.runCommand "mutable-source-tree" { } ''
    mkdir -p "$out/nested"
    echo original > "$out/nested/file"
    echo executable > "$out/program"
    chmod +x "$out/program"
    ln -s nested/file "$out/symlink"
  '';
  evaluate =
    extra:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "test";
          home.homeDirectory = "/home/test";
          home.stateVersion = "25.11";
          programs.home-manager.enable = false;
        }
        extra
      ];
    };
  mkHome =
    copyCommand: phase:
    evaluate {
      home.mutableFilesCopyCommand = copyCommand;
      home.file = {
        "mutable file 'quoted'" = {
          mutable = phase != "linked";
          force = phase == "linked";
          text = "${phase}\n";
          onChange = ''
            test "$(cat "$HOME/mutable file 'quoted'")" = ${lib.escapeShellArg phase}
            echo hook >> "$HOME/hooks"
          '';
        };
        immutable.text = "linked";
        disabled = {
          enable = false;
          mutable = true;
          text = "disabled";
        };
        directory = {
          source = tree;
          mutable = true;
          recursive = true;
        };
        executable = {
          text = "exec";
          mutable = true;
          executable = true;
        };
        nonExecutable = {
          source = "${tree}/program";
          mutable = true;
          executable = false;
        };
        inheritedExecutable = {
          source = "${tree}/program";
          mutable = true;
        };
      }
      // lib.optionalAttrs (phase == "first") {
        removed = {
          text = "remove";
          mutable = true;
        };
      };
      xdg = lib.genAttrs [ "configFile" "dataFile" "cacheFile" "stateFile" ] (_: {
        mutable = {
          text = phase;
          mutable = true;
        };
      });
    };
  selectedNodes = [
    "checkLinkTargets"
    "checkFilesChanged"
    "writeBoundary"
    "mutableFilesCleanup"
    "linkGeneration"
    "mutableFilesCopy"
    "onFilesChange"
    "mutableFilesOnChange"
  ];
  script =
    home:
    let
      sorted = dag.topoSort home.config.home.activation;
    in
    assert sorted ? result;
    assert lib.all (name: builtins.hasAttr name home.config.home.activation) selectedNodes;
    pkgs.writeShellScript "test-file-activation" (
      ''
        set -euo pipefail
        ${home.config.lib.bash.initHomeManagerLib}
        hmDriverVersion=1
        export VERBOSE_ARG=""
        export HOME_MANAGER_BACKUP_EXT="" HOME_MANAGER_BACKUP_COMMAND="" HOME_MANAGER_BACKUP_OVERWRITE=""
      ''
      + lib.concatMapStrings (
        node: lib.optionalString (lib.elem node.name selectedNodes) node.data
      ) sorted.result
    );
  generation = home: home.activationPackage;
  global = evaluate {
    home.mutableFiles = true;
    home.file.inherited.text = "inherited";
    home.file.optOut = {
      text = "link";
      mutable = false;
    };
    home.file.disabled = {
      text = "disabled";
      enable = false;
    };
    xdg.configFile.inherited.text = "inherited";
  };
  rejects = extra: !(builtins.tryEval (evaluate extra).activationPackage.drvPath).success;
in
lib.genAttrs [ "cp" "rsync" ] (
  copyCommand:
  let
    first = mkHome copyCommand "first";
    second = mkHome copyCommand "second";
    linked = mkHome copyCommand "linked";
    empty = evaluate { };
    activate = home: ''
      export newGenPath=${generation home}
      ${script home}
      export oldGenPath="$newGenPath"
    '';
  in
  assert global.config.home.file.inherited._hmMutable;
  assert global.config.home.file.optOut.enable;
  assert !global.config.home.file.disabled._hmMutable;
  assert global.config.home.file."${global.config.xdg.configHome}/inherited"._hmMutable;
  pkgs.runCommand "hm-mutable-${copyCommand}"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gettext
      ];
    }
    ''
      export HOME="$TMPDIR/home" USER=test
      mkdir -p "$HOME"
      mkdir -p "$TMPDIR/fork-generation/home-mutable-files"
      ln -s ${(evaluate { }).config.home-files} "$TMPDIR/fork-generation/home-files"
      printf 'legacy\tinherit\n' > "$TMPDIR/fork-generation/home-mutable-files/.metadata"
      echo legacy > "$HOME/legacy"
      export oldGenPath="$TMPDIR/fork-generation"
      ${activate first}
      test ! -e "$HOME/legacy"
      test -f "$HOME/mutable file 'quoted'"
      test ! -L "$HOME/mutable file 'quoted'"
      test -w "$HOME/mutable file 'quoted'"
      test -L "$HOME/immutable"
      test ! -e "$HOME/disabled"
      test -x "$HOME/executable"
      test ! -x "$HOME/nonExecutable"
      test -x "$HOME/inheritedExecutable"
      test ! -L "$HOME/directory"
      test ! -L "$HOME/directory/symlink"
      test -w "$HOME/directory/nested/file"
      test -x "$HOME/directory/program"
      for location in .config .cache .local/share .local/state; do
        test -f "$HOME/$location/mutable"
        test ! -L "$HOME/$location/mutable"
      done
      echo edited > "$HOME/mutable file 'quoted'"
      echo extra > "$HOME/directory/extra"
      ${activate first}
      test "$(cat "$HOME/mutable file 'quoted'")" = first
      test ! -e "$HOME/directory/extra"
      test "$(wc -l < "$HOME/hooks")" -eq 2

      export DRY_RUN=1
      ${activate second}
      unset DRY_RUN
      export oldGenPath=${generation first}
      test "$(cat "$HOME/mutable file 'quoted'")" = first
      test -f "$HOME/removed"
      test "$(wc -l < "$HOME/hooks")" -eq 2
      ${activate second}
      test ! -e "$HOME/removed"
      test "$(cat "$HOME/mutable file 'quoted'")" = second
      ${activate linked}
      test -L "$HOME/mutable file 'quoted'"
      ${activate second}
      test ! -L "$HOME/mutable file 'quoted'"
      ${activate empty}
      test ! -e "$HOME/mutable file 'quoted'"
      test ! -e "$HOME/directory"
      test ! -e "$HOME/immutable"
      ${activate global}
      test -f "$HOME/inherited"
      test ! -L "$HOME/inherited"
      test -L "$HOME/optOut"
      test ! -e "$HOME/disabled"
      ${activate empty}

      export HOME="$TMPDIR/safety-home"
      unset oldGenPath
      mkdir -p "$HOME"
      mkdir -p "$TMPDIR/outside"
      echo untouched > "$TMPDIR/outside/mutable"
      ln -s "$TMPDIR/outside" "$HOME/.config"
      export newGenPath=${generation first}
      if ${script first} > "$TMPDIR/rejected.log" 2>&1; then
        echo 'Expected symlink-parent rejection' >&2
        exit 1
      fi
      grep -q 'refusing to write through symlink parent' "$TMPDIR/rejected.log"
      test "$(cat "$TMPDIR/outside/mutable")" = untouched
      touch "$out"
    ''
)
// {
  invalid-targets =
    assert rejects {
      home.file.bad = {
        text = "bad";
        mutable = true;
        target = "../outside";
      };
    };
    assert rejects {
      home.file.bad = {
        text = "bad";
        mutable = true;
        target = "/outside";
      };
    };
    assert rejects {
      home.file.bad = {
        text = "bad";
        mutable = true;
        target = ".metadata";
      };
    };
    assert rejects {
      home.file.bad = {
        text = "bad";
        mutable = true;
        target = "tab\there";
      };
    };
    assert rejects {
      home.file = {
        directory = {
          source = tree;
          mutable = true;
        };
        "directory/child".text = "overlap";
      };
    };
    assert rejects {
      home.file = {
        first = {
          text = "same";
          target = "duplicate";
          mutable = true;
        };
        second = {
          text = "same";
          target = "duplicate";
          mutable = true;
        };
      };
    };
    pkgs.runCommand "hm-mutable-invalid-targets" { } "touch $out";
}
