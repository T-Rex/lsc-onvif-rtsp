# Build environment for the LSC Smart Connect PTZ 3007325 (Anyka AK3918EV330,
# ARM926EJ-S, ARMv5TEJ, soft-float) ONVIF package.
#
# The image contains only tools. All sources are fetched, verified and built
# by build.sh at container run time, and all results land in the bind-mounted
# /output directory.

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Host tools: build helpers (BusyBox kconfig needs a native gcc), readelf/file
# for ABI checks, qemu-user-static for ARM tests, curl/xmllint/python3/ss/pgrep
# for the SOAP and WS-Discovery tests, zlib1g-dev for upstream "make test",
# busybox-static to run the camera scripts with BusyBox sh and applets only.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        binutils \
        busybox-static \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        file \
        gcc \
        git \
        iproute2 \
        libc6-dev \
        libxml2-utils \
        make \
        patch \
        procps \
        python3 \
        qemu-user-static \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Bootlin pre-built toolchain: ARMv5TE (arm926ej-s), EABI soft-float, musl libc.
# Pinned by version and SHA-256.
ARG TOOLCHAIN=armv5-eabi--musl--stable-2025.08-1
ARG TOOLCHAIN_SHA256=8cdb4ad70c6b5a66427fa3315fe3ddde1c19c90232674dec59045e04d2a36cf1
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o tc.tar.xz \
      "https://toolchains.bootlin.com/downloads/releases/toolchains/armv5-eabi/tarballs/${TOOLCHAIN}.tar.xz"; \
    echo "${TOOLCHAIN_SHA256}  tc.tar.xz" | sha256sum -c -; \
    mkdir -p /opt; \
    tar -xJf tc.tar.xz -C /opt; \
    mv "/opt/${TOOLCHAIN}" /opt/toolchain; \
    rm tc.tar.xz; \
    cd /opt/toolchain && ./relocate-sdk.sh; \
    echo "${TOOLCHAIN}" > /opt/toolchain/TOOLCHAIN_NAME

ENV PATH="/opt/toolchain/bin:${PATH}" \
    CROSS_PREFIX=arm-buildroot-linux-musleabi-

WORKDIR /src
# build.sh is piped through tr to drop CR characters, so a CRLF checkout
# on Windows still builds.
CMD ["/bin/bash", "-c", "tr -d '\\r' < /src/build.sh > /tmp/build.sh && exec /bin/bash /tmp/build.sh"]
