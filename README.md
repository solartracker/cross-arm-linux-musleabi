# ARM Linux musl Cross-Compiler Build Script

This repository contains a single, self-contained shell script that builds an **ARMv7 soft-float `arm-linux-musleabi` cross-compiler** using **musl libc**. The resulting toolchain is suitable for building both statically and dynamically linked binaries for older ARM Linux systems, embedded platforms, and environments where musl is preferred over glibc.

The script performs a complete, from-source toolchain bootstrap, including binutils, Linux kernel headers, GCC (bootstrap and final), and musl libc.

## TL;DR

Build a reproducible ARMv7 musl-based cross-compiler entirely from source.

- Target: `arm-linux-musleabi` (ARMv7 soft-float)
- libc: musl
- Languages: C, C++
- Raspberry Pi 3B build time: ~4 hours

## Target Overview

- **Target triple:** `arm-linux-musleabi`
- **Architecture:** ARMv7 (soft-float)
- **C library:** musl
- **Languages:** C and C++

## What the Script Builds

1. binutils 2.40  
2. Linux kernel headers 2.6.36.4  
3. GCC 12.5.0 (bootstrap compiler)  
4. libgcc (bootstrap)  
5. musl libc 1.2.4  
6. GCC 12.5.0 (final compiler with C and C++ support)

All sources are verified using SHA-256 checksums and cached locally.

## Host System Requirements

Linux host system.

### Required Packages (Debian/Ubuntu)

```sh
sudo apt update
sudo apt install     build-essential     binutils     bison     flex     texinfo     gawk     make     perl     patch     file     wget     curl     git     libgmp-dev     libmpfr-dev     libmpc-dev     libisl-dev     zlib1g-dev
```

## Build Time Expectations

On a **Raspberry Pi 3 Model B**, a clean build took approximately **4 hours** and required:

- SSD-based storage
- 2 GB swap file
- Adequate cooling

Build times on modern x86_64 systems are significantly shorter.

## Usage

```sh
cd
git clone https://github.com/solartracker/cross-arm-linux-musleabi
cd cross-arm-linux-musleabi
./build-arm-linux-musleabi.sh
```

The script is restartable and skips completed stages on reruns.

Toolchain output:

```sh
$HOME/cross-arm-linux-musleabi-build/bin/
```

Add to PATH:

```sh
export PATH="$HOME/cross-arm-linux-musleabi-build/bin:$PATH"
```

## Testing the Toolchain

```c
#include <stdio.h>

int main(void) {
    puts("hello, arm-linux-musleabi");
    return 0;
}
```

```sh
arm-linux-musleabi-gcc -static hello.c -o hello
file hello
readelf -d hello || true
```

## Example Makefile

```makefile
CROSS ?= arm-linux-musleabi-

CC      := $(CROSS)gcc
STRIP   := $(CROSS)strip

CFLAGS  := -O2 -Wall
LDFLAGS := -static

TARGET  := hello
SRCS    := hello.c

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@
	$(STRIP) $@

clean:
	rm -f $(TARGET)
```

## Common Pitfalls

- Out-of-memory kills during GCC builds (add swap or reduce `-j`)
- Thermal throttling on ARM boards
- Mixing host headers or libraries into the sysroot
- Expecting dynamically linked ARM binaries to run on the host

## License

GPL-3.0-or-later  
Copyright © 2025 Richard Elwell
