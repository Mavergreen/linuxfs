FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential flex bison bc perl make curl ca-certificates xz-utils python3 file \
      cpio procps git e2fsprogs btrfs-progs xfsprogs ntfs-3g exfatprogs dosfstools f2fs-tools attr fuse3 libfuse3-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
# apfsprogs (mkapfs, apfsck) for APFS test images: linux-apfs/apfsprogs v0.2.1, by commit and tarball SHA-256
RUN curl -fsSL -o /tmp/apfsprogs.tar.gz https://codeload.github.com/linux-apfs/apfsprogs/tar.gz/3721463ba7f539e532907bc1d10ed5b9a97d0449 \
    && echo "5cda1bf9678dc2ad9c99c77e243cc31d4941f1b873fc6b596b787fe176bfd08e  /tmp/apfsprogs.tar.gz" | sha256sum -c - \
    && mkdir /tmp/apfsprogs && tar xzf /tmp/apfsprogs.tar.gz -C /tmp/apfsprogs --strip-components=1 \
    && make -C /tmp/apfsprogs/mkapfs && make -C /tmp/apfsprogs/apfsck \
    && install -m 755 /tmp/apfsprogs/mkapfs/mkapfs /tmp/apfsprogs/apfsck/apfsck /usr/local/bin/ \
    && rm -rf /tmp/apfsprogs /tmp/apfsprogs.tar.gz
