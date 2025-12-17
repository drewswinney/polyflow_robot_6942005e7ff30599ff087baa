{ lib, pkgs, ... }:
{
  ##############################################################################
  # Hardware / boot
  ##############################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x:
        super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];

    loader = {
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        useGenerationDeviceTree = true;
      };
    };

    # Quiet kernel output on console (keep in journal)
    consoleLogLevel = 3; # errors only
    kernel.sysctl."kernel.printk" = "3 4 1 3";
    kernelModules = [
      "can"
      "can_raw"
      "mcp251xfd"
      "spi_bcm2835"
    ];

    kernelPackages = pkgs.linuxKernel.packages.linux_6_1;
    supportedFilesystems = lib.mkForce [ "vfat" "ext4" ];
  };

  hardware = {
    enableRedistributableFirmware = true;

    # Tie into the Pi-4 dtmerge pipeline from nixos-hardware
    raspberry-pi."4".apply-overlays-dtmerge.enable = true;

    deviceTree = {
      enable = true;

      # Be explicit about the base DTB; this matches what the Pi-4 hw module uses.
      # (This avoids “overlays merged into the wrong DTB” issues.)
      filter = "bcm2711-rpi-4-b.dtb";

      overlays = [
        {
          name = "polyflow-waveshare-can-fd-hat-mode-a";
          # overlays live at systems/raspi-4/overlays
          dtsFile = ../overlays/polyflow-waveshare-can-fd-hat-mode-a.dts;
        }
      ];
    };
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };
}
