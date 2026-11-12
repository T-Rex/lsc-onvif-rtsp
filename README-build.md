# Building the ONVIF package (Docker Desktop on Windows)

Produces a self-contained ONVIF server package for the **LSC Smart Connect PTZ
3007325** (Anyka AK3918EV330, ARM926EJ-S, ARMv5TEJ, Linux 4.4.192, BusyBox):

- `onvif_simple_server` (CGI) and `wsd_simple_server` from
  [roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server),
  commit `7b3941af76a57277ba975efaf2366cb8c6fa1936`
- BusyBox 1.36.1 `httpd` (only this applet) with the upstream ONVIF CGI patch
- control scripts, configuration and documentation

All compilation and testing runs in a Linux container. Nothing needs to be
installed on Windows except Docker Desktop (Linux containers).

## Build

PowerShell:

```powershell
cd C:\Users\T-Rex\Documents\Projects\onvif-server
docker compose build            # builder image: Debian 12 + Bootlin toolchain + QEMU (once)
docker compose run --rm build   # fetch, compile, verify, test, package
```

The same without Compose:

```powershell
docker build -t onvif-armv5-builder .
docker run --rm -v "${PWD}:/src:ro" -v "${PWD}\output:/output" onvif-armv5-builder
```

The first run downloads about 80 MB (toolchain) plus about 10 MB of sources.
A build including the tests takes a few minutes. The command exits non-zero
if compilation, the ABI check or any test fails.

## Output (`.\output`, bind-mounted)

| Path | Content |
| --- | --- |
| `onvif-camera\` | Deployment folder; copy it to the SD card as `onvif` |
| `onvif-camera.tar.gz` | The same folder as an archive |
| `SHA256SUMS` | Checksums of the archive and the binaries |
| `build-report.md` | Versions, ABI, dependencies, test results, limitations |
| `deployment-guide.md` | Installation, testing, stop and removal on the camera |
| `binary-checks.txt` | Full `file` / `readelf` / disassembly check output |
| `test-results.txt` | Full log of the QEMU integration tests |
| `unstripped\` | The binaries with symbols (debugging and the ISA check only) |
| `build-logs\` | Compiler logs of every component; SOAP request/response samples |

Each run deletes and recreates these paths.

Reproducibility: all inputs are pinned (commit, tarball SHA-256, toolchain
SHA-256), and `SOURCE_DATE_EPOCH` is set to the upstream commit time. Two clean
builds produced byte-identical `httpd`, `onvif_simple_server` and
`wsd_simple_server`. The archive itself differs between runs only because
`VERSION` records the build time. The Debian base image and its apt
packages (host tools and QEMU) are not pinned.

## What `build.sh` does

1. Clones onvif_simple_server and checks out the pinned commit. Downloads
   BusyBox 1.36.1, mbedtls 3.6.4, json-c 0.18 and zlib 1.3.1 and verifies
   their SHA-256 checksums.
2. Builds zlib, json-c and libmbedcrypto as static ARM libraries.
   libmbedcrypto uses the upstream minimal config `extras/mbedtls_config.h`:
   SHA-1 and Base64, all the WS-UsernameToken check needs.
3. Applies `patches/onvif_simple_server/*.patch`, builds the CGI and the WSD
   daemon (`-static`, `-mcpu=arm926ej-s -marm -mfloat-abi=soft -Os`), and runs
   the upstream unit tests (`make test`, native).
4. Applies `patches/busybox/0001-httpd-onvif-cgi.patch` and builds a static
   BusyBox containing only `httpd` (`config/busybox-httpd.fragment` on top of
   `allnoconfig`).
5. Assembles `onvif-camera/` from the binaries, the upstream XML templates and
   `package/` (scripts and configuration, normalised to LF line endings).
6. `tests/check-binaries.sh` checks every binary: ELF32 ARM, EABI5, soft-float
   flag, `Tag_CPU_arch` v5TEJ, no FP/NEON attributes, no program interpreter,
   no `DT_NEEDED`, no Thumb code, and a disassembly scan for ARMv6+/VFP/NEON
   instructions. The only allowed hits are musl routines that are guarded at
   run time.
7. `tests/run-tests.sh` runs the real `start.sh` / `status.sh` / `stop.sh`
   on a copy of the package with all execute bits removed (FAT32
   simulation). All ARM programs run under `qemu-arm-static -cpu arm926`. It
   then sends about 50 SOAP requests, makes WS-Discovery multicast and unicast
   probes, captures Hello/Bye, and tests authentication, the IP access list,
   duplicate-start protection and RAM logging. A negative control shows that
   the `arm926` CPU model rejects an ARMv6 instruction.
8. Writes the archive, checksums and `build-report.md`.

## Toolchain

[Bootlin](https://toolchains.bootlin.com) `armv5-eabi--musl--stable-2025.08-1`
(GCC 14.3.0, binutils 2.43.1, musl 1.2.5, Linux headers 5.4). The default
target is `-mcpu=arm926ej-s -mfloat-abi=soft`. The tarball is pinned by
SHA-256 in the `Dockerfile`. musl was chosen for small static binaries without
glibc's static-NSS problems. Debian `armhf` is ARMv7 hard-float and would not
run on this CPU.

## Changing the configuration

The camera-side configuration is in `package/etc/` and ends up in
`onvif-camera/etc/`. You can also edit it directly on the SD card later,
without rebuilding. See `docs/deployment-guide.md`.

Paths compiled into the binaries (not configurable at run time):

| Binary | Path | Purpose |
| --- | --- | --- |
| onvif_simple_server | `/tmp/onvif/etc/onvif_simple_server.conf` | configuration (written by start.sh) |
| onvif_simple_server | `/tmp/onvif/log/onvif_simple_server.log` | CGI log (start.sh links `/tmp/onvif/log` to `logs/` on the card) |
| onvif_simple_server | `/tmp/onvif/onvif_simple_server.debug` | if it exists, it holds the debug level |
| wsd_simple_server | `/tmp/onvif/log/wsd_simple_server.log` | daemon log |

## Repository layout

```
Dockerfile, docker-compose.yml   build environment
build.sh                         the build (runs in the container)
patches/                         source patches (documented in their headers)
config/busybox-httpd.fragment    BusyBox configuration
package/                         scripts and configuration for the camera
docs/deployment-guide.md         copied to output/ and into the package
tests/                           ABI check, QEMU integration tests, report generator
```

## Troubleshooting the build

- `docker: error during connect`: start Docker Desktop and make sure it uses
  Linux containers.
- Downloads fail behind a proxy: configure the proxy in Docker Desktop
  (Settings > Resources > Proxies).
- Different upstream commit: set `ONVIF_COMMIT` in `docker-compose.yml`. The
  patches may then need updating; the build stops if a patch does not apply.
- Line endings: the build strips CR characters, so a checkout with
  `core.autocrlf=true` still produces LF files for the camera.
