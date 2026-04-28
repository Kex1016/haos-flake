{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.haos.usb;
in
{
  options.services.haos.usb = {
    enable = lib.mkEnableOption "USB passthrough for HAOS guest";

    devices = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            vendorId = lib.mkOption {
              type = lib.types.str;
              description = "USB vendor ID (e.g. '0x1234').";
            };
            productId = lib.mkOption {
              type = lib.types.str;
              description = "USB product ID (e.g. '0x5678').";
            };
          };
        }
      );
      default = [ ];
      description = "List of USB devices to pass through to the guest VM.";
    };

    guestName = lib.mkOption {
      type = lib.types.str;
      default = config.services.haos.guest.name or "haos";
      description = "Name of the libvirt guest domain to attach USB devices to.";
    };

    automount = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically attach USB devices to the VM on startup.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.devices != [ ]) (
    let
      attachScript = pkgs.writeShellScriptBin "haos-attach-usb" ''
        set -euo pipefail
        # Wait for the VM to exist (created by haos-install-guest)
        if ! virsh dominfo "${cfg.guestName}" >/dev/null 2>&1; then
          echo "VM '${cfg.guestName}' does not exist, cannot autostart." >&2
          exit 1
        fi
        # Wait for the VM to start [blocking loop]
        while ! virsh domstate "${cfg.guestName}" | grep -q "running"; do
          echo "Waiting for VM '${cfg.guestName}' to start..."
          sleep 1
        done
        # Sleep for 5 seconds to wait for the VM to initialize its USB controller
        sleep 5
        ${lib.concatMapStringsSep "\n" (dev: ''
            echo "Attaching USB device ${dev.vendorId}:${dev.productId} to ${cfg.guestName}..."
            ${pkgs.libvirt}/bin/virsh attach-device "${cfg.guestName}" /dev/stdin <<'XML'
            <hostdev mode='subsystem' type='usb'>
              <source>
                <vendor id='${dev.vendorId}'/>
                <product id='${dev.productId}'/>
              </source>
            </hostdev>
          XML
        '') cfg.devices}
        echo "All USB devices attached."
      '';
    in
    {
      environment.systemPackages = [ attachScript ];

      systemd.services.haos-automount = lib.mkIf cfg.automount.enable {
        description = "Attach USB devices to HAOS guest";
        after = [
          "haos-autostart.service"
          "libvirtd.service"
        ];
        wants = [ "haos-autostart.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.libvirt ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          sleep 5
          ${attachScript}/bin/haos-attach-usb
        '';
      };
    }
  );
}
