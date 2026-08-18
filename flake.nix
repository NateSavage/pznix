{
  description = "Declarative, self-contained Project Zomboid dedicated server for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules.default = import ./module.nix;
    nixosModules.project-zomboid-server = self.nixosModules.default;
  };
}
