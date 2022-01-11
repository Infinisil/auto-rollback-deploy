{ config, nodes, lib, ... }:

let
  primaryNode = config.prometheus.primaryNode;
  wireguardPort = config.prometheus.wireguardPort;
  endpoint = "${config.prometheus.wireguardListenOn}:${toString config.prometheus.wireguardPort}";

  # all the nodes that should connect using wireguard
  nodes = builtins.filter (node: node.isLocal == false) (lib.mapAttrsToList (_: v: v) config.prometheus.nodes);
  
  # helpers
  mkWireguardPeer = {
      publicKey
    , allowedIPs
    , presharedKeyFile ? null
    }: (
      {
        allowedIPs = allowedIPs;
        publicKey = publicKey;
        # add presharedkey if specified
      } // (if presharedKeyFile != null then { presharedKeyFile = presharedKeyFile; } else {})
  );

  # just a little shorthand for making secrets easier, doesn't really
  # add much "easy" to it, as we have a lot of helper functions
  mkSecrets = secrets: lib.mapAttrs (n: v: { file = v; }) secrets;

  mkPeerConfig = node: { config, ... }: {
      # secrets
      secrets.files = mkSecrets {
        "wg-${node.name}-privatekey" = node.wgPrivateKey;
        "wg-${node.name}-preshared" = node.wgPresharedKey;
      };

      networking.wireguard = {
        enable = true;

        interfaces.wgprom = {
          ips = [ node.ips ];

          privateKeyFile = "${toString config.secrets.files."wg-${node.name}-privatekey".file}";

          peers = [
            {
              allowedIPs = [ primaryNode.ip ];
              endpoint = endpoint;
              persistentKeepalive = 25;
              publicKey = lib.strings.fileContents primaryNode.wgPublicKey;
              presharedKeyFile = "${toString config.secrets.files."wg-${node.name}-preshared".file}";
            }
          ];
        };
      };
    };
in {
  nodes = {
    # server config
    "${primaryNode.name}".configuration = { config, ... }: {
      # make secrets
      secrets.files = mkSecrets (
        (builtins.listToAttrs (
          lib.forEach nodes (node: { name = "wg-${node.name}-preshared"; value = node.wgPresharedKey; })
        )) // {
          "wg-${primaryNode.name}-privatekey" = primaryNode.wgPrivateKey;
        }
      );

      networking.wireguard = {
        enable = true;

        interfaces.wgprom = {
          ips = [ primaryNode.ip ];
          privateKeyFile = "${toString config.secrets.files."wg-${primaryNode.name}-privatekey".file}";
          listenPort = wireguardPort;

          # add all our peers from nodes
          peers = let
            peerConfigs = lib.forEach nodes (node: mkWireguardPeer {
              allowedIPs = [ node.ips ];
              publicKey = lib.strings.fileContents node.wgPublicKey;
              presharedKeyFile = "${toString config.secrets.files."wg-${node.name}-preshared".file}";
            });
          in peerConfigs;
        };
      };
    };
    # peer configs
  } // (lib.listToAttrs (lib.forEach nodes (node: lib.nameValuePair node.name { configuration = (mkPeerConfig node); } )));
}
