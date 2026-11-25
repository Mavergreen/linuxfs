# Ingredients

Everything baked into Linux Filesystems for Mavericks, where it is pinned and what moves it.

| Ingredient | Pinned in | Tracked by | A bump |
|---|---|---|---|
| LKL (`lkl/linux`, the Linux Kernel Library; its kernel, host library and `lklfuse`) | `components/lkl/version`: `REPO`, `REF=master`, `DIGEST` (the commit) and `TARBALL_SHA256` (GitHub's tarball of it, for `fetch_pinned_source.sh`) | `git-refs` on `lkl/linux` `master` with `currentDigest`; the tarball SHA-256 is written by a pins bot on Renovate's branch | a new upstream: `UPSTREAM_VERSION` is re-derived from the tree by `build/derive-upstream-version.sh` (kernel version and commit date), giving `<version>-mavericks.1` |
| linux-apfs-rw (`linux-apfs/linux-apfs-rw`, the APFS driver, built into LKL as `fs/apfs` by `build/graft-apfs.sh`; linuxfs mounts it read-only) | `components/linux-apfs/version`: `REPO`, `TAG`, `DIGEST` (the tag's commit) and `TARBALL_SHA256` | `github-tags` on `linux-apfs/linux-apfs-rw` with `currentDigest`; the pins bot writes the tarball SHA-256 on Renovate's branch (`build/pin-lkl.sh components/linux-apfs/version`) | a repackage: the driver is not the upstream `UPSTREAM_VERSION` names |
| Our LKL patches | `patches/lkl/*.patch`, applied in name order by shipyard's `apply_patches.sh` | ours | a repackage, dispatched by hand (`local_release=true`) |
| Mavergreen macFUSE's libfuse 3 headers and `libfuse3.4.dylib` (compile and link time only; lklfuse runs against the installed `/usr/local/lib/libfuse3.4.dylib`), and the macFUSE the 10.9 acceptance job installs (with the Recaulk that release pins at its own tag) | `components/macfuse/version`: the release tag; `build/build-lkl-darwin.sh` takes the headers and dylib from its pkg with shipyard's `fetch_product_pkg.sh` | `github-releases` on `Mavergreen/macfuse`, `-mavericks.N` versioning | a repackage |
| clang22 (compiles the host library, lklfuse, our C tools and the Sparkle updater; supplies the `llvm-*` Mach-O readers) | `components/clang22/version`, plus `components/clang22/linux-sha256` (its Linux archive's line of the release's `SHA256SUMS`) | `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning; the pins bot writes `linux-sha256` on Renovate's branch | a repackage |
| Recaulk (`librecaulk.a`, through clang22's config) | follows clang22 | follows clang22 | follows clang22 |
| Mavergreen macFUSE (run time, `--requires macfuse>=5.5.0-mavericks.4`) | not baked in; the floor is `MACFUSE_MIN` in `build/package.sh` (it carries the single-threaded-loop fix; lklfuse ending on SIGTERM on 10.9 is LKL's setjmp mask, patch 0011, so `.2` and `.3` with it are untested; the before-login mount itself needs `.2`, tools/fs.c's gate; lklfuse finds names exactly, with no directory scan, only on `.5` or later, which it detects from the installed version and otherwise scans, patch 0012), kept at or below the pin so a linuxfs update never waits on macfuse's updater | the pkg's preinstall refuses a volume without it, or with an older one | none |
| The Linux build container (kbuild, mkfs and fsck tools, FUSE; `build/linux-host.sh` locally, `release.yml` and `on-mavericks.yml` in CI) | `build/linux-host/Dockerfile`: `debian:trixie-slim` by digest | Renovate's dockerfile manager | none by itself: the next release builds in it |
| MacOSX10.9 SDK, stevedore, the compat guard, packaging, signing and release scripts | `Mavergreen/shipyard@v1` | the github-actions manager tracks the tag | none by itself |

Upstream's release notes: `build/upstream-release-notes-url.sh` links the pinned commit's history on `lkl/linux`.

The Sparkle updater's icon: none, by explicit opt-in to the generic macOS application icon (`updater/ICON-CREDIT.txt`).

## Declared state

Not ingredients: `patches/lkl/` and the build scripts are this repo's own recipe, and a declared state names
files only. A change there is a repackage cut deliberately (`workflow_dispatch` with `local_release=true`).

- upstream: components/lkl/version
- macfuse: components/macfuse/version
- clang22: components/clang22/version

## Conformance deviations

- native-build:kernel: the LKL kernel is built by Linux's kbuild on a Linux host (build/linux-host.sh) and converted to Mach-O by build/elf2macho.py (python3), so the build does not run natively on 10.9; exit: a Mach-O output format in LKL's arch/lkl, or kbuild running on 10.9 with clang22
- install-path:Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper: the root helper that opens disks for the console user runs as root, and root-run code may not live under /usr/local, which a user can often write (Homebrew); this is the OS's root-owned place for privileged helpers; exit: /opt/mavergreen/linuxfs once flag-day P4 moves products to a root-owned prefix
- install-path:System/Library/Filesystems/macfuse_ext4.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:System/Library/Filesystems/macfuse_ntfs.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:System/Library/Filesystems/macfuse_btrfs.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:System/Library/Filesystems/macfuse_xfs.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:System/Library/Filesystems/macfuse_f2fs.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:System/Library/Filesystems/macfuse_apfs.fs/*: DiskArbitration on 10.9 reads filesystem bundles only from /System/Library/Filesystems (the spike found no other directory works), and runs their probe, mount and fsck programs as root; exit: none, the OS's own place for filesystem bundles
- install-path:Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d/*: the programs the before-login root path execs by these absolute paths (lklfuse, the CLI, the prober, linuxfs-open), run as the unprivileged _linuxfs; they are exec'd with root-chosen paths, so they sit in the OS's root-owned place for privileged helpers, not under /usr/local, which a user can often write (Homebrew); exit: /opt/mavergreen/linuxfs once flag-day P4 moves products to a root-owned prefix
- no-standalone:linuxfs: linuxfs works only installed: a root helper launched from /Library/LaunchDaemons opens disks for the console user, DiskArbitration mounts them through bundles in /System/Library/Filesystems (the agent remains as the keychain keeper), and lklfuse mounts through macFUSE's kext; unpacked from an archive, none of them is loaded, so `linuxfs mount` could open no disk and mount nothing
- on-target:repo-suite: the guest does not run run-repo-tests.sh. tests/smoke-mavericks.sh exercises the installed product on 10.9 (every filesystem through `linuxfs mount`, the helper and the agent); the repo's 10.9 tests (helper-test.sh, agent-test.sh, lklfuse-ops-darwin.sh, host-ops-test.sh, boot-darwin.sh) build with clang22 from the source tree and need Linux beside them (build/linux-host.sh) to make their images, which the guest has not; exit: those tests take their images from a directory, as the smoke does, and on-mavericks.yml's guest job runs run-repo-tests.sh with shipyard's scripts copied in.
