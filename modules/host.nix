# Host configuration for running Home Assistant OS as a libvirt/KVM guest.
#
# Enables the libvirtd daemon with OVMF (UEFI) support and installs the
# tools needed to create and manage guest VMs from the command line.

{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.services.haos;
  hasShutdownTimeout = options.virtualisation.libvirtd ? shutdownTimeout;
in
{
  options.services.haos = {
    enable = lib.mkEnableOption "Home Assistant OS libvirt host";

    user = lib.mkOption {
      type = lib.types.str;
      default = "haos";
      description = "User account that should have access to libvirtd.";
    };

    shutdownTimeout = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Seconds to wait for guests to shut down when the host stops.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd =
      {
        enable = true;
        # Shut guests down instead of saving their state, so a stale managed
        # save image can never block the next start. Starting is handled by
        # the haos-autostart service, not libvirt-guests.
        onBoot = "ignore";
        onShutdown = "shutdown";
      }
      # shutdownTimeout only exists on newer nixpkgs; older releases read the
      # same variable from the libvirt-guests environment.
      // lib.optionalAttrs hasShutdownTimeout { shutdownTimeout = cfg.shutdownTimeout; };

    systemd.services.libvirt-guests.environment = lib.optionalAttrs (!hasShutdownTimeout) {
      SHUTDOWN_TIMEOUT = toString cfg.shutdownTimeout;
    };

    environment.systemPackages = with pkgs; [
      virt-manager
      usbutils
    ];

    users.users.${cfg.user} = {
      extraGroups = [ "libvirtd" ];
    };
  };
}
