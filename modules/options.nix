{ nixus, options, config, lib, ... }:
let
  inherit (lib) types;

  extraConfig = { pkgs, lib, config, ... }: {
    # Export the pkgs arg because we use it outside the module
    # See https://github.com/NixOS/nixpkgs/pull/82751 why that's necessary
    options._pkgs = lib.mkOption {
      readOnly = true;
      internal = true;
      default = pkgs;
    };

    config.systemd.services = lib.mkIf (!config.services.openssh.startWhenNeeded) {
      # By default the sshd service doesn't stop when changed so you don't lose connection to it when misconfigured
      # But in Nixus we want to detect a misconfiguration since we can rollback in that case
      sshd.stopIfChanged = lib.mkForce true;
    };
  };

  # Legacy, relies on NixOS internals, makes nixus work with nixpkgs versions
  # before https://github.com/NixOS/nixpkgs/pull/143207
  pkgsModule = nixpkgs: { lib, config, ... }: {
    config.nixpkgs.system = lib.mkDefault nixus.pkgs.system;
    # Not using nixpkgs.pkgs because that would apply the overlays again
    config._module.args.pkgs = lib.mkDefault (import nixpkgs {
      inherit (config.nixpkgs) config overlays localSystem crossSystem;
    });
  };

  topconfig = config;

  nodeOptions = { name, config, ... }: {

    options = {

      nixpkgs = lib.mkOption {
        type = lib.types.path;
        example = lib.literalExample ''
          fetchTarball {
            url = "https://github.com/NixOS/nixpkgs/tarball/a06925d8c608d7ba1d4297dc996c187c37c6b7e9";
            sha256 = "0xy6rimd300j5bdqmzizs6l71x1n06pfimbim1952fyjk8a3q4pr";
          }
        '';
        description = ''
          The path to the nixpkgs version to use for this host.
        '';
      };

      configuration = lib.mkOption {
        type =
          let
            baseModules = import (config.nixpkgs + "/nixos/modules/module-list.nix");
            legacy = types.submoduleWith {
              specialArgs = {
                lib = nixus.extendLib (import (config.nixpkgs + "/lib"));
                nodes = lib.mapAttrs (name: value: value.configuration) topconfig.nodes;
                inherit name baseModules;
                modulesPath = config.nixpkgs + "/nixos/modules";
              };
              modules = baseModules ++ [ (pkgsModule config.nixpkgs) extraConfig ];
            };
            evalConfig = import (config.nixpkgs + "/nixos/lib/eval-config.nix") {
              system = nixus.pkgs.system;
              specialArgs.lib = nixus.extendLib (import (config.nixpkgs + "/lib"));
              modules = [
                extraConfig
                {
                  _module.args = {
                    nodes = lib.mapAttrs (name: value: value.configuration) topconfig.nodes;
                    inherit name;
                  };
                }
              ];
            };
          in evalConfig.type or legacy;
        default = {};
        example = lib.literalExample ''
          {
            imports = [ ./hardware-configuration.nix ];
            boot.loader.grub.device = "/dev/sda";
            networking.hostName = "test";
          }
        '';
        description = ''
          The NixOS configuration for this host.
        '';
      };

      privilegeEscalationCommand = lib.mkOption {
        type = types.listOf types.str;
        default = [ "sudo" ];
        example = lib.literalExample ''[ "doas" ]'';
        description = ''
          The command to use for privilege escalation.
        '';
      };

    };

    config = {
      _module.args.pkgs = config.configuration._pkgs;
    };
  };

in {

  options = {
    defaults = lib.mkOption {
      type = lib.types.submodule nodeOptions;
      example = lib.literalExample ''
        { name, ... }: {
          networking.hostName = name;
        }
      '';
      description = ''
        Configuration to apply to all nodes.
      '';
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule (options.defaults.type.functor.payload.modules ++ options.defaults.definitions));
      description = "nodes";
    };

  };
}
