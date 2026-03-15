{
  description = "NixOS modules for running Home Assistant OS as a libvirt guest VM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }: {
    nixosModules = {
      host = import ./modules/host.nix;
      networking = import ./modules/networking.nix;
      guest = import ./modules/guest.nix;
      usb = import ./modules/usb.nix;

      default = { imports = [ self.nixosModules.host self.nixosModules.networking ]; };
    };
  };
}