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

  # Build a NetworkManager keyfile from the networkConfig submodule, then
  # package it into an ISO 9660 image (volume label "CONFIG") that HAOS reads
  # on boot to configure the guest network interface.
  mkNetworkConfigISO = nc:
    let
      keyfileContent =
        if nc.enableDHCP then
          "[connection]\nid=haos-network\ntype=ethernet\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=disabled\n"
        else
          "[connection]\nid=haos-network\ntype=ethernet\n\n[ipv4]\nmethod=manual\n"
          + lib.optionalString (nc.staticIP != null) (
            "address1="
            + nc.staticIP
            + "/"
            + toString nc.prefixLength
            + lib.optionalString (nc.gateway != null) ("," + nc.gateway)
            + "\n"
          )
          + lib.optionalString (nc.dns != [ ]) ("dns=" + lib.concatStringsSep ";" nc.dns + ";\n")
          + "\n[ipv6]\nmethod=disabled\n";
      keyfile = pkgs.writeText "haos-network-keyfile" keyfileContent;
    in
    pkgs.runCommand "haos-network-config-iso"
      {
        nativeBuildInputs = [ pkgs.xorriso ];
      }
      ''
        mkdir -p config/network
        cp ${keyfile} config/network/haos-network
        xorriso -as mkisofs \
          -volid CONFIG \
          -o "$out" \
          config/
      '';

  # Shell fragment that adds the CONFIG drive disk argument to virt-install
  # when networkConfig is set.  The trailing backslash + newline + indentation
  # lets it fit naturally inside the multi-line virt-install invocation.
  # Use if-then-else (not lib.optionalString) so mkNetworkConfigISO is only
  # called when networkConfig is actually set.
  networkDiskArg =
    if cfg.networkConfig != null then
      "--disk ${mkNetworkConfigISO cfg.networkConfig},device=cdrom,readonly=yes \\\n          "
    else
      "";
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

    networkConfig = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enableDHCP = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable DHCP on the primary network interface of the guest.";
          };

          staticIP = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.1.50";
            description = ''
              Static IPv4 address for the guest (e.g. "192.168.1.50").
              Only used when enableDHCP is false.
            '';
          };

          prefixLength = lib.mkOption {
            type = lib.types.int;
            default = 24;
            description = "Network prefix length for the static IP address. Only used when enableDHCP is false.";
          };

          gateway = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.1.1";
            description = "Default gateway address. Only used when enableDHCP is false.";
          };

          dns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "1.1.1.1" "8.8.8.8" ];
            description = "List of DNS server addresses to use in the NetworkManager keyfile. Only applied when enableDHCP is false.";
          };
        };
      });
      default = null;
      description = ''
        Guest network configuration.  When set, a CONFIG drive ISO is created
        containing a NetworkManager keyfile and attached to the guest VM.
        Home Assistant OS reads this drive on boot and applies the network
        settings, allowing the guest to obtain an IP address automatically.

        Set to null (the default) to skip network configuration injection.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.optional (
      cfg.networkConfig != null && !cfg.networkConfig.enableDHCP && cfg.networkConfig.staticIP == null
    ) {
      assertion = false;
      message = "services.haos.guest.networkConfig: staticIP must be set when enableDHCP is false.";
    };

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
          ${networkDiskArg}--noautoconsole
        echo "VM '${cfg.name}' created successfully."
      '';
    };
  };
}
