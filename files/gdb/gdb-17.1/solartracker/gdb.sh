#!/bin/sh
################################################################################
# gdb.sh
#
# This script launches the ARM-targeted, musl-linked gdb executable by calling
# libc.so as the dynamic loader. It is intended for embedded or minimal ARM
# systems lacking /lib/ld-musl-arm.so.1. The script resolves its own location,
# sets it as the working directory, and forwards all arguments directly to GDB.
#
# Copyright (C) 2025 Richard Elwell
# Licensed under GPLv3 or later
################################################################################
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
"${SCRIPT_DIR}/lib/libc.so" "${SCRIPT_DIR}/bin/gdb" "$@"

