{ config, lib, nixus, ... }:

let
  inherit (lib) types;

  # we need to reference the global configuration
  # in our submodule.
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
      mkDeployScript = members: nixus.pkgs.writeScript "deploy" ''
        #!${nixus.pkgs.runtimeShell}
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
    };
  };
}
