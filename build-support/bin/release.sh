#!/usr/bin/env bash
# Copyright 2014 Pants project contributors (see CONTRIBUTORS.md).
# Licensed under the Apache License, Version 2.0 (see LICENSE).

set -e

ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && cd "$(git rev-parse --show-toplevel)" && pwd)
source ${ROOT}/build-support/common.sh

PY=$(which python2.7 || exit 0)
[[ -n "${PY}" ]] || die "You must have python2.7 installed and on the path to release."
export PY

function run_local_pants() {
  ${ROOT}/pants "$@"
}

# NB: Pants core does not have the ability to change its own version, so we compute the
# suffix here and mutate the VERSION_FILE to affect the current version.
readonly VERSION_FILE="${ROOT}/src/python/pants/VERSION"
PANTS_STABLE_VERSION="$(cat "${VERSION_FILE}")"
HEAD_SHA=$(git rev-parse --verify HEAD)
readonly PANTS_UNSTABLE_VERSION="${PANTS_STABLE_VERSION}+${HEAD_SHA:0:8}"

readonly DEPLOY_DIR="${ROOT}/dist/deploy"
readonly DEPLOY_3RDPARTY_WHEELS_PATH="wheels/3rdparty/${HEAD_SHA}"
readonly DEPLOY_PANTS_WHEELS_PATH="wheels/pantsbuild.pants/${HEAD_SHA}"
readonly DEPLOY_3RDPARTY_WHEEL_DIR="${DEPLOY_DIR}/${DEPLOY_3RDPARTY_WHEELS_PATH}"
readonly DEPLOY_PANTS_WHEEL_DIR="${DEPLOY_DIR}/${DEPLOY_PANTS_WHEELS_PATH}"

# A space-separated list of pants packages to include in any pexes that are built: by default,
# only pants core is included.
: ${PANTS_PEX_PACKAGES:="pantsbuild.pants"}

# URL from which pex release binaries can be downloaded.
: ${PEX_DOWNLOAD_PREFIX:="https://github.com/pantsbuild/pex/releases/download"}

source ${ROOT}/contrib/release_packages.sh

function requirement() {
  package="$1"
  grep "^${package}[^A-Za-z0-9]" "${ROOT}/3rdparty/python/requirements.txt" || die "Could not find requirement for ${package}"
}

function run_pex27() {
  # TODO: Cache this in case we run pex multiple times
  (
    PEX_VERSION="$(requirement pex | sed -e "s|pex==||")"
    PEX_PEX=pex27

    pexdir="$(mktemp -d -t build_pex.XXXXX)"
    trap "rm -rf ${pexdir}" EXIT

    pex="${pexdir}/${PEX_PEX}"

    curl -sSL "${PEX_DOWNLOAD_PREFIX}/v${PEX_VERSION}/${PEX_PEX}" > "${pex}"
    chmod +x "${pex}"
    "${pex}" "$@"
  )
}

function run_packages_script() {
  (
    cd "${ROOT}"
    run_pex27 "$(requirement future)" "$(requirement beautifulsoup4)" "$(requirement configparser)" "$(requirement subprocess32)" -- "${ROOT}/src/python/pants/releases/packages.py" "$@"
  )
}

function find_pkg() {
  local -r pkg_name=$1
  local -r version=$2
  local -r search_dir=$3
  find "${search_dir}" -type f -name "${pkg_name}-${version}-*.whl"
}

function pkg_pants_install_test() {
  local version=$1
  shift
  local PIP_ARGS="$@"
  pip install ${PIP_ARGS} "pantsbuild.pants==${version}" || \
    die "pip install of pantsbuild.pants failed!"
  execute_packaged_pants_with_internal_backends list src:: || \
    die "'pants list src::' failed in venv!"
  [[ "$(execute_packaged_pants_with_internal_backends --version 2>/dev/null)" \
     == "${version}" ]] || die "Installed version of pants does match requested version!"
}

function pkg_testinfra_install_test() {
  local version=$1
  shift
  local PIP_ARGS="$@"
  pip install ${PIP_ARGS} "pantsbuild.pants.testinfra==${version}" && \
  python -c "import pants_test"
}

#
# End of package declarations.
#

REQUIREMENTS_3RDPARTY_FILES=(
  "3rdparty/python/requirements.txt"
  "3rdparty/python/twitter/commons/requirements.txt"
)

# When we do (dry-run) testing, we need to run the packaged pants.
# It doesn't have internal backend plugins so when we execute it
# at the repo build root, the root pants.ini will ask it to load
# internal backend packages and their dependencies which it doesn't have,
# and it'll fail. To solve that problem, we load the internal backend package
# dependencies into the pantsbuild.pants venv.
function execute_packaged_pants_with_internal_backends() {
  pip install --ignore-installed \
    -r pants-plugins/3rdparty/python/requirements.txt &> /dev/null && \
  pants \
    --no-verify-config \
    --pythonpath="['pants-plugins/src/python']" \
    --backend-packages="[\
        'pants.backend.codegen',\
        'pants.backend.docgen',\
        'pants.backend.graph_info',\
        'pants.backend.jvm',\
        'pants.backend.native',\
        'pants.backend.project_info',\
        'pants.backend.python',\
        'internal_backend.repositories',\
        'internal_backend.sitegen',\
        'internal_backend.utilities',\
      ]" \
    "$@"
}

function pkg_name() {
  PACKAGE=$1
  eval NAME=\${$PACKAGE[0]}
  echo ${NAME}
}

function pkg_build_target() {
  PACKAGE=$1
  eval TARGET=\${$PACKAGE[1]}
  echo ${TARGET}
}

function bdist_wheel_flags() {
  PACKAGE=$1
  eval BDIST_WHEEL_FLAGS=\${$PACKAGE[3]}
    echo ${BDIST_WHEEL_FLAGS}
}

function pants_version_reset() {
  pushd ${ROOT} > /dev/null
    git checkout -- ${VERSION_FILE}
  popd > /dev/null
}

function pants_version_set() {
  # Mutates `src/python/pants/VERSION` to temporarily override it. Sets a `trap` to restore to
  # HEAD on exit.
  local version=$1
  trap pants_version_reset EXIT
  echo "${version}" > "${VERSION_FILE}"
}

function build_3rdparty_packages() {
  # Builds whls for 3rdparty dependencies of pants.
  local version=$1

  rm -rf "${DEPLOY_3RDPARTY_WHEEL_DIR}"
  mkdir -p "${DEPLOY_3RDPARTY_WHEEL_DIR}/${version}"

  local req_args=""
  for req_file in "${REQUIREMENTS_3RDPARTY_FILES[@]}"; do
    req_args="${req_args} -r ${ROOT}/$req_file"
  done

  start_travis_section "3rdparty" "Building 3rdparty whls from ${REQUIREMENTS_3RDPARTY_FILES[@]}"
  activate_tmp_venv

  pip wheel --wheel-dir="${DEPLOY_3RDPARTY_WHEEL_DIR}/${version}" ${req_args}

  deactivate
  end_travis_section
}

function build_pants_packages() {
  local version=$1

  rm -rf "${DEPLOY_PANTS_WHEEL_DIR}"
  mkdir -p "${DEPLOY_PANTS_WHEEL_DIR}/${version}"

  pants_version_set "${version}"

  start_travis_section "${NAME}" "Building packages"
  packages=($(run_packages_script build_and_print "${version}"))
  for package in "${packages[@]}"
  do
    (
      wheel=$(find_pkg ${package} ${version} "${ROOT}/dist") && \
      cp -p "${wheel}" "${DEPLOY_PANTS_WHEEL_DIR}/${version}"
    ) || die "Failed to find package ${package}-${version}!"
  done
  end_travis_section

  pants_version_reset
}

function build_fs_util() {
  local version=$1

  start_travis_section "fs_util" "Building fs_util binary"
  # fs_util is a standalone tool which can be used to inspect and manipulate
  # Pants's engine's file store, and interact with content addressable storage
  # services which implement the Bazel remote execution API.
  # It is a useful standalone tool which people may want to consume, for
  # instance when debugging pants issues, or if they're implementing a remote
  # execution API. Accordingly, we include it in our releases.
  (
    set -e
    RUST_BACKTRACE=1 "${ROOT}/build-support/bin/native/cargo" build --release \
      --manifest-path="${ROOT}/src/rust/engine/fs/fs_util/Cargo.toml"
    dst_dir="${DEPLOY_DIR}/bin/fs_util/$("${ROOT}/build-support/bin/get_os.sh")/${version}"
    mkdir -p "${dst_dir}"
    cp "${ROOT}/src/rust/engine/target/release/fs_util" "${dst_dir}/"
  ) || die "Failed to build fs_util"
  end_travis_section
}

function activate_tmp_venv() {
  VENV_DIR=$(mktemp -d -t pants.XXXXX) && \
  ${ROOT}/build-support/virtualenv $VENV_DIR && \
  source $VENV_DIR/bin/activate
}

function pre_install() {
  start_travis_section "SetupVenv" "Setting up virtualenv"
  activate_tmp_venv
  end_travis_section
}

function post_install() {
  # this assume pre_install is called and a new temp venv activation has been done.
  if [[ "${pause_after_venv_creation}" == "true" ]]; then
    cat <<EOM

If you want to poke around with the new version of pants that has been built
and installed in a temporary virtualenv, fire up another shell window and type:

  source ${VENV_DIR}/bin/activate
  cd ${ROOT}

From there, you can run 'pants' (not './pants') to do some testing.

When you're done testing, press enter to continue.
EOM
    read
  fi
  deactivate
}

function install_and_test_packages() {
  local VERSION=$1
  shift
  local PIP_ARGS=(
    "${VERSION}"
    "$@"
    --quiet
    # Prefer remote or `--find-links` packages to cache contents.
    --no-cache-dir
  )

  pre_install || die "Failed to setup virtualenv while testing ${NAME}-${VERSION}!"

  # Avoid caching plugin installs.
  export PANTS_PLUGIN_CACHE_DIR=$(mktemp -d -t plugins_cache.XXXXX)
  trap "rm -rf ${PANTS_PLUGIN_CACHE_DIR}" EXIT

  packages=($(run_packages_script list | grep '.' | awk '{print $1}'))

  export PANTS_PYTHON_REPOS_REPOS="${DEPLOY_PANTS_WHEEL_DIR}/${VERSION}"
  for package in "${packages[@]}"
  do
    start_travis_section "${package}" "Installing and testing package ${package}-${VERSION}"
    eval pkg_${package##*\.}_install_test ${PIP_ARGS[@]} || \
      die "Failed to install and test package ${package}-${VERSION}!"
    end_travis_section
  done
  unset PANTS_PYTHON_REPOS_REPOS

  post_install || die "Failed to deactivate virtual env while testing ${NAME}-${VERSION}!"
}

function dry_run_install() {
  # Build a complete set of whls, and then ensure that we can install pants using only whls.
  local VERSION="${PANTS_UNSTABLE_VERSION}"
  build_pants_packages "${VERSION}" && \
  build_3rdparty_packages "${VERSION}" && \
  install_and_test_packages "${VERSION}" \
    --only-binary=:all: \
    -f "${DEPLOY_3RDPARTY_WHEEL_DIR}/${VERSION}" -f "${DEPLOY_PANTS_WHEEL_DIR}/${VERSION}"
}

ALLOWED_ORIGIN_URLS=(
  git@github.com:pantsbuild/pants.git
  git@github.com:pantsbuild/pants
  https://github.com/pantsbuild/pants.git
  https://github.com/pantsbuild/pants
)

function check_origin() {
  banner "Checking for a valid git origin"

  origin_url="$(git remote -v | grep origin | grep "\(push\)" | cut -f2 | cut -d' ' -f1)"
  for url in "${ALLOWED_ORIGIN_URLS[@]}"
  do
    if [[ "${origin_url}" == "${url}" ]]
    then
      return
    fi
  done
  msg=$(cat << EOM
Your origin url is not valid for releasing:
  ${origin_url}

It must be one of:
$(echo "${ALLOWED_ORIGIN_URLS[@]}" | tr ' ' '\n' | sed -E "s|^|  |")
EOM
)
  die "$msg"
}

function get_branch() {
  git branch | grep -E '^\* ' | cut -d' ' -f2-
}

function check_clean_branch() {
  banner "Checking for a clean branch"

  pattern="^(master)|([0-9]+\.[0-9]+\.x)$"
  branch=$(get_branch)
  [[ -z "$(git status --porcelain)" &&
     $branch =~ $pattern
  ]] || die "You are not on a clean branch."
}

function check_pgp() {
  banner "Checking pgp setup"

  msg=$(cat << EOM
You must configure your release signing pgp key.

You can configure the key by running:
  git config --add user.signingkey [key id]

Key id should be the id of the pgp key you have registered with pypi.
EOM
)
  get_pgp_keyid &> /dev/null || die "${msg}"
  echo "Found the following key for release signing:"
  $(get_pgp_program) -k $(get_pgp_keyid)
  read -p "Is this the correct key? [Yn]: " answer
  [[ "${answer:-y}" =~ [Yy]([Ee][Ss])? ]] || die "${msg}"
}

function get_pgp_keyid() {
  git config --get user.signingkey
}

function get_pgp_program() {
  git config --get gpg.program || echo "gpg"
}

function tag_release() {
  release_version="${PANTS_STABLE_VERSION}" && \
  tag_name="release_${release_version}" && \
  git tag -f \
    --local-user=$(get_pgp_keyid) \
    -m "pantsbuild.pants release ${release_version}" \
    ${tag_name} && \
  git push -f git@github.com:pantsbuild/pants.git ${tag_name}
}

function publish_docs_if_master() {
  branch=$(get_branch)
  if [[ "${branch}" == "master" ]]; then
    ${ROOT}/build-support/bin/publish_docs.sh -p -y
  else
    echo "Skipping docsite publishing on non-master branch (${branch})."
  fi
}

function check_owners() {
  run_packages_script check-my-ownership
}

function reversion_whls() {
  # Reversions all whls from an input directory to an output directory.
  # Adds one pants-specific glob to match the `VERSION` file in `pantsbuild.pants`.
  local src_dir=$1
  local dest_dir=$2
  local output_version=$3

  for whl in `ls -1 "${src_dir}"/*.whl`; do
    run_local_pants -q run src/python/pants/releases:reversion -- \
      --glob='pants/VERSION' \
      "${whl}" "${dest_dir}" "${output_version}" \
      || die "Could not reversion whl ${whl} to ${output_version}"
  done
}

readonly BINARY_BASE_URL=https://binaries.pantsbuild.org

function list_prebuilt_wheels() {
  # List prebuilt wheels as tab-separated tuples of filename and URL-encoded name.
  wheel_listing="$(mktemp -t pants.wheels.XXXXX)"
  trap "rm -f ${wheel_listing}" RETURN

  for wheels_path in "${DEPLOY_PANTS_WHEELS_PATH}" "${DEPLOY_3RDPARTY_WHEELS_PATH}"; do
    curl -sSL "${BINARY_BASE_URL}/?prefix=${wheels_path}" > "${wheel_listing}"
    "${PY}" << EOF
from __future__ import print_function
import sys
import urllib
import xml.etree.ElementTree as ET
root = ET.parse("${wheel_listing}")
ns = {'s3': 'http://s3.amazonaws.com/doc/2006-03-01/'}
for key in root.findall('s3:Contents/s3:Key', ns):
  # Because filenames may contain characters that have different meanings
  # in URLs (namely '+'), # print the key both as url-encoded and as a file path.
  print('{}\t{}'.format(key.text, urllib.quote_plus(key.text)))
EOF
 done
}

function fetch_prebuilt_wheels() {
  local -r to_dir="$1"

  banner "Fetching prebuilt wheels for ${PANTS_UNSTABLE_VERSION}"
  (
    cd "${to_dir}"
    list_prebuilt_wheels | {
      while read path_tuple
      do
        local file_path=$(echo "$path_tuple" | awk -F'\t' '{print $1}')
        local url_path=$(echo "$path_tuple" | awk -F'\t' '{print $2}')
        echo "${BINARY_BASE_URL}/${url_path}:"
        local dest="${to_dir}/${file_path}"
        mkdir -p "$(dirname "${dest}")"
        curl --fail --progress-bar -o "${dest}" "${BINARY_BASE_URL}/${url_path}" \
          || die "Could not fetch ${dest}."
      done
    }
  )
}

function fetch_and_check_prebuilt_wheels() {
  # Fetches wheels from S3 into subdirectories of the given directory.
  local check_dir="$1"
  if [[ -z "${check_dir}" ]]
  then
    check_dir=$(mktemp -d -t pants.wheel_check.XXXXX)
    trap "rm -rf ${check_dir}" RETURN
  fi

  banner "Checking prebuilt wheels for ${PANTS_UNSTABLE_VERSION}"
  fetch_prebuilt_wheels "${check_dir}"

  local missing=()
  RELEASE_PACKAGES=($(run_packages_script list | grep '.' | awk '{print $1}'))
  for PACKAGE in "${RELEASE_PACKAGES[@]}"
  do
    NAME=$(pkg_name $PACKAGE)
    packages=($(find_pkg "${NAME}" "${PANTS_UNSTABLE_VERSION}" "${check_dir}"))
    if [ ${#packages[@]} -eq 0 ]; then
      missing+=("${NAME}")
      continue
    fi

    # Confirm that if the package is not cross platform that we have whls for two platforms.
    local cross_platform=""
    for package in "${packages[@]}"
    do
      if [[ "${package}" =~ "-none-any.whl" ]]
      then
        cross_platform="true"
      fi
    done

    if [ "${cross_platform}" != "true" ] && [ ${#packages[@]} -ne 2 ]; then
      missing+=("${NAME} (expected whls for each platform: had only ${packages[@]})")
      continue
    fi
  done

  if (( ${#missing[@]} > 0 ))
  then
    echo "Failed to find prebuilt packages for:"
    for package in "${missing[@]}"
    do
      echo "  ${package}"
    done
    die
  fi
}

function adjust_wheel_platform() {
  # Renames wheels to adjust their tag from a src platform to a dst platform.
  local src_plat="$1"
  local dst_plat="$2"
  local dir="$3"
  for src_whl in `find "${dir}" -name '*'"${src_plat}.whl"`; do
    local dst_whl=${src_whl/$src_plat/$dst_plat}
    mv -f "${src_whl}" "${dst_whl}"
  done
}

function activate_twine() {
  local -r venv_dir="${ROOT}/build-support/twine-deps.venv"

  rm -rf "${venv_dir}"
  "${ROOT}/build-support/virtualenv" "${venv_dir}"
  source "${venv_dir}/bin/activate"
  pip install twine
}

function execute_pex() {
  run_pex27 \
      --no-build \
      --no-pypi \
      --disable-cache \
      -f "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_UNSTABLE_VERSION}" \
      -f "${DEPLOY_3RDPARTY_WHEEL_DIR}/${PANTS_UNSTABLE_VERSION}" \
      "$@"
}

function build_pex() {
  # Builds a pex from the current UNSTABLE version.
  # If $1 == "build", builds a pex just for this platform, from source.
  # If $1 == "fetch", fetches the linux and OSX wheels which were built on travis.
  local mode="$1"

  local linux_platform="linux_x86_64"
  local osx_platform="macosx_10.11_x86_64"

  case "${mode}" in
    build)
      case "$(uname)" in
	Darwin)
	  local platform="${osx_platform}"
	  ;;
	Linux)
	  local platform="${linux_platform}"
	  ;;
	*)
	  echo >&2 "Unknown uname"
	  exit 1
	  ;;
      esac
      local platforms=("${platform}")
      local dest="${ROOT}/dist/pants.${PANTS_UNSTABLE_VERSION}.${platform}.pex"
      local stable_dest="${DEPLOY_DIR}/pex/pants.${PANTS_STABLE_VERSION}.${platform}.pex"
      ;;
    fetch)
      local platforms=("${linux_platform}" "${osx_platform}")
      local dest="${ROOT}/dist/pants.${PANTS_UNSTABLE_VERSION}.pex"
      local stable_dest="${DEPLOY_DIR}/pex/pants.${PANTS_STABLE_VERSION}.pex"
      ;;
    *)
      echo >&2 "Bad build_pex mode ${mode}"
      exit 1
      ;;
  esac

  rm -rf "${DEPLOY_DIR}"
  mkdir -p "${DEPLOY_DIR}"

  if [[ "${mode}" == "fetch" ]]; then
    fetch_and_check_prebuilt_wheels "${DEPLOY_DIR}"
  else
    build_pants_packages "${PANTS_UNSTABLE_VERSION}"
    build_3rdparty_packages "${PANTS_UNSTABLE_VERSION}"
  fi

  local requirements=()
  for pkg_name in $PANTS_PEX_PACKAGES; do
    requirements=("${requirements[@]}" "${pkg_name}==${PANTS_UNSTABLE_VERSION}")
  done

  local platform_flags=()
  for platform in "${platforms[@]}"; do
    platform_flags=("${platform_flags[@]}" "--platform=${platform}")
  done

  execute_pex \
    -o "${dest}" \
    --script=pants \
    "${platform_flags[@]}" \
    "${requirements[@]}"

  if [[ "${PANTS_PEX_RELEASE}" == "stable" ]]; then
    mkdir -p "$(dirname "${stable_dest}")"
    cp "${dest}" "${stable_dest}"
  fi

  banner "Successfully built ${dest}"
}

function publish_packages() {
  rm -rf "${DEPLOY_PANTS_WHEEL_DIR}"
  mkdir -p "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_STABLE_VERSION}"

  start_travis_section "Publishing" "Publishing packages for ${PANTS_STABLE_VERSION}"

  # Fetch unstable wheels, rename any linux whls to manylinux, and reversion them
  # from PANTS_UNSTABLE_VERSION to PANTS_STABLE_VERSION
  fetch_and_check_prebuilt_wheels "${DEPLOY_DIR}"
  adjust_wheel_platform "linux_x86_64" "manylinux1_x86_64" \
    "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_UNSTABLE_VERSION}"
  reversion_whls \
    "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_UNSTABLE_VERSION}" \
    "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_STABLE_VERSION}" \
    "${PANTS_STABLE_VERSION}"

  activate_twine
  trap deactivate RETURN

  twine upload --sign --sign-with=$(get_pgp_program) --identity=$(get_pgp_keyid) \
    "${DEPLOY_PANTS_WHEEL_DIR}/${PANTS_STABLE_VERSION}"/*.whl

  end_travis_section
}

function usage() {
  echo "With no options all packages are built, smoke tested and published to"
  echo "PyPi.  Credentials are needed for this as described in the"
  echo "release docs: http://pantsbuild.org/release.html"
  echo
  echo "Usage: $0 [-d] [-c] (-h|-n|-t|-l|-o|-e|-p)"
  echo " -d  Enables debug mode (verbose output, script pauses after venv creation)"
  echo " -h  Prints out this help message."
  echo " -n  Performs a release dry run."
  echo "       All package distributions will be built, installed locally in"
  echo "       an ephemeral virtualenv and exercised to validate basic"
  echo "       functioning."
  echo " -t  Tests a live release."
  echo "       Ensures the latest packages have been propagated to PyPi"
  echo "       and can be installed in an ephemeral virtualenv."
  echo " -l  Lists all pantsbuild packages that this script releases."
  echo " -o  Lists all pantsbuild package owners."
  echo " -e  Check that wheels are prebuilt for this release."
  echo " -p  Build a pex from prebuilt wheels for this release."
  echo " -q  Build a pex which only works on the host platform, using the code as exists on disk."
  echo
  echo "All options (except for '-d') are mutually exclusive."

  if (( $# > 0 )); then
    die "$@"
  else
    exit 0
  fi
}

while getopts "hdntcloepqw" opt; do
  case ${opt} in
    h) usage ;;
    d) debug="true" ;;
    n) dry_run="true" ;;
    t) test_release="true" ;;
    l) run_packages_script list ; exit $? ;;
    o) run_packages_script list-owners ; exit $? ;;
    e) fetch_and_check_prebuilt_wheels ; exit $? ;;
    p) build_pex fetch ; exit $? ;;
    q) build_pex build ; exit $? ;;
    w) list_prebuilt_wheels ; exit $? ;;
    *) usage "Invalid option: -${OPTARG}" ;;
  esac
done

if [[ "${debug}" == "true" ]]; then
  set -x
  pause_after_venv_creation="true"
fi

if [[ "${dry_run}" == "true" && "${test_release}" == "true" ]]; then
  usage "The dry run and test options are mutually exclusive, pick one."
elif [[ "${dry_run}" == "true" ]]; then
  banner "Performing a dry run release" && \
  (
    dry_run_install && build_fs_util "${PANTS_UNSTABLE_VERSION}" && \
    banner "Dry run release succeeded"
  ) || die "Dry run release failed."
elif [[ "${test_release}" == "true" ]]; then
  banner "Installing and testing the latest released packages" && \
  (
    install_and_test_packages "${PANTS_STABLE_VERSION}" && \
    banner "Successfully installed and tested the latest released packages"
  ) || die "Failed to install and test the latest released packages."
else
  banner "Releasing packages to PyPi" && \
  (
    check_origin && check_clean_branch && check_pgp && check_owners && \
      publish_packages && tag_release && publish_docs_if_master && \
      banner "Successfully released packages to PyPi"
  ) || die "Failed to release packages to PyPi."
fi
