# Linux Filesystems for Mavericks

Mount many kinds of filesystems on Mac OS X 10.9 Mavericks.

Inspired by
[anylinuxfs](https://github.com/nohajc/anylinuxfs),
but instead of a VM it's implemented in native processes via
[LKL](https://github.com/lkl/linux)
and FUSE.

## Usage

1. Install [macFUSE for Mavericks](https://github.com/Mavergreen/macfuse/releases/latest)
2. Install this
3. Connect any supported filesystem, use normally, eject normally

General CLI options:

```sh
linuxfs help
```

### Supported filesystems

- APFS
- NTFS
- ext4 (and 3 and 2)
- btrfs
- xfs
- f2fs

### APFS write support

Read-only by default.
[Write support is experimental](https://github.com/linux-apfs/linux-apfs-rw).
To read-write mount external disks:

```sh
linuxfs prefs APFSWrite on
```

### NTFS write support

Uses the Mac's read-only built-in NTFS by default.
To read-write mount external disks:

```sh
linuxfs prefs NTFSTakeover on
```
