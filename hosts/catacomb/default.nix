# Catacomb multi-sig — top-level NixOS module.
#
# Imported via `nixosModules.catacomb` from this flake's outputs. All
# per-deploy values are pulled from `config.catacomb.*` — see `options.nix`
# for the option surface, set values in your consumer flake.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./options.nix
    ./disko.nix
    ./safe-stack.nix
    ./nginx.nix
    ./ui.nix
  ];

  assertions = [
    {
      assertion = lib.hasAttr config.catacomb.primaryChain config.catacomb.chains;
      message = ''
        catacomb.primaryChain ("${config.catacomb.primaryChain}") must be a key in catacomb.chains.
        Available chains: ${lib.concatStringsSep ", " (lib.attrNames config.catacomb.chains)}.
      '';
    }
  ];

  system.stateVersion = "25.05";
  nixpkgs.hostPlatform = "x86_64-linux";

  # Disko's EF02 partition wires GRUB onto `catacomb.bootDevice` automatically.
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  networking.hostName = config.catacomb.hostName;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = config.catacomb.sshAuthorizedKeys;

  time.timeZone = config.catacomb.timeZone;

  # Docker (vs podman) — upstream safe-infrastructure compose syntax targets
  # the Docker CLI; running it under podman-compose hits compatibility edges.
  virtualisation.docker.enable = true;
}
