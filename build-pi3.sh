#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NODE_DIR="$SCRIPT_DIR"
HOST="pi3"
INSTALL_TO=0
INSTALL_ONLY=0
REMOTE_PREFIX="$HOME/.local/node22"
LOG_FILE=""
STATUS_PREFIX="[build]"

CLEAN=0
CONFIGURE_ONLY=0
USE_NODE_SNAPSHOT=0
AUTO_INSTALL_DEPS=1
CONTAINER_RUNTIME="auto"
CONTAINER_IMAGE="arm32v7/debian:buster"
CONTAINER_PLATFORM="linux/arm/v7"
CONTAINER_INSTALL_BINFMT=1
BUILDER_IMAGE=""
BUILDER_IMAGE_CACHE=1
FORCE_REBUILD_BUILDER_IMAGE=0
PERSISTENT_CONTAINER=1
CONTAINER_NAME=""
RESET_CONTAINER=0
DOCKER_USE_SUDO=0
JOBS=$(command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

usage() {
  cat <<'USAGE'
Usage: build-$HOST.sh [options]

Build Node.js for Raspberry Pi 3 by compiling natively in an ARMv7 container
(default image: arm32v7/debian:buster).

Options:
  --clean                    Remove out/ and run make distclean inside container
  --no-clean                 Keep previous build artifacts (default)
  --jobs N                   Parallel jobs inside container (default: nproc)
  --with-node-snapshot       Enable startup snapshot build
  --without-node-snapshot    Disable startup snapshot (default)
  --configure-only           Run ./configure only, skip make
  --container-runtime NAME   auto|docker|podman (default: auto)
  --container-image IMAGE    Base container image (default: arm32v7/debian:buster)
  --container-platform P     Container platform (default: linux/arm/v7)
  --container-name NAME      Persistent build container name (default: derived)
  --builder-image IMAGE      Builder image tag (default: derived from --container-image)
  --no-builder-image-cache   Use base image directly (reinstall deps each run)
  --rebuild-builder-image    Rebuild cached builder image before running
  --reset-container          Remove and recreate persistent work container
  --ephemeral-container      Use one-shot container (--rm) instead of persistent one
  --no-container-binfmt      Do not auto-install qemu binfmt handlers
  --auto-install-deps        Auto-install missing host deps (docker/podman/sudo)
  --no-auto-install-deps     Disable automatic host dependency install
  --host HOST                Host used for deploy/install (default: $HOST)
  --install                  Install built node on host via ssh/scp
  --install-only             Install existing out/Release/node only (skip build)
  --no-install               Do not install on host (default)
  --remote-prefix PATH       Install prefix on host (default: ~/.local/node22)
  --log-file PATH            Build logfile path (default: /var/tmp/node-build-<ts>.log)
  -h, --help                 Show this help
USAGE
}

detect_source_and_build_tree() {
  dir="$1"
  base="$(basename "$dir")"
  source_dir=""
  build_tree=""

  case "$base" in
    *.build|*.make|*.other)
      source_dir="${dir%.*}"
      build_tree="$dir"
      ;;
    *)
      source_dir="$dir"
      if [ -d "${dir}.build" ]; then
        build_tree="${dir}.build"
      elif [ -d "${dir}.make" ]; then
        build_tree="${dir}.make"
      elif [ -d "${dir}.other" ]; then
        build_tree="${dir}.other"
      fi
      ;;
  esac

  if [ -n "$source_dir" ] && [ ! -f "$source_dir/configure" ]; then
    source_dir=""
  fi

  if [ -n "$build_tree" ] && [ ! -f "$build_tree/configure" ]; then
    build_tree=""
  fi

  printf '%s\n%s\n' "$source_dir" "$build_tree"
}

sync_source_to_build_tree() {
  src="$1"
  bld="$2"
  if [ -z "$src" ] || [ -z "$bld" ] || [ "$src" = "$bld" ]; then
    return 0
  fi
  require_cmd cpto
  status "Syncing source -> build tree via cpto: $src -> $bld"
  cpto "$src" "$bld"
}

reexec_in_build_tree_if_needed() {
  set -- "$@"
  detected="$(detect_source_and_build_tree "$NODE_DIR")"
  source_dir="$(printf '%s\n' "$detected" | sed -n '1p')"
  build_tree="$(printf '%s\n' "$detected" | sed -n '2p')"

  if [ -n "$source_dir" ] && [ -n "$build_tree" ] && [ "$NODE_DIR" = "$source_dir" ]; then
    sync_source_to_build_tree "$source_dir" "$build_tree"
    script_name="$(basename "$0")"
    if [ -x "$build_tree/$script_name" ]; then
      exec "$build_tree/$script_name" "$@"
    fi
    echo "error: expected script missing in build tree: $build_tree/$script_name" >&2
    exit 2
  fi
}

status() {
  printf '%s %s\n' "$STATUS_PREFIX" "$*"
}

ensure_not_source_tree_build() {
  base_name="$(basename "$NODE_DIR")"
  if [ "$base_name" = "node" ]; then
    if [ -d "${NODE_DIR}.other" ] || [ -d "${NODE_DIR}.make" ]; then
      echo "error: source-tree build blocked for $NODE_DIR" >&2
      echo "hint: run from a sibling build tree (for example: ${NODE_DIR}.other)." >&2
      exit 2
    fi
  fi
}

ensure_not_codex_sandbox() {
  if [ -r /proc/1/cmdline ] && tr '\0' ' ' </proc/1/cmdline | grep -q 'codex-linux-sandbox'; then
    echo "error: detected codex sandbox environment." >&2
    echo "hint: run this script from an escalated shell so interactive sudo/askpass can work." >&2
    exit 2
  fi
}

ensure_log_file() {
  if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/var/tmp/node-build-$(date +%Y%m%d-%H%M%S).log"
  fi
  log_dir=$(dirname "$LOG_FILE")
  mkdir -p "$log_dir"
}

show_failure_summary() {
  if [ ! -f "$LOG_FILE" ]; then
    status "Build failed; logfile missing: $LOG_FILE"
    return 0
  fi

  status "Build failed. Logfile: $LOG_FILE"
  status "Likely failure lines:"
  if ! grep -nE '(^make(\[[0-9]+\])?: \*\*\*|error:|fatal:|undefined reference|ld:|collect2: error)' "$LOG_FILE" | tail -n 25; then
    status "(No common error markers found by grep.)"
  fi
  status "Last 80 lines of logfile:"
  tail -n 80 "$LOG_FILE" || true
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 1
  }
}

apt_install_missing_pkgs() {
  askpass="${SUDO_ASKPASS:-}"

  if [ "$#" -eq 0 ]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "error: missing apt-get; cannot auto-install: $*" >&2
    return 1
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "error: missing sudo; cannot auto-install: $*" >&2
    return 1
  fi
  if [ -z "$askpass" ] && [ -x "$HOME/bin/simple-askpass" ]; then
    askpass="$HOME/bin/simple-askpass"
  fi

  echo "Installing missing packages: $*"
  if [ -n "$askpass" ] && [ -x "$askpass" ]; then
    env SUDO_ASKPASS="$askpass" sudo -A apt-get update -qy
    env SUDO_ASKPASS="$askpass" sudo -A apt-get install -y "$@"
  else
    sudo apt-get update -qy
    sudo apt-get install -y "$@"
  fi
}

choose_container_runtime() {
  if [ "$CONTAINER_RUNTIME" != "auto" ]; then
    echo "$CONTAINER_RUNTIME"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo docker
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    echo podman
    return
  fi
}

container_exec() {
  runtime="$1"
  shift

  if [ "$runtime" = "docker" ] && [ "$DOCKER_USE_SUDO" -eq 1 ]; then
    sudo docker "$@"
  else
    "$runtime" "$@"
  fi
}

ensure_container_runtime() {
  runtime_probe="$(choose_container_runtime 2>/dev/null)"
  if [ -n "$runtime_probe" ]; then
    return 0
  fi

  if [ "$AUTO_INSTALL_DEPS" -ne 1 ]; then
    echo "error: no container runtime found (docker/podman)." >&2
    return 1
  fi

  apt_install_missing_pkgs docker.io sudo
}

detect_runtime_privileges() {
  runtime="$1"

  if [ "$runtime" != "docker" ]; then
    return 0
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_USE_SUDO=0
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_USE_SUDO=1
    return 0
  fi

  echo "error: docker is installed but not accessible (no socket permission and sudo docker unavailable)." >&2
  return 1
}

ensure_binfmt_if_needed() {
  runtime="$1"

  if container_exec "$runtime" run --rm --platform "$CONTAINER_PLATFORM" "$CONTAINER_IMAGE" true >/dev/null 2>&1; then
    return 0
  fi

  if [ "$CONTAINER_INSTALL_BINFMT" -eq 1 ] && [ "$runtime" = "docker" ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "error: sudo required to install binfmt handlers for docker." >&2
      return 1
    fi
    echo "Enabling ${CONTAINER_PLATFORM} binfmt handlers for docker..."
    sudo docker run --privileged --rm tonistiigi/binfmt --install arm >/dev/null
    container_exec "$runtime" run --rm --platform "$CONTAINER_PLATFORM" "$CONTAINER_IMAGE" true >/dev/null
    return 0
  fi

  echo "error: container runtime cannot run ${CONTAINER_PLATFORM} image: $CONTAINER_IMAGE" >&2
  echo "Hint: install qemu/binfmt support, or run with docker and allow binfmt install." >&2
  return 1
}

derive_builder_image() {
  image_key="$(printf '%s' "$CONTAINER_IMAGE" | tr '/:@' '___' | tr -cd 'A-Za-z0-9._-')"
  printf 'node-pi3-builder:%s' "$image_key"
}

derive_work_container() {
  image_key="$(printf '%s' "$CONTAINER_IMAGE" | tr '/:@' '___' | tr -cd 'A-Za-z0-9._-')"
  printf 'node-pi3-work-%s' "$image_key"
}

ensure_builder_image() {
  runtime="$1"

  if [ "$BUILDER_IMAGE_CACHE" -ne 1 ]; then
    echo "$CONTAINER_IMAGE"
    return 0
  fi

  builder_image="$BUILDER_IMAGE"
  if [ -z "$builder_image" ]; then
    builder_image="$(derive_builder_image)"
  fi

  if [ "$FORCE_REBUILD_BUILDER_IMAGE" -eq 1 ]; then
    container_exec "$runtime" rmi -f "$builder_image" >/dev/null 2>&1 || true
  fi

  if container_exec "$runtime" image inspect "$builder_image" >/dev/null 2>&1; then
    echo "$builder_image"
    return 0
  fi

  echo "Building cached builder image: $builder_image (from $CONTAINER_IMAGE)" >&2
  container_exec "$runtime" build \
    --platform "$CONTAINER_PLATFORM" \
    --build-arg BASE_IMAGE="$CONTAINER_IMAGE" \
    -t "$builder_image" \
    - <<'DOCKERFILE'
ARG BASE_IMAGE="$CONTAINER_IMAGE"
FROM ${BASE_IMAGE}
SHELL ["/bin/sh", "-c"]
RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    if grep -Eq "^[[:space:]]*deb .*[[:space:]]buster([[:space:]]|/)" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then \
      sed -i "s|http://deb.debian.org/debian|http://archive.debian.org/debian|g" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true; \
      sed -i "s|http://security.debian.org/debian-security|http://archive.debian.org/debian-security|g" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true; \
      printf "Acquire::Check-Valid-Until \"false\";\n" > /etc/apt/apt.conf.d/99no-check-valid; \
    fi; \
    printf "deb http://archive.debian.org/debian buster-backports main\n" > /etc/apt/sources.list.d/buster-backports.list; \
    printf "Package: *\nPin: release n=buster-backports\nPin-Priority: 90\n\nPackage: clang-13 clang-tools-13 clang++-13 lld-13 llvm-13 llvm-13-dev llvm-13-tools libclang-common-13-dev libclang-cpp13 libclang1-13\nPin: release n=buster-backports\nPin-Priority: 990\n" > /etc/apt/preferences.d/clang13; \
    apt-get update -qy; \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config git ca-certificates ccache file \
      wget xz-utils zlib1g-dev libssl-dev libffi-dev libbz2-dev \
      libreadline-dev libsqlite3-dev libncursesw5-dev libgdbm-dev \
      liblzma-dev uuid-dev \
      clang-13 lld-13 libc++-13-dev libc++abi-13-dev; \
    ln -sf /usr/bin/clang-13 /usr/local/bin/clang; \
    ln -sf /usr/bin/clang++-13 /usr/local/bin/clang++; \
    cd /tmp; \
    wget -q https://www.python.org/ftp/python/3.9.21/Python-3.9.21.tgz; \
    tar -xzf Python-3.9.21.tgz; \
    cd Python-3.9.21; \
    ./configure --prefix=/opt/python3.9 --with-ensurepip=install; \
    make -j"$(nproc)"; \
    make altinstall; \
    ln -sf /opt/python3.9/bin/python3.9 /usr/local/bin/python3.9; \
    ln -sf /opt/python3.9/bin/python3.9 /usr/local/bin/python3; \
    cd /; \
    rm -rf /tmp/Python-3.9.21 /tmp/Python-3.9.21.tgz; \
    rm -rf /var/lib/apt/lists/*
DOCKERFILE

  echo "$builder_image"
}

ensure_work_container() {
  runtime="$1"
  run_image="$2"
  ccache_dir="$3"

  if [ "$PERSISTENT_CONTAINER" -ne 1 ]; then
    return 0
  fi

  work_container="$CONTAINER_NAME"
  if [ -z "$work_container" ]; then
    work_container="$(derive_work_container)"
  fi

  if [ "$RESET_CONTAINER" -eq 1 ]; then
    container_exec "$runtime" rm -f "$work_container" >/dev/null 2>&1 || true
  fi

  if container_exec "$runtime" container inspect "$work_container" >/dev/null 2>&1; then
    state="$(container_exec "$runtime" inspect -f '{{.State.Running}}' "$work_container" 2>/dev/null || echo false)"
    if [ "$state" != "true" ]; then
      container_exec "$runtime" start "$work_container" >/dev/null
    fi
    echo "$work_container"
    return 0
  fi

  echo "Creating persistent build container: $work_container" >&2
  container_exec "$runtime" create -t \
    --name "$work_container" \
    --platform "$CONTAINER_PLATFORM" \
    -v "$NODE_DIR:/src/node" \
    -v "$ccache_dir:/ccache" \
    -w /src/node \
    "$run_image" \
    sh -c 'while :; do sleep 3600; done' >/dev/null
  container_exec "$runtime" start "$work_container" >/dev/null
  echo "$work_container"
}

warn_if_stale_work_container() {
  runtime="$1"
  work_container="$2"
  run_image="$3"

  if [ "$PERSISTENT_CONTAINER" -ne 1 ]; then
    return 0
  fi
  if [ -z "$work_container" ]; then
    return 0
  fi

  container_image_id="$("$runtime" inspect -f '{{.Image}}' "$work_container" 2>/dev/null || true)"
  current_image_id="$("$runtime" image inspect -f '{{.Id}}' "$run_image" 2>/dev/null || true)"

  if [ -n "$container_image_id" ] && [ -n "$current_image_id" ] && [ "$container_image_id" != "$current_image_id" ]; then
    echo "WARNING: persistent container '$work_container' uses an older image." >&2
    echo "WARNING: container image id: $container_image_id" >&2
    echo "WARNING: current image id:   $current_image_id" >&2
    echo "WARNING: run with --reset-container to recreate it from the current image." >&2
  fi
}

run_container_build() {
  runtime="$1"
  run_image="$2"
  work_container="$3"
  ccache_dir="${CCACHE_DIR:-$HOME/.ccache-node-armhf}"
  run_uid="$(id -u)"
  run_gid="$(id -g)"
  snapshot_flag=""

  if [ "$USE_NODE_SNAPSHOT" -eq 0 ]; then
    snapshot_flag="--without-node-snapshot"
  fi

  mkdir -p "$ccache_dir"

  status "Using runtime: $runtime"
  status "Using image:   $run_image"
  status "Platform:      $CONTAINER_PLATFORM"
  status "Source dir:    $NODE_DIR"
  if [ "$PERSISTENT_CONTAINER" -eq 1 ]; then
    status "Container:     $work_container (persistent)"
  else
    status "Container:     ephemeral (--rm)"
  fi
  status "Logfile:       $LOG_FILE"

  # shellcheck disable=SC2016
  build_cmd='
      set -eu
      export CCACHE_DIR=/ccache
      export CCACHE_BASEDIR=/src/node
      export CCACHE_COMPRESS=1
      export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
      export PYTHON=/usr/local/bin/python3.9
      export CC="ccache clang-13"
      export CXX="ccache clang++-13"
      export CFLAGS="${CFLAGS:-} -U__ILP32__"
      export CXXFLAGS="${CXXFLAGS:-} -U__ILP32__ -stdlib=libc++"
      export LDFLAGS="${LDFLAGS:-} -stdlib=libc++ -rtlib=compiler-rt"
      mkdir -p "$CCACHE_DIR"
      ccache -M "$CCACHE_MAXSIZE" >/dev/null || true

      if [ "${CLEAN}" = "1" ]; then
        make distclean >/dev/null 2>&1 || true
        rm -rf out
      fi

      ./configure --dest-os=linux --dest-cpu=arm ${SNAPSHOT_FLAG}

      if [ "${CONFIGURE_ONLY}" = "1" ]; then
        echo "Configure complete. Skipping make (--configure-only)."
        exit 0
      fi

      make -j"${JOBS}"
      file out/Release/node || true
      ccache -s | sed -n "1,20p" || true
    '

  if [ "$PERSISTENT_CONTAINER" -eq 1 ]; then
    status "Starting build in persistent container..."
    if container_exec "$runtime" exec -t \
      -u "${run_uid}:${run_gid}" \
      -e CLEAN="$CLEAN" \
      -e JOBS="$JOBS" \
      -e SNAPSHOT_FLAG="$snapshot_flag" \
      -e CONFIGURE_ONLY="$CONFIGURE_ONLY" \
      "$work_container" \
      sh -c "$build_cmd" >"$LOG_FILE" 2>&1; then
      status "Build command finished successfully."
    else
      show_failure_summary
      return 1
    fi
  else
    status "Starting build in ephemeral container..."
    if container_exec "$runtime" run --rm -t \
      --platform "$CONTAINER_PLATFORM" \
      -u "${run_uid}:${run_gid}" \
      -v "$NODE_DIR:/src/node" \
      -v "$ccache_dir:/ccache" \
      -w /src/node \
      -e CLEAN="$CLEAN" \
      -e JOBS="$JOBS" \
      -e SNAPSHOT_FLAG="$snapshot_flag" \
      -e CONFIGURE_ONLY="$CONFIGURE_ONLY" \
      "$run_image" \
      sh -c "$build_cmd" >"$LOG_FILE" 2>&1; then
      status "Build command finished successfully."
    else
      show_failure_summary
      return 1
    fi
  fi
}

install_on() {
  remote_host="$1"
  remote_prefix="$2"
  remote_tmp="/var/tmp/node-$$"
  remote_bin_dir="${remote_prefix}/bin"
  remote_node="${remote_bin_dir}/node"
  remote_nodejs="${remote_bin_dir}/nodejs"

  require_cmd scp
  require_cmd ssh

  if [ ! -x "$NODE_DIR/out/Release/node" ]; then
    echo "error: built binary not found: $NODE_DIR/out/Release/node" >&2
    return 1
  fi

  echo "Installing node on ${remote_host}:${remote_node}"
  scp "$NODE_DIR/out/Release/node" "${remote_host}:${remote_tmp}"
  ssh "$remote_host" "
    set -eu
    mkdir -p '${remote_bin_dir}'
    install -m 0755 '${remote_tmp}' '${remote_node}'
    rm -f '${remote_tmp}'
    [ -e '${remote_nodejs}' ] || ln -s '${remote_node}' '${remote_nodejs}'
    for shell_init in \"\$HOME/.bashrc\" \"\$HOME/.profile\"; do
      [ -e \"\$shell_init\" ] || : > \"\$shell_init\"
      if ! grep -Fq '${remote_bin_dir}' \"\$shell_init\"; then
        printf '\nexport PATH=\"%s:\$PATH\"\n' '${remote_bin_dir}' >> \"\$shell_init\"
      fi
    done
    '${remote_node}' -v
  "

  echo "Install complete on ${remote_host}. node path: ${remote_node}"
}

reexec_in_build_tree_if_needed "$@"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean)
      CLEAN=1
      shift
      ;;
    --no-clean)
      CLEAN=0
      shift
      ;;
    --jobs)
      JOBS="${2:-}"
      shift 2
      ;;
    --with-node-snapshot)
      USE_NODE_SNAPSHOT=1
      shift
      ;;
    --without-node-snapshot)
      USE_NODE_SNAPSHOT=0
      shift
      ;;
    --configure-only)
      CONFIGURE_ONLY=1
      shift
      ;;
    --container-runtime)
      CONTAINER_RUNTIME="${2:-}"
      shift 2
      ;;
    --container-image)
      CONTAINER_IMAGE="${2:-}"
      shift 2
      ;;
    --container-platform)
      CONTAINER_PLATFORM="${2:-}"
      shift 2
      ;;
    --container-name)
      CONTAINER_NAME="${2:-}"
      shift 2
      ;;
    --rebuild-builder-image)
      FORCE_REBUILD_BUILDER_IMAGE=1
      shift
      ;;
    --builder-image)
      BUILDER_IMAGE="${2:-}"
      shift 2
      ;;
    --no-builder-image-cache)
      BUILDER_IMAGE_CACHE=0
      shift
      ;;
    --reset-container)
      RESET_CONTAINER=1
      shift
      ;;
    --ephemeral-container)
      PERSISTENT_CONTAINER=0
      shift
      ;;
    --no-container-binfmt)
      CONTAINER_INSTALL_BINFMT=0
      shift
      ;;
    --auto-install-deps)
      AUTO_INSTALL_DEPS=1
      shift
      ;;
    --no-auto-install-deps)
      AUTO_INSTALL_DEPS=0
      shift
      ;;
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --install)
      INSTALL_TO=1
      shift
      ;;
    --install-only)
      INSTALL_TO=1
      INSTALL_ONLY=1
      shift
      ;;
    --no-install)
      INSTALL_TO=0
      INSTALL_ONLY=0
      shift
      ;;
    --remote-prefix)
      REMOTE_PREFIX="${2:-}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

cd "$NODE_DIR"
ensure_not_source_tree_build
ensure_not_codex_sandbox
ensure_log_file

detected_paths="$(detect_source_and_build_tree "$NODE_DIR")"
source_dir="$(printf '%s\n' "$detected_paths" | sed -n '1p')"
build_tree="$(printf '%s\n' "$detected_paths" | sed -n '2p')"
if [ -n "$source_dir" ] && [ -n "$build_tree" ] && [ "$NODE_DIR" = "$build_tree" ]; then
  sync_source_to_build_tree "$source_dir" "$build_tree"
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
  install_on "$HOST" "$REMOTE_PREFIX"
  exit 0
fi

if [ "$INSTALL_TO" -eq 1 ] && [ "$CLEAN" -eq 0 ] && [ "$CONFIGURE_ONLY" -eq 0 ] && [ -x "$NODE_DIR/out/Release/node" ]; then
  echo "Existing binary found at out/Release/node; skipping rebuild for --install."
  echo "Use --clean --install if you want to rebuild before install."
  install_on "$HOST" "$REMOTE_PREFIX"
  exit 0
fi

ensure_container_runtime
runtime="$(choose_container_runtime 2>/dev/null)"
if [ -z "$runtime" ]; then
  echo "error: no container runtime available after dependency check." >&2
  exit 1
fi

detect_runtime_privileges "$runtime"
ensure_binfmt_if_needed "$runtime"
run_image="$(ensure_builder_image "$runtime")"
ccache_dir="${CCACHE_DIR:-$HOME/.ccache-node-armhf}"
mkdir -p "$ccache_dir"
work_container="$(ensure_work_container "$runtime" "$run_image" "$ccache_dir")"
warn_if_stale_work_container "$runtime" "$work_container" "$run_image"
run_container_build "$runtime" "$run_image" "$work_container"

if [ -x out/Release/node ]; then
  cat <<NEXT

Build complete: $NODE_DIR/out/Release/node
Deploy/check example:
  scp out/Release/node $HOST:/var/tmp/node
  ssh $HOST '/var/tmp/node -v'
NEXT
fi

if [ "$INSTALL_TO" -eq 1 ]; then
  install_on "$HOST" "$REMOTE_PREFIX"
fi
