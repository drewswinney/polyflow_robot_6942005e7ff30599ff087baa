{
  description = "NixOS (Pi 4) + ROS 2 Humble + prebuilt colcon workspace";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://ros.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  ##############################################################################
  # Inputs
  ##############################################################################
  inputs = {
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay";
    nix-ros-overlay.flake = false;
    nixpkgs.url = "github:lopsided98/nixpkgs/nix-ros";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nix-ros-workspace.url = "github:hacker1024/nix-ros-workspace";
    nix-ros-workspace.flake = false;
    polyflowRos.url = "github:polyflowrobotics/polyflow-ros";
    polyflowRos.flake = false;
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
    uv2nix.url = "github:pyproject-nix/uv2nix";
    uv2nix.inputs.pyproject-nix.follows = "pyproject-nix";
    uv2nix.inputs.nixpkgs.follows = "nixpkgs";
    pyproject-build-systems.url = "github:pyproject-nix/build-system-pkgs";
    pyproject-build-systems.inputs.pyproject-nix.follows = "pyproject-nix";
    pyproject-build-systems.inputs.uv2nix.follows = "uv2nix";
    pyproject-build-systems.inputs.nixpkgs.follows = "nixpkgs";
  };

  ##############################################################################
  # Outputs
  ##############################################################################
  outputs = { self, nixpkgs, nixos-hardware, nix-ros-workspace, nix-ros-overlay, polyflowRos, pyproject-nix, uv2nix, pyproject-build-systems, ... }:
  let
    ##############################################################################
    # System target and overlays
    ##############################################################################
    system = "aarch64-linux";

    # Overlay: pin python3 -> python312 (ROS Humble Python deps are happy here)
    pinPython312 = final: prev: {
      python3         = prev.python312;
      python3Packages = prev.python312Packages;
    };

    # ROS overlay setup from nix-ros-overlay (non-flake)
    rosBase = import nix-ros-overlay { inherit system; };

    rosOverlays =
      if builtins.isFunction rosBase then
        # Direct overlay function
        [ rosBase ]
      else if builtins.isList rosBase then
        # Already a list of overlay functions
        rosBase
      else if rosBase ? default && builtins.isFunction rosBase.default then
        # Attrset with a `default` overlay
        [ rosBase.default ]
      else if rosBase ? overlays && builtins.isList rosBase.overlays then
        # Attrset with `overlays = [ overlay1 overlay2 … ]`
        rosBase.overlays
      else if rosBase ? overlays
           && rosBase.overlays ? default
           && builtins.isFunction rosBase.overlays.default then
        # Attrset with `overlays.default` as the primary overlay
        [ rosBase.overlays.default ]
      else
        throw "nix-ros-overlay: unexpected structure; expected an overlay or list of overlays";

    rosWorkspaceOverlay = (import nix-ros-workspace { inherit system; }).overlay;
    
    pkgs = import nixpkgs {
      inherit system;
      overlays = rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
    };

    lib     = pkgs.lib;
    rosPkgs = pkgs.rosPackages.humble;

    # Metadata configuration from environment variables
    metadata =
      let
        getValue = envName: default:
          let
            envValue = builtins.getEnv envName;
          in
            if envValue != "" then envValue else default;
      in {
        robotId = getValue "ROBOT_ID" "polyflow-robot";
        signalingUrl = getValue "SIGNALING_URL" "wss://example.com";
        password = getValue "PASSWORD" "changeme";
        githubUser = getValue "GITHUB_USER" "polyflowrobotics";
        turnServerUrl = getValue "TURN_SERVER_URL" "turn:example.com";
        turnServerUsername = getValue "TURN_SERVER_USERNAME" "username";
        turnServerPassword = getValue "TURN_SERVER_PASSWORD" "password";
      };

    ############################################################################
    # Workspace discovery
    ############################################################################
    mkPackageDirs = { basePath, filterFn ? (_: _: true), label, vendorLayout ? true, flatVendor ? "." }:
      if basePath == null || !builtins.pathExists basePath then
        {}
      else
        let
          packagesAll =
            if vendorLayout then
              let
                vendorDirs = lib.filterAttrs (_: v: v == "directory") (builtins.readDir basePath);
              in
                lib.foldl'
                  (acc: vendor:
                    let
                      vendorPath = "${toString basePath}/${vendor}";
                      pkgDirs = lib.filterAttrs (_: v: v == "directory") (builtins.readDir vendorPath);
                      pkgAttrs = lib.mapAttrs (pkg: _: { path = "${vendorPath}/${pkg}"; vendor = vendor; }) pkgDirs;
                    in lib.attrsets.unionOfDisjoint acc pkgAttrs
                  )
                  {}
                  (lib.attrNames vendorDirs)
            else
              let
                pkgDirs = lib.filterAttrs (_: v: v == "directory") (builtins.readDir basePath);
              in
                lib.mapAttrs (pkg: _: { path = "${toString basePath}/${pkg}"; vendor = flatVendor; }) pkgDirs;
        in
          lib.filterAttrs filterFn packagesAll;

    rosLibsCandidates = [
      ./libs
      ../../shared/libs
    ];

    rosLibsPath = lib.findFirst (p: builtins.pathExists p) null rosLibsCandidates;

    rosPackageDirs = mkPackageDirs {
      basePath = rosLibsPath;
      filterFn = name: _: name != "webrtc";
      label = "polyflow-ros (user)";
      vendorLayout = true;
    };

    polyflowSystemPath =
      let
        systemPath = "${polyflowRos}/system";
      in
        if builtins.pathExists systemPath then systemPath
        else throw "polyflow-ros system directory not found at ${systemPath}";

    systemRosPackageDirs = mkPackageDirs {
      basePath = polyflowSystemPath;
      label = "polyflow-ros (system)";
      vendorLayout = false;
      flatVendor = "system";
    };

    # Base Python set for pyproject-nix/uv2nix with annotated-types
    pythonForPyproject = pkgs.python3.override {
      packageOverrides = final: prev: {
        "annotated-types" =
          if prev ? "annotated-types" then prev."annotated-types" else prev.buildPythonPackage rec {
            pname = "annotated-types";
            version = "0.7.0";
            format = "pyproject";
            src = pkgs.fetchFromGitHub {
              owner = "annotated-types";
              repo = "annotated-types";
              tag = "v${version}";
              hash = "sha256-I1SPUKq2WIwEX5JmS3HrJvrpNrKDu30RWkBRDFE+k9A=";
            };
            nativeBuildInputs = [ prev.hatchling ];
            propagatedBuildInputs = lib.optionals (prev.pythonOlder "3.9") [ prev."typing-extensions" ];
          };
      };
    };

    pyProjectPythonBase = pkgs.callPackage pyproject-nix.build.packages {
      python = pythonForPyproject;
    };

    robotConsoleSrc = builtins.path { path = ./robot-console; name = "robot-console-src"; };

    robotConsole = pkgs.stdenv.mkDerivation {
      pname = "robot-console";
      version = "0.1.0";
      src = robotConsoleSrc;
      dontUnpack = true;
      dontBuild = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p $out/dist
        if [ -d "$src/dist" ]; then
          cp -rT "$src/dist" "$out/dist"
        else
          echo "robot-console dist/ not found; run npm install && npm run build in robot-console before building the image." >&2
          exit 1
        fi
      '';
    };

    robotApiSrc = pkgs.lib.cleanSource ./robot-api;
    robotApi = pkgs.python3Packages.buildPythonPackage {
      pname = "robot-api";
      version = "0.1.0";
      src = robotApiSrc;
      format = "pyproject";
      propagatedBuildInputs = with pkgs.python3Packages; [
        fastapi
        uvicorn
        pydantic
        psutil
        websockets
      ];
      nativeBuildInputs = [
        pkgs.python3Packages.setuptools
        pkgs.python3Packages.wheel
      ];
    };

    ############################################################################
    # ROS 2 workspace (Humble)
    ############################################################################
    mkRosWorkspace = { name, packageDirs, enableLaunch ? false, launchPath ? null }:
      let
        pythonPackageDirs = lib.filterAttrs (pkgName: pkgInfo:
          builtins.pathExists "${pkgInfo.path}/pyproject.toml"
        ) packageDirs;

        nativeOverlays = lib.mapAttrsToList (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            nativeDepsFile = "${pkgPath}/native-deps.nix";
            hasNativeDeps = builtins.pathExists nativeDepsFile;
          in
            if hasNativeDeps then
              let
                nativeDepsMap = import nativeDepsFile;
              in
                (final: prev:
                  lib.attrsets.concatMapAttrs (pyPkgName: nixPkgNames:
                    lib.optionalAttrs (prev ? ${pyPkgName}) {
                      ${pyPkgName} = prev.${pyPkgName}.overrideAttrs (old: {
                        buildInputs = (old.buildInputs or []) ++ (map (n: pkgs.${n}) nixPkgNames);
                        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
                      });
                    }
                  ) nativeDepsMap
                )
            else
              (final: prev: {})
        ) pythonPackageDirs;

        uvDeps = lib.mapAttrs (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasUvLock = builtins.pathExists "${pkgPath}/uv.lock";
          in
            if hasUvLock then
              let
                workspaceRoot = builtins.path { path = pkgPath; };
                workspace = uv2nix.lib.workspace.loadWorkspace { inherit workspaceRoot; };

                nativeDepsFile = "${pkgPath}/native-deps.nix";
                hasNativeDeps = builtins.pathExists nativeDepsFile;
                nativeDepsOverlay = if hasNativeDeps then
                  let
                    nativeDepsMap = import nativeDepsFile;
                  in
                    (final: prev:
                      lib.attrsets.concatMapAttrs (pyPkgName: nixPkgNames:
                        lib.optionalAttrs (prev ? ${pyPkgName}) {
                          ${pyPkgName} = prev.${pyPkgName}.overrideAttrs (old: {
                            buildInputs = (old.buildInputs or []) ++ (map (n: pkgs.${n}) nixPkgNames);
                            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
                          });
                        }
                      ) nativeDepsMap
                    )
                else
                  (final: prev: {});

                overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
                pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
                  python = pkgs.python3;
                }).overrideScope (
                  lib.composeManyExtensions [
                    pyproject-build-systems.overlays.default
                    overlay
                    nativeDepsOverlay
                  ]
                );

                uvLockContent = builtins.readFile "${pkgPath}/uv.lock";
                uvLockData = builtins.fromTOML uvLockContent;
                allPackages = uvLockData.package or [];
                dependencyPackages = builtins.filter (pkg:
                  !((pkg.source or {}) ? editable)
                ) allPackages;

                allDeps = builtins.filter (dep: dep != null) (map (pkg:
                  let
                    normalizedName = builtins.replaceStrings ["_"] ["-"] pkg.name;
                  in
                    pythonSet.${normalizedName} or null
                ) dependencyPackages);
              in
                allDeps
            else
              []
        ) pythonPackageDirs;

        workspacePackages = lib.mapAttrs (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
            version = if hasPyproject then
              (builtins.fromTOML (builtins.readFile "${pkgPath}/pyproject.toml")).project.version
            else
              "0.0.1";
          in
          pkgs.python3Packages.buildPythonPackage {
            pname   = pkgName;
            version = version;
            src     = pkgs.lib.cleanSource pkgPath;

            format  = if hasPyproject then "pyproject" else "setuptools";

            dontUseCmakeConfigure = true;
            dontUseCmakeBuild     = true;
            dontUseCmakeInstall   = true;
            dontWrapPythonPrograms = true;

            nativeBuildInputs = if hasPyproject then [
              pkgs.python3Packages.pdm-backend
            ] else [
              pkgs.python3Packages.setuptools
            ];

            nativeCheckInputs = [];
            doCheck = false;
            dontCheckRuntimeDeps = true;
            catchConflicts = false;

            propagatedBuildInputs = with rosPkgs; [
              rclpy
              launch
              launch-ros
              ament-index-python
              composition-interfaces
            ] ++ [
              pkgs.python3Packages.pyyaml
            ] ++ (if uvDeps ? ${pkgName} then uvDeps.${pkgName} else []);

            postInstall = ''
              set -euo pipefail
              pkg="${pkgName}"

              # Ament index registration
              mkdir -p $out/share/ament_index/resource_index/packages
              echo "$pkg" > $out/share/ament_index/resource_index/packages/$pkg

              # Package share (package.xml + launch files)
              mkdir -p $out/share/$pkg/
              [ -f package.xml ] && cp package.xml $out/share/$pkg/ || true
              [ -f node.launch.py ] && cp node.launch.py $out/share/$pkg/ || true
              [ -f $pkg.launch.py ] && cp $pkg.launch.py $out/share/$pkg/ || true
              [ -d launch ] && cp -r launch $out/share/$pkg/ || true

              # Resource markers
              if [ -f resource/$pkg ]; then
                install -Dm644 resource/$pkg $out/share/$pkg/resource/$pkg
              elif [ -d resource ]; then
                mkdir -p $out/share/$pkg/resource
                cp -r resource/* $out/share/$pkg/resource/ || true
              fi

              # Libexec shim for launch_ros
              mkdir -p $out/lib/$pkg
              cat > "$out/lib/$pkg/''${pkg}_node" <<EOF
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m ${pkgName}.node "\$@"
EOF
              chmod +x $out/lib/$pkg/''${pkg}_node
            '';
          }
        ) packageDirs;

        workspaceBase = pkgs.buildEnv {
          name = name;
          paths = lib.attrValues workspacePackages;
        };

        uvRuntimePackages = lib.flatten (lib.attrValues uvDeps);

        runtimeEnv = pkgs.buildEnv {
          name = "${name}-uv-runtime-env";
          paths = uvRuntimePackages;
          pathsToLink = [ "/lib" "/lib/python3.12/site-packages" ];
        };

        workspaceWithLaunch = pkgs.runCommand "${name}-with-launch" {} ''
          mkdir -p $out
          if [ -d "${workspaceBase}" ]; then
            for item in ${workspaceBase}/*; do
              itemname=$(basename "$item")
              [ "$itemname" != "share" ] && cp -r "$item" "$out/" || true
            done
          fi
          mkdir -p $out/share
          [ -d "${workspaceBase}/share" ] && cp -r ${workspaceBase}/share/* $out/share/ 2>/dev/null || true
          cp ${launchPath} $out/share/nodes.launch.py
        '';

        workspace = if enableLaunch && launchPath != null && builtins.pathExists launchPath
          then workspaceWithLaunch
          else workspaceBase;
      in {
        inherit workspace workspaceBase runtimeEnv workspacePackages uvRuntimePackages uvDeps;
      };

    workspaceLaunchPath = ./nodes.launch.py;

    rosWorkspaceSet = mkRosWorkspace {
      name = "polyflow-ros";
      packageDirs = rosPackageDirs;
      enableLaunch = true;
      launchPath = workspaceLaunchPath;
    };

    systemRosWorkspaceSet = mkRosWorkspace {
      name = "polyflow-ros-system";
      packageDirs = systemRosPackageDirs;
    };

    rosWorkspace = rosWorkspaceSet.workspace;
    rosRuntimeEnv = rosWorkspaceSet.runtimeEnv;
    systemRosWorkspace = systemRosWorkspaceSet.workspace;
    systemRosRuntimeEnv = systemRosWorkspaceSet.runtimeEnv;

    rosPy = rosPkgs.python3;
    rosPyPkgs = rosPkgs.python3Packages or (rosPy.pkgs or (throw "rosPkgs.python3Packages unavailable"));
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname        = "osrf-pycommon";
      version      = "2.0.2";
      src          = osrfSrc;
      pyproject    = true;
      build-system = [ py.pkgs.setuptools py.pkgs.wheel ];
      doCheck      = false;
    };

    pyEnv = py.withPackages (ps: [
      ps.pyyaml
      ps.empy
      ps.catkin-pkg
      osrfFixed
    ]);

  in
  {
    # Export packages
    packages.${system} = {
      robotConsole = robotConsole;
      robotApi     = robotApi;
      rosWorkspace     = rosWorkspace;
      rosRuntimeEnv  = rosRuntimeEnv;
      systemRosWorkspace = systemRosWorkspace;
      systemRosRuntimeEnv = systemRosRuntimeEnv;
    };

    # Full NixOS config for Pi 4 (sd-image)
    nixosConfigurations.rpi4 =
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit pyEnv robotConsole robotApi rosWorkspace rosRuntimeEnv systemRosWorkspace systemRosRuntimeEnv metadata;
        };
        modules = [
          ({ ... }: {
            nixpkgs.overlays =
              rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
          })
          nixos-hardware.nixosModules.raspberry-pi-4
          ./configuration.nix
        ];
      };
  };
}
