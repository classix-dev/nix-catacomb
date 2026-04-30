# NixOS configuration for the Catacomb multi-sig host.
#
# Sketch — not booted, not yet verified end-to-end.
{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disko.nix
    ./branding.nix
    ./safe-stack.nix
    ./nginx.nix
  ];

  system.stateVersion = "25.05";
  nixpkgs.hostPlatform = "x86_64-linux";

  # GRUB on /dev/vda — DigitalOcean droplets boot BIOS by default.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    efiSupport = false;
  };

  networking.hostName = "catacomb";
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  # Console + SSH access. Replace the placeholder key before any real deploy.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    # TODO: paste deploy key(s) here, or move to a per-environment overlay.
    # "ssh-ed25519 AAAA... operator@example"
  ];

  # Time / locale defaults — match maintainer convention if known.
  time.timeZone = "UTC";

  # Container runtime for the Safe stack. Podman is rootless-friendly and
  # docker-compatible.
  virtualisation = {
    podman = {
      enable = true;
      dockerSocket.enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers.backend = "podman";
  };

  # Minimal package set. Anything else lands via the safe-stack module.
  environment.systemPackages = [ ];
}
