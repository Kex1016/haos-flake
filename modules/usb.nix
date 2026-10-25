{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.haos.usb;

  # lsusb and udev print ids without the 0x prefix
  bareId = id: lib.removePrefix "0x" (lib.toLower id);
  lsusbId = dev: "${bareId dev.vendorId}:${bareId dev.productId}";
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

    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        How long to wait at boot for the USB devices to appear before starting
        the VM anyway. Missing devices never prevent the VM from starting.
        Set to 0 to not wait at all.
      '';
    };

    automount = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically attach USB devices to the VM on startup.";
      };
    };

    hotplug = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        defaultText = lib.literalExpression "config.services.haos.usb.enable";
        description = ''
          Attach the devices to the running VM when they are plugged in, and
          detach them when they are unplugged, using udev rules.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.devices != [ ]) (
    let
      # haos-usb attach|detach <vendor-id> <product-id>
      # Idempotent, and a no-op while the VM is not running. Attaching also
      # adds the device to the persistent definition with an optional startup
      # policy, so it comes back after a restart but never blocks one.
      usbScript = pkgs.writeShellScriptBin "haos-usb" ''
        set -euo pipefail
        PATH=${
          lib.makeBinPath [
            pkgs.libvirt
            pkgs.gnugrep
          ]
        }:$PATH
        dom="${cfg.guestName}"

        if [ $# -ne 3 ]; then
          echo "Usage: haos-usb attach|detach <vendor-id> <product-id>" >&2
          exit 2
        fi
        action=$1
        vendor=''${2#0x}
        vendor=''${vendor,,}
        product=''${3#0x}
        product=''${product,,}

        hostdev="<hostdev mode='subsystem' type='usb'>
          <source startupPolicy='optional'>
            <vendor id='0x$vendor'/>
            <product id='0x$product'/>
          </source>
        </hostdev>"

        # True if the domain XML given as $1 contains the device
        has_device() {
          grep -A1 "<vendor id='0x$vendor'/>" <<<"$1" | grep "<product id='0x$product'/>" >/dev/null
        }

        if ! virsh dominfo "$dom" >/dev/null 2>&1; then
          echo "VM '$dom' does not exist, skipping $vendor:$product."
          exit 0
        fi
        running=false
        if [ "$(virsh domstate "$dom")" = "running" ]; then
          running=true
        fi

        case "$action" in
          attach)
            if ! has_device "$(virsh dumpxml --inactive "$dom")"; then
              echo "Adding USB device $vendor:$product to the '$dom' definition..."
              virsh attach-device "$dom" /dev/stdin --config <<<"$hostdev"
            fi
            if ! $running; then
              echo "VM '$dom' is not running, $vendor:$product will be attached when it starts."
            elif has_device "$(virsh dumpxml "$dom")"; then
              echo "USB device $vendor:$product is already attached to '$dom'."
            else
              echo "Attaching USB device $vendor:$product to '$dom'..."
              virsh attach-device "$dom" /dev/stdin --live <<<"$hostdev"
            fi
            ;;
          detach)
            if $running && has_device "$(virsh dumpxml "$dom")"; then
              echo "Detaching USB device $vendor:$product from '$dom'..."
              virsh detach-device "$dom" /dev/stdin --live <<<"$hostdev" ||
                echo "USB device $vendor:$product was already gone."
            fi
            ;;
          *)
            echo "Usage: haos-usb attach|detach <vendor-id> <product-id>" >&2
            exit 2
            ;;
        esac
      '';

      attachScript = pkgs.writeShellScriptBin "haos-attach-usb" ''
        set -euo pipefail
        ${lib.concatMapStringsSep "\n" (
          dev: "${usbScript}/bin/haos-usb attach ${bareId dev.vendorId} ${bareId dev.productId}"
        ) cfg.devices}
      '';

      waitForUsbScript = pkgs.writeShellScriptBin "haos-wait-for-usb" ''
        set -euo pipefail
        deadline=$((SECONDS + ${toString cfg.waitTimeoutSeconds}))

        for id in ${lib.concatMapStringsSep " " lsusbId cfg.devices}; do
          until ${pkgs.usbutils}/bin/lsusb -d "$id" >/dev/null; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "Warning: USB device $id not found, continuing without it." >&2
              continue 2
            fi
            echo "Waiting for USB device $id to be available..."
            sleep 1
          done
          echo "USB device $id is available."
        done
      '';
    in
    {
      environment.systemPackages = [
        usbScript
        attachScript
        waitForUsbScript
      ];

      # Wait for the USB devices before haos-autostart starts the VM
      systemd.services.haos-autostart =
        lib.mkIf (cfg.automount.enable && config.services.haos.guest.enable or false)
          {
            after = [ "systemd-udev-settle.service" ];
            preStart = "${waitForUsbScript}/bin/haos-wait-for-usb";
          };

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

      # Instances are named <vendor-id>-<product-id>, e.g. 10c4-ea60
      systemd.services."haos-usb-attach@" = lib.mkIf cfg.hotplug.enable {
        description = "Attach USB device %i to HAOS guest";
        after = [ "libvirtd.service" ];
        serviceConfig.Type = "oneshot";
        scriptArgs = "%i";
        script = ''
          ${usbScript}/bin/haos-usb attach "''${1%-*}" "''${1#*-}"
        '';
      };

      systemd.services."haos-usb-detach@" = lib.mkIf cfg.hotplug.enable {
        description = "Detach USB device %i from HAOS guest";
        after = [ "libvirtd.service" ];
        serviceConfig.Type = "oneshot";
        scriptArgs = "%i";
        script = ''
          ${usbScript}/bin/haos-usb detach "''${1%-*}" "''${1#*-}"
        '';
      };

      # SYSTEMD_WANTS only acts on add, so removal starts its unit directly.
      # libvirt handles the /dev/bus/usb permissions itself.
      services.udev.extraRules = lib.mkIf cfg.hotplug.enable (
        lib.concatMapStrings (
          dev:
          let
            match = ''SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_VENDOR_ID}=="${bareId dev.vendorId}", ENV{ID_MODEL_ID}=="${bareId dev.productId}"'';
            instance = "${bareId dev.vendorId}-${bareId dev.productId}";
          in
          ''
            ACTION=="add", ${match}, TAG+="systemd", ENV{SYSTEMD_WANTS}+="haos-usb-attach@${instance}.service"
            ACTION=="remove", ${match}, RUN+="${config.systemd.package}/bin/systemctl --no-block start haos-usb-detach@${instance}.service"
          ''
        ) cfg.devices
      );
    }
  );
}
