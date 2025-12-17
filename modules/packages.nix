{ pkgs, rosPkgs, pyEnv, ... }:
{
  ##############################################################################
  # Packages
  ##############################################################################
  environment.systemPackages =
    (with pkgs; [ git python3 can-utils iproute2 ]) ++
    (with rosPkgs; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]) ++
    [ pyEnv ];
}
