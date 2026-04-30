# Single-disk BIOS layout. Disk path comes from `catacomb.bootDevice`
# (default `/dev/vda` — fits most cloud VMs).
{ config, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = config.catacomb.bootDevice;
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # GRUB BIOS boot partition
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
