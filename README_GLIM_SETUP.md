# elevation_mapping_cupy + GLIM (Blackwell GPU)

How to build and run [elevation_mapping_cupy](README.md) on a Blackwell-class
NVIDIA GPU (RTX PRO 6000 / sm_120) and feed it odometry + TF from
[GLIM](../glim/README.md) running in a separate container.

## Stack

- ROS 2 Jazzy (Ubuntu 24.04)
- CUDA 12.6 / cuDNN
- cupy 14 (numpy 2)
- GLIM (Humble container) publishing `map -> odom -> base_link` and `imu -> lidar` TF

The upstream Dockerfile assumed pre-Blackwell GPUs and numpy 1. We patched it
to use cupy 14 (Blackwell-capable), reinstall `scipy / scikit-learn / opencv /
shapely / transforms3d` against numpy 2, and rebuild `cv_bridge` from source
so its native module is numpy-2 compatible. See
[docker/Dockerfile.x64](docker/Dockerfile.x64) and
[docker/src.repos](docker/src.repos).

## How to build

There are two builds: the Docker **image** (host side, slow, do once) and the
ROS **workspace** inside the container (fast, redo when the package source
changes).

### Image build (host)

```bash
cd /root/slam/elevation_mapping_cupy/docker
docker build -f Dockerfile.x64 -t elevation_mapping_cupy:x64 .
```

Takes ~10 min cold (downloads CUDA base, ROS packages, torch, cupy). Result
is tagged `elevation_mapping_cupy:x64` (~26 GB on disk, 8.7 GB content).
Subsequent builds are cached and finish in seconds unless `Dockerfile.x64`
or `src.repos` changed.

### Workspace build (inside container)

```bash
ROS_DOMAIN_ID=0 /root/slam/elevation_mapping_cupy/docker/run.sh
# now inside the container:
cd ~/workspace
source /opt/ros/jazzy/setup.bash
vcs import < src/elevation_mapping_cupy/docker/src.repos src/ --recursive
colcon build --symlink-install --merge-install --packages-up-to elevation_mapping_cupy
source install/setup.bash
```

`vcs import` is a one-time pull of `ros2_numpy` and `vision_opencv` into
`~/workspace/src/`. After that, only `colcon build` needs re-running when
source changes. `--symlink-install` means edits to Python files take effect
without rebuilding.

### Rebuilding incrementally

```bash
# inside the container, after editing src/elevation_mapping_cupy/...
colcon build --symlink-install --merge-install --packages-select elevation_mapping_cupy
```

## Launch playbook

### 1. Configure GLIM

Edit `glim/config/config_ros.json` so GLIM's frames line up with what
elevation mapping expects:

```jsonc
"base_frame_id": "base_link",   // was "" (defaulted to IMU frame)
"odom_frame_id": "odom",
"map_frame_id":  "map",
"points_topic":  "/os_cloud_node/points",
"imu_topic":     "/os_cloud_node/imu"
```

GLIM will publish the TF tree `map -> odom -> base_link` plus `imu -> lidar`.

### 2. Launch GLIM (terminal 1)

```bash
docker run -it --rm \
  --net=host --ipc=host --pid=host \
  --gpus all \
  -e DISPLAY -e ROS_DOMAIN_ID=0 \
  -v $(realpath /root/slam/glim/config):/glim/config \
  koide3/glim_ros2:humble_cuda12.2 \
  ros2 run glim_ros glim_rosnode --ros-args -p config_path:=/glim/config
```

### 3. Launch elevation mapping (terminal 2)

Start the container and source the workspace overlay (build steps from
[How to build](#how-to-build) must be done once first):

```bash
# host
ROS_DOMAIN_ID=0 /root/slam/elevation_mapping_cupy/docker/run.sh

# inside the container
source /opt/ros/jazzy/setup.bash
source ~/workspace/install/setup.bash
ros2 launch elevation_mapping_cupy elevation_mapping.launch.py \
  robot_config:=glim/base.yaml \
  launch_rviz:=true
```

To open a second shell into the running container (e.g. to run `ros2 topic`
without killing the launch), use:

```bash
docker exec -it $(docker ps --filter ancestor=elevation_mapping_cupy:x64 -q) bash
# then inside:
source /opt/ros/jazzy/setup.bash
source ~/workspace/install/setup.bash
```

The GLIM-tailored setup file lives at
[config/setups/glim/base.yaml](elevation_mapping_cupy/config/setups/glim/base.yaml):

```yaml
map_frame: 'odom'           # use smooth odom (avoids loop-closure jumps)
base_frame: 'base_link'
corrected_map_frame: 'odom'
subscribers:
  lidar:
    topic_name: '/os_cloud_node/points'
    data_type: pointcloud
```

If your lidar topic isn't `/os_cloud_node/points`, edit the `topic_name` (and
the matching `points_topic` in GLIM's config).

### 4. Verify

From either container:

```bash
ros2 topic hz /os_cloud_node/points                       # lidar flowing
ros2 run tf2_ros tf2_echo odom base_link                  # GLIM TF reaching us
ros2 topic hz /elevation_mapping_node/elevation_map_raw   # map publishing
```

## Replaying a rosbag instead of live data

Run both containers with `use_sim_time:=true` and play the bag with `--clock`:

```bash
# elevation mapping
ros2 launch elevation_mapping_cupy elevation_mapping.launch.py \
  robot_config:=glim/base.yaml use_sim_time:=true

# bag (any container with the bag mounted)
ros2 bag play /path/to/bag --clock
```

## What's changed from upstream

Patches against the upstream `ros2` branch of
[`leggedrobotics/elevation_mapping_cupy`](https://github.com/leggedrobotics/elevation_mapping_cupy).
All of these exist because the upstream Docker recipe assumes a numpy-1 /
pre-Blackwell stack, and we needed cupy 14 to get kernels for the RTX PRO
6000 (sm_120).

### Fixed

- **`docker build` failed on numpy uninstall.** Upstream `pip install
  cupy-cuda12x` pulled cupy 14 which tries to upgrade `numpy` past 2.0, but
  pip can't uninstall apt's `python3-numpy` (no RECORD file). → Added
  `--ignore-installed numpy` to the pip line in
  [`docker/Dockerfile.x64`](docker/Dockerfile.x64).
- **`CUDA_ERROR_NO_BINARY_FOR_GPU` on Blackwell.** Older cupy 13.x wheels
  have no kernel image for sm_120. → Use the latest `cupy-cuda12x` (14.x).
- **`numpy.core.multiarray failed to import`** from apt-installed
  `python3-scipy`, `python3-scikit-learn`, `python3-opencv`,
  `python3-shapely`, `python3-transforms3d` (compiled against numpy 1). →
  Added a pip reinstall of those packages against numpy 2 in the
  Dockerfile.
- **`cv_bridge.so` crash on import** (ROS Jazzy ships it compiled against
  numpy 1). → Added `ros-perception/vision_opencv` (rolling branch) to
  [`docker/src.repos`](docker/src.repos) so colcon rebuilds `cv_bridge`
  from source against numpy 2.
- **`np.maximum_sctype` removed in numpy 2** breaks `transforms3d` 0.4.1.
  → Pip-install latest `transforms3d` in the Dockerfile.
- **`Permission denied` building inside the container** because the
  bind-mounted workspace is host-root-owned. → `docker/run.sh` now chowns
  `/home/ubuntu/workspace` to `ubuntu` on container start.
- **`docker/run.sh` referenced wrong image tag** (`:jazzy` vs `:x64`),
  didn't mount the package source, didn't pass `ROS_DOMAIN_ID`, didn't set
  `--ipc=host`. → Rewritten to mount the source at
  `/home/ubuntu/workspace/src/elevation_mapping_cupy`, share IPC/PID with
  the host, and propagate `ROS_DOMAIN_ID`.

### Added

- [`config/setups/glim/base.yaml`](elevation_mapping_cupy/config/setups/glim/base.yaml) —
  setup file wired to GLIM's frames (`odom` / `base_link`) and lidar topic
  (`/os_cloud_node/points`). Pass `robot_config:=glim/base.yaml` to the
  launch file.

### File-by-file diff summary

| File | Change |
|---|---|
| [docker/Dockerfile.x64](docker/Dockerfile.x64) | `--ignore-installed numpy` on cupy install; new pip reinstall of scipy/sklearn/opencv/shapely/transforms3d |
| [docker/src.repos](docker/src.repos) | Added `vision_opencv` (rolling) entry |
| [docker/run.sh](docker/run.sh) | Rewritten: correct image tag, source mount, `--ipc=host`, `ROS_DOMAIN_ID`, workspace chown |
| [elevation_mapping_cupy/config/setups/glim/base.yaml](elevation_mapping_cupy/config/setups/glim/base.yaml) | New: GLIM-tailored setup |
| [README_GLIM_SETUP.md](README_GLIM_SETUP.md) | New: this document |

## Troubleshooting

- **`PermissionError: 'log'` / `Permission denied: 'src/ros2_numpy'`** inside
  the container: the bind-mounted workspace is owned by host root but the
  container runs as `ubuntu`. `run.sh` fixes this on start; if you launched
  the container another way, run
  `sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace` once.
- **Empty map**: usually a TF problem. Check `tf2_echo odom <lidar_frame>` —
  if it fails, GLIM isn't publishing yet or `base_frame_id` / static TFs are
  misnamed.
- **`CUDA_ERROR_NO_BINARY_FOR_GPU`**: cupy version doesn't include kernels for
  your compute capability. cupy 14 supports Blackwell (sm_120); older 13.x
  does not.
- **`numpy.core.multiarray failed to import`**: a native module was compiled
  against numpy 1. Rebuild it from source (see `cv_bridge` example in
  `docker/src.repos`) or upgrade the pip package against numpy 2.
- **Containers can't see each other's topics / `ros2 topic list` doesn't
  show GLIM topics** (this is [Fast-DDS#2956](https://github.com/eProsima/Fast-DDS/issues/2956)):
  Fast DDS uses shared-memory transport by default and needs `/dev/shm` and
  the host PID namespace to negotiate it across containers. Both containers
  must run with **all three** of `--net=host --ipc=host --pid=host` plus the
  same `ROS_DOMAIN_ID`. Our [`docker/run.sh`](docker/run.sh) and the GLIM
  launch command in section 2 already include them — verify your actual
  `docker run` invocation has them too. Inside the containers:
  ```bash
  ls /dev/shm    # should show fastrtps_* entries from both nodes
  ```
  **Fallback** if SHM still doesn't negotiate (e.g. Docker Desktop on Mac,
  rootless docker, or different `/dev/shm` size limits): disable SHM and
  force UDP by exporting before launching on **both** sides:
  ```bash
  export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
  ```
  Or switch RMW entirely:
  ```bash
  export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp   # install rmw-cyclonedds-cpp first
  ```
- **Cross-distro DDS** (GLIM is Humble, this image is Jazzy): both default
  to `rmw_fastrtps_cpp` and stable messages (`sensor_msgs/PointCloud2`,
  `tf2_msgs/TFMessage`, `grid_map_msgs/GridMap`) interop fine. If discovery
  is flaky, force the same RMW on both with
  `export RMW_IMPLEMENTATION=rmw_fastrtps_cpp`.
