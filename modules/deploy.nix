{ nixus, lib, config, ... }:
let
  inherit (lib) types;

  nodeOptions = ({ name, pkgs, config, ... }:
    let
      switch = pkgs.runCommandNoCC "switch" {
        inherit (config) switchTimeout successTimeout ignoreFailingSystemdUnits privilegeEscalationCommand;
        shell = pkgs.runtimeShell;
      } ''
        mkdir -p $out/bin
        substituteAll ${../scripts/switch} $out/bin/switch
        chmod +x $out/bin/switch
      '';
      system = config.configuration.system.build.toplevel;
    in {
    options = {
      deployScriptPhases = lib.mkOption {
        type = types.dagOf types.lines;
        default = {};
      };

      deployScript = lib.mkOption {
        type = types.package;
      };

      successTimeout = lib.mkOption {
        type = types.ints.unsigned;
        default = 20;
        description = ''
          How many seconds remote hosts should wait for the success
          confirmation before rolling back.
        '';
      };

      switchTimeout = lib.mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = ''
          How many seconds remote hosts should wait for the system activation
          command to finish before considering it failed.
        '';
      };

      ignoreFailingSystemdUnits = lib.mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether a system activation should be considered successful despite
          failing systemd units.
        '';
      };

      # TODO: What about different ssh ports? Some access abstraction perhaps?
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = name;
        example = "root@172.18.67.46";
        description = ''
          How to reach the host via ssh. Deploying is disabled if null. The
          username must either be root, or a user that is allowed to do
          passwordless privilege escalation. If no username is given, the one
          that runs the deploy script is used.
        '';
      };

      sshOpts = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "-o ControlPath=none -o BatchMode=yes";
      };

      hasFastConnection = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether there is a fast connection to this host. If true it will cause
          all derivations to be copied directly from the deployment host. If
          false, the substituters are used when possible instead.
        '';
      };

      closurePaths = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = ''
          Derivation paths to copy to the host while deploying
        '';
      };

    };

    config.closurePaths = [ system switch ];

    config.deployScriptPhases = {
      copy-closure = lib.dag.entryBefore ["switch"] ''
        echo "Copying closure to host..." >&2
        # TOOD: Prevent garbage collection until the end of the deploy
        tries=3
        while [ "$tries" -ne 0 ] &&
          ! NIX_SSH_OPTS="-o ServerAliveInterval=15" nix-copy-closure ${lib.optionalString (!config.hasFastConnection) "-s"} --to "$HOST" ${lib.escapeShellArgs config.closurePaths}; do
          tries=$(( $tries - 1 ))
          echo "Failed to copy closure, $tries tries left"
        done
      '';

      switch =
        let
          privilegeEscalation = builtins.concatStringsSep " " config.privilegeEscalationCommand;
        in lib.dag.entryAnywhere ''
        echo "Triggering system switcher..." >&2
        id=$(ssh ${config.sshOpts} "$HOST" exec "${switch}/bin/switch" start "${system}")

        echo "Trying to confirm success..." >&2
        active=1
        while [ "$active" != 0 ]; do
          # TODO: Because of the imperative network-setup script, when e.g. the
          # defaultGateway is removed, the previous entry is still persisted on
          # a rebuild switch, even though with a reboot it wouldn't. Maybe use
          # the more modern and declarative networkd to get around this
          set +e
          status=$(timeout --foreground 15 ssh ${config.sshOpts} "$HOST" exec "${switch}/bin/switch" active "$id")
          active=$?
          set -e
          sleep 1
        done

        case "$status" in
          "success")
            echo "Successfully activated new system!" >&2
            ;;
          "failure")
            echo "Failed to activate new system! Rolled back to previous one" >&2
            echo "Run the following command to see the logs for the switch:" >&2
            echo "ssh ''${HOST@Q} ${privilegeEscalation} cat /var/lib/system-switcher/system-$id/log" >&2
            # TODO: Try to better show what failed
            ;;
          *)
            echo "This shouldn't occur, the status is $status!" >&2
            ;;
        esac
      '';
    };

    config.deployScript =
      let
        sortedScripts = (lib.dag.topoSort config.deployScriptPhases).result or (throw "Cycle in DAG for deployScriptPhases");
      in
      nixus.pkgs.writeShellScript "deploy-${name}" (''
        PATH=${lib.makeBinPath
          (with nixus.pkgs; [
            # Without bash being here deployments to localhost do not work. The
            # reason for that is not yet known. Reported in #6.
            bash
            coreutils
            findutils
            gnused
            jq
            openssh
            procps
            rsync
          ])}''${PATH:+:$PATH}

        set -euo pipefail

        # Kill all child processes when interrupting/exiting
        trap exit INT TERM
        trap 'for pid in $(jobs -p) ; do kill -- -$pid ; done' EXIT
        # Be sure to use --foreground for all timeouts, therwise a Ctrl-C won't stop them!
        # See https://unix.stackexchange.com/a/233685/214651

        # Prefix all output with host name
        # From https://unix.stackexchange.com/a/440439/214651
        exec > >(sed "s/^/[${name}] /")
        exec 2> >(sed "s/^/[${name}] /" >&2)
      '' + (if config.host == null then ''
        echo "Don't know how to reach node, you need to set a non-null value for nodes.\"$HOSTNAME\".host" >&2
        exit 1
      '' else ''
        HOST=${config.host}

        echo "Connecting to host..." >&2

        if ! OLDSYSTEM=$(timeout --foreground 30 \
            ssh ${config.sshOpts} "$HOST" realpath /run/current-system\
          ); then
          echo "Unable to connect to host!" >&2
          exit 1
        fi

        if [ "$OLDSYSTEM" == "${system}" ]; then
          echo "No deploy necessary" >&2
          #exit 0
        fi

        ${lib.concatMapStringsSep "\n\n" ({ name, data }: ''
          # ======== PHASE: ${name} ========
          ${data}
        '') sortedScripts}

        echo "Finished" >&2
      ''));
    });

in {

  options = {
    defaults = lib.mkOption {
      type = lib.types.submodule nodeOptions;
    };

    deployScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
    };
  };

  # TODO: What about requiring either all nodes to succeed or all get rolled back?
  config.deployScript =
    # TODO: Handle signals to kill the async command
    nixus.pkgs.writeScript "deploy" ''
      #!${nixus.pkgs.runtimeShell}
      ${lib.concatMapStrings (node: lib.optionalString node.enabled ''

        ${node.deployScript} &
      '') (lib.attrValues config.nodes)}
      wait
    '';

}
