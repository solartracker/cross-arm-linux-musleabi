#!/bin/bash
################################################################################
# build-arm-linux-musleabi.sh
#
# Builds a cross-compiler for ARMv7 soft-float musl libc
#
# Copyright (C) 2025 Richard Elwell
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
CACHED_DIR="${PARENT_DIR}/solartracker-sources"
set -e
set -x

################################################################################
# Helpers

# If autoconf/configure fails due to missing libraries or undefined symbols, you
# immediately see all undefined references without having to manually search config.log
handle_configure_error() {
    local rc=$1

    #grep -R --include="config.log" --color=always "undefined reference" .
    #find . -name "config.log" -exec grep -H "undefined reference" {} \;
    find . -name "config.log" -exec grep -H -E "undefined reference|can't load library|unrecognized command-line option" {} \;

    # Force failure if rc is zero, since error was detected
    [ "${rc}" -eq 0 ] && return 1

    return ${rc}
}

################################################################################
# Package management

# new files:       rw-r--r-- (644)
# new directories: rwxr-xr-x (755)
umask 022

# Checksum verification for downloaded file
verify_hash() {
    [ -n "$1" ] || return 1

    local file="$1"
    local expected="$2"
    local option="$3"
    local actual=""

    if [ ! -f "${file}" ]; then
        echo "ERROR: File not found: ${file}"
        return 1
    fi

    if [ -z "${option}" ]; then
        # hash the compressed binary file. this method is best when downloading
        # compressed binary files.
        actual="$(sha256sum "${file}" | awk '{print $1}')"
    elif [ "${option}" == "tar_extract" ]; then
        # hash the data, file names, directory names. this method is best when
        # archiving Github repos.
        actual="$(tar -xJOf "${file}" | sha256sum | awk '{print $1}')"
    elif [ "${option}" == "xz_extract" ]; then
        # hash the data, file names, directory names, timestamps, permissions, and
        # tar internal structures. this method is not as "future-proof" for archiving
        # Github repos because it is possible that the tar internal structures
        # could change over time as the tar implementations evolve.
        actual="$(xz -dc "${file}" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi

    if [ "${actual}" != "${expected}" ]; then
        echo "ERROR: SHA256 mismatch for ${file}"
        echo "Expected: ${expected}"
        echo "Actual:   ${actual}"
        return 1
    fi

    echo "SHA256 OK: ${file}"
    return 0
}

retry() {
    local max=$1
    shift
    local i=1
    while :; do
        if ! "$@"; then
            if [ "${i}" -ge "${max}" ]; then
                return 1
            fi
            i=$((i + 1))
            sleep 10
        else
            return 0
        fi
    done
}

wget_clean() {
    [ -n "$1" ]          || return 1
    [ -n "$2" ]          || return 1
    [ -n "$3" ]          || return 1

    local temp_path="$1"
    local source_url="$2"
    local target_path="$3"

    rm -f "${temp_path}"
    if ! wget -O "${temp_path}" --tries=9 --retry-connrefused --waitretry=5 "${source_url}"; then
        rm -f "${temp_path}"
        return 1
    else
        if ! mv -f "${temp_path}" "${target_path}"; then
            rm -f "${temp_path}" "${target_path}"
            return 1
        fi
    fi

    return 0
}

download()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "${CACHED_DIR}" ] || return 1

    local source_url="$1"
    local source="$2"
    local target_dir="$3"
    local cached_path="${CACHED_DIR}/${source}"
    local target_path="${target_dir}/${source}"
    local temp_path=""

    if [ ! -f "${cached_path}" ]; then
        mkdir -p "${CACHED_DIR}"
        if [ ! -f "${target_path}" ]; then
            cleanup() { rm -f "${cached_path}" "${temp_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            temp_path=$(mktemp "${cached_path}.XXXXXX")
            if ! retry 100 wget_clean "${temp_path}" "${source_url}" "${cached_path}"; then
                return 1
            fi
            trap - EXIT INT TERM
        else
            cleanup() { rm -f "${cached_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            if ! mv -f "${target_path}" "${cached_path}"; then
                return 1
            fi
            trap - EXIT INT TERM
        fi
    fi

    if [ ! -f "${target_path}" ]; then
        if [ -f "${cached_path}" ]; then
            ln -sfn "${cached_path}" "${target_path}"
        fi
    fi

    return 0
) # END sub-shell

clone_github()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "$4" ]            || return 1
    [ -n "$5" ]            || return 1
    [ -n "${CACHED_DIR}" ] || return 1

    local source_url="$1"
    local source_version="$2"
    local source_subdir="$3"
    local source="$4"
    local target_dir="$5"
    local cached_path="${CACHED_DIR}/${source}"
    local target_path="${target_dir}/${source}"
    local temp_dir=""
    local timestamp=""

    if [ ! -f "${cached_path}" ]; then
        umask 022
        mkdir -p "${CACHED_DIR}"
        if [ ! -f "${target_path}" ]; then
            cleanup() { rm -rf "${cached_path}" "${temp_dir}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            temp_dir=$(mktemp -d "${target_dir}/temp.XXXXXX")
            mkdir -p "${temp_dir}"
            if ! retry 100 git clone "${source_url}" "${temp_dir}/${source_subdir}"; then
                return 1
            fi
            cd "${temp_dir}/${source_subdir}"
            if ! retry 100 git checkout ${source_version}; then
                return 1
            fi
            if ! retry 100 git submodule update --init --recursive; then
                return 1
            fi
            timestamp="$(git log -1 --format='@%ct')"
            rm -rf .git
            cd ../..
            #chmod -R g-w,o-w "${temp_dir}/${source_subdir}"
            tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
                -C "${temp_dir}" "${source_subdir}" \
                -cv | xz -zc -7e -T0 >"${cached_path}"
            touch -d "${timestamp}" "${cached_path}"
            rm -rf "${temp_dir}"
            trap - EXIT INT TERM
        else
            cleanup() { rm -f "${cached_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            if ! mv -f "${target_path}" "${cached_path}"; then
                return 1
            fi
            trap - EXIT INT TERM
        fi
    fi

    if [ ! -f "${target_path}" ]; then
        if [ -f "${cached_path}" ]; then
            ln -sfn "${cached_path}" "${target_path}"
        fi
    fi

    return 0
) # END sub-shell

download_archive() {
    [ "$#" -eq 3 ] || [ "$#" -eq 5 ] || return 1

    local source_url="$1"
    local source="$2"
    local target_dir="$3"
    local source_version="$4"
    local source_subdir="$5"

    if [ -z "${source_version}" ]; then
        download "${source_url}" "${source}" "${target_dir}"
    else
        clone_github "${source_url}" "${source_version}" "${source_subdir}" "${source}" "${target_dir}"
    fi
}

apply_patch() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_path="$1"
    local target_dir="$2"

    if [ -f "${patch_path}" ]; then
        echo "Applying patch: ${patch_path}"
        if patch --dry-run --silent -p1 -d "${target_dir}/" -i "${patch_path}"; then
            if ! patch -p1 -d "${target_dir}/" -i "${patch_path}"; then
                echo "The patch failed."
                return 1
            fi
        else
            echo "The patch was not applied. Failed dry run."
            return 1
        fi
    else
        echo "Patch not found: ${patch_path}"
        return 1
    fi

    return 0
}

apply_patch_folder() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_dir="$1"
    local target_dir="$2"
    local patch_file=""
    local rc=0

    if [ -d "${patch_dir}" ]; then
        for patch_file in ${patch_dir}/*.patch; do
            if [ -f "${patch_file}" ]; then
                if ! apply_patch "${patch_file}" "${target_dir}"; then
                    rc=1
                fi
            fi
        done
    fi

    return ${rc}
}

rm_safe() {
    [ -n "$1" ] || return 1
    local target_dir="$1"

    # Prevent absolute paths
    case "${target_dir}" in
        /*)
            echo "Refusing to remove absolute path: ${target_dir}"
            return 1
            ;;
    esac

    # Prevent current/parent directories
    case "${target_dir}" in
        "."|".."|*/..|*/.)
            echo "Refusing to remove . or .. or paths containing ..: ${target_dir}"
            return 1
            ;;
    esac

    # Finally, remove safely
    rm -rf -- "${target_dir}"

    return 0
}

apply_patches() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_dir="$1"
    local target_dir="$2"

    if ! apply_patch_folder "${patch_dir}" "${target_dir}"; then
        #rm_safe "${target_dir}"
        return 1
    fi

    return 0
}

extract_package() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local source_path="$1"
    local target_dir="$2"

    case "${source_path}" in
        *.tar.gz|*.tgz)
            tar xzvf "${source_path}" -C "${target_dir}"
            ;;
        *.tar.bz2|*.tbz)
            tar xjvf "${source_path}" -C "${target_dir}"
            ;;
        *.tar.xz|*.txz)
            tar xJvf "${source_path}" -C "${target_dir}"
            ;;
        *.tar.lz|*.tlz)
            tar xlvf "${source_path}" -C "${target_dir}"
            ;;
        *.tar.zst)
            tar xvf "${source_path}" -C "${target_dir}"
            ;;
        *.tar)
            tar xvf "${source_path}" -C "${target_dir}"
            ;;
        *)
            echo "Unsupported archive type: ${source_path}" >&2
            return 1
            ;;
    esac

    return 0
}

unpack_archive()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local source_path="$1"
    local target_dir="$2"
    local dir_tmp=""

    if [ ! -d "${target_dir}" ]; then
        dir_tmp=$(mktemp -d "${target_dir}.XXXXXX")
        cleanup() { rm -rf "${dir_tmp}"; }
        trap 'cleanup; exit 130' INT
        trap 'cleanup; exit 143' TERM
        trap 'cleanup' EXIT
        mkdir -p "${dir_tmp}"
        if extract_package "${source_path}" "${dir_tmp}"; then
            # try to rename single sub-directory
            if ! mv -f "${dir_tmp}"/* "${target_dir}"/; then
                # otherwise, move multiple files and sub-directories
                mkdir -p "${target_dir}"
                mv -f "${dir_tmp}"/* "${target_dir}"/
            fi
        fi
    fi

    return 0
) # END sub-shell

is_version_git() {
    case "$1" in
        *+git*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_arm() {
    case "$(uname -m)" in
        arm*|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

archive_build_directory()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1

    local repo_dir="$1"
    local build_dir="$2"
    local build_subdir="$(basename -- "$build_dir")"
    local repo_version=""
    local timestamp=""
    local repo_filename=""
    local repo_status=""
    local repo_modified=""
    local repo_dirty=""
    local cached_path=""

    cd "${repo_dir}"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    repo_status="$(git status --porcelain)"
    repo_dirty="$([ -n "${repo_status}" ] && echo yes || echo no)"
    [ -n "${repo_status}" ] && repo_modified="+modified"
    [ -z "${repo_status}" ] && repo_status="(no differences or untracked files)"
    repo_version="$(git rev-parse HEAD)"
    timestamp="$(git log -1 --format='@%ct')"
    timestamp_utc="$(date -u -d "${timestamp}" '+%Y%m%d+%H%M%S')"
    timestamp_local="$(date -d "${timestamp}" '+%Y-%m-%d %H:%M:%S %Z %z')"

	cat >"${build_dir}/VERSION" <<-EOF
		---------------------------------------------------------------
		BUILD_START_LOCALTIME  ${BUILD_START_LOCALTIME}
		BUILD_END_LOCALTIME    ${BUILD_END_LOCALTIME}
		GIT_COMMIT             ${repo_version}
		GIT_COMMIT_LOCALTIME   ${timestamp_local}
		GIT_DIRTY              ${repo_dirty}
		---------------------------------------------------------------
		${repo_status}
		---------------------------------------------------------------
	EOF

    repo_filename="${build_subdir}+${timestamp_utc}.tar.xz"
    cached_path="${CACHED_DIR}/${repo_filename}"
    temp_path=$(mktemp "${cached_path}.XXXXXX")
    cleanup() { rm -f "${temp_path}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    if ! tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
            --exclude="${build_subdir}/src" \
            --transform "s|^${build_subdir}|${build_subdir}+git-${repo_version}${repo_modified}|" \
            -C "${PARENT_DIR}" "${build_subdir}" \
            -cv | xz -zc -7e -T0 >"${temp_path}"; then
        return 1
    fi
    touch -d "${timestamp}" "${temp_path}" || return 1
    mv -f "${temp_path}" "${cached_path}" || return 1
    trap - EXIT INT TERM

    return 0
) # END sub-shell

update_patch_library() {
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "$4" ]            || return 1
    [ -n "${PARENT_DIR}" ] || return 1
    [ -n "${SCRIPT_DIR}" ] || return 1

    local git_commit="$1"
    local patches_dir="$2"
    local pkg_name="$3"
    local pkg_subdir="$4"
    local entware_packages_dir="${PARENT_DIR}/entware-packages"

    if [ ! -d "${entware_packages_dir}" ]; then
        cd "${PARENT_DIR}"
        git clone https://github.com/Entware/entware-packages
    fi

    cd "${entware_packages_dir}"
    git fetch origin
    git reset --hard "${git_commit}"
    [ -d "${patches_dir}" ] || return 1
    mkdir -p "${SCRIPT_DIR}/patches/${pkg_name}/${pkg_subdir}/entware"
    cp -pf "${patches_dir}"/* "${SCRIPT_DIR}/patches/${pkg_name}/${pkg_subdir}/entware/"
    cd ..

    return 0
}

check_static() {
    local rc=0
    for bin in "$@"; do
        echo "Checking ${bin}"
        file "${bin}" || true
        if readelf -d "${bin}" 2>/dev/null | grep NEEDED; then
            rc=1
        fi || true
        ldd "${bin}" 2>&1 || true
    done

    if [ ${rc} -eq 1 ]; then
        echo "*** NOT STATICALLY LINKED ***"
        echo "*** NOT STATICALLY LINKED ***"
        echo "*** NOT STATICALLY LINKED ***"
    fi

    return ${rc}
}

finalize_build() {
    set +x
    echo ""
    echo "Stripping symbols and sections from files..."
    strip -v "$@"

    # Exit here, if the programs are not statically linked.
    # If any binaries are not static, check_static() returns 1
    # set -e will cause the shell to exit here, so renaming won't happen below.
    echo ""
    echo "Checking statically linked programs..."
    check_static "$@"

    # Append ".static" to the program names
    echo ""
    echo "Renaming programs with .static suffix..."
    for bin in "$@"; do
        mv -f "${bin}" "${bin}.static"
    done
    set -x

    return 0
}

################################################################################
# Host dependencies

BUILD_RC="${HOME}/.cross-buildrc"

load_install_pref() {
    INSTALL_DEPS="ask"
    [ -f "$BUILD_RC" ] && . "$BUILD_RC"
    return 0
}

save_install_pref() {
    echo "INSTALL_DEPS=$INSTALL_DEPS" > "$BUILD_RC"
    return 0
}

prompt_install_choice() {
    echo
    echo "Host dependencies are missing or outdated."
    echo "Choose an action:"
    echo "  [y] Install now"
    echo "  [a] Always install automatically"
    echo "  [n] Do not install (abort build)"
    echo

    read -r -p "Selection [y/a/n]: " choice

    case "$choice" in
        y|Y)
            return 0
            ;;
        a|A)
            INSTALL_DEPS="yes"
            save_install_pref
            return 0
            ;;
        n|N)
            INSTALL_DEPS="no"
            #save_install_pref
            return 1
            ;;
        *)
            echo "Invalid selection."
            return 1
            ;;
    esac
    return 0
}

install_dependencies() {
    load_install_pref

    # list each package and optional version
    # example: "build-essential 12.9"
    local dependencies=(
        "build-essential"
        "binutils"
        "bison"
        "flex"
        "texinfo"
        "gawk"
        "perl"
        "patch"
        "file"
        "wget"
        "curl"
        "git"
        "libgmp-dev"
        "libmpfr-dev"
        "libmpc-dev"
        "libisl-dev"
        "zlib1g-dev"
    )
    local to_install=()

    echo "[*] Checking dependencies..."
    for entry in "${dependencies[@]}"; do
        local pkg min_version installed_version
        read -r pkg min_version <<< "$entry"

        if installed_version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"; then
            if [ -n "$min_version" ]; then
                if dpkg --compare-versions "$installed_version" ge "$min_version"; then
                    echo "[*] $pkg $installed_version is OK."
                else
                    echo "[*] $pkg $installed_version is too old (min $min_version)."
                    to_install+=("$pkg")
                fi
            else
                echo "[*] $pkg is installed."
            fi
        else
            echo "[*] $pkg not installed."
            to_install+=("$pkg")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        echo "[*] All dependencies satisfied."
        return 0
    fi

    case "$INSTALL_DEPS" in
        yes)
            ;;
        no)
            echo "[!] Missing dependencies and auto-install disabled."
            return 1
            ;;
        ask)
            if ! prompt_install_choice; then
                return 1
            fi
            ;;
    esac

    echo "[*] Installing dependencies: ${to_install[*]}"
    sudo apt-get update
    sudo apt-get install -y "${to_install[@]}"

    return 0
}


################################################################################
# General

CROSSBUILD_DIR="${SCRIPT_DIR}-build"
mkdir -p "${CROSSBUILD_DIR}"

STAGEDIR="${CROSSBUILD_DIR}"
SRC_ROOT="${CROSSBUILD_DIR}/src"
mkdir -p "$SRC_ROOT"

#export LDFLAGS="-L${STAGEDIR}/lib -Wl,--gc-sections"
#export CPPFLAGS="-I${STAGEDIR}/include"
#export CFLAGS="-O3 -march=armv7-a -mtune=cortex-a9 -fomit-frame-pointer -mabi=aapcs-linux -marm -msoft-float -mfloat-abi=soft -ffunction-sections -fdata-sections -pipe -Wall -fPIC -std=gnu99"

MAKE="make -j$(grep -c ^processor /proc/cpuinfo)" # parallelism
#MAKE="make -j1"                                  # one job at a time

#export PKG_CONFIG="pkg-config"
#export PKG_CONFIG_LIBDIR="${STAGEDIR}/lib/pkgconfig"
#unset PKG_CONFIG_PATH

# sudo apt update && sudo apt install build-essential binutils bison flex texinfo gawk make perl patch file wget curl git libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev

export PREFIX="${CROSSBUILD_DIR}"
export TARGET=arm-linux-musleabi
export PATH="${PREFIX}/bin:${PATH}"
SYSROOT="${PREFIX}/${TARGET}"

set +x
install_dependencies
echo ""
echo ""
echo "[*] Starting ARM cross-compiler build..."
echo ""
echo ""
set -x
BUILD_START_LOCALTIME="$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
BUILD_END_LOCALTIME="${BUILD_START_LOCALTIME}"


archive_build_directory "${SCRIPT_DIR}" "${CROSSBUILD_DIR}"
exit 1


################################################################################
# binutils-2.40
(
PKG_NAME=binutils
PKG_VERSION=2.40
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/binutils/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="0f8a4c272d7f17f369ded10a4aca28b8e304828e95526da482b0ccc4dfc9d8e1"

mkdir -p "${SRC_ROOT}/${PKG_NAME}" && cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --prefix="${PREFIX}" \
        --target=${TARGET} \
        --disable-nls \
        --disable-werror \
    || handle_configure_error $?

    $MAKE
    make install

    touch "../${PKG_BUILD_SUBDIR}/__package_installed"
fi
)

################################################################################
# linux-2.6.36.4
(
PKG_NAME=linux
PKG_VERSION=2.6.36.4
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://www.kernel.org/pub/linux/kernel/v$(echo "$PKG_VERSION" | cut -d. -f1,2)/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="70d124743041974e1220fb39465627ded1df0fdd46da6cd74f6e3da414194d03"

mkdir -p "${SRC_ROOT}/${PKG_NAME}" && cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"

    cd "${PKG_SOURCE_SUBDIR}"
    make ARCH=arm INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install

    touch "../${PKG_BUILD_SUBDIR}/__package_installed"
fi
)

################################################################################
# gcc-12.5.0 (bootstrap gcc)
(
PKG_NAME=gcc
PKG_VERSION=12.5.0
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/gcc/${PKG_NAME}-${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-bootstrap"
PKG_HASH="71cd373d0f04615e66c5b5b14d49c1a4c1a08efa7b30625cd240b11bab4062b3"

mkdir -p "${SRC_ROOT}/${PKG_NAME}" && cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed__gcc" ]; then
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${PREFIX}" \
        --without-headers \
        --enable-languages=c \
        --disable-threads \
        --disable-shared \
        --disable-multilib \
        --disable-nls \
        --disable-libssp \
        --disable-libquadmath \
        --disable-libgomp \
        --disable-libsanitizer \
        --disable-libstdcxx-pch \
        --disable-libgcov \
    || handle_configure_error $?

    $MAKE all-gcc
    make install-gcc
    touch "../${PKG_BUILD_SUBDIR}/__package_installed__gcc"
fi
)

################################################################################
# gcc-12.5.0 (bootstrap libgcc)
(
PKG_NAME=gcc
PKG_VERSION=12.5.0
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-bootstrap"

cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed__libgcc" ]; then
    cd "${PKG_BUILD_SUBDIR}"
    $MAKE all-target-libgcc
    make install-target-libgcc
    touch "../${PKG_BUILD_SUBDIR}/__package_installed__libgcc"
fi
)

################################################################################
# musl-1.2.4
(
PKG_NAME=musl
PKG_VERSION=1.2.4
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://musl.libc.org/releases/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="7a35eae33d5372a7c0da1188de798726f68825513b7ae3ebe97aaaa52114f039"

mkdir -p "${SRC_ROOT}/${PKG_NAME}" && cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    export CROSS_COMPILE=${TARGET}-

    ../${PKG_SOURCE_SUBDIR}/configure \
        --prefix="${SYSROOT}" \
        --target=${TARGET} \
        --syslibdir=/lib \
        --with-headers="${SYSROOT}/include" \
    || handle_configure_error $?

    $MAKE
    make install

    touch "../${PKG_BUILD_SUBDIR}/__package_installed"
fi
)

################################################################################
# gcc-12.5.0 (final)
(
PKG_NAME=gcc
PKG_VERSION=12.5.0
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/gcc/${PKG_NAME}-${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-final"
PKG_HASH="71cd373d0f04615e66c5b5b14d49c1a4c1a08efa7b30625cd240b11bab4062b3"

mkdir -p "${SRC_ROOT}/${PKG_NAME}" && cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --enable-languages=c,c++ \
        --enable-shared \
        --disable-multilib \
        --disable-nls \
        --disable-libsanitizer \
    || handle_configure_error $?

    $MAKE
    make install

    touch "../${PKG_BUILD_SUBDIR}/__package_installed"
fi
)

################################################################################
# Archive the built toolchain
#
BUILD_END_LOCALTIME="$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
set +x
echo ""
echo ""
echo "[*] Finished compiling."
echo ""
echo ""
echo "[*] Now archiving the built toolchain (this will take a while)..."
echo ""
echo ""
set -x
archive_build_directory "${SCRIPT_DIR}" "${CROSSBUILD_DIR}"

################################################################################
# Interpreter path for running dynamically-linked executables on this device.
#
# Normally, cross-compiled programs do not run on the host, but the Raspberry Pi
# is backwards compatible with ARMv7 soft-float programs.  The actual target
# devices are things like home routers, smart tv's, smart phone, etc.  So, this
# is really only for convenience for Pi users, to test programs on the host.
#
# If you only create statically-linked executables, then you don't even need to
# do this.
# 
if is_arm; then
    if [ ! -f "/lib/ld-musl-arm.so.1" ]; then
        if ! sudo -n true 2>/dev/null; then
            echo "Password required."
        else
            sudo ln -sfn "${SYSROOT}/lib/libc.so" "/lib/ld-musl-arm.so.1"
        fi
    fi
fi

################################################################################
# Shortcut to top-level of this toolchain
#
TOPDIR=/xcc
if [ ! -d "${TOPDIR}" ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "Password required."
    else
        sudo ln -sfn "${CROSSBUILD_DIR}" "${TOPDIR}"
    fi
fi

################################################################################
# Show example
set +e
set +x
echo ""
echo ""
echo "Environment variables for cross-compiling:"
echo ""
echo "export PREFIX=\"${CROSSBUILD_DIR}\""
echo "export TARGET=arm-linux-musleabi"
echo 'export PATH="${PREFIX}/bin:${PATH}"'
echo ""
echo "Usage examples:"
echo ""
echo "arm-linux-musleabi-gcc -static hello.c -o hello"
echo "    -OR-"
echo "arm-linux-musleabi-gcc hello.c -o hello"
echo ""

