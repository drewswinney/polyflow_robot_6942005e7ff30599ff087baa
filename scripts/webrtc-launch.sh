#!/usr/bin/env bash
set -eo pipefail

# Guard PATH/PYTHONPATH before enabling nounset; systemd often runs with them unset.
PATH="${PATH-}"
PYTHONPATH="${PYTHONPATH-}"
AMENT_PREFIX_PATH="${AMENT_PREFIX_PATH-}"
LD_LIBRARY_PATH="${LD_LIBRARY_PATH-}"
if [ -z "${RMW_IMPLEMENTATION-}" ]; then
  RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
fi
export RMW_IMPLEMENTATION

set -u
shopt -s nullglob

# Load configuration from metadata.json
METADATA_FILE="/var/lib/polyflow/metadata.json"
if [ -f "$METADATA_FILE" ]; then
  echo "[INFO] Loading configuration from $METADATA_FILE" >&2

  # Use jq to parse JSON and export environment variables
  ROBOT_ID=$(jq -r '.ROBOT_ID // ""' "$METADATA_FILE")
  SIGNALING_URL=$(jq -r '.SIGNALING_URL // ""' "$METADATA_FILE")
  TURN_SERVER_URL=$(jq -r '.TURN_SERVER_URL // ""' "$METADATA_FILE")
  TURN_SERVER_USERNAME=$(jq -r '.TURN_SERVER_USERNAME // ""' "$METADATA_FILE")
  TURN_SERVER_PASSWORD=$(jq -r '.TURN_SERVER_PASSWORD // ""' "$METADATA_FILE")
  export ROBOT_ID
  export SIGNALING_URL
  export TURN_SERVER_URL
  export TURN_SERVER_USERNAME
  export TURN_SERVER_PASSWORD
else
  echo "[ERROR] metadata.json not found at $METADATA_FILE" >&2
  exit 1
fi

PYTHONPATH_BASE="@pythonPath@"
if [ -n "$PYTHONPATH_BASE" ]; then
  PYTHONPATH="$PYTHONPATH_BASE${PYTHONPATH:+:}${PYTHONPATH}"
fi

AMENT_PREFIX_BASE="@amentPrefixPath@"
if [ -n "$AMENT_PREFIX_BASE" ]; then
  AMENT_PREFIX_PATH="$AMENT_PREFIX_BASE${AMENT_PREFIX_PATH:+:}${AMENT_PREFIX_PATH}"
fi

LIBRARY_PATH_BASE="@workspaceLibraryPath@"
if [ -n "$LIBRARY_PATH_BASE" ]; then
  LD_LIBRARY_PATH="$LIBRARY_PATH_BASE${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH}"
fi

export PYTHONPATH
export AMENT_PREFIX_PATH
export LD_LIBRARY_PATH

# Local setup scripts expect AMENT_TRACE_SETUP_FILES to be unset when absent.
set +u
for prefix in @workspaceRuntimePrefixes@; do
  for script in "$prefix"/setup.bash "$prefix"/local_setup.bash \
                "$prefix"/install/setup.bash "$prefix"/install/local_setup.bash \
                "$prefix"/share/*/local_setup.bash "$prefix"/share/*/setup.bash; do
    if [ -f "$script" ]; then
      echo "[INFO] Sourcing $script" >&2
      # shellcheck disable=SC1090
      . "$script"
    fi
  done
done
set -u

echo "[DEBUG] AMENT_PREFIX_PATH=$AMENT_PREFIX_PATH" >&2
echo "[DEBUG] PYTHONPATH=$PYTHONPATH" >&2
echo "[DEBUG] RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION" >&2

exec ros2 launch webrtc webrtc.launch.py
