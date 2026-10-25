{
  config,
  lib,
  pkgs,
  ...
}:
let
  isMutable = file: if file.mutable == null then config.home.mutableFiles else file.mutable;
  fileOptions = {
    options.mutable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Copy this entry as writable files instead of linking it. Edits are
        reset on every activation. Null inherits home.mutableFiles.
      '';
    };
  };
  fileType = lib.types.attrsOf (lib.types.submodule fileOptions);
  files = lib.attrValues config.home.file;
  mutableFiles = lib.sort (left: right: left.target < right.target) (
    lib.filter (file: file._hmMutable) files
  );
  managedFiles = lib.filter (file: file.enable || file._hmMutable) files;
  validTarget =
    target:
    target != ""
    && !(lib.hasPrefix "/" target)
    && lib.all (part: part != ".." && part != "." && part != "") (lib.splitString "/" target)
    && !(lib.hasInfix "\n" target)
    && !(lib.hasInfix "\t" target)
    && target != ".metadata"
    && !(lib.hasPrefix ".metadata/" target);
  sourcePath =
    file:
    let
      source = toString file.source;
    in
    if builtins.hasContext source then
      file.source
    else
      builtins.path {
        path = file.source;
        name = lib.hm.strings.storeFileName (baseNameOf source);
      };
  manifest = pkgs.runCommand "home-manager-mutable-files" { } (
    ''
      mkdir -p "$out"
      touch "$out/.metadata"
    ''
    + lib.concatMapStrings (file: ''
      mkdir -p "$out"/${lib.escapeShellArg (dirOf file.target)}
      ln -s ${lib.escapeShellArg (sourcePath file)} "$out"/${lib.escapeShellArg file.target}
      printf '%s\t%s\n' ${
        lib.escapeShellArgs [
          file.target
          (if file.executable == null then "inherit" else lib.boolToString file.executable)
        ]
      } >> "$out/.metadata"
    '') mutableFiles
  );
  shellHelpers = ''
    mutableSafeParent() {
      local relativePath="$1" parent="$HOME" component
      local -a components
      case "/$relativePath/" in
        *'//'*|*'/../'*|*'/./'*)
          errorEcho "hm-mutable: refusing unsafe target $relativePath"
          return 1
          ;;
      esac
      IFS=/ read -r -a components <<< "$relativePath"
      for component in "''${components[@]:0:''${#components[@]}-1}"; do
        parent="$parent/$component"
        if [[ -L "$parent" ]]; then
          errorEcho "hm-mutable: refusing to write through symlink parent $parent"
          return 1
        fi
      done
    }
  '';
in
{
  options = {
    home.mutableFiles = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether managed files default to writable copies.";
    };
    home.mutableFilesCopyCommand = lib.mkOption {
      type = lib.types.enum [
        "cp"
        "rsync"
      ];
      default = "cp";
      description = "Tool used to copy mutable files during activation.";
    };
    home.file = lib.mkOption {
      type = fileType;
      apply = lib.mapAttrs (
        _: file:
        file
        // {
          _hmMutable = file.enable && isMutable file;
          enable = file.enable && !(isMutable file);
        }
      );
    };
    xdg = lib.genAttrs [ "configFile" "dataFile" "cacheFile" "stateFile" ] (
      _: lib.mkOption { type = fileType; }
    );
  };

  config = {
    assertions = [
      {
        assertion = lib.all (file: validTarget file.target) mutableFiles;
        message = "hm-mutable: mutable targets must be normalized paths inside the home directory, without tabs/newlines or the reserved name .metadata.";
      }
      {
        assertion =
          lib.length (lib.unique (map (file: file.target) managedFiles)) == lib.length managedFiles
          && lib.all (
            file:
            lib.all (
              other:
              !(lib.hasPrefix "${file.target}/" other.target) && !(lib.hasPrefix "${other.target}/" file.target)
            ) managedFiles
          ) mutableFiles;
        message = "hm-mutable: mutable targets must not overlap other managed targets.";
      }
    ];

    home.extraBuilderCommands = ''
      ln -s ${manifest} "$out/home-mutable-files"
    '';

    home.activation.mutableFilesCleanup =
      lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
        ''
          ${shellHelpers}
          if [[ -n "''${oldGenPath:-}" && -f "$oldGenPath/home-mutable-files/.metadata" ]]; then
            while IFS=$'\t' read -r relativePath executable; do
              [[ -n "$relativePath" ]] || continue
              if [[ ! -L ${manifest}/"$relativePath" ]]; then
                mutableSafeParent "$relativePath"
                run rm -rf -- "$HOME/$relativePath"
              fi
            done < "$oldGenPath/home-mutable-files/.metadata"
          fi
        '';

    home.activation.mutableFilesCopy =
      lib.hm.dag.entryBetween [ "onFilesChange" ] [ "linkGeneration" ]
        (
          ''
            ${shellHelpers}
          ''
          + lib.concatMapStrings (
            file:
            let
              target = ''"$HOME"/${lib.escapeShellArg file.target}'';
            in
            ''
              mutableSafeParent ${lib.escapeShellArg file.target}
              run mkdir -p -- "$(dirname -- ${target})"
              run rm -rf -- ${target}
              ${
                if config.home.mutableFilesCopyCommand == "rsync" then
                  ''
                    if [[ -d ${lib.escapeShellArg (sourcePath file)} ]]; then
                      run mkdir -p -- ${target}
                      run ${lib.getExe pkgs.rsync} -rLpt --chmod=Du+rwx,Fu+rw -- \
                        ${lib.escapeShellArg "${sourcePath file}/"} ${target}/
                    else
                      run ${lib.getExe pkgs.rsync} -rLpt --chmod=Fu+rw -- \
                        ${lib.escapeShellArg (sourcePath file)} ${target}
                    fi
                  ''
                else
                  ''
                    run cp -RL --preserve=mode -- ${lib.escapeShellArg (sourcePath file)} ${target}
                    run chmod -R u+w -- ${target}
                  ''
              }
              ${lib.optionalString (file.executable != null) ''
                if [[ ! -d ${lib.escapeShellArg (sourcePath file)} ]]; then
                  run chmod ${if file.executable then "+x" else "-x"} -- ${target}
                fi
              ''}
            ''
          ) mutableFiles
        );

    home.activation.mutableFilesOnChange =
      lib.hm.dag.entryBetween [ "onFilesChange" ] [ "mutableFilesCopy" ]
        (
          lib.concatMapStrings (
            file:
            lib.optionalString (file.onChange != "") ''
              if [[ ! -v DRY_RUN ]]; then
                ${file.onChange}
              fi
            ''
          ) mutableFiles
        );
  };
}
