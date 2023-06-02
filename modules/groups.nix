{ config, lib, nixus, ... }:

let
  inherit (lib) types;

  # we need to reference the global configuration in our submodule.
  gconfig = config;

  groupOpts = { config, ... }: {
    options = {
      deployScript = lib.mkOption {
        type = types.package;
        readOnly = true;
      };

      members = lib.mkOption {
        type = types.listOf types.str;
        default = [];
      };
    };

    config.deployScript = let
      mkDeployScript = members: nixus.pkgs.writeShellScript "deploy" ''
        ${lib.concatMapStrings (nodeName: lib.optionalString gconfig.nodes.${nodeName}.enabled ''

          ${gconfig.nodes.${nodeName}.deployScript} &
        '') config.members}
        wait
      '';
    in mkDeployScript config.members;
  };
in {
  options = {
    groups = lib.mkOption {
      type = types.attrsOf (types.submodule groupOpts);
      default = {};
      description = ''
        Allows creating groups of nodes for deploying them together, instead of deploying all nodes.
        Building the script for deploying can be done like `nix-build -A config.groups.home.deployScript`
     '';
      example = {
        servers = [
          "vps-web"
          "vps-web2"
          "vps-db"
        ];
        home = [
          "eos"
          "server1"
          "router"
        ];
      };
    };
  };
}
