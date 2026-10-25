# lazul development environment: cross toolchains, C library, QEMU and
# firmware for riscv64 and x86_64.
#
# Build it with "make image" and run make inside it with ./dmake.

ARG STANDARD_VERSION=1.56.0
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
    && rm -rf /var/lib/apt/lists/*

ARG STANDARD_VERSION
RUN gem install --no-document standard -v $STANDARD_VERSION

WORKDIR /src
CMD ["bash"]
