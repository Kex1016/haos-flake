{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.haos.guest;

  imageInfo = builtins.fromJSON (builtins.readFile ../image.json);

  fetchedImage =
    pkgs.runCommand "haos-image-${imageInfo.version}"
      {
        src = pkgs.fetchurl {
          url = imageInfo.url;
          sha256 = imageInfo.sha256;
        };
        nativeBuildInputs = [ pkgs.xz ];
      }
      ''
        xz -d -k "$src" -c > "$out"
      '';
in
{
  options.services.haos.guest = {
    enable = lib.mkEnableOption "HAOS guest VM";

    name = lib.mkOption {
      type = lib.types.str;
      default = "haos";
      description = "Name of the libvirt guest domain.";
    };

    vcpus = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Number of virtual CPUs to allocate.";
    };

    memoryMB = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Amount of memory (in MB) to allocate.";
    };

    diskSizeGB = lib.mkOption {
      type = lib.types.int;
      default = 32;
      description = "Disk size (in GB) for the guest VM.";
    };

    diskPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/libvirt/images/haos.qcow2";
      description = "Path to the guest disk image.";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "br0";
      description = "Network bridge the guest should be connected to.";
    };

    imagePath = lib.mkOption {
      type = lib.types.str;
      default = "${fetchedImage}";
      defaultText = lib.literalExpression ''"''${fetchedImage}"'';
      description = ''
        Path to the Home Assistant OS qcow2 image.
        Defaults to an automatically fetched image (version ${imageInfo.version}).
        Set this to a local file path to use your own image instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.haos-install-guest = {
      description = "Create Home Assistant OS guest VM";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.libvirt
        pkgs.qemu
        pkgs.virt-manager
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        # Skip if the VM already exists
        if virsh dominfo "${cfg.name}" >/dev/null 2>&1; then
          echo "VM '${cfg.name}' already exists, skipping creation."
          exit 0
        fi

        if [ ! -f "${cfg.imagePath}" ]; then
          echo "Error: HAOS image not found at ${cfg.imagePath}" >&2
          exit 1
        fi

        # Copy the downloaded image to the libvirt images directory
        if [ ! -f "${cfg.diskPath}" ]; then
          destdir="$(dirname "${cfg.diskPath}")"
          if [ ! -d "$destdir" ]; then
            echo "Error: destination directory $destdir does not exist" >&2
            exit 1
          fi
          echo "Copying HAOS image to ${cfg.diskPath}..."
          cp "${cfg.imagePath}" "${cfg.diskPath}"
          qemu-img resize "${cfg.diskPath}" ${toString cfg.diskSizeGB}G
        fi

        echo "Creating HAOS guest VM '${cfg.name}'..."
        virt-install \
          --name "${cfg.name}" \
          --memory ${toString cfg.memoryMB} \
          --vcpus ${toString cfg.vcpus} \
          --disk "${cfg.diskPath}",format=qcow2 \
          --import \
          --os-variant generic \
          --network bridge=${cfg.bridge},model=virtio \
          --boot uefi \
          --graphics none \
          --noautoconsole
        echo "VM '${cfg.name}' created successfully."
      '';
    };

    # VM autostart service
    systemd.services.haos-autostart = {
      description = "Autostart Home Assistant OS guest VM";
      after = [
        "libvirtd.service"
        "haos-install-guest.service"
      ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.libvirt ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        # Wait for the VM to exist (created by haos-install-guest)
        if ! virsh dominfo "${cfg.name}" >/dev/null 2>&1; then
          echo "VM '${cfg.name}' does not exist, cannot autostart." >&2
          exit 1
        fi

        # Check if already running
        state=$(virsh domstate "${cfg.name}" 2>/dev/null || echo "unknown")
        if [ "$state" = "running" ]; then
          echo "VM '${cfg.name}' is already running."
          exit 0
        fi

        echo "Starting VM '${cfg.name}'..."
        virsh start "${cfg.name}"
        echo "VM '${cfg.name}' started successfully."
      '';
    };

  };
}
