{ lib, pkgs, hostname, wifiConfPath, wifiModeSwitch, robotApi, robotConsole, webrtcLauncher,
  workspaceLauncher, rosWorkspace, rosRuntimeEnv, systemRosWorkspace, systemRosRuntimeEnv, polyflowRebuildRunner, user, homeDir,
  rosServicesToRestart, password, metadata, ... }:
{
  ##############################################################################
  # Services
  ##############################################################################
  # Boot-time Wi-Fi mode selection: hotspot when no creds, STA when configured.
  systemd.services.polyflow-wifi-mode = {
    description = "Polyflow Wi-Fi mode switch (AP vs STA)";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" "network-online.target" ];
    wants = [ "NetworkManager.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      RemainAfterExit = true;
      Restart = "no"; # be explicit
      # Add timeout to prevent indefinite hangs
      TimeoutStartSec = "60s";
    };
  };

  systemd.paths.polyflow-wifi-mode = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = wifiConfPath;
      PathExists = wifiConfPath;
      Unit = "polyflow-wifi-mode.service";
    };
  };

  systemd.services.polyflow-robot-api = {
    description = "Polyflow Robot REST API";
    wantedBy = [ "multi-user.target" ];
    after  = [ "NetworkManager.service" "loki.service" ];
    wants  = [ "NetworkManager.service" "loki.service" ];
    environment = {
      WIFI_CONF_PATH = wifiConfPath;
      WIFI_SWITCH_CMD = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      ROBOT_API_TOKEN_PATH = "/var/lib/polyflow/api_token";
      ROBOT_API_ALLOWED_ORIGINS = "http://localhost,http://127.0.0.1,http://localhost:5173,http://127.0.0.1:5173,http://localhost:4173,http://127.0.0.1:4173,http://${hostname}.local";
      ALLOY_LOKI_TAIL_URL = "ws://127.0.0.1:3100/loki/api/v1/tail";
    };
    serviceConfig = {
      ExecStart = "${robotApi}/bin/robot-api";
      WorkingDirectory = "/var/lib/polyflow";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  systemd.services.grafana-alloy = {
    description = "Grafana Alloy metrics collector";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    wants = [ ];
    serviceConfig = {
      ExecStart = "${pkgs.grafana-alloy}/bin/alloy run --storage.path /var/lib/grafana-alloy /etc/alloy/config.alloy";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      Environment = "ROBOT_ID=${hostname}";
      StateDirectory = "grafana-alloy";
      WorkingDirectory = "/var/lib/grafana-alloy";
      SupplementaryGroups = lib.mkAfter [ "systemd-journal" ];
    };
  };

  services.loki = {
    enable = true;
    dataDir = "/var/lib/grafana-loki";
    configuration = {
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = 3100;
        grpc_listen_address = "0.0.0.0";
        grpc_listen_port = 9095;
      };

      auth_enabled = false;

      common = {
        path_prefix = "/var/lib/grafana-loki";
        replication_factor = 1;
        instance_interface_names = [ "dummy0" ];
        ring = {
          kvstore.store = "inmemory";
          instance_addr = "10.254.254.1";
        };
      };

      ingester = {
        wal.enabled = false;
        lifecycler = {
          address = "10.254.254.1";
          join_after = "0s";
          final_sleep = "0s";
        };
      };

      memberlist = {
        bind_addr = [ "10.254.254.1" ];
        advertise_addr = "10.254.254.1";
        bind_port = 7946;
        advertise_port = 7946;
        join_members = [ ];
        abort_if_cluster_join_fails = false;
      };

      ingester_client.remote_timeout = "10s";

      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "loki_index_";
          period = "24h";
        };
      }];

      storage_config = {
        tsdb_shipper = {
          active_index_directory = "/var/lib/grafana-loki/tsdb-index";
          cache_location = "/var/lib/grafana-loki/tsdb-cache";
        };
        filesystem.directory = "/var/lib/grafana-loki/chunks";
      };

      compactor = {
        working_directory = "/var/lib/grafana-loki/compactor";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
        compaction_interval = "10m";
      };

      ruler = {
        rule_path = "/var/lib/grafana-loki/rules";
        ring.kvstore.store = "inmemory";
        wal.dir = "/var/lib/grafana-loki/ruler-wal";
      };

      query_range.results_cache.cache.embedded_cache = {
        enabled = true;
        max_size_mb = 32;
      };

      limits_config = {
        ingestion_rate_mb = 8;
        ingestion_burst_size_mb = 16;
        allow_structured_metadata = false;

        retention_period = "168h";
      };

      analytics.reporting_enabled = false;
    };
  };


  systemd.services.loki = {
    after = lib.mkAfter [
      "network.target"
      "systemd-networkd.service"
      "sys-subsystem-net-devices-dummy0.device"
      "polyflow-wifi-mode.service"
    ];

    wants = [
      "network.target"
      "systemd-networkd.service"
      "sys-subsystem-net-devices-dummy0.device"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launcher";
    after    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wants    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wantedBy = [ "multi-user.target" ];

    script = ''
      exec ${webrtcLauncher}/bin/webrtc-launch
    '';

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    restartIfChanged = true;
    restartTriggers = [ webrtcLauncher systemRosWorkspace systemRosRuntimeEnv ];

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
    };
  };

  systemd.services.polyflow-ros-workspace = {
    description = "Run all ROS workspace launch files";
    after    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wants    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    restartIfChanged = true;
    restartTriggers = [ rosWorkspace workspaceLauncher ];

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart = "on-failure";
      RestartSec = "2s";
      ExecStart        = "${workspaceLauncher}/bin/polyflow-workspace-launch";
    };
  };

  systemd.services.polyflow-rebuild = {
    description = "Rebuild NixOS from GitHub flake (triggered remotely)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.git pkgs.nix pkgs.nixos-rebuild pkgs.util-linux ];

    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/polyflow";
      StandardOutput = "journal";
      StandardError = "journal";

      # Use flock to prevent concurrent rebuilds
      # -n = non-blocking (fail immediately if locked)
      # -E 75 = exit code 75 if already locked (TEMPFAIL)
      ExecStart = "${pkgs.util-linux}/bin/flock -n -E 75 /run/lock/polyflow-rebuild.lock ${polyflowRebuildRunner}/bin/polyflow-rebuild";
    };
  };

  # Let the robot user start the rebuild service without interactive auth.
  security.polkit = {
    enable = true;
    extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units"
            && action.lookup("unit") == "polyflow-rebuild.service"
            && subject.user == "${user}") {
          return polkit.Result.YES;
        }
      });
    '';
  };

  # CAN0 (spi0.0 -> can0)
  systemd.services.can0-up = {
    description = "Bring up CAN0 (MCP2518FD on spi0.0)";
    wantedBy    = [ "multi-user.target" ];

    # Wait until the net device exists
    after    = [ "sys-subsystem-net-devices-can0.device" ];
    requires = [ "sys-subsystem-net-devices-can0.device" ];

    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        # Make sure it's down first
        "${pkgs.iproute2}/bin/ip link set can0 down"
        # Configure CAN-FD: 1 Mbps arb, 2 Mbps data
        "${pkgs.iproute2}/bin/ip link set can0 type can bitrate 1000000 dbitrate 2000000 fd on"
        # Bring it up
        "${pkgs.iproute2}/bin/ip link set can0 up"
      ];
      ExecStop = "${pkgs.iproute2}/bin/ip link set can0 down";
    };
  };

  # CAN1 (spi1.0 -> can1)
  systemd.services.can1-up = {
    description = "Bring up CAN1 (MCP2518FD on spi1.0)";
    wantedBy    = [ "multi-user.target" ];

    after    = [ "sys-subsystem-net-devices-can1.device" ];
    requires = [ "sys-subsystem-net-devices-can1.device" ];

    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.iproute2}/bin/ip link set can1 down"
        "${pkgs.iproute2}/bin/ip link set can1 type can bitrate 1000000 dbitrate 2000000 fd on"
        "${pkgs.iproute2}/bin/ip link set can1 up"
      ];
      ExecStop = "${pkgs.iproute2}/bin/ip link set can1 down";
    };
  };
}
