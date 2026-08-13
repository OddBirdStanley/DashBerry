# Pinned build environment for the DashBerry Zero image.
#
# WHY THIS EXISTS
# ---------------
# showmewebcam pins buildroot 2021.02.8, whose package versions are frozen in
# 2021. Building 2021 sources with a 2026 host toolchain is where every build
# failure so far has come from — cmake 4 dropping pre-3.5 policies, gcc 14
# promoting four warnings to errors, gcc 15 defaulting to C23. build.sh works
# around each of those, but a workaround is a guess about someone else's
# machine, and that list only grows as hosts move on.
#
# This removes the variable instead of managing it. Debian bookworm carries
# gcc 12 and cmake 3.25, both of which PREDATE every breaking change build.sh
# works around — so inside this image not one of those workarounds is needed.
# That doubles as a test of the pin: if build.sh reports a workaround firing in
# here, the base image has drifted and this file needs revisiting.
#
# Not the default, because it needs Docker and a few GB. `ZERO_CONTAINER=1
# zero/build.sh` opts in, and build.sh recommends it whenever it sees a host
# toolchain newer than what buildroot 2021.02 expects.
FROM debian:bookworm-slim

# Buildroot's mandatory and optional host dependencies; its own
# support/dependencies/dependencies.sh is the authority and this matches what
# that script checks for. Two worth calling out because a slim image has
# neither and buildroot checks for both BY NAME: `which` and `awk` (gawk).
RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        binutils \
        bzip2 \
        ca-certificates \
        cmake \
        cpio \
        file \
        g++ \
        gawk \
        gcc \
        git \
        gzip \
        libncurses-dev \
        locales \
        make \
        patch \
        perl \
        pkg-config \
        python3 \
        rsync \
        sed \
        tar \
        unzip \
        wget \
        which \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Buildroot refuses to run as root, and a build run as root would leave
# root-owned files in the bind-mounted work tree either way. build.sh passes
# --user for exactly that reason.
ENV LC_ALL=C LANG=C

WORKDIR /zero
