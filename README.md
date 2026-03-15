# haos-flake

NixOS modules for running [Home Assistant OS](https://www.home-assistant.io/installation/) as a libvirt/KVM guest VM.

The modules configure the host hypervisor (libvirtd with OVMF/UEFI), set up a
bridged network so the VM sits on the local network, automatically install the
guest VM, and provide a helper script to attach USB devices (e.g. Zigbee/Z-Wave
sticks).

## Quick start (flakes)

Add the flake as an input in your NixOS configuration:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    haos-flake.url = "github:Kex1016/haos-flake";
  };

  outputs = { nixpkgs, haos-flake, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        haos-flake.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then enable the services in your `configuration.nix`:

```nix
# configuration.nix
{ ... }:
{
  services.haos = {
    enable = true;
    user = "myme"; # user that should have access to libvirtd
  };

  services.haos.networking = {
    enable = true;
    physicalInterface = "eno1";
    address = "10.0.0.5";
    prefixLength = 24;
    defaultGateway = "10.0.0.1";
  };
}
```

## Non-flake usage

```nix
# configuration.nix
{ ... }:
{
  imports = [
    (import /path/to/haos-flake)
  ];

  services.haos.enable = true;
  services.haos.networking.enable = true;
}
```

## Modules

| Module | Description |
|---|---|
| `host.nix` | Enables libvirtd with OVMF, installs virt-manager and usbutils |
| `networking.nix` | Configures a bridge interface (`br0`) for the guest VM |
| `guest.nix` | Installs the HAOS guest VM automatically via a systemd service |
| `usb.nix` | Provides a `haos-attach-usb` script to pass USB devices into the guest |

## Guest VM creation

Enable the guest module to create the HAOS VM.  By default the latest
Home Assistant OS qcow2 image is fetched automatically (the version
tracked in `image.json`), so you don't need to download it manually.

When the module is enabled, a systemd service (`haos-install-guest`)
automatically creates the guest VM on first boot.  If the VM already exists
the service is a no-op.

```nix
services.haos.guest = {
  enable = true;
  memoryMB = 2048;
  vcpus = 2;
  diskSizeGB = 32;
};
```

To use your own image file instead, set `imagePath`:

```nix
services.haos.guest = {
  enable = true;
  imagePath = "/var/lib/libvirt/images/haos_ova-12.4.qcow2";
};
```

### Automatic image updates

A GitHub Actions workflow runs daily and checks the
[home-assistant/operating-system](https://github.com/home-assistant/operating-system/releases)
releases for a new version.  When a new release is found it opens a pull
request that updates `image.json` with the new URL and SHA-256 hash.

## USB passthrough

```nix
services.haos.usb = {
  enable = true;
  devices = [
    { vendorId = "0x1cf1"; productId = "0x0030"; } # ConBee II
  ];
};
```

Attach devices to the running VM:

```bash
sudo haos-attach-usb
```