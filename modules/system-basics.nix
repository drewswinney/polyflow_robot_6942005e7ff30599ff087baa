{ lib, pkgs, hostname, robotConsole, user, ... }:
{
  ##############################################################################
  # System basics
  ##############################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];
  systemd.services.NetworkManager-wait-online.enable = false;

  systemd.network = {
    enable = true;
    wait-online.enable = false;

    netdevs."10-dummy0" = {
      netdevConfig = {
        Name = "dummy0";
        Kind = "dummy";
      };
    };

    networks."10-dummy0" = {
      matchConfig.Name = "dummy0";
      address = [ "10.254.254.1/32" ];
      networkConfig.ConfigureWithoutCarrier = true;
      linkConfig.RequiredForOnline = false;
    };
  };

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    networkmanager.wifi.powersave = false;
    networkmanager.logLevel = "WARN";
    useDHCP = false;
    dhcpcd.enable = false;
    nftables.enable = true;
    firewall = {
      allowedTCPPorts = [ 80 ];
      # Allow DHCP/DNS on the hotspot interface so clients can get leases.
      interfaces."wlan0" = {
        allowedUDPPorts = [ 53 67 68 ];
        allowedTCPPorts = [ 53 ];
      };
    };
  };

  services.openssh.enable = true;
  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.addresses = true;
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/polyflow 0755 root root -"
    "d /var/lib/grafana-loki 0750 loki loki - -"
    # Clean any stale dnsmasq PID file NetworkManager might leave
    "r /run/nm-dnsmasq-wlan0.pid"
  ];
  services.caddy.enable = false;

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = false;
    virtualHosts."default" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ];
      locations = {
        # Strip the /api/ prefix when proxying to the FastAPI app
        "/api/" = {
           proxyPass = "http://127.0.0.1:8082/";
           proxyWebsockets = true;
        };
        "/" = {
          root = "${robotConsole}/dist";
          tryFiles = "$uri $uri/ /index.html";
          extraConfig = "autoindex off;";
        };
      };
    };
  };

  # Build-time NSS in the sandbox lacks a root entry; skip logrotate config check
  # to avoid failing builds in nixos-generate/docker.
  services.logrotate.checkConfig = false;
  services.timesyncd.enable = lib.mkDefault true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  # Local Prometheus Node Exporter (scraped by Alloy)
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [ "systemd" "processes" "tcpstat" ];
  };

  # No extra NSS modules; disable nscd to avoid PID file permission warnings.
  system.nssModules = lib.mkForce [];
  services.nscd.enable = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" user ];
    trusted-substituters = [ "https://ros.cachix.org" ];
    trusted-public-keys = [
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
    accept-flake-config = true;
  };

  system.stateVersion = "23.11";

  environment.etc."alloy/config.alloy" = {
    # config.alloy lives at systems/raspi-4/config.alloy
    source = ../config.alloy;
    mode = "0644";
  };
}
