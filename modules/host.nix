# Host configuration for running Home Assistant OS as a libvirt/KVM guest.
#
# Enables the libvirtd daemon with OVMF (UEFI) support and installs the
# tools needed to create and manage guest VMs from the command line.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.haos;
in
{
  options.services.haos = {
    enable = lib.mkEnableOption "Home Assistant OS libvirt host";

    user = lib.mkOption {
      type = lib.types.str;
      default = "haos";
      description = "User account that should have access to libvirtd.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd = {
      enable = true;
      qemu.ovmf.enable = true;
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
