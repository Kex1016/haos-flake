{ config, lib, ... }:

let
  cfg = config.services.haos.networking;
in
{
  options.services.haos.networking = {
    enable = lib.mkEnableOption "HAOS bridged network";

    physicalInterface = lib.mkOption {
      type = lib.types.str;
      default = "eno1";
      description = "Physical network interface to attach to the bridge.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.5";
      description = "Static IPv4 address for the bridge interface.";
    };

    prefixLength = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "Network prefix length for the bridge interface.";
    };

    defaultGateway = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.1";
      description = "Default gateway address.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.defaultGateway = cfg.defaultGateway;

    networking.bridges.br0.interfaces = [ cfg.physicalInterface ];

    networking.interfaces.br0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = cfg.address;
          prefixLength = cfg.prefixLength;
        }
      ];
    };
  };
}
