# Plan: boot reliability and USB hotplug

Three reported problems. Root causes were found by reading `modules/*.nix`;
none of this has been run on a host yet.

## 1. Manual start fails after reboot until `managedsave-remove`

**Cause.** NixOS sets `virtualisation.libvirtd.onShutdown = "suspend"` by
default, so every host shutdown/reboot runs `virsh managedsave` on the guest.
The saved RAM image embeds the QEMU/OVMF paths and device state from before
the reboot. After a NixOS update (new store paths) or with a hostdev attached,
the restore on `virsh start` can fail, and the stale image keeps failing until
it is removed.

**Fix.**
- `host.nix`: set `virtualisation.libvirtd.onShutdown = "shutdown"` (graceful
  ACPI shutdown, no saved state) and `onBoot = "ignore"`. Add options
  `services.haos.shutdownTimeout` (default 120) wired to
  `virtualisation.libvirtd.shutdownTimeout`.
- `guest.nix`: in every start path, run
  `virsh managedsave-remove "$name"` before `virsh start`, so a leftover image
  from before the upgrade can never block boot. Ignore its failure.

## 2. VM is never auto-started after reboot

**Causes, in `usb.nix` (`haos-wait-for-usb`).** The user's host (homura) has
`usb.automount.enable = true`, so this script is the only start path.
- `lsusb | grep -q "0x10c4:0xea60"` never matches. `lsusb` prints
  `ID 10c4:ea60` without the `0x` prefix, so the loop times out after 60 s and
  the service exits 1. **This is the main reason the VM never starts.**
- `((attempt++))` returns status 1 when `attempt` is 0, which kills the script
  under `set -e`.
- `lsusb | grep -q` under `pipefail` can fail with SIGPIPE even on a match.
- A missing USB stick blocks VM start for the whole timeout and then forever,
  and `haos-install-guest` is only `after`, not `wants`, of the start unit.

**Fix.**
- Strip `0x` when matching (`lib.removePrefix "0x"`), match with
  `lsusb -d vid:pid` and test its exit status, no pipe.
- Replace the counter with a `for i in $(seq 1 $timeout)` loop.
- A missing device must not prevent boot: log a warning and start the VM
  anyway (new option `usb.waitTimeoutSeconds`, default 30; `0` = do not wait).
- Collapse `haos-autostart` and `haos-autostart-with-usb` into one unit
  `haos-autostart` that always exists, optionally waits for USB, clears
  managedsave, starts the VM. Add `wants = [ "haos-install-guest.service" ]`.
- Also set `virsh autostart` off explicitly so libvirt and systemd never race.
- `Restart=on-failure`, `RestartSec=10` as a safety net.

## 3. USB devices cannot be hotplugged

**Causes.**
- `haos-attach-usb` uses `virsh attach-device` with no `--live --config`
  intent and no idempotency: a second run fails with "already in use" and
  `set -e` aborts.
- Attach only happens once at boot via `haos-automount`. Unplug/replug of the
  stick is never handled; QEMU drops the hostdev when the device disappears.
- `virt-install` is not given an explicit USB controller, so hotplug depends
  on virt-install defaults.

**Fix.**
- `guest.nix`: add `--controller type=usb,model=qemu-xhci` to `virt-install`.
  Existing VMs are not recreated, so document a one-off migration:
  `virsh attach-device haos --config` with a `<controller type='usb'
  model='qemu-xhci'/>` snippet, then cold-restart the guest.
- `usb.nix`: add a udev rule per configured device
  (`SUBSYSTEM=="usb", ENV{ID_VENDOR_ID}=="10c4", ENV{ID_MODEL_ID}=="ea60"`)
  that on `add` starts `haos-usb-attach@<vid>-<pid>.service` and on `remove`
  starts `haos-usb-detach@<vid>-<pid>.service` (`TAG+="systemd"`,
  `ENV{SYSTEMD_WANTS}`). Both are small templated oneshots that call a shared
  `haos-usb` script (`attach|detach <vid> <pid>`).
- The script must be idempotent: skip attach if
  `virsh dumpxml | grep` already shows the device, ignore "not found" on
  detach, and exit 0 quietly when the VM is not running (the boot-time unit
  attaches later).
- Keep `haos-attach-usb` as a thin wrapper that loops over `cfg.devices`, for
  manual use.
- `haos-automount` stays, but only attaches devices after the VM is running,
  and uses `--live` plus `--config` so the definition survives a restart.
- New option `usb.hotplug.enable` (default true when `usb.enable`).
- Add an `allowedDevices`-style note: libvirt itself handles `/dev/bus/usb`
  permissions, no extra udev `MODE` is needed; verify on the host.

## Order of work (one commit each)

1. `fix(guest): clear managed save before start, shut down gracefully`
2. `fix(usb): match lsusb ids without 0x prefix`
3. `fix(usb): do not block VM start on missing devices`
4. `refactor(guest): merge autostart units`
5. `feat(guest): add explicit xhci usb controller`
6. `feat(usb): hotplug via udev and templated units`
7. `docs: document hotplug, shutdown behaviour and migration`

## Verification (needs a NixOS host)

- `nix flake check` and `nixos-rebuild build` for a config using the module.
- Reboot with the guest running: confirm it shuts down, no managed save image
  (`virsh -c qemu:///system list --with-managed-save`), and starts by itself.
- Boot with the USB stick unplugged: VM still starts after the timeout.
- With the VM running, unplug and replug the stick: `virsh dumpxml haos` shows
  the hostdev disappear and return; Home Assistant sees the device.
- Run `haos-attach-usb` twice: second run exits 0.

## Out of scope

- Switching from `virsh` shell to the libvirt domain XML options of NixOS
  (e.g. NixVirt). Worth considering later, not needed to fix these bugs.
