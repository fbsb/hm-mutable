{
  description = "Writable, reset-on-activation files for Home Manager";

  inputs = {
    home-manager.url = "github:nix-community/home-manager";
    nixpkgs.follows = "home-manager/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      homeManagerModules.default = ./module.nix;
      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          testsFor =
            hm:
            import ./tests {
              pkgs = hm.inputs.nixpkgs.legacyPackages.${system};
              home-manager = hm;
              module = self.homeManagerModules.default;
            };
        in
        testsFor home-manager
      );
      formatter = nixpkgs.lib.genAttrs systems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
