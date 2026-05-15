# Session handoff — elevation_mapping_cupy + GLIM on RTX PRO 6000 Blackwell

Use this as a pickup-from-cold notes file. The full user-facing setup doc is
[`README_GLIM_SETUP.md`](../README_GLIM_SETUP.md) at the repo root.

## Where we left off

- Docker image `elevation_mapping_cupy:x64` builds cleanly.
- Workspace builds inside the container (cv_bridge rebuilt from source).
- elevation_mapping_node + GLIM (separate `koide3/glim_ros2:jazzy_cuda13.1`
  container) are talking end-to-end. Topics flow, kernels compile, GridMap
  publishes.
- **Last open item**: TF frame name. With GLIM's default
  `base_frame_id: ""`, GLIM auto-detects the IMU frame from the bag and
  publishes `odom -> <auto>`, but our config asks for `os_sensor`. User
  needs to either (a) check the actual frame via
  `ros2 topic echo /tf_static --once --qos-durability transient_local` and
  patch [`config/setups/glim/base.yaml`](../elevation_mapping_cupy/config/setups/glim/base.yaml)
  `base_frame:` to match, or (b) set `base_frame_id` in
  `glim/config/config_ros.json` (only viable if the bag has a static TF
  for the desired base frame).

## Files we edited

| File | Change | Why |
|---|---|---|
| [`docker/Dockerfile.x64`](../docker/Dockerfile.x64) | Added `--ignore-installed numpy` to cupy install; added second pip install of `scipy scikit-learn opencv-python-headless shapely transforms3d` against numpy 2 | cupy 14 needed for Blackwell; numpy 2 cascade broke apt-shipped scientific stack |
| [`docker/src.repos`](../docker/src.repos) | Added `vision_opencv` (rolling) | Forces colcon to rebuild `cv_bridge` against numpy 2 (apt's prebuilt is numpy-1-only) |
| [`docker/run.sh`](../docker/run.sh) | Rewritten: correct image tag (`:x64`), source mount, `--ipc=host --pid=host`, `ROS_DOMAIN_ID`, `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`, on-start chown of workspace | Fast DDS docker-to-docker; bind-mount perms |
| [`elevation_mapping_cupy/config/setups/glim/base.yaml`](../elevation_mapping_cupy/config/setups/glim/base.yaml) | NEW — GLIM-tailored setup. Subscribes to `/glim_ros/points`, `map_frame=odom`, `base_frame=os_sensor` (likely needs edit) | Plug into GLIM's pose chain + deskewed cloud |
| [`elevation_mapping_cupy/kernels/custom_kernels.py`](../elevation_mapping_cupy/elevation_mapping_cupy/kernels/custom_kernels.py) | Replaced every `float16` with `float` in CUDA preamble | cupy 14 forward-declares `float16` as an incomplete placeholder; `__half` substitution doesn't help |
| [`elevation_mapping_cupy/kernels/kk.py`](../elevation_mapping_cupy/elevation_mapping_cupy/kernels/kk.py) | Same `float16` → `float` sweep in two preambles | Same root cause |
| [`README_GLIM_SETUP.md`](../README_GLIM_SETUP.md) | NEW — full setup, build, launch, integration-issues log, troubleshooting | User-facing doc |

## Hardware / stack assumed

- Host: x86_64, NVIDIA driver 580.x (CUDA 13.0 reported), RTX PRO 6000
  Blackwell (sm_120).
- Docker with nvidia-container-toolkit (`--gpus all`).
- ROS 2 Jazzy (Ubuntu 24.04) inside the elevation container.
- GLIM container: `koide3/glim_ros2:jazzy_cuda13.1` (ROS 2 Jazzy, matching).

## What to keep in mind for next session

### If we're staying on this hardware

- **Kernel cache**: after editing kernel `.py` files, run
  `rm -rf ~/.cupy/kernel_cache` inside the container before relaunching,
  otherwise cupy may reuse the failed compile.
- **`--symlink-install`** is on, so Python edits don't need `colcon build`.
- The user has `glim_rosbag` running, which **stops after one bag pass**.
  `/os_cloud_node/points` only flows while the bag is playing. Use
  `/glim_ros/points` (already in the config) so we don't depend on the
  bag still being in flight.

### If porting to Jetson (Orin)

What carries over unchanged:
- DDS fixes (`--ipc=host --pid=host`, `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`)
- All GLIM integration (subscribe topic, frame names, etc.)
- Workspace chown trick

What changes:
- **Base image**: drop `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`. Use an
  L4T base aligned with the device's JetPack, e.g.
  `nvcr.io/nvidia/l4t-jetpack:r36.x` (Orin / JetPack 6, Ubuntu 22.04) or
  `nvcr.io/nvidia/l4t-cuda:12.2.x-devel`.
- **ROS distro**: JetPack 6 ships Ubuntu 22.04 → **Humble**, not Jazzy.
  cv_bridge / vcs setup is the same idea.
- **cupy**: aarch64 wheel exists. Orin is sm_87, supported by cupy **13.x**
  too — staying on cupy 13 + numpy 1 sidesteps both the numpy-2 cascade and
  the `float16` kernel patch entirely. Try cupy 13 first on Jetson.
- **Torch**: don't `pip install torch`; use NVIDIA's prebuilt Jetson PyTorch
  wheels (CUDA wheels from PyPI are x86-only).
- **Docker runtime**: `--runtime=nvidia` (with `nvidia-container-runtime`
  configured on the Jetson) instead of `--gpus all`.

A `Dockerfile.jetson` was discussed but not written — would need actual
hardware to validate. The float16 patch may or may not be needed depending
on cupy version.

### What to verify before declaring "done"

- [ ] `tf2_echo odom <base_frame>` succeeds with whatever frame is in
  `glim/base.yaml`.
- [ ] `ros2 topic hz /elevation_mapping_node/elevation_map_raw` shows ~5 Hz.
- [ ] RViz GridMap display shows non-empty `elevation` and
  `traversability` layers (give the robot some motion for traversability
  to populate).
- [ ] No NVRTC errors after `rm -rf ~/.cupy/kernel_cache` + relaunch.

## Anti-list (things to avoid)

- Don't pin cupy back to 13.x on this Blackwell host —
  `CUDA_ERROR_NO_BINARY_FOR_GPU`. Only do that for older GPUs / Jetson.
- Don't try to fix `float16` by aliasing it (`typedef float float16;` or
  `using float16 = __half;`) — cupy 14 already declares the symbol, so
  any redeclaration is a hard NVRTC error. Replace usages instead.
- Don't subscribe elevation_mapping to `/glim_ros/map` — that's the
  accumulated map (giant cloud, slow updates). Use per-frame
  `/glim_ros/points`.
- Don't omit `--ipc=host` from either container — discovery breaks
  silently.
