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

Disks are recognised and mounted by the Mac itself (DiskArbitration), through filesystem bundles this installs in
`/System/Library/Filesystems`, so they appear in Disk Utility and `diskutil` like any other, and they mount even
before anyone logs in, once the Mac is told to mount disks without a login (10.9 has no setting for it in the
interface: `sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin
-bool true`); such a disk is mounted by root and served by an unprivileged `_linuxfs` user, and is open to every user. `diskutil mount`, `diskutil unmount` and `diskutil eject` work as usual.

General CLI options:

```sh
linuxfs help
```

For a disk, `linuxfs mount DEVICE` is `diskutil mount` plus the options `--ro` and `--password-stdin`; the options for
image files (a mount point, `--linux-ids`, `--tier2`, `-o`) are not for disks. Everything else about a disk is set
with `linuxfs prefs`.

### Preferences

`linuxfs prefs` shows them; `linuxfs prefs KEY on|off` sets one for you. Keys: `ReadOnly`, `NTFSTakeover` and
`APFSWrite`. The mount program runs as root, so it reads your preferences
(`~/Library/Preferences/dev.mavergreen.linuxfs.plist`, when you are at the console) and then the machine's, in
`/Library/Preferences/dev.mavergreen.linuxfs.plist`. Set the machine's with `sudo defaults write
/Library/Preferences/dev.mavergreen.linuxfs KEY -bool true`, for disks mounted before login, when no user's
preferences apply.

### Keeping a volume from mounting by itself

```sh
linuxfs ignore /dev/disk2s1      # or the volume's name, with its disk attached: linuxfs ignore "my data"
linuxfs unignore /dev/disk2s1
linuxfs ignore                   # lists them
```

As for the Mac's own volumes, this is an `/etc/fstab` entry with `noauto` (by the volume's UUID, or its name when it has
none), which the linuxfs helper writes for you: the volume then stays unmounted when its disk is connected, and
`diskutil mount` or Disk Utility's Mount still mounts it. There is no switch for every volume at once. The entry is about
the volume, not the filesystem: an NTFS volume you ignore stays unmounted at connection whether linuxfs or the Mac's own
NTFS would mount it (with `NTFSTakeover` off too), since you asked for that volume not to mount by itself. Installing this
version turns the old `Ignore:NAME` preferences into such entries for the disks attached at the time, and drops the old
`Automount` preference; for each name it could not convert (its disk was not attached), you are told once, at your next
login, to attach it and run `linuxfs ignore`. Uninstalling linuxfs removes its entries, and only those.

### Supported filesystems

- APFS
- NTFS
- ext4 (and 3 and 2)
- btrfs
- xfs
- f2fs

### Encrypted APFS

Connecting one shows the Mac's own password dialog (with a checkbox to keep the password in your login keychain). From
a terminal, `printf PASSWORD | linuxfs mount --password-stdin /dev/diskNsM` does it without the dialog.

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
