{ lib, user, password, homeDir, ... }:
{
  ##############################################################################
  # Users
  ##############################################################################
  users.mutableUsers = false;
  # Keep an explicit root entry so builds that query user 0 (e.g., logrotate.conf)
  # can resolve it even with immutable users. Set uid/gid explicitly and lock the
  # password so root password auth stays disabled.
  users.groups.root.gid = 0;
  users.users.root = {
    uid = 0;
    group = "root";
    isSystemUser = true;
    hashedPassword = "!";
  };
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;
}
