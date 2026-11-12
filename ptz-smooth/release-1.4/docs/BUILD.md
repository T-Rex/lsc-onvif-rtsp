# BUILD — onvif_ptz_bridge 1.4 (ARMv5TEJ, Docker)

All compilation happens inside the existing `onvif-armv5-builder:latest` image
(musl cross-toolchain `arm-buildroot-linux-musleabi-`). No tools are installed on
Windows. The output is a **statically linked, soft-float ARMv5TEJ** binary.

## Prerequisites
- Docker Desktop (Linux containers).
- The base image `onvif-armv5-builder:latest` already built (used by the ONVIF
  and earlier PTZ builds). If missing, build it from the repo's top-level
  `Dockerfile` / `docker-compose.yml` first.

## Build + test (Windows PowerShell)
```powershell
# from the repo root
docker run --rm -v "${PWD}:/work" onvif-armv5-builder:latest `
  bash -c "cd /work/ptz-smooth/release-1.4; tr -d '\r' < build.sh > /tmp/b14.sh; HERE=/work/ptz-smooth/release-1.4 bash /tmp/b14.sh"
```
Or the convenience wrapper (also runs the restore tests):
```powershell
sh ptz-smooth/release-1.4/scripts/run-tests.sh      # needs an sh; or run the docker line above
```

## Outputs (bind-mounted, visible from Windows)
```
ptz-smooth/release-1.4/output/
├── onvif-ptz-bridge-1.4.0/           # the release package (bin/scripts/docs/config/ptz)
├── onvif-ptz-bridge-1.4.0-armv5.tar  # release archive (UNCOMPRESSED tar; camera has no gzip)
├── SHA256SUMS
├── binary-checks.txt                 # file + readelf -h/-A/-d
├── build-report.md
├── test-results.txt                  # unit + daemon (expect 54/54)
├── soap-results.txt                  # ONVIF SOAP (expect 11/11)
└── unstripped/onvif_ptz_bridge
```

## Flags (in `build.sh`)
```
-mcpu=arm926ej-s -marm -mfloat-abi=soft -Os -std=gnu11 -Wall -Wextra
-ffunction-sections -fdata-sections   (compile)
-static -Wl,--gc-sections -lm          (link)
```

## Verify the ABI (must match the camera)
`output/binary-checks.txt` must show:
- `ELF 32-bit LSB executable, ARM, EABI5 ... statically linked`
- `Tag_CPU_arch: v5TEJ`, `Tag_CPU_name: "5TEJ"`
- `Flags: 0x5000200, Version5 EABI, soft-float ABI`
- `There is no dynamic section in this file.` (fully static — no shared libs)

A binary without these (e.g. `armhf`/hard-float, or dynamically linked) must not
be deployed — it will not run on ARM926EJ-S.

## Last known-good build (this release)
- bridge 1.4.0 SHA-256: `bfec6df5da2bc2eace45976583eb5eb20ae2144d5c3b52f5ceb76ea962481d73`
- archive SHA-256: see `output/SHA256SUMS` (the archive cannot embed its own SHA)
- Tests: 54/54 unit+daemon, 11/11 SOAP, 13/13 restore. ARM arch v5TEJ, static, soft-float.
