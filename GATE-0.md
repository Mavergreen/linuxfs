# Gate 0a: LKL on Mac OS X 10.9

Does the Linux kernel, as a library (LKL), run on 10.9 and write ext4, btrfs, xfs and NTFS
(ntfs3) images that Linux's own checkers find clean? This file records what it took.

LKL pin: `lkl/linux` `d0f76a77e8c2ca68bd7d96190b8da09040eab072` (Linux 6.12).

## Mach-O route

**Route 1 (build ELF, convert) worked.** Route 2 (native Mach-O kernel build) was not needed.

The kernel is built for Linux exactly as upstream builds it (`build/build-lkl-linux.sh`), and
`build/elf2macho.py` converts its `lkl.o` to a Mach-O relocatable. `build/build-lkl-darwin.sh`
then cross-compiles the host library and programs with clang22 for 10.9 and archives them
with the converted kernel into `liblkl.a`.

Why route 1 was easy:

- `lkl.o` is already linked with the kernel's linker script (`ld -r`), so every
  `__start_*`/`__stop_*`, initcall and `__param` symbol is resolved inside the object. Nothing
  needs Mach-O's `section$start$` symbols.
- The kernel is built `-fPIC`. Text uses only `PC32`, `PLT32` and GOT-relative relocations;
  data uses only `R_X86_64_64`, plus `PC32` in `.rodata`. All have exact Mach-O forms.
- The object needs only two host symbols: `lkl_printf` and `lkl_bug`.
- About 25 allocated sections. Mach-O allows 255.

What the converter does:

| ELF | Mach-O |
|---|---|
| `.text` | `__TEXT,__text` |
| other allocated sections, and empty ones such as `__ex_table` whose `__start_`/`__stop_` symbols are referenced | `__DATA,__k<N>_<name>`; `.bss` as zero-fill, placed last |
| `PC32`/`PLT32` in text | `SIGNED`/`BRANCH`, in-place addend A+4 |
| `PC32` in data | `SUBTRACTOR`(section start) + `UNSIGNED`, in-place A−offset |
| `R_X86_64_64` | `UNSIGNED`, length 3 |
| `GOTPCREL`, `GOTPCRELX`, `REX_GOTPCRELX` | `SIGNED` into a GOT section the converter adds, one `UNSIGNED` slot per target; no instruction is rewritten |
| section symbols | a local symbol at each section's start |
| every symbol | Mach-O leading underscore |
| `.debug_*`, `.comment` | dropped |

Two linker-script symbols needed care. One lies in the alignment padding before its own
section (`__bss_start`, at .bss−16), and it means that section's start. One lies past its
section's end; it belongs to the later section that starts at its address.

The converter stops with an error on any relocation type or symbol kind it doesn't map,
including TLS and IFUNC symbols (`tests/elf2macho-test.sh`, run in the Linux baseline). A
symbol exactly at a section's end (`__start_ro_after_init`, at the end of `.data`) stays with
the earlier section. So ranges built from such symbols are right only while the linker keeps
the kernel's data sections contiguous and in order. `build/check-macho-layout.sh` enforces that
on every linked binary (it fails the build otherwise), and lld does it today.

Result on the 10.9 box (`tests/boot-darwin.sh`): upstream's boot test passes 35/35, including
`start_kernel`, proc mount, epoll, pipes, and many syscall threads. The binaries pass the
family's 10.9 compatibility guard (minos 10.9, SDK 10.9, no post-10.9 imports).

## LKL changes

In `patches/lkl/`, in application order:

1. `0000-defconfig-exfat-ntfs3.patch`: `CONFIG_NTFS3_FS=y` and `CONFIG_EXFAT_FS=y` in LKL's
   defconfig.
2. `0001-umount-waits-for-device-release.patch`: `lkl_umount_blkdev` waits until the device
   can be opened `O_EXCL`.
   - **This is a data-loss bug on every host, Linux included.** LKL runs system calls on kernel
     threads, so `umount()` defers the superblock teardown to `delayed_mntput_work` and returns
     at once. A `lkl_sys_halt()` right after that (which lklfuse does) drops the final journal
     and superblock writes.
   - Every ext4 and xfs image came back needing journal recovery. Found by the Linux baseline's
     fsck step.
   - The umount and the wait share the caller's one timeout. If the teardown outlasts it, the
     call returns `-ETIMEDOUT` and still removes its `/dev` and `/mnt` nodes, since the file
     system is unmounted either way (`gate0-rw -p umount-timeout`, with timeout 0, then
     `e2fsck -fn`).
3. `0002-darwin-host.patch`: the Darwin branch of `posix-host.c` and `lib/endian.h`.
   - semaphores: upstream's mutex/condvar fallback, because Darwin's `sem_init` always fails;
   - timers: dispatch timer sources, because there is no `timer_create`;
   - threads: 8 MiB stacks for the threads LKL creates, where Darwin's default is 512 KiB.
     Kernel code also runs on two kinds of thread LKL doesn't create: system calls run on
     the caller's own thread, and the timer interrupt and softirqs run on a libdispatch
     worker (512 KiB). Kernel code is written for 16 KiB stacks, so 512 KiB is ample, but
     the gate's 8 MiB covers only the threads LKL creates. See "For Gate 0b";
   - thread stack query: `pthread_get_stack*_np`;
   - clock: `mach_absolute_time`;
   - block I/O: `pread`/`pwrite` loops, because there is no `preadv` before 10.15;
   - flush: `F_FULLFSYNC`;
   - byte order: `OSByteOrder`.
   - Tested alone by `tests/host-ops-test.sh` (15 cases, mutation-checked; a watchdog turns a hang into a failure).
4. `0003-darwin-block-device-capacity.patch`: `fd_get_capacity` asks the disk driver
   (`DKIOCGETBLOCKCOUNT` × `DKIOCGETBLOCKSIZE`) when the fd is a block or character device,
   because Darwin's `lseek` and `fstat` report 0 for disks. It refuses a disk whose blocks
   aren't 512 bytes: LKL's virtio block device does 512-byte I/O, which a raw 4Kn disk
   rejects. Tested by the device rounds (Gate 0a+); reporting the size in blocks instead of
   bytes makes the mount fail.

## Back-fills

None needed. LKL's host library uses nothing 10.9 lacks once `0002` is applied. clang22's own
runtime support covered the rest.

## Timings

| What | 10.9 box (Mac Pro, Darwin 13.4) |
|---|---|
| boot test, whole run | 7.2 s wall |
| `start_kernel` | 95 ms |

### Read-write, `gate0-rw -p write` (three rounds each, fresh images)

Both columns ran on the same Mac Pro. The 10.9 column is native. The Linux column is the
same test in the Docker VM (boot2docker under VMware Fusion, on a virtual disk), so it is
only a sanity check and not a native-Linux benchmark. Images are 512 MiB files on the host
file system.

| fs | 4 MiB file, fsynced: 10.9 | Linux VM | 2,000 small files, synced: 10.9 | Linux VM | max RSS: 10.9 | Linux VM |
|---|---|---|---|---|---|---|
| ext4 | 59–110 MiB/s | 44–49 MiB/s | 124–306 ms | 124–838 ms | 32 MiB | 38 MiB |
| btrfs | 205–304 MiB/s | 256–317 MiB/s | 627–745 ms | 0.9–1.5 s | 33 MiB | 38 MiB |
| xfs | 76–98 MiB/s | 24–44 MiB/s | 453–501 ms | 0.8–1.7 s | 40 MiB | 45 MiB |
| ntfs3 | 79–102 MiB/s | 23–48 MiB/s | 230–539 ms | 0.6–1.2 s | 35 MiB | 40 MiB |

LKL on 10.9 is at least as fast as the same build in a Linux VM on the same machine. RSS is
under 41 MiB with `mem=128M`. Speed is nowhere near limiting.

## Read-write on 10.9 (Task 5)

`tests/gate0-darwin.sh round`, three times in a row with fresh images. Each round does this:

1. Linux makes the images.
2. 10.9 runs these:
   - `write` on all four filesystems;
   - the 1 MiB write at file offset 7.9 GiB in ext4;
   - a raw-device write and read-back at 4.5 GiB on an unformatted 5 GiB image (see below);
   - kill -9 mid-write on ext4 and xfs, after at least 100 writes have landed.
3. Linux's own checker replays the killed ext4 journal (`tests/lib/fsck-killed.sh`, on a copy:
   `e2fsck -fy` may fix no more than the replay, and a second `e2fsck -fn` must find nothing).
   xfs can only be replayed by a kernel.
4. 10.9 remounts ext4 and xfs read-write, so that LKL replays both journals.
5. Linux runs `e2fsck -fn`, `btrfs check --readonly`, `xfs_repair -n` and `ntfsfix -n`.
6. 10.9 runs `verify` on every image, upstream's disk test, and the 7.9 GiB read-back.

**Offsets past 4 GiB.** ext4 places `big.bin`'s data near its inode, not near its file
offset: the 7.9 GiB *file* offset lands at about 0.25 GiB on the disk. So that step proves
large file offsets, but not large device offsets. The raw-device step proves the latter. LKL
writes and reads 1 MiB at device offset 4.5 GiB. Then, with the kernel gone, the host checks
that its own file holds those bytes at 4.5 GiB, and that 0.5 GiB (where a 32-bit-truncated
offset would land) is still zero. A mutant that truncates the offset fails all three checks.

**All three rounds passed on all four filesystems.** No patch beyond Task 4's was needed; the
disk backend's Darwin changes (in `0002`) were enough.

**NTFS `chkdsk`: waived by the maintainer (2026-11-18).** No Windows machine is readily
available. Given clean `ntfsfix -n` checks and full read-back in every round, the maintainer
accepts NTFS as probably fine without it. An NTFS image written on 10.9 is kept at
`~/Library/Caches/mm-build/linuxfs-gate0/ntfs-for-chkdsk.img` (raw, 512 MiB), in case one
turns up. The product's NTFS support should get a real `chkdsk` before release, including
after an unclean unmount.

## Upstreamability

- `0001` is a real bug fix for every LKL host and lklfuse user.
- `0002` follows upstream's existing `#ifdef __FreeBSD__` pattern in the same files.
- `elf2macho.py` is self-contained. Upstream might prefer it as an `OUTPUT_FORMAT=macho-x86-64`
  post-link step in `arch/lkl/Makefile`.

## Verdict

**Gate 0a: PASS for ext4, btrfs and xfs. NTFS (ntfs3): PASS by waiver. It passed everything
run here, and the spec's Windows `chkdsk` was waived by the maintainer (see Task 5).**

- **Rounds:** three consecutive clean rounds on 10.9 with the final code, after ten clean ones
  during development. The Linux baseline (`tests/gate0-linux.sh`) passes 30/30. Each round
  covered all four filesystems:
  - every operation the gate names;
  - 2,000-entry directories and a 64-deep chain;
  - file offsets past 4 GiB, and device offsets past 4 GiB (raw device);
  - kill -9 mid-write.
- **Checkers:** Linux's own checkers found every image clean, and 10.9 read the content back: the whole 4 MiB file, the large-offset data, every name,
  link, mode and owner, all 2,000 directory entries, and the content of 5 of the 2,000 small
  files. The kill -9 churn files are not checked; only the earlier content is.
- **NTFS:** `ntfsfix -n` passed every round. The spec's hand `chkdsk` was waived (Task 5); the
  product should still get one before release.
- **Speed and memory:** both are fine (Timings).
- **Route:** the decisive risk was producing Mach-O, and route 1 settled it with no kernel
  changes at all.
- **The gate also found a real LKL bug.** Unmount returns before the file system is flushed
  (`0001`). It affects lklfuse on every host, and the product needs the fix.

Next is Gate 0b, which waits on `macfuse` shipping libfuse 3.

### Patches, and what upstreaming each needs

| Patch | Upstreamable as-is? | What would make it so |
|---|---|---|
| `0000-defconfig-exfat-ntfs3` | Likely; a one-line defconfig choice | upstream's view on defconfig size |
| `0001-umount-waits-for-device-release` | Yes. It fixes a data-loss bug for every LKL user | a test in `tests/disk.c`: unmount, halt, then check the image is clean. A kernel-side fix (have `umount` from LKL's syscall threads complete the teardown synchronously) may be preferred upstream |
| `0002-darwin-host` | Close. It follows the FreeBSD pattern | a `Makefile.autoconf` Darwin branch, so `make -C tools/lkl` works on macOS, plus a CI job |
| `0003-darwin-block-device-capacity` | With 0002 | nothing more. 4Kn support would mean advertising `VIRTIO_BLK_F_BLK_SIZE` |
| `build/elf2macho.py` (not a patch) | No, as written | recast as `OUTPUT_FORMAT=macho-x86-64` in `arch/lkl/Makefile` running the conversion after `lkl.o`. Upstream may prefer route 2 (native Mach-O) as the long-term answer |

### Back-fills versus the spec

- **No Recaulk needed.** The spec expected `clock_gettime` from Recaulk on 10.9;
  `mach_absolute_time` does the job with no dependency.
- **Semaphores** use LKL's existing condvar fallback, not dispatch semaphores.

### For Gate 0b and the product

- **FUSE worker stacks:** lklfuse's system calls run on libfuse's worker threads, which get
  Darwin's 512 KiB default. lklfuse should set an 8 MiB stack for them, to match the gate's
  premise.
- **lklfuse needs `0001`.** Without it, every unmount (`lklfuse` exit) can leave the journal
  dirty.
- **lklfuse `-o ro` cannot mount xfs.** It opens the image `O_RDONLY`, and xfs writes its log at
  mount even read-only. Options:
  - LKL advertises `VIRTIO_BLK_F_RO` for read-only disks (upstreamable);
  - read-only mounts pass `norecovery` for xfs;
  - open read-write and mount `MS_RDONLY`, which is what the gate does.
- **Real block devices:** done in Gate 0a+ (below) for image-backed disks. Still open: a
  physical USB disk (needs root), 4Kn disks, and pulling a disk mid-write.
- **Build host:** the kernel and the Darwin library are built on Linux. Producing `liblkl.a`
  needs no Linux at run time, only at build time. The spec's 10.9 build gap (GNU make, bash,
  flex, bison and kconfig on 10.9) applies only if the product must build on 10.9 itself.
  - CI can build on Linux, as the family's other cross builds do.
- **Tools:** `elf2macho.py` and the Linux build need python3 and Debian's kernel build tools,
  pinned in `build/linux-host/Dockerfile`.
- **Size:** `liblkl.a` is about 16 MiB, and each linked test program about 14.7 MiB (kernel
  included, unstripped). A stripped lklfuse should be about 9 MiB.
- **Memory:** `mem=128M` sufficed for every test; peak RSS stayed under 41 MiB.

## Gate 0a+: real block devices

`GATE0_DEVICE=rdisk` or `disk` runs the two-host round's Mac phases on real Darwin disks: each
image Linux made is attached with `hdiutil attach -nomount` (owned by the attaching user, so
no root), LKL works on `/dev/rdiskN` or `/dev/diskN`, and the disks are detached before Linux
checks the image files. Needs `0003`; without it every mount fails (capacity 0).

- Three clean `rdisk` rounds and one clean `disk` round: every write, kill, replay, Linux fsck
  and verify step of the file round, except `raw-large`, whose host-side check reads the image
  file (the 7.9 GiB ext4 write covers offsets past 4 GiB on the device). A disk that won't
  detach fails the phase and stays listed in `$GATE0_IMAGES/devices`; an unknown
  `GATE0_DEVICE` is refused.
- `rdisk` works because LKL's I/O is always 512-byte aligned; `rdisk` refuses anything
  unaligned with `EINVAL`.
- The buffered `disk` node is slower, and its flushes reach the image (Linux fsck clean).

| fs | 4 MiB file, fsynced: file | rdisk | disk | 2,000 small files, synced: rdisk | disk |
|---|---|---|---|---|---|
| ext4 | 59–110 MiB/s | 72–115 MiB/s | 32 MiB/s | 290–632 ms | 281 ms |
| btrfs | 205–304 MiB/s | 157–197 MiB/s | 39 MiB/s | 647–685 ms | 665 ms |
| xfs | 76–98 MiB/s | 74–96 MiB/s | 35 MiB/s | 621–846 ms | 446 ms |
| ntfs3 | 79–102 MiB/s | 71–91 MiB/s | 37 MiB/s | 565–1073 ms | 703 ms |

**For the product:** use `/dev/rdiskN`. The root helper opens it read-write (after claiming
the disk from DiskArbitration) and passes the fd to the unprivileged lklfuse; LKL's capacity
query and I/O work on that fd as on a file. A 4Kn disk should be refused with a message
(the check is in `0003`, but no 4Kn disk was available to test it).

## Gate 0a+: NTFS killed mid-write

ntfs3 has no journal replay; Linux's ntfs3 only marks the volume dirty while it is mounted.
Each round now writes a second NTFS image, `ntfs-killed.img`, and kills a writer on it
(`tests/gate0-linux.sh`, and both the file and `rdisk` rounds of `tests/gate0-darwin.sh`). After
the kill:

- **ntfs3 refuses to mount it read-write**: `volume is dirty and "force" flag is not set!`,
  `-EINVAL` (`gate0-rw -p dirty-refused`; mounting with `force` makes the check fail).
- **Read-only, everything written before the kill reads back** (`-p verify`).
- **`ntfsfix -n` must report damage** (in every run so far, `$MFTMirr does not match $MFT`);
  `ntfsfix` repairs a copy, and `ntfsfix -n` then finds its MFT and boot sector consistent (`tests/lib/fsck-killed.sh IMAGE ntfs`). That is all
  ntfs-3g can check. Whether Windows `chkdsk` agrees is not tested (see the waiver above).
- Linux baseline 35/35; three file rounds and one `rdisk` round clean.

**For the product:** a dirty NTFS volume (after a crash, a pulled disk, and probably after
Windows hibernation or fast startup, though that is untested) cannot be mounted read-write. lklfuse
should then mount it read-only and say why, rather than use `force`. `ntfsfix` is no way out:
it fixes the MFT mirror and empties `$LogFile`, but leaves the volume marked dirty so that
Windows runs `chkdsk`, so ntfs3 still refuses it read-write. (`ntfsfix -d` would clear the
flag; untested, and less than `chkdsk`.) The honest advice is to let Windows check it.

## Gate 0b prep: lklfuse

Gate 0b mounts Linux filesystems on 10.9 through LKL's own FUSE front end, `lklfuse`, and
Mavergreen macFUSE's libfuse 3. Everything that doesn't need macFUSE installed on the 10.9
box is done.

**Proven on Linux** (`tests/gate0b-linux.sh`, 42/42, run with `LINUX_HOST_FUSE=1 build/linux-host.sh`):
- lklfuse mounts ext4, btrfs, xfs and ntfs3. Then `cp`, `mkdir`, 200 small files, `mv`,
  `setfattr` and `touch` run through the mount.
- After `fusermount3 -u`, lklfuse exits 0, the image is clean, and a second mount reads
  everything back: content, rename, xattr, mtime.
- Unmount needs no patch. lklfuse unmounts the root of its own chroot, which Linux turns into
  a read-only remount; that flushes and marks the volume clean. A lklfuse that halts without
  unmounting leaves ext4 and NTFS dirty, and the test catches it.
- kill -9 mid-write: on ext4, the next mount replays the journal and earlier data survives.
  On NTFS, lklfuse exits with `volume is dirty` and leaves no mount.
- `tests/lib/check-fs.sh` is now the one checker for both gates. It also fails a log that still
  needs replaying, which the stock checkers can let through:
  - ext4: `e2fsck -fn` skips the replay and exits 0, so on its own it let the no-unmount mutant
    through;
  - btrfs: `btrfs check --readonly` passes a non-zero `log_root`;
  - xfs: `xfs_repair -n` already fails a dirty log (checked on a killed image).

  A mount counts as ready only once a listing through it succeeds. The FUSE mount appears
  before LKL has mounted anything, and a failed LKL mount ends lklfuse.

**Built for 10.9** (`build/build-lkl-darwin.sh` → `lklfuse`, ~15 MiB):
- `0004-lklfuse-darwin.patch`:
  - macFUSE's portable callback signatures (`FUSE_DARWIN_ENABLE_EXTENSIONS 0`);
  - `st_atimespec` in place of `st_atim`;
  - Linux-only open flags compiled out;
  - a refusal to start without `-f`, because macFUSE's libfuse can't fork after mounting;
  - **errno translation.** LKL returns Linux errno values, and macFUSE hands a callback's result
    to Darwin unchanged. Untranslated:
    - a missing xattr (Linux `ENODATA`, 61) reads as `ECONNREFUSED`;
    - `com.apple.*` xattrs, which Linux rejects with `EOPNOTSUPP` (95), arrive as `EMULTIHOP`
      instead of the `ENOTSUP` that makes macFUSE fall back to AppleDouble;
    - `ENOTEMPTY`, `ENAMETOOLONG`, `ELOOP` and others are wrong too.

    Every LKL result now goes through `lklfuse_err()`: same name, Darwin's number, with
    `ENODATA`→`ENOATTR`, `EOPNOTSUPP`→`ENOTSUP`, and `EIO` for anything Darwin lacks;
  - **xattr and rename flags translated.** Darwin's `XATTR_CREATE`/`XATTR_REPLACE` are 2 and 4,
    Linux's 1 and 2. macFUSE's `RENAME_EXCL`/`RENAME_SWAP` become `RENAME_NOREPLACE`/`RENAME_EXCHANGE`.

  Linux behavior is unchanged: the translations are identity there.
- `tests/lklfuse-ops-test.c` calls lklfuse's callbacks directly on an ext4 image, with no
  FUSE mount, and checks what the host would be told. On 10.9 it passes 15/15
  (`tests/lklfuse-ops-darwin.sh`); before the translation, 10 of the 15 cases failed. It passes
  on Linux too, inside the Linux baseline.
- It builds against the pinned `macfuse/library` libfuse 3 headers
  (`components/libfuse3`, the macFUSE spike's commit). It links a stub `libfuse3` whose
  install name is `/usr/local/lib/libfuse3.4.dylib`.
- The macfuse session checked its built library: it exports all 14 symbols lklfuse imports,
  with compatibility version 4.0.0 (the stub records 1.0.0, so dyld accepts it) and libfuse 3.18.3.
- The compatibility guard is clean, and `libfuse3.4.dylib` is the only non-system import.

**Ready to run on 10.9:** `tests/gate0b-darwin.sh` repeats the Linux cases with macOS
tools (`xattr`, `umount`, `diskutil unmount`), with images made and checked by Linux. It runs
on the image file, or on `/dev/rdiskN` with `GATE0_DEVICE=rdisk`. It exits 77 until Mavergreen
macFUSE is installed. Installing that on the 10.9 box needs the maintainer's OK.

**Facts from the macfuse session's 10.9 VM measurements (2026-11-20)** that shape lklfuse:
- `destroy()` runs on `umount`, `diskutil unmount` and SIGTERM;
- `max_write` is 1 MiB;
- the multithreaded loop is stable, and `FUSE_THREAD_STACK` is honored (lklfuse runs
  single-threaded anyway, on the main thread's 8 MiB stack).

**What Gate 0b itself will measure** (not testable without the install):
- Finder: `.DS_Store`, `com.apple.*` xattrs (Linux rejects names outside its namespaces),
  Spotlight and `.Trashes`;
- throughput through FUSE versus Gate 0a's direct numbers;
- LKL's single CPU under Finder load.

## Gate 0b: lklfuse on 10.9 through Mavergreen macFUSE

Run by the macfuse session on its 10.9.5 VM, which has Mavergreen macFUSE 5.5.0-mavericks.2,
Recaulk 20261120.2 and a hand-linked RecaulkKPI.kext. The VM has no Linux beside it, so the run
used a bundle (`build/gate0b-bundle.sh`): the 10.9 lklfuse, its callback test, the test script
and images made by Linux. Each Linux check is a gzipped snapshot, checked here afterwards by
`tests/gate0b-check-bundle.sh`.

**Bundle 2 (2026-11-21): PASS.** 84/84, on image files (42) and on `/dev/rdiskN` (42), in 206 s.
No panic and no watchdog event. All 20 snapshots pass Linux's checkers.
- **lklfuse's callbacks:** they report Darwin errno values and xattr/rename flags (15/15),
  with no FUSE involved.
- **ext4, btrfs, xfs, NTFS:**
  - lklfuse mounts each one;
  - `cp`, `mkdir`, 200 files, `mv`, `xattr -w` and `touch -t` work through the mount;
  - `umount` and `diskutil unmount` both end lklfuse with exit 0, and Linux finds the image
    clean;
  - a second mount reads back the contents, the rename, the xattr and the mtime.
- **kill -9 mid-write:** on ext4, the next mount replays the journal and the earlier data
  survives. On NTFS, lklfuse refuses the dirty volume and says why.

**Bundle 1 (2026-11-20): 80/84.** In both modes, the first plain `umount` of btrfs was refused
(`Resource busy`), and the step that remounts it failed as a result. The `diskutil unmount`
that followed worked, and every snapshot was clean. It did not happen again in bundle 2,
which logs every unmount's holders and retries a busy `umount` for 10 s.
- Bundle 2's root `lsof` samples show Finder holding mount directories open for a few seconds
  at a time, including during btrfs writes. That is the likely cause, but it is inferred.
- Neither Spotlight nor Time Machine was ever seen holding a mount.
- **For the product:** eject through DiskArbitration, as `diskutil` does, because it asks
  holders to let go. A bare `umount` doesn't.

**Small follow-ups:**
- lklfuse opens the image without `O_CLOEXEC`, so macFUSE's `mount_macfuse` briefly inherits
  it (fd 3). This needs a one-line change to `0004`.
- No throughput or Finder-copy numbers yet: this VM is unaccelerated QEMU, so its timings
  wouldn't mean anything. Those need real hardware with the stack installed.

**Verdict:** the product's premise holds on 10.9. Linux's own ext4, btrfs, xfs and ntfs3,
running in-process through LKL and exposed through Mavergreen macFUSE, read and write
correctly, unmount cleanly, and survive a killed daemon. What's left is product work (helper,
automount agent, DiskArbitration, packaging), plus measuring Finder behavior and speed on real
hardware.
