#!/bin/bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-elevation_mapping_cupy:x64}"
SRC_DIR="${SRC_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# X11 forwarding (RViz, etc.)
XSOCK=/tmp/.X11-unix
XAUTH=/tmp/.docker.xauth
if [ ! -f "$XAUTH" ]; then
  touch "$XAUTH"
  xauth nlist "$DISPLAY" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "$XAUTH" nmerge - || true
  chmod a+r "$XAUTH"
fi

echo "[run.sh] image       : $IMAGE_NAME"
echo "[run.sh] src mount   : $SRC_DIR -> /home/ubuntu/workspace/src/elevation_mapping_cupy"
echo "[run.sh] ROS_DOMAIN_ID: $ROS_DOMAIN_ID"

docker run --rm -it \
  --gpus all \
  --net=host \
  --ipc=host \
  --pid=host \
  --privileged \
  --ulimit rtprio=99 \
  --cap-add=sys_nice \
  -e DISPLAY \
  -e "XAUTHORITY=$XAUTH" \
  -e "QT_X11_NO_MITSHM=1" \
  -e "ROS_DOMAIN_ID=$ROS_DOMAIN_ID" \
  -e "FASTDDS_BUILTIN_TRANSPORTS=UDPv4" \
  -v "$XSOCK":"$XSOCK":rw \
  -v "$XAUTH":"$XAUTH":rw \
  -v "$SRC_DIR":/home/ubuntu/workspace/src/elevation_mapping_cupy \
  -v /media:/media \
  "$IMAGE_NAME" \
  bash -lc 'sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace && exec bash'
