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

      waitForUsbScript = pkgs.writeShellScriptBin "haos-wait-for-usb" ''
        set -euo pipefail
        max_attempts=60
        attempt=0

        ${lib.concatMapStringsSep "\n" (dev: ''
          while [ $attempt -lt $max_attempts ]; do
            if lsusb | grep -q "${dev.vendorId}:${dev.productId}"; then
              echo "USB device ${dev.vendorId}:${dev.productId} is available."
              break
            fi
            echo "Waiting for USB device ${dev.vendorId}:${dev.productId} to be available..."
            sleep 1
            ((attempt++))
          done

          if [ $attempt -ge $max_attempts ]; then
            echo "Timeout waiting for USB device ${dev.vendorId}:${dev.productId}" >&2
            exit 1
          fi
          attempt=0
        '') cfg.devices}

        echo "All USB devices are available."
      '';
    in
    {
      environment.systemPackages = [
        attachScript
        waitForUsbScript
      ];

      # Only create autostart-with-usb service when automount is enabled
      systemd.services.haos-autostart-with-usb = lib.mkIf cfg.automount.enable {
        description = "Wait for USB devices, then autostart Home Assistant OS guest VM";
        after = [
          "libvirtd.service"
          "haos-install-guest.service"
          "systemd-udev-settle.service"
        ];
        requires = [ "libvirtd.service" ];
        wantedBy = [ "multi-user.target" ];

        path = [ pkgs.libvirt pkgs.usbutils ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -euo pipefail

          # Wait for the VM to exist (created by haos-install-guest)
          if ! virsh dominfo "${cfg.guestName}" >/dev/null 2>&1; then
            echo "VM '${cfg.guestName}' does not exist, cannot autostart." >&2
            exit 1
          fi

          # Check if already running
          state=$(virsh domstate "${cfg.guestName}" 2>/dev/null || echo "unknown")
          if [ "$state" = "running" ]; then
            echo "VM '${cfg.guestName}' is already running."
            exit 0
          fi

          # Wait for USB devices to be available
          echo "Waiting for USB devices to be available..."
          ${waitForUsbScript}/bin/haos-wait-for-usb

          # Start the VM
          echo "Starting VM '${cfg.guestName}'..."
          virsh start "${cfg.guestName}"
          echo "VM '${cfg.guestName}' started successfully."
        '';
      };

      systemd.services.haos-automount = lib.mkIf cfg.automount.enable {
        description = "Attach USB devices to HAOS guest";
        after = [
          "haos-autostart-with-usb.service"
          "libvirtd.service"
        ];
        wants = [ "haos-autostart-with-usb.service" ];
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
