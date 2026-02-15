#!/bin/bash
################################################################################
# build-arm-linux-musleabi.sh
#
# Builds a cross-compiler for ARMv7 soft-float musl libc
#
# NOTE: Compiling GCC on a Raspberry Pi can generate significant heat, often
# exceeding 80°C in stock cases. Upgrading to an aluminum case with copper shims
# and good thermal paste provides effective passive cooling that dramatically
# improves heat dissipation, keeping CPU temperatures below 55°C and preventing
# thermal throttling during long builds.
#
# On a Raspberry Pi 3 Model B, a clean build took approximately 5 hours and
# required:
#
# - SSD-based storage
# - 10 GB swap file (just in case)
# - Adequate cooling
# 
# Build times on modern x86_64 systems are significantly shorter.
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
FILE_DOWNLOADER='use_wget'
#FILE_DOWNLOADER='use_curl'
#FILE_DOWNLOADER='use_curl_socks5_proxy'; CURL_SOCKS5_PROXY="192.168.1.1:9150"
set -e
set -x

main() {
export TARGET=arm-linux-musleabi
RELEASE_VERSION=0.2.2
HOST_CPU="$(uname -m)"

CROSSBUILD_DIR="${SCRIPT_DIR}-build"
TARGET_DIR="${CROSSBUILD_DIR}/${TARGET}"

export PREFIX="${CROSSBUILD_DIR}"
export HOST=${TARGET}
export SYSROOT="${TARGET_DIR}/sysroot"

CROSS_PREFIX=${TARGET}-

STRIP=strip
READELF=readelf

case "${HOST_CPU}" in
    armv7l)
        ARCH_NATIVE=true
        ;;
    *)
        ARCH_NATIVE=false
        ;;
esac

SRC_ROOT="${CROSSBUILD_DIR}/src/${TARGET}"
STAGE="${CROSSBUILD_DIR}/stage/${TARGET}"

BUILD_START_PATH="${CROSSBUILD_DIR}/.build_start"
VERSION_PATH="${CROSSBUILD_DIR}/VERSION"

MAKE="make -j$(grep -c ^processor /proc/cpuinfo)" # parallelism
#MAKE="make -j1"                                  # one job at a time

check_dependencies

#create_cmake_toolchain_file

download_and_compile

archive_and_configuration

return 0
} #END main()

################################################################################
# Host dependencies
#
check_dependencies()
( # BEGIN sub-shell
    set +x
    install_dependencies || return 1
    return 0
) # END sub-shell

prompt_install_choice() {
    echo
    echo "Host dependencies are missing or outdated."
    echo "Choose an action:"
    echo "  [y] Install now"
    echo "  [n] Do not install (abort build)"
    echo

    read -r -p "Selection [y/n]: " choice

    case "$choice" in
        y|Y)
            return 0
            ;;
        n|N)
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

    # list each package and optional minimum version
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
        "tar"
        "libgmp-dev"
        "libmpfr-dev"
        "libmpc-dev"
        "libisl-dev"
        "zlib1g-dev"
        "cmake"
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
            echo "[*] $pkg is missing."
            to_install+=("$pkg")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        echo "[*] All dependencies satisfied."
        return 0
    fi

    if ! prompt_install_choice; then
        return 1
    fi

    echo "[*] Installing dependencies: ${to_install[*]}"
    sudo apt-get update
    sudo apt-get install -y "${to_install[@]}"

    return 0
}

################################################################################
# CMake toolchain file
#
create_cmake_toolchain_file() {
mkdir -p "${SRC_ROOT}"

# CMAKE options
CMAKE_BUILD_TYPE="RelWithDebInfo"
CMAKE_VERBOSE_MAKEFILE="YES"
CMAKE_C_FLAGS="${CFLAGS}"
CMAKE_CXX_FLAGS="${CXXFLAGS}"
CMAKE_LD_FLAGS="${LDFLAGS}"
CMAKE_CPP_FLAGS="${CPPFLAGS}"

{
    printf '%s\n' "# toolchain.cmake"
    printf '%s\n' "set(CMAKE_SYSTEM_NAME Linux)"
    printf '%s\n' "set(CMAKE_SYSTEM_PROCESSOR arm)"
    printf '%s\n' ""
    printf '%s\n' "# Cross-compiler"
    printf '%s\n' "set(CMAKE_C_COMPILER arm-linux-musleabi-gcc)"
    printf '%s\n' "set(CMAKE_CXX_COMPILER arm-linux-musleabi-g++)"
    printf '%s\n' "set(CMAKE_AR arm-linux-musleabi-ar)"
    printf '%s\n' "set(CMAKE_RANLIB arm-linux-musleabi-ranlib)"
    printf '%s\n' "set(CMAKE_STRIP arm-linux-musleabi-strip)"
    printf '%s\n' ""
#    printf '%s\n' "# Optional: sysroot"
#    printf '%s\n' "set(CMAKE_SYSROOT \"${SYSROOT}\")"
    printf '%s\n' ""
#    printf '%s\n' "# Avoid picking host libraries"
#    printf '%s\n' "set(CMAKE_FIND_ROOT_PATH \"${PREFIX}\")"
    printf '%s\n' ""
#    printf '%s\n' "# Tell CMake to search only in sysroot"
#    printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)"
#    printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)"
#    printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)"
    printf '%s\n' ""
#    printf '%s\n' "set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY) # critical for skipping warning probes"
#    printf '%s\n' ""
    printf '%s\n' "set(CMAKE_C_STANDARD 11)"
    printf '%s\n' "set(CMAKE_CXX_STANDARD 17)"
    printf '%s\n' ""
} >"${SRC_ROOT}/arm-musl.toolchain.cmake"

return 0
} #END create_cmake_toolchain_file

################################################################################
# Helpers

# If autoconf/configure fails due to missing libraries or undefined symbols, you
# immediately see all undefined references without having to manually search config.log
handle_configure_error()
( # BEGIN sub-shell
    set +x
    local rc=$1
    local config_log_file="$2"

    if [ -z "${config_log_file}" ] || [ ! -f "${config_log_file}" ]; then
        config_log_file="config.log"
    fi

    #grep -R --include="config.log" --color=always "undefined reference" .
    #find . -name "config.log" -exec grep -H "undefined reference" {} \;
    #find . -name "config.log" -exec grep -H -E "undefined reference|can't load library|unrecognized command-line option|No such file or directory" {} \;
    find . -name "config.log" -exec grep -H -E "undefined reference|can't load library|unrecognized command-line option" {} \;

    # Force failure if rc is zero, since error was detected
    [ "${rc}" -eq 0 ] && return 1

    return ${rc}
) # END sub-shell

################################################################################
# Package management

# new files:       rw-r--r-- (644)
# new directories: rwxr-xr-x (755)
umask 022

sign_file()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1

    local target_path="$1"
    local option="$2"
    local sum_path="$(readlink -f "${target_path}").sum"
    local target_file="$(basename -- "${target_path}")"
    local target_file_hash=""
    local temp_path=""
    local now_localtime=""

    if [ ! -f "${target_path}" ]; then
        echo "ERROR: File not found: ${target_path}"
        return 1
    fi

    if [ -z "${option}" ]; then
        target_file_hash="$(sha256sum "${target_path}" | awk '{print $1}')"
    elif [ "${option}" = "full_extract" ]; then
        target_file_hash="$(hash_archive "${target_path}")"
    elif [ "${option}" = "xz_extract" ]; then
        target_file_hash="$(xz -dc "${target_path}" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi

    now_localtime="$(date '+%Y-%m-%d %H:%M:%S %Z %z')"

    cleanup() { rm -f "${temp_path}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    temp_path=$(mktemp "${sum_path}.XXXXXX")
    {
        #printf '%s released %s\n' "${target_file}" "${now_localtime}"
        #printf '\n'
        #printf 'SHA256: %s\n' "${target_file_hash}"
        #printf '\n'
        printf '%s  %s\n' "${target_file_hash}" "${target_file}"
    } >"${temp_path}" || return 1
    chmod --reference="${target_path}" "${temp_path}" || return 1
    touch -r "${target_path}" "${temp_path}" || return 1
    mv -f "${temp_path}" "${sum_path}" || return 1
    trap - EXIT INT TERM

    return 0
) # END sub-shell

hash_dir()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1

    dir_path="$1"

    cleanup() { :; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    cd "${dir_path}" || return 1
    (
        find ./ -type f | sort | while IFS= read -r f; do
            set +x
            echo "${f}"        # include the path
            cat "${f}"         # include the contents
        done
    ) | sha256sum | awk '{print $1}'

    return 0
) # END sub-shell

hash_archive()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1

    source_path="$1"
    target_dir="$(dirname "${source_path}")"
    target_file="$(basename "${source_path}")"

    cd "${target_dir}" || return 1

    cleanup() { rm -rf "${dir_tmp}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    dir_tmp=$(mktemp -d "${target_file}.XXXXXX")
    mkdir -p "${dir_tmp}"
    if ! extract_package "${source_path}" "${dir_tmp}" >/dev/null 2>&1; then
        return 1
    else
        hash_dir "${dir_tmp}"
    fi

    return 0
) # END sub-shell

# Checksum verification for downloaded file
verify_hash() {
    [ -n "$1" ] || return 1

    local source_path="$1"
    local expected="$2"
    local option="$3"
    local actual=""
    local sum_path="$(readlink -f "${source_path}").sum"
    local line=""

    if [ ! -f "${source_path}" ]; then
        echo "ERROR: File not found: ${source_path}"
        return 1
    fi

    if [ -z "${option}" ]; then
        # hash the compressed binary archive itself
        actual="$(sha256sum "${source_path}" | awk '{print $1}')"
    elif [ "${option}" = "full_extract" ]; then
        # hash the data inside the compressed binary archive
        actual="$(hash_archive "${source_path}")"
    elif [ "${option}" = "xz_extract" ]; then
        # hash the data, file names, directory names, timestamps, permissions, and
        # tar internal structures. this method is not as "future-proof" for archiving
        # Github repos because it is possible that the tar internal structures
        # could change over time as the tar implementations evolve.
        actual="$(xz -dc "${source_path}" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi

    if [ -z "${expected}" ]; then
        if [ ! -f "${sum_path}" ]; then
            echo "ERROR: Signature file not found: ${sum_path}"
            return 1
        else
            IFS= read -r line <"${sum_path}" || return 1
            expected=${line%%[[:space:]]*}
            if [ -z "${expected}" ]; then
                echo "ERROR: Bad signature file: ${sum_path}"
                return 1
            fi
        fi
    fi

    if [ "${actual}" != "${expected}" ]; then
        echo "ERROR: SHA256 mismatch for ${source_path}"
        echo "Expected: ${expected}"
        echo "Actual:   ${actual}"
        return 1
    fi

    echo "SHA256 OK: ${source_path}"
    return 0
}

# the signature file is just a checksum hash
signature_file_exists() {
    [ -n "$1" ] || return 1
    local source_path="$1"
    local sum_path="$(readlink -f "${source_path}").sum"
    if [ -f "${sum_path}" ]; then
        return 0
    else
        return 1
    fi
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

invoke_download_command() {
    [ -n "$1" ]                   || return 1
    [ -n "$2" ]                   || return 1

    local temp_path="$1"
    local source_url="$2"
    case "${FILE_DOWNLOADER}" in
        use_wget)
            if ! wget -O "${temp_path}" \
                      --tries=1 --retry-connrefused --waitretry=5 \
                      "${source_url}"; then
                return 1
            fi
            ;;
        use_curl)
            if ! curl --fail --retry 1 --retry-connrefused --retry-delay 5 \
                      --output "$temp_path" \
                      --remote-time \
                      "$source_url"; then
                return 1
            fi
            ;;
        use_curl_socks5_proxy)
            if [ -z "${CURL_SOCKS5_PROXY}" ]; then
                echo "You must specify a SOCKS5 proxy for download command: ${FILE_DOWNLOADER}" >&2
                return 1
            fi
            if ! curl --socks5-hostname ${CURL_SOCKS5_PROXY} \
                      --fail --retry 1 --retry-connrefused --retry-delay 5 \
                      --output "$temp_path" \
                      --remote-time \
                      "$source_url"; then
                return 1
            fi
            ;;
        *)
            echo "Unsupported file download command: '${FILE_DOWNLOADER}'" >&2
            return 1
            ;;
    esac
    return 0
}

download_clean() {
    [ -n "$1" ]          || return 1
    [ -n "$2" ]          || return 1
    [ -n "$3" ]          || return 1

    local temp_path="$1"
    local source_url="$2"
    local target_path="$3"

    rm -f "${temp_path}"
    if ! invoke_download_command "${temp_path}" "${source_url}"; then
        rm -f "${temp_path}"
        if [ -f "${target_path}" ]; then
            return 0
        else
            return 1
        fi
    else
        if [ -f "${target_path}" ]; then
            rm -f "${temp_path}"
            return 0
        else
            if ! mv -f "${temp_path}" "${target_path}"; then
                rm -f "${temp_path}" "${target_path}"
                return 1
            fi
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
            if ! retry 1000 download_clean "${temp_path}" "${source_url}" "${cached_path}"; then
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
    local temp_path=""
    local temp_dir=""
    local timestamp=""

    if [ ! -f "${cached_path}" ]; then
        umask 022
        mkdir -p "${CACHED_DIR}"
        if [ ! -f "${target_path}" ]; then
            cleanup() { rm -rf "${temp_path}" "${temp_dir}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            temp_path=$(mktemp "${cached_path}.XXXXXX")
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
            if ! tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
                    -C "${temp_dir}" "${source_subdir}" \
                    -cv | xz -zc -7e -T0 >"${temp_path}"; then
                return 1
            fi
            touch -d "${timestamp}" "${temp_path}" || return 1
            mv -f "${temp_path}" "${cached_path}" || return 1
            rm -rf "${temp_dir}" || return 1
            trap - EXIT INT TERM
            sign_file "${cached_path}" "full_extract"
        else
            cleanup() { rm -f "${cached_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            mv -f "${target_path}" "${cached_path}" || return 1
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

    local patch_file="$1"
    local target_dir="$2"

    if [ -f "${patch_file}" ]; then
        echo "Applying patch: ${patch_file}"
        if patch --dry-run --silent -p1 -d "${target_dir}/" -i "${patch_file}"; then
            if ! patch -p1 -d "${target_dir}/" -i "${patch_file}"; then
                echo "The patch failed."
                return 1
            fi
        else
            echo "The patch was not applied. Failed dry run."
            return 1
        fi
    else
        echo "Patch not found: ${patch_file}"
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

apply_patches() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_file_or_dir="$1"
    local target_dir="$2"

    if [ -f "${patch_file_or_dir}" ]; then
        if ! apply_patch "${patch_file_or_dir}" "${target_dir}"; then
            return 1
        fi
    elif [ -d "${patch_file_or_dir}" ]; then
        if ! apply_patch_folder "${patch_file_or_dir}" "${target_dir}"; then
            return 1
        fi
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
            tar xzvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.bz2|*.tbz)
            tar xjvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.xz|*.txz)
            tar xJvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.lz|*.tlz)
            tar xlvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.zst)
            tar xvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar)
            tar xvf "${source_path}" -C "${target_dir}" || return 1
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
    local top_dir="${target_dir%%/*}"
    local dir_tmp=""

    if [ ! -d "${target_dir}" ]; then
        cleanup() { rm -rf "${dir_tmp}" "${target_dir}"; }
        trap 'cleanup; exit 130' INT
        trap 'cleanup; exit 143' TERM
        trap 'cleanup' EXIT
        dir_tmp=$(mktemp -d "${top_dir}.XXXXXX")
        mkdir -p "${dir_tmp}"
        if ! extract_package "${source_path}" "${dir_tmp}"; then
            return 1
        else
            # try to rename single sub-directory
            if ! mv -f "${dir_tmp}"/* "${target_dir}"/; then
                # otherwise, move multiple files and sub-directories
                mkdir -p "${target_dir}" || return 1
                mv -f "${dir_tmp}"/* "${target_dir}"/ || return 1
            fi
        fi
        rm -rf "${dir_tmp}" || return 1
        trap - EXIT INT TERM
    fi

    return 0
) # END sub-shell

unpack_and_verify()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local source_path="$1"
    local target_dir="$2"
    local expected="$3"
    local actual=""
    local sum_path="$(readlink -f "${source_path}").sum"
    local line=""
    local top_dir="${target_dir%%/*}"
    local dir_tmp=""

    if [ ! -d "${target_dir}" ]; then
        cleanup() { rm -rf "${dir_tmp}" "${target_dir}"; }
        trap 'cleanup; exit 130' INT
        trap 'cleanup; exit 143' TERM
        trap 'cleanup' EXIT
        dir_tmp=$(mktemp -d "${top_dir}.XXXXXX")
        mkdir -p "${dir_tmp}"
        if ! extract_package "${source_path}" "${dir_tmp}"; then
            return 1
        else
            actual="$(hash_dir "${dir_tmp}")"

            if [ -z "${expected}" ]; then
                if [ ! -f "${sum_path}" ]; then
                    echo "ERROR: Signature file not found: ${sum_path}"
                    return 1
                else
                    IFS= read -r line <"${sum_path}" || return 1
                    expected=${line%%[[:space:]]*}
                    if [ -z "${expected}" ]; then
                        echo "ERROR: Bad signature file: ${sum_path}"
                        return 1
                    fi
                fi
            fi

            if [ "${actual}" != "${expected}" ]; then
                echo "ERROR: SHA256 mismatch for ${source_path}"
                echo "Expected: ${expected}"
                echo "Actual:   ${actual}"
                return 1
            fi

            echo "SHA256 OK: ${source_path}"

            # try to rename single sub-directory
            if ! mv -f "${dir_tmp}"/* "${target_dir}"/; then
                # otherwise, move multiple files and sub-directories
                mkdir -p "${target_dir}" || return 1
                mv -f "${dir_tmp}"/* "${target_dir}"/ || return 1
            fi
        fi
        rm -rf "${dir_tmp}" || return 1
        trap - EXIT INT TERM
    fi

    return 0
) # END sub-shell

get_latest_package() {
    [ "$#" -eq 3 ] || return 1

    local prefix=$1
    local middle=$2
    local suffix=$3
    local pattern=${prefix}${middle}${suffix}
    local latest=""
    local version=""

    (
        cd "$CACHED_DIR" || return 1

        set -- $pattern
        [ "$1" != "$pattern" ] || return 1   # no matches

        latest=$1
        for f do
            latest=$f
        done

        version=${latest#"$prefix"}
        version=${version%"$suffix"}
        printf '%s\n' "$version"
    )
    return 0
}

enable_options() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1
    local p n
    $2 && p=enable || p=disable
    for n in $1; do printf -- "--%s-%s " "$p" "$n"; done
    return 0
}

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *)      return 1 ;;
    esac
}

ends_with() {
    case "$1" in
        *"$2") return 0 ;;
        *)     return 1 ;;
    esac
}

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
    ldd() {
        if ${ARCH_NATIVE}; then
            "${PREFIX}/lib/libc.so" --list "$@"
        else
            true
        fi
    }

    local rc=0
    for bin in "$@"; do
        echo "Checking ${bin}"
        file "${bin}" || true
        if ${READELF} -d "${bin}" 2>/dev/null | grep NEEDED; then
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
    ${STRIP} -v "$@"

    # Exit here, if the programs are not statically linked.
    # If any binaries are not static, check_static() returns 1
    # set -e will cause the shell to exit here, so renaming won't happen below.
    echo ""
    echo "Checking statically linked programs..."
    check_static "$@"

    # Append ".static" to the program names
    echo ""
    echo "Create symbolic link with .static suffix..."
    for bin in "$@"; do
        case "$bin" in
            *.static) : ;;   # do nothing
            *) ln -sfn "$(basename "${bin}")" "${bin}.static" ;;
        esac
    done
    set -x

    return 0
}

# temporarily hide shared libraries (.so) to force cmake to use the static ones (.a)
hide_shared_libraries() {
    if [ -d "${PREFIX}/lib_hidden" ]; then
        mv -f "${PREFIX}/lib_hidden/"* "${PREFIX}/lib/" || true
        rmdir "${PREFIX}/lib_hidden" || true
    fi
    mkdir -p "${PREFIX}/lib_hidden" || true
    mv -f "${PREFIX}/lib/"*".so"* "${PREFIX}/lib_hidden/" || true
    return 0
}

# restore the hidden shared libraries
restore_shared_libraries() {
    if [ -d "${PREFIX}/lib_hidden" ]; then
        mv -f "${PREFIX}/lib_hidden/"* "${PREFIX}/lib/" || true
        rmdir "${PREFIX}/lib_hidden" || true
    fi
    return 0
}

add_items_to_install_package()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1
    [ -n "$PKG_ROOT" ]            || return 1
    [ -n "$PKG_ROOT_VERSION" ]    || return 1
    [ -n "$PACKAGER_ROOT" ]       || return 1
    [ -n "$PACKAGER_NAME" ]       || return 1
    [ -n "$CACHED_DIR" ]          || return 1

    local timestamp_file="$1"
    local pkg_files=""
    for fmt in gz xz; do
        local pkg_file="${PACKAGER_NAME}.tar.${fmt}"
        local pkg_path="${CACHED_DIR}/${pkg_file}"
        local temp_path=""
        local timestamp=""
        local compressor=""

        case "${fmt}" in
            gz) compressor="gzip -9 -n" ;;
            xz) compressor="xz -zc -7e -T0" ;;
        esac

        echo "[*] Creating install package (.${fmt})..."
        mkdir -p "${CACHED_DIR}"
        rm -f "${pkg_path}"
        rm -f "${pkg_path}.sum"
        cleanup() { rm -f "${temp_path}"; }
        trap 'cleanup; exit 130' INT
        trap 'cleanup; exit 143' TERM
        trap 'cleanup' EXIT
        temp_path=$(mktemp "${pkg_path}.XXXXXX")
        timestamp="@$(stat -c %Y "${timestamp_file}")"
        cd "${PACKAGER_ROOT}" || return 1
        if ! tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
                -C "${PACKAGER_ROOT}" * \
                -cv | ${compressor} >"${temp_path}"; then
            return 1
        fi
        touch -d "${timestamp}" "${temp_path}" || return 1
        chmod 644 "${temp_path}" || return 1
        mv -f "${temp_path}" "${pkg_path}" || return 1
        trap - EXIT INT TERM
        echo ""
        sign_file "${pkg_path}"

        if [ -z "${pkg_files}" ]; then
            pkg_files="${pkg_path}"
        else
            pkg_files="${pkg_files}\n${pkg_path}"
        fi
    done

    echo "[*] Finished creating the install package."
    echo ""
    echo "[*] Install package is here:"
    printf '%b\n' "${pkg_files}"
    echo ""

    return 0
) # END sub-shell

################################################################################
# Archive the cross toolchain directory
#

is_arm() {
    case "$(uname -m)" in
        arm*|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

on_build_started() {
    if [ ! -f "${BUILD_START_PATH}" ]; then
        SAVED_PWD="${PWD}"
        write_version_info
        touch "${BUILD_START_PATH}"
        cd "$SAVED_PWD"
    fi
    return 0
}

on_build_finished() {
    local mtime=""

    if [ -z "${BUILD_START_TIME}" ]; then
        if [ ! -f "${BUILD_START_PATH}" ]; then
            BUILD_START_TIME="(unknown)"
            BUILD_STOP_TIME="(unknown)"
            write_version_info
        else
            mtime=$(stat -c %Y "${BUILD_START_PATH}")
            BUILD_START_TIME="$(date -d "@$mtime" '+%Y-%m-%d %H:%M:%S %Z %z')"
            BUILD_STOP_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
        fi

        read REPO_VERSION REPO_TIMESTAMP REPO_DIRTY <"${BUILD_START_PATH}"
        rm -f "${BUILD_START_PATH}"
        append_version_info
    fi

    return 0
}

write_version_info()
( # BEGIN sub-shell
    [ -d "${CROSSBUILD_DIR}" ] || return 1

    cd "${SCRIPT_DIR}"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

    local repo_status="$(git status --porcelain)"
    local repo_dirty=""
    local repo_modified=""
    if [ -n "${repo_status}" ]; then
        repo_dirty="yes"
        repo_modified="-modified"
    else
        repo_dirty="no"
        repo_status="(no differences or untracked files)"
    fi

    local repo_version="$(git rev-parse HEAD)"
    local timestamp="$(git log -1 --format='@%ct')"
    local timestamp_utc="$(date -u -d "${timestamp}" '+%Y%m%d%H%M%S')"
    local timestamp_local="$(date -d "${timestamp}" '+%Y-%m-%d %H:%M:%S %Z %z')"
    local temp_path=""

    cleanup() { rm -f "${temp_path}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    temp_path=$(mktemp "${VERSION_PATH}.XXXXXX")
    {
        printf '%s\n' '---------------------------------------------------------------'
        printf 'RELEASE_VERSION        %s\n' "${RELEASE_VERSION}"
        printf 'GIT_COMMIT             %s\n' "${repo_version}"
        printf 'GIT_COMMIT_TIME        %s\n' "${timestamp_local}"
        printf 'GIT_DIRTY              %s\n' "${repo_dirty}"
        printf 'CPU_ARCHITECTURE       %s\n' "$(uname -m)"
        printf '%s\n' '---------------------------------------------------------------'
        printf '%s\n' "${repo_status}"
        printf '%s\n' '---------------------------------------------------------------'
        if [ -n "${repo_modified}" ]; then
        printf '%s\n' "$(git diff)"
        printf '%s\n' '---------------------------------------------------------------'
        fi
    } >"${temp_path}" || return 1
    mv -f "${temp_path}" "${VERSION_PATH}" || return 1

    temp_path=$(mktemp "${BUILD_START_PATH}.XXXXXX")
    echo "${repo_version} ${timestamp} ${repo_dirty}" >"${temp_path}" || return 1
    mv -f "${temp_path}" "${BUILD_START_PATH}" || return 1
    trap - EXIT INT TERM

    return 0
) # END sub-shell

append_version_info() {
    {
        printf 'BUILD_START_TIME       %s\n' "${BUILD_START_TIME}"
        printf 'BUILD_STOP_TIME        %s\n' "${BUILD_STOP_TIME}"
        printf '%s\n' '---------------------------------------------------------------'
    } >>"${VERSION_PATH}"

    return 0
}

archive_build_directory()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1

    local repo_dir="$1"
    local build_dir="$2"
    local repo_subdir="$(basename -- "${repo_dir}")"
    local build_subdir="$(basename -- "${build_dir}")"
    local version_path="${build_dir}/VERSION"
    local repo_filename=""
    local repo_modified=""
    local cached_path=""
    local temp_path=""
    local repo_version="${REPO_VERSION}"
    local timestamp="${REPO_TIMESTAMP}"
    local repo_dirty="${REPO_DIRTY}"
    local host_cpu="$(uname -m)"

    [ -d "${build_dir}" ] || return 1
    [ "${repo_dirty}" = "yes" ] && repo_modified="-modified"

    timestamp_utc="$(date -u -d "${timestamp}" '+%Y%m%d%H%M%S')"
    repo_filename="${repo_subdir}-${host_cpu}-${timestamp_utc}${repo_modified}.tar.xz"
    cached_path="${CACHED_DIR}/${repo_filename}"
    [ -z "${repo_modified}" ] && [ -f "${cached_path}" ] && return 0

    mkdir -p "${CACHED_DIR}"

    cleanup() { rm -f "${temp_path}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    temp_path=$(mktemp "${cached_path}.XXXXXX")
    if ! tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
            --exclude="${build_subdir}/src" \
            --exclude="${build_subdir}/stage" \
            --exclude="${build_subdir}/packager" \
            --transform "s|^${build_subdir}|${build_subdir}-${host_cpu}+git-${repo_version}${repo_modified}|" \
            -C "${PARENT_DIR}" "${build_subdir}" \
            -cv | xz -zc -7e -T0 >"${temp_path}"; then
        return 1
    fi

    touch -d "${timestamp}" "${temp_path}" || return 1
    chmod 644 "${temp_path}" || return 1
    mv -f "${temp_path}" "${cached_path}" || return 1
    trap - EXIT INT TERM
    sign_file "${cached_path}" # done

    # create link designed to behave just like the downloaded release asset
    local release_filename="${repo_subdir}-${host_cpu}-${RELEASE_VERSION}.tar.xz"
    local release_path="${CACHED_DIR}/${release_filename}"
    ln -sfn "${repo_filename}" "${release_path}"
    ln -sfn "${repo_filename}.sum" "${release_path}.sum"

    return 0
) # END sub-shell


################################################################################
download_and_compile() {
( #BEGIN sub-shell
export PATH="${CROSSBUILD_DIR}/bin:${PATH}"
mkdir -p "${SRC_ROOT}"
mkdir -p "${CROSSBUILD_DIR}"
mkdir -p "${STAGE}"
set +x
echo ""
echo ""
echo "[*] Starting ARM cross-compiler build..."
echo ""
echo ""
set -x

################################################################################
# zlib-1.3.1
(
PKG_NAME=zlib
PKG_VERSION=1.3.1
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://github.com/madler/zlib/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    export PREFIX="${STAGE}"
    export LDFLAGS="-L${PREFIX}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${PREFIX}/include -D_GNU_SOURCE"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --prefix="${PREFIX}" \
        --static \
    || handle_configure_error $?

    $MAKE
    make install

    rm -rf "${PREFIX}/lib/"*".so"*

    touch "__package_installed"
fi
)

################################################################################
# lz4-1.10.0
(
PKG_NAME=lz4
PKG_VERSION=1.10.0
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://github.com/lz4/lz4/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    on_build_started
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    PREFIX_TOOLCHAIN="${PREFIX}"

    export PREFIX="${STAGE}"
    export LDFLAGS="-L${PREFIX}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${PREFIX}/include -D_GNU_SOURCE"

    make clean || true
    $MAKE lib
    make install PREFIX=${PREFIX}

    rm -rf "${PREFIX}/lib/"*".so"*

    ## strip and verify statically-linked 
    #finalize_build "${PREFIX}/bin/lz4"

    ## install the program
    #mkdir -p "${PREFIX_TOOLCHAIN}/bin/"
    #cp -p "${PREFIX}/bin/lz4" "${PREFIX_TOOLCHAIN}/bin/"

    touch __package_installed
fi
)

################################################################################
# xz-5.8.2
(
PKG_NAME=xz
PKG_VERSION=5.8.2
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://github.com/tukaani-project/xz/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="890966ec3f5d5cc151077879e157c0593500a522f413ac50ba26d22a9a145214"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    PREFIX_TOOLCHAIN="${PREFIX}"

    export PREFIX="${STAGE}"
    export LDFLAGS="-L${PREFIX}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${PREFIX}/include -D_GNU_SOURCE"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --enable-year2038 \
        --enable-static \
        --disable-shared \
        --disable-assembler \
        --disable-dependency-tracking \
        --disable-nls \
        --disable-rpath \
        --disable-scripts \
        --disable-doc \
        --prefix="${PREFIX}" \
    || handle_configure_error $?

    $MAKE
    make install

    rm -rf "${PREFIX}/lib/"*".so"*

    ## strip and verify statically-linked
    #finalize_build "${PREFIX}/bin/xz"

    ## install the program
    #mkdir -p "${PREFIX_TOOLCHAIN}/bin/"
    #cp -p "${PREFIX}/bin/xz" "${PREFIX_TOOLCHAIN}/bin/"
    #cp -p "${PREFIX}/bin/lzma" "${PREFIX_TOOLCHAIN}/bin/"

    touch "__package_installed"
fi
)

################################################################################
# zstd-1.5.7
(
PKG_NAME=zstd
PKG_VERSION=1.5.7
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://github.com/facebook/zstd/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    on_build_started
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "." "${PKG_SOURCE_VERSION}" "${PKG_SOURCE_SUBDIR}"
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    PREFIX_TOOLCHAIN="${PREFIX}"

    export PREFIX="${STAGE}"
    export LDFLAGS="-L${PREFIX}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${PREFIX}/include -D_GNU_SOURCE"

    $MAKE zstd \
        LDFLAGS="-static ${LDFLAGS}" \
        CPPFLAGS="${CPPFLAGS}"
        LIBS="${PREFIX}/lib/libz.a ${PREFIX}/lib/liblzma.a ${PREFIX}/lib/liblz4.a"

    make install

    rm -rf "${PREFIX}/lib/"*".so"*

    # strip and verify statically-linked
    finalize_build "${PREFIX}/bin/zstd"

    # install the program
    #mkdir -p "${PREFIX_TOOLCHAIN}/bin/"
    #cp -p "${PREFIX}/bin/zstd" "${PREFIX_TOOLCHAIN}/bin/"

    touch __package_installed
fi
)

################################################################################
# binutils-2.45
(
PKG_NAME=binutils
PKG_VERSION=2.45
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/binutils/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="c50c0e7f9cb188980e2cc97e4537626b1672441815587f1eab69d2a1bfbef5d2"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    export LDFLAGS="-L${STAGE}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${STAGE}/include -D_GNU_SOURCE"
    export PKG_CONFIG="pkg-config"
    export PKG_CONFIG_LIBDIR="${STAGE}/lib/pkgconfig"
    unset PKG_CONFIG_PATH

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --with-system-zlib \
        --with-zstd \
        --enable-compressed-debug-sections=ld \
        --enable-default-compressed-debug-sections-algorithm=zlib \
        --disable-nls \
        --disable-werror \
        ac_cv_prog_with_compressed_debug_sections=yes \
    || handle_configure_error $?

    $MAKE
    make install

    touch "__package_installed"
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
PKG_HASH="70d124743041974e1220fb39465627ded1df0fdd46da6cd74f6e3da414194d03"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    on_build_started
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    make ARCH=arm INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install

    touch "__package_installed"
fi
)

################################################################################
# gcc-15.2.0 (bootstrap gcc)
(
PKG_NAME=gcc
PKG_VERSION=15.2.0
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/gcc/${PKG_NAME}-${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-bootstrap"
PKG_HASH="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed__gcc" ]; then
    on_build_started
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
        --disable-libstdcxx \
        --disable-libitm \
        --disable-libatomic \
        --disable-libvtv \
        --disable-bootstrap \
        --disable-libcilkrts \
        --disable-libada \
        --disable-libquadmath-support \
    || handle_configure_error $?

    $MAKE all-gcc
    make install-gcc

    touch "__package_installed__gcc"
fi
)

################################################################################
# gcc-15.2.0 (bootstrap libgcc)
(
PKG_NAME=gcc
PKG_VERSION=15.2.0
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-bootstrap"

cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed__libgcc" ]; then
    on_build_started

    cd "${PKG_BUILD_SUBDIR}"

    $MAKE all-target-libgcc
    make install-target-libgcc

    touch "__package_installed__libgcc"
fi
)

################################################################################
# musl-1.2.5
(
PKG_NAME=musl
PKG_VERSION=1.2.5
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://musl.libc.org/releases/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/musl-1.2.5/solartracker" "${PKG_SOURCE_SUBDIR}"

    # SECURITY ADVISORY: All releases through 1.2.5 are affected by CVE-2025-26519 and should be patched (1, 2).
    apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/musl-1.2.5/cve" "${PKG_SOURCE_SUBDIR}"

    # SECURITY ADVISORY: All releases through 1.2.1 are affected by CVE-2020-28928 and should be patched or upgraded to a later version.
    #apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/musl-1.2.1/cve" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    export CROSS_COMPILE=${CROSS_PREFIX}

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${SYSROOT}" \
        --includedir="${SYSROOT}/usr/include" \
        --syslibdir=/lib \
    || handle_configure_error $?

    $MAKE
    make install

    touch "__package_installed"
fi
)

################################################################################
# gcc-15.2.0 (final)
(
PKG_NAME=gcc
PKG_VERSION=15.2.0
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build-final"

cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --enable-languages=c,c++ \
        --enable-year2038 \
        --enable-shared \
        --disable-multilib \
        --disable-nls \
        --disable-libsanitizer \
        --with-arch=armv7-a --with-tune=cortex-a9 --with-float=soft --with-abi=aapcs-linux \
        --enable-cxx-flags='-march=armv7-a -mtune=cortex-a9 -marm -mfloat-abi=soft -mabi=aapcs-linux' \
    || handle_configure_error $?

    $MAKE
    make install

    touch "__package_installed"
fi
)

################################################################################
# gdb-17.1 (client)
(
PKG_NAME=gdb
PKG_VERSION=17.1
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/gdb/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_BUILD_SUBDIR="${PKG_SOURCE_SUBDIR}-build"
PKG_HASH="14996f5f74c9f68f5a543fdc45bca7800207f91f92aeea6c2e791822c7c6d876"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_BUILD_SUBDIR}/__package_installed" ]; then
    on_build_started
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"

    rm -rf "${PKG_BUILD_SUBDIR}"
    mkdir "${PKG_BUILD_SUBDIR}"
    cd "${PKG_BUILD_SUBDIR}"

    export LDFLAGS="-L${STAGE}/lib -Wl,--gc-sections"
    export CPPFLAGS="-I${STAGE}/include -D_GNU_SOURCE"
    export PKG_CONFIG="pkg-config"
    export PKG_CONFIG_LIBDIR="${STAGE}/lib/pkgconfig"
    unset PKG_CONFIG_PATH

    ../${PKG_SOURCE_SUBDIR}/configure \
        --target=${TARGET} \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --with-static-standard-libraries \
        --enable-year2038 \
        --disable-nls \
        --disable-werror \
        --without-python \
        --with-expat \
        --with-system-zlib \
        --with-zstd \
        --enable-compressed-debug-sections=ld \
        --enable-default-compressed-debug-sections-algorithm=zlib \
    || handle_configure_error $?

    $MAKE
    make install

    ## strip and verify statically-linked
    #finalize_build "${PREFIX}/bin/${CROSS_PREFIX}gdb"

    touch "__package_installed"
fi
)

################################################################################
# Done compiling the toolchain
#
on_build_finished

) #END sub-shell
set +x
echo ""
echo "[*] Finished compiling."
echo ""

return 0
} #END download_and_compile()


archive_and_configuration() {
################################################################################
# Archive the built toolchain
#
echo ""
echo "[*] Now archiving the built toolchain (this may take a while)..."
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
#
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

return 0
} #END archive_and_configuration()


main
echo ""
echo "Script exited cleanly."
echo ""

