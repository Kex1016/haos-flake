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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
| `guest.nix` | Installs the HAOS guest VM and starts it on boot via systemd services |
| `usb.nix` | Passes USB devices into the guest, with hotplug support |

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

### Boot and shutdown

The `haos-autostart` service starts the VM on every boot. libvirt's own
autostart is switched off for the guest so the two never race, and the
service retries every 10 seconds if the start fails.

On host shutdown or reboot the guest gets an ACPI shutdown instead of having
its memory saved to disk (`virtualisation.libvirtd.onShutdown = "shutdown"`).
A saved image from an older QEMU or OVMF could otherwise fail to restore and
keep the VM from starting. Any leftover image is removed before each start.

```nix
services.haos.shutdownTimeout = 120; # seconds to wait for the guest to stop
```

## USB passthrough

```nix
services.haos.usb = {
  enable = true;
  automount.enable = true;
  devices = [
    { vendorId = "0x1cf1"; productId = "0x0030"; } # ConBee II
  ];
};
```

| Option | Default | Description |
|---|---|---|
| `automount.enable` | `false` | Wait for the devices at boot, then attach them once the VM runs |
| `waitTimeoutSeconds` | `30` | How long boot waits for the devices; `0` does not wait. A missing device never stops the VM from starting |
| `hotplug.enable` | same as `enable` | Attach devices when they are plugged in and detach them when unplugged |

Attached devices are also added to the VM definition with
`startupPolicy='optional'`, so they are passed through again after a restart,
and a missing device does not block the start.

Hotplug uses a udev rule per device that starts `haos-usb-attach@<vid>-<pid>`
on plug and `haos-usb-detach@<vid>-<pid>` on unplug. libvirt sets the
`/dev/bus/usb` permissions itself, so no extra udev `MODE` is needed.

Attach all configured devices by hand (safe to run more than once):

```bash
sudo haos-attach-usb
```

Or a single device:

```bash
sudo haos-usb attach 1cf1 0030
sudo haos-usb detach 1cf1 0030
```

## Migrating an existing VM

The module never recreates an existing VM, so a guest created before these
changes needs two one-off steps.

1. Remove a managed save image left from the old suspend-on-shutdown
   behaviour, if the VM fails to start:

   ```bash
   sudo virsh -c qemu:///system managedsave-remove haos
   ```

2. Switch the guest to an xhci USB controller, which new VMs get from
   `virt-install`. Check what it has now:

   ```bash
   sudo virsh -c qemu:///system dumpxml haos | grep "controller type='usb'"
   ```

   If that already shows `model='qemu-xhci'`, skip this step. Otherwise run
   `sudo virsh -c qemu:///system edit haos`, delete every
   `<controller type='usb' ...>...</controller>` element (including its
   `<address>` line), add

   ```xml
   <controller type='usb' index='0' model='qemu-xhci'/>
   ```

   and save. The change applies on a cold restart:

   ```bash
   sudo virsh -c qemu:///system shutdown haos
   # wait until `virsh list --all` shows it shut off
   sudo virsh -c qemu:///system start haos
   ```