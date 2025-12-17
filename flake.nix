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

    # Metadata configuration
    # Build-time values come from environment variables with sensible defaults
    # To set robot-specific values, export environment variables before building:
    #   export ROBOT_ID="my-robot"
    #   export GITHUB_USER="myuser"
    #   nixos-generate ...
    #
    # Or use the helper script to decrypt and export from metadata.json:
    #   eval $(nix run .#decrypt-and-export-metadata)
    #   nixos-generate ...
    metadata =
      let
        getValue = envName: default:
          let
            envValue = builtins.getEnv envName;
          in
            if envValue != "" then envValue else default;
      in {
        # Use valid defaults that satisfy NixOS validation
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
        builtins.trace ''${label}: base path ${toString basePath} missing; skipping'' {}
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

          filtered = lib.filterAttrs filterFn packagesAll;
          summary = map (name: let info = filtered.${name}; in "${info.vendor}/${name}") (lib.attrNames filtered);
        in
          builtins.trace
            ''${label}: found ROS dirs ${lib.concatStringsSep ", " summary} under ${toString basePath}''
            filtered;

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

    # Base Python set for pyproject-nix/uv2nix packages
    # pyproject-build-systems expects annotated-types to exist; ensure it is present.
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

    # Robot Console static assets (expects dist/ already built in ./robot-console)
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

    # Robot API (FastAPI) packaged from ./robot-api
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
        # Only keep packages that declare a pyproject.toml
        pythonPackageDirs = lib.filterAttrs (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
          in
            if hasPyproject then true
            else builtins.trace ''${name}: skipping ${pkgName}; no pyproject.toml in ${pkgPath}'' false
        ) packageDirs;

        # Load native dependency overrides from each workspace package
        nativeOverlays = lib.mapAttrsToList (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            nativeDepsFile = "${pkgPath}/native-deps.nix";
            hasNativeDeps = builtins.pathExists nativeDepsFile;
          in
            if hasNativeDeps then
              let
                # Load mapping: { python-pkg-name = [ "nixpkg1" "nixpkg2" ]; }
                nativeDepsMap = import nativeDepsFile;
              in
                # Convert to overlay
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
              (final: prev: {})  # empty overlay
        ) pythonPackageDirs;

        # Create overlays for each ROS package with pyproject.toml
        workspaceOverlays = lib.mapAttrsToList (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
          in
            if hasPyproject then
              let
                workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = pkgPath; };
              in
                workspace.mkPyprojectOverlay { sourcePreference = "wheel"; }
            else
              (final: prev: {})  # empty overlay for packages without pyproject.toml
        ) pythonPackageDirs;

        # Create Python set with all ROS workspace dependencies
        workspacePythonSet = pyProjectPythonBase.overrideScope (
          lib.composeManyExtensions (
            [ pyproject-build-systems.overlays.default ]
            ++ workspaceOverlays
            ++ nativeOverlays  # Apply native dependency overrides from each package
          )
        );

        # For each ROS package with a uv.lock, extract all dependencies (including transitive)
        uvDeps = lib.mapAttrs (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasUvLock = builtins.pathExists "${pkgPath}/uv.lock";
          in
            if hasUvLock then
              let
                # Read all package names from uv.lock
                lockfile = builtins.fromTOML (builtins.readFile "${pkgPath}/uv.lock");
                allPackages = lockfile.package or [];

                # Extract package names, excluding the package itself
                depNames = builtins.filter (n: n != pkgName)
                  (builtins.map (pkg: pkg.name) allPackages);

                # Safely try to get each dependency from the Python set
                tryGetPkg = depName:
                  let
                    result = builtins.tryEval (workspacePythonSet.${depName} or null);
                  in
                    if result.success && result.value != null then [result.value] else [];
              in
                builtins.concatMap tryGetPkg depNames
            else
              []
        ) pythonPackageDirs;

        workspacePackages = lib.mapAttrs (pkgName: pkgInfo:
          let
            pkgPath = pkgInfo.path;
            hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
            # Read version from pyproject.toml if it exists, otherwise use default
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

            # Skip runtime/runtime-deps checks; ROS launch handles runtime resolution
            nativeCheckInputs = [];
            doCheck = false;

            # Disable Python runtime deps check - this is the correct variable name
            dontCheckRuntimeDeps = true;

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

              echo "[postInstall] Processing package: $pkg" >&2
              echo "[postInstall] Build directory (PWD): $PWD" >&2
              echo "[postInstall] Listing build directory contents:" >&2
              ls -la . >&2 || true

              # 1: ament index registration
              mkdir -p $out/share/ament_index/resource_index/packages
              echo "$pkg" > $out/share/ament_index/resource_index/packages/$pkg

              # 2: package share (package.xml + launch)
              mkdir -p $out/share/$pkg/
              if [ -f package.xml ]; then
                echo "[postInstall] Copying package.xml" >&2
                cp package.xml $out/share/$pkg/
              else
                echo "[postInstall] No package.xml found" >&2
              fi

              # Copy launch files - try both naming conventions
              # 1. node.launch.py (standard name)
              if [ -f node.launch.py ]; then
                echo "[postInstall] Copying node.launch.py" >&2
                cp node.launch.py $out/share/$pkg/
              else
                echo "[postInstall] No node.launch.py found" >&2
              fi

              # 2. $pkg.launch.py (package-named launch file, e.g., webrtc.launch.py)
              if [ -f $pkg.launch.py ]; then
                echo "[postInstall] Copying $pkg.launch.py" >&2
                cp $pkg.launch.py $out/share/$pkg/
              else
                echo "[postInstall] No $pkg.launch.py found" >&2
              fi

              # 3. Copy entire launch directory if it exists
              if [ -d launch ]; then
                echo "[postInstall] Copying launch directory" >&2
                cp -r launch $out/share/$pkg/
              else
                echo "[postInstall] No launch directory found" >&2
              fi

              # Resource marker(s)
              if [ -f resource/$pkg ]; then
                echo "[postInstall] Copying resource marker file" >&2
                install -Dm644 resource/$pkg $out/share/$pkg/resource/$pkg
              elif [ -d resource ]; then
                echo "[postInstall] Copying resource directory" >&2
                mkdir -p $out/share/$pkg/resource
                cp -r resource/* $out/share/$pkg/resource/ || true
              else
                echo "[postInstall] No resource marker or directory found" >&2
              fi

              # 3: libexec shim so launch_ros finds the executable under lib/$pkg/$pkg_node
              mkdir -p $out/lib/$pkg
              cat > "$out/lib/$pkg/''${pkg}_node" <<EOF
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m ${pkgName}.node "\$@"
EOF
              chmod +x $out/lib/$pkg/''${pkg}_node

              echo "[postInstall] Final package share directory contents:" >&2
              ls -la $out/share/$pkg/ >&2 || true
            '';
          }
        ) packageDirs;

        workspaceBase = pkgs.buildEnv {
          name = name;
          paths = lib.attrValues workspacePackages;
        };

        # uv2nix runtime-only dependencies collected from workspace uv.lock files
        uvRuntimePackages = lib.flatten (lib.attrValues uvDeps);

        runtimeEnv = pkgs.buildEnv {
          name = "${name}-uv-runtime-env";
          paths = uvRuntimePackages;
          pathsToLink = [ "/lib" ];
        };

        workspaceWithLaunch = pkgs.runCommand "${name}-with-launch" {} ''
          # Create output directory structure
          mkdir -p $out

          # Copy everything from base workspace EXCEPT share directory
          if [ -d "${workspaceBase}" ]; then
            for item in ${workspaceBase}/*; do
              itemname=$(basename "$item")
              if [ "$itemname" != "share" ]; then
                cp -r "$item" "$out/"
              fi
            done
          fi

          # Create fresh share directory and copy contents
          mkdir -p $out/share
          if [ -d "${workspaceBase}/share" ]; then
            cp -r ${workspaceBase}/share/* $out/share/ 2>/dev/null || true
          fi

          # Add nodes.launch.py
          cp ${launchPath} $out/share/nodes.launch.py
        '';

        workspace = if enableLaunch && launchPath != null && builtins.pathExists launchPath
          then workspaceWithLaunch
          else workspaceBase;
      in {
        inherit workspace workspaceBase runtimeEnv workspacePackages uvRuntimePackages;
        nativeOverlays = nativeOverlays;
        workspaceOverlays = workspaceOverlays;
        pythonSet = workspacePythonSet;
        uvDeps = uvDeps;
      };

    # nodes.launch.py - optional for base repo, required for robot repos
    # Generated by polyflow-studio and placed at repo root
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

    # Python (ROS toolchain) + helpers
    rosPy = rosPkgs.python3;
    # Keep ament_python builds on the ROS Python set; do not fall back to the repo-pinned 3.12 toolchain.
    rosPyPkgs = rosPkgs.python3Packages or (rosPy.pkgs or (throw "rosPkgs.python3Packages unavailable"));
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    # Build a fixed osrf-pycommon (PEP 517), reusing nixpkgs' source
    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname        = "osrf-pycommon";
      version      = "2.0.2";
      src          = osrfSrc;
      pyproject    = true;
      build-system = [ py.pkgs.setuptools py.pkgs.wheel ];
      doCheck      = false;
    };

    # Minimal Python environment for ROS tooling and helpers
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