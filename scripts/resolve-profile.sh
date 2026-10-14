#!/usr/bin/env bash
#
# Resolve workflow inputs into an exact, reproducible build profile.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile-data.sh
. "${SCRIPT_DIR}/lib/profile-data.sh"
# shellcheck source=lib/git-helpers.sh
. "${SCRIPT_DIR}/lib/git-helpers.sh"

: "${INPUT_BUILD_PROFILE:?}"
: "${INPUT_BRANCH_MODE:?}"
: "${INPUT_CLANG_CHOICE:?}"
: "${INPUT_ROOT_SOLUTION:?}"
: "${INPUT_BUILD_MODE:?}"
: "${GITHUB_ENV:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_STEP_SUMMARY:?}"

INPUT_KERNEL_BRANCH="${INPUT_KERNEL_BRANCH:-}"
INPUT_ROM_GKI_MODULE_COMPAT="${INPUT_ROM_GKI_MODULE_COMPAT:-Strict GKI module checks (default)}"

resolve_build_profile "$INPUT_BUILD_PROFILE"
resolve_root_solution "$INPUT_ROOT_SOLUTION"

case "$INPUT_ROM_GKI_MODULE_COMPAT" in
  "Strict GKI module checks (default)") ROM_GKI_MODULE_COMPAT=0 ;;
  "Use existing ROM system_dlkm modules (experimental)")
    if [[ "$PROFILE_ID" != sm8650-oneplus12-crdroid ]]; then
      echo "::error::ROM GKI module compatibility mode is currently validated only for the OnePlus 12 crDroid profile."
      exit 1
    fi
    ROM_GKI_MODULE_COMPAT=1
    ;;
  *)
    echo "::error::Unknown ROM GKI module compatibility mode: $INPUT_ROM_GKI_MODULE_COMPAT"
    exit 1
    ;;
esac

case "$INPUT_BUILD_MODE" in
  "Full build (artifact only)"|"Full build and publish release"|"Patch/config validation only") ;;
  *)
    echo "::error::Unsupported build mode: $INPUT_BUILD_MODE"
    exit 1
    ;;
esac

if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  DEFAULT_KERNEL_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${UPSTREAM_SOC}.git"
  DEFAULT_MODULES_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_modules_and_devicetree_oneplus_${UPSTREAM_SOC}.git"
  KERNEL_CLONE_DIR="${SOC}-kernel"
  MODULES_CLONE_DIR="${SOC}-modules"
else
  DEFAULT_KERNEL_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${UPSTREAM_SOC}.git"
  DEFAULT_MODULES_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${UPSTREAM_SOC}-modules.git"
  KERNEL_CLONE_DIR="${SOC}"
  MODULES_CLONE_DIR="${UPSTREAM_SOC}-modules"
fi
KERNEL_REPO="${KERNEL_REPO_OVERRIDE:-$DEFAULT_KERNEL_REPO}"
MODULES_REPO="${MODULES_REPO_OVERRIDE:-$DEFAULT_MODULES_REPO}"

# Manual branch mode check - ensures user selected branch is strictly honored
if [[ "$INPUT_BRANCH_MODE" == "I want to select the branch myself" ]]; then
  KERNEL_BRANCH="$INPUT_KERNEL_BRANCH"
  if [[ -z "$KERNEL_BRANCH" ]]; then
    echo "::error::Please select a branch when using manual branch mode."
    exit 1
  fi
  if ! git check-ref-format --branch "$KERNEL_BRANCH" >/dev/null 2>&1; then
    echo "::error::Invalid Git branch name: $KERNEL_BRANCH"
    exit 1
  fi
else
  KERNEL_BRANCH="$(git_ls_remote_retry --symref "$KERNEL_REPO" HEAD \
    | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
  if [[ -z "$KERNEL_BRANCH" ]]; then
    echo "::error::Could not detect the default branch from $KERNEL_REPO"
    exit 1
  fi
fi

MODULES_BRANCH="${MODULES_BRANCH_OVERRIDE:-$KERNEL_BRANCH}"

resolve_clang_version "$INPUT_CLANG_CHOICE" "$KERNEL_BRANCH"
infer_android_versions "$KERNEL_BRANCH"
if [[ -z "$SUPPORTED_ANDROID_VERSIONS" ]]; then
  echo "::warning::Android version could not be inferred from '$KERNEL_BRANCH'; package version checking will be disabled."
fi

KSU_REPO=""
KSU_REF=""
KSU_COMMIT=""
case "$KSU_TYPE" in
  None) ;;
  Official-KernelSU)
    KSU_REPO="https://github.com/tiann/KernelSU.git"
    KSU_REF="main"
    ;;
  KernelSU-Next)
    KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
    KSU_REF="dev"
    ;;
  KernelSU-Next-with-susfs|KernelSU-Next-with-susfs-nomount|KernelSU-Next-with-susfs-zeromount)
    KSU_REPO="https://github.com/pershoot/KernelSU-Next.git"
    KSU_REF="dev-susfs"
    ;;
  KowSU)
    KSU_REPO="https://github.com/KOWX712/KernelSU.git"
    KSU_REF="master"
    ;;
  SukiSU-Ultra-with-KPM|SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM|SukiSU-Ultra-with-susfs-zeromount-KPM)
    KSU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"
    KSU_REF="main"
    if [[ "$KSU_TYPE" == *susfs* ]]; then
      KSU_REF="7fbbb1f12e2410b69c8ebf958be84f165b8d0c93"
      KSU_COMMIT="$KSU_REF"
    fi
    ;;
  ReSukiSU*)
    KSU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
    KSU_REF="main"
    if [[ "$KSU_TYPE" == *susfs* ]]; then
      KSU_REF="fa8311f632a215b5381ec644627c6198d1e8a13e"
      KSU_COMMIT="$KSU_REF"
    fi
    ;;
esac

if [[ -n "$KSU_REPO" && -z "$KSU_COMMIT" ]]; then
  KSU_COMMIT="$(git_ls_remote_retry --exit-code "$KSU_REPO" "refs/heads/${KSU_REF}" \
    | awk 'NR == 1 {print $1}')"
  if [[ ! "$KSU_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::Could not resolve $KSU_REPO branch '$KSU_REF' to a commit."
    exit 1
  fi
fi

SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_REF=""
SUSFS_COMMIT=""
SUSFS_PATCH_FILE=""
SUSFS_MIN_VERSION=""
if [[ "$KSU_TYPE" == *susfs* ]]; then
  SUSFS_MIN_VERSION="2.2.0"
  resolve_susfs_settings "$SOC" "$KERNEL_BRANCH"
  case "$KSU_TYPE" in
    SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM|SukiSU-Ultra-with-susfs-zeromount-KPM)
      SUSFS_COMMIT="$(sukisu_compatible_susfs_commit "$SUSFS_REF")"
      ;;
    *)
      SUSFS_COMMIT="$(git_ls_remote_retry --exit-code "$SUSFS_REPO" "refs/heads/${SUSFS_REF}" \
        | awk 'NR == 1 {print $1}')"
      ;;
  esac
  if [[ ! "$SUSFS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::Could not resolve susfs branch '$SUSFS_REF' to a commit."
    exit 1
  fi
fi

ZEROMOUNT_REPO="https://github.com/troy896/Super-Builders.git"
ZEROMOUNT_COMMIT=""
ZEROMOUNT_GKI_TAG=""
if [[ "$KSU_TYPE" == *zeromount* ]]; then
  ZEROMOUNT_COMMIT="2978dcad87dc7055e2e4596c603313c553a9a4b4"
  ZEROMOUNT_GKI_TAG="${SUSFS_REF#gki-}"
fi

NOMOUNT_REPO="https://github.com/maxsteeel/nomount.git"
NOMOUNT_REF=""
NOMOUNT_COMMIT=""
if [[ "$KSU_TYPE" == *nomount* ]]; then
  NOMOUNT_REF="master"
  NOMOUNT_COMMIT="$(git_ls_remote_retry --exit-code "$NOMOUNT_REPO" "refs/heads/${NOMOUNT_REF}" \
    | awk 'NR == 1 {print $1}')"
  if [[ ! "$NOMOUNT_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::Could not resolve NoMount branch '$NOMOUNT_REF' to a commit."
    exit 1
  fi
fi

KERNEL_COMMIT="$(git_ls_remote_retry --exit-code --heads "$KERNEL_REPO" "$KERNEL_BRANCH" \
  | awk 'NR == 1 {print $1}')"
if [[ ! "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Branch '$KERNEL_BRANCH' was not found in $KERNEL_REPO"
  exit 1
fi

MODULES_COMMIT="$(git_ls_remote_retry --exit-code --heads "$MODULES_REPO" "$MODULES_BRANCH" \
  | awk 'NR == 1 {print $1}')"
if [[ ! "$MODULES_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Branch '$MODULES_BRANCH' was not found in $MODULES_REPO"
  exit 1
fi

ANYKERNEL_REPO="https://github.com/osm0sis/AnyKernel3.git"
ANYKERNEL_COMMIT="020dfeccf9d7e962a48400fc94d3e451df92eead"

{
  echo "PROFILE_ID=$PROFILE_ID"
  echo "TARGET_NAME=$TARGET_NAME"
  echo "DEVICE_CODENAMES=$DEVICE_CODENAMES"
  echo "DEVICE_NAMES=$DEVICE_NAMES"
  echo "SUPPORTED_ANDROID_VERSIONS=$SUPPORTED_ANDROID_VERSIONS"
  echo "BUILD_MODE=$INPUT_BUILD_MODE"
  echo "SOC=$SOC"
  echo "UPSTREAM_SOC=$UPSTREAM_SOC"
  echo "PLATFORM_SLUG=$PLATFORM_SLUG"
  echo "PLATFORM_NAME=$PLATFORM_NAME"
  echo "BUILD_CONFIGS=$BUILD_CONFIGS"
  echo "KERNEL_MAKE_FLAGS=$KERNEL_MAKE_FLAGS"
  echo "ROM_GKI_MODULE_COMPAT=$ROM_GKI_MODULE_COMPAT"
  echo "SOURCE_LAYOUT=$SOURCE_LAYOUT"
  echo "KERNEL_SOURCE=$KERNEL_SOURCE"
  echo "SOURCE_NAME=$SOURCE_NAME"
  echo "SOURCE_SLUG=$SOURCE_SLUG"
  echo "KERNEL_REPO=$KERNEL_REPO"
  echo "MODULES_REPO=$MODULES_REPO"
  echo "KERNEL_CLONE_DIR=$KERNEL_CLONE_DIR"
  echo "MODULES_CLONE_DIR=$MODULES_CLONE_DIR"
  echo "OFFICIAL_BUILD_TARGET=$OFFICIAL_BUILD_TARGET"
  echo "OFFICIAL_GKI_FRAGMENT=$OFFICIAL_GKI_FRAGMENT"
  echo "KERNEL_BRANCH=$KERNEL_BRANCH"
  echo "MODULES_BRANCH=$MODULES_BRANCH"
  echo "KERNEL_COMMIT=$KERNEL_COMMIT"
  echo "MODULES_COMMIT=$MODULES_COMMIT"
  echo "CLANG_VERSION=$CLANG_VERSION"
  echo "KSU_TYPE=$KSU_TYPE"
  echo "KSU_REPO=$KSU_REPO"
  echo "KSU_REF=$KSU_REF"
  echo "KSU_COMMIT=$KSU_COMMIT"
  echo "SUSFS_REPO=$SUSFS_REPO"
  echo "SUSFS_REF=$SUSFS_REF"
  echo "SUSFS_COMMIT=$SUSFS_COMMIT"
  echo "SUSFS_PATCH_FILE=$SUSFS_PATCH_FILE"
  echo "SUSFS_MIN_VERSION=$SUSFS_MIN_VERSION"
  echo "ZEROMOUNT_REPO=$ZEROMOUNT_REPO"
  echo "ZEROMOUNT_COMMIT=$ZEROMOUNT_COMMIT"
  echo "ZEROMOUNT_GKI_TAG=$ZEROMOUNT_GKI_TAG"
  echo "NOMOUNT_REPO=$NOMOUNT_REPO"
  echo "NOMOUNT_REF=$NOMOUNT_REF"
  echo "NOMOUNT_COMMIT=$NOMOUNT_COMMIT"
  echo "ANYKERNEL_REPO=$ANYKERNEL_REPO"
  echo "ANYKERNEL_COMMIT=$ANYKERNEL_COMMIT"
} >> "$GITHUB_ENV"

{
  echo "profile_id=$PROFILE_ID"
  echo "target_name=$TARGET_NAME"
  echo "device_codenames=$DEVICE_CODENAMES"
  echo "device_names=$DEVICE_NAMES"
  echo "supported_android_versions=$SUPPORTED_ANDROID_VERSIONS"
  echo "build_mode=$INPUT_BUILD_MODE"
  echo "soc=$SOC"
  echo "upstream_soc=$UPSTREAM_SOC"
  echo "platform_slug=$PLATFORM_SLUG"
  echo "platform_name=$PLATFORM_NAME"
  echo "kernel_source=$KERNEL_SOURCE"
  echo "source_name=$SOURCE_NAME"
  echo "source_slug=$SOURCE_SLUG"
  echo "source_layout=$SOURCE_LAYOUT"
  echo "kernel_branch=$KERNEL_BRANCH"
  echo "modules_branch=$MODULES_BRANCH"
  echo "kernel_commit=$KERNEL_COMMIT"
  echo "modules_commit=$MODULES_COMMIT"
  echo "clang_version=$CLANG_VERSION"
  echo "ksu_type=$KSU_TYPE"
  echo "rom_gki_module_compat=$ROM_GKI_MODULE_COMPAT"
  echo "ksu_commit=$KSU_COMMIT"
  echo "susfs_ref=$SUSFS_REF"
  echo "susfs_commit=$SUSFS_COMMIT"
  echo "susfs_min_version=$SUSFS_MIN_VERSION"
  echo "zeromount_commit=$ZEROMOUNT_COMMIT"
  echo "zeromount_gki_tag=$ZEROMOUNT_GKI_TAG"
  echo "nomount_ref=$NOMOUNT_REF"
  echo "nomount_commit=$NOMOUNT_COMMIT"
  echo "anykernel_commit=$ANYKERNEL_COMMIT"
} >> "$GITHUB_OUTPUT"
