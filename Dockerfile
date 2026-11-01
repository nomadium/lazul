# lazul development environment: cross toolchains, C library, QEMU and
# firmware for riscv64 and amd64.
#
# Build it with "make image" and run make inside it with ./dmake.

ARG STANDARD_VERSION=1.56.0
ARG PICOLIBC_VERSION=1.8.10

# picolibc for the amd64 kernel. Debian only packages it for embedded
# targets, so it is built here, from the same release as Debian's riscv64
# package, and copied into the final image.
FROM debian:trixie AS picolibc-amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
        meson \
        ninja-build \
    && rm -rf /var/lib/apt/lists/*

ARG PICOLIBC_VERSION
COPY build_config/picolibc-amd64.txt /tmp/
RUN git clone --depth 1 --branch $PICOLIBC_VERSION \
        https://github.com/picolibc/picolibc.git /tmp/picolibc \
    && meson setup /tmp/picolibc-build /tmp/picolibc \
        --cross-file /tmp/picolibc-amd64.txt \
        -Dprefix=/opt/picolibc-amd64 -Dspecsdir=/opt/picolibc-amd64/lib \
        -Dincludedir=include -Dlibdir=lib -Dmultilib=false -Dtests=false \
        -Dsemihost=false -Dpicocrt=false -Dthread-local-storage=true \
    && ninja -C /tmp/picolibc-build install

FROM debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        gcc-riscv64-unknown-elf \
        gdb-multiarch \
        git \
        opensbi \
        ovmf \
        picolibc-riscv64-unknown-elf \
        qemu-system-misc \
        qemu-system-x86 \
        rake \
        ruby \
        ruby-dev \
        u-boot-qemu \
    && rm -rf /var/lib/apt/lists/*

COPY --from=picolibc-amd64 /opt/picolibc-amd64 /opt/picolibc-amd64

ARG STANDARD_VERSION
RUN gem install --no-document standard -v $STANDARD_VERSION

WORKDIR /src
CMD ["bash"]
