/*
 * linuxfs-helper's refusals, called directly: which paths it accepts, which peers, and that it never opens a
 * partition the Mac has mounted (the boot volume here). helper_serve is driven through a socketpair.
 * usage: helper-policy-test
 */
#define LINUXFS_HELPER_NO_MAIN
#include "../tools/helper.c"

static int tapno, failures;

static void is(int got, int want, const char *what)
{
	tapno++;
	printf("%sok %d - %s", got == want ? "" : "not ", tapno, what);
	if (got != want) {
		printf(" (got %d, want %d)", got, want);
		failures++;
	}
	printf("\n");
}

static void answers(const char *req, uid_t peer, uid_t console, const char *want, const char *what)
{
	int sv[2];
	char buf[1024] = { 0 };
	ssize_t n;

	socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
	write(sv[1], req, strlen(req));
	helper_serve(sv[0], peer, console, 0);
	n = read(sv[1], buf, sizeof(buf) - 1);
	close(sv[0]);
	close(sv[1]);
	tapno++;
	if (n > 0 && strncmp(buf, want, strlen(want)) == 0) {
		printf("ok %d - %s\n", tapno, what);
	} else {
		printf("not ok %d - %s (got '%s', want '%s...')\n", tapno, what, buf, want);
		failures++;
	}
}

int main(void)
{
	struct statfs root;
	char raw[128], where[1024], req[256];

	is(helper_device_ok("/dev/rdisk2s1"), 1, "a raw partition node is accepted");
	is(helper_device_ok("/dev/rdisk2"), 1, "a raw whole-disk node is accepted");
	is(helper_device_ok("/dev/disk2s1"), 0, "a block node is refused (raw only)");
	is(helper_device_ok("/dev/rdisk2s"), 0, "a partition suffix with no number is refused");
	is(helper_device_ok("/dev/rdisks1"), 0, "no disk number is refused");
	is(helper_device_ok("/dev/rdisk2s1/../../etc/passwd"), 0, "a path that goes on is refused");
	is(helper_device_ok("/etc/passwd"), 0, "a file is refused");
	is(helper_peer_ok(0, 501), 1, "root may ask");
	is(helper_peer_ok(501, 501), 1, "the console user may ask");
	is(helper_peer_ok(502, 501), 0, "another user may not");
	if (statfs("/", &root) == 0 && strncmp(root.f_mntfromname, "/dev/disk", 9) == 0) {
		snprintf(raw, sizeof(raw), "/dev/r%s", root.f_mntfromname + 5);
		is(helper_mac_mounted(raw, where, sizeof(where)) && strcmp(where, "/") == 0, 1,
		   "the boot volume's partition is seen as mounted by the Mac at /");
		snprintf(req, sizeof(req), "open %s rw\n", raw);
		answers(req, getuid(), getuid(), "no mounted by the Mac at /", "open of the boot partition is refused, naming where it is mounted");
		snprintf(req, sizeof(req), "probe %s\n", raw);
		answers(req, getuid(), getuid(), "no mounted by the Mac", "probe of the boot partition is refused too");
	}
	is(helper_mac_mounted("/dev/rdisk99s9", where, sizeof(where)), 0, "a partition nothing mounts is not mounted");
	/* what the partition is, not only what its bytes say */
	is(helper_media_refusal("C12A7328-F81F-11D2-BA4B-00A0C93EC93B", 1, 0, "vfat", 1) != NULL, 1, "the EFI System Partition is refused");
	is(helper_media_refusal("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", 1, 1, "vfat", 1) != NULL, 1, "an ESP is refused on ejectable media too, in any case");
	is(helper_media_refusal("0xEF", 1, 1, "vfat", 1) != NULL, 1, "an MBR EFI partition is refused");
	is(helper_media_refusal("48465300-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "an Apple HFS+ partition is refused whatever its bytes say");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "an APFS partition is refused");
	is(helper_media_refusal("53746F72-6167-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "a CoreStorage partition is refused");
	is(helper_media_refusal("426F6F74-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "Apple Boot (Recovery HD) is refused");
	is(helper_media_refusal("E3C9E316-0B5C-4DB8-817D-F92DF00215AE", 1, 1, "ntfs3", 1) != NULL, 1, "Microsoft Reserved is refused");
	is(helper_media_refusal("DE94BBA4-06D1-4D40-A16A-BFD50179D6AC", 1, 1, "ntfs3", 1) != NULL, 1, "Windows Recovery is refused");
	is(helper_media_refusal("GUID_partition_scheme", 0, 1, "ext4", 1) != NULL, 1, "a disk with partitions under it is refused (I3)");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 0, "ntfs3", 1) != NULL, 1, "internal NTFS (Boot Camp) is refused");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 0, "vfat", 1) != NULL, 1, "internal FAT is refused");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 1, "ntfs3", 1) == NULL, 1, "NTFS on ejectable media is served");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 1, "exfat", 1) == NULL, 1, "exFAT on ejectable media is served");
	is(helper_media_refusal("0FC63DAF-8483-4772-8E79-3D69D8477DE4", 1, 0, "ext4", 1) == NULL, 1, "internal Linux ext4 is served");
	is(helper_media_refusal("0x83", 1, 0, "btrfs", 1) == NULL, 1, "an internal MBR Linux partition is served");
	is(helper_media_refusal("", 1, 1, "ext4", 1) == NULL, 1, "an unpartitioned ejectable disk (a stick, an image) is served");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, NULL, 0) == NULL, 1, "an APFS partition may be opened read-only (to probe it)");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "apfs", 0) == NULL, 1, "APFS is served read-only");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "apfs", 1) == NULL, 1, "APFS on ejectable media may be served read-write (the user opted in: APFSWrite)");
	is(helper_media_refusal("", 1, 1, "apfs", 1) == NULL, 1, "so may an unpartitioned APFS disk");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 0, "apfs", 1) != NULL, 1, "internal APFS (a newer macOS's own) is never served read-write");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 0, "apfs", 0) == NULL, 1, "but is served read-only");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 0) != NULL, 1, "an APFS-typed partition holding anything else is refused");
	{
		struct media_facts f;

		is(helper_media_facts("disk0s1", &f) == 0 && strcasecmp(f.content, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") == 0 &&
		   f.leaf && !f.ejectable, 1, "IOKit says disk0s1 is this Mac's internal ESP");
		is(helper_media_facts("disk0", &f) == 0 && !f.leaf, 1, "IOKit says disk0 has partitions under it");
		is(helper_media_facts("disk99s9", &f) < 0, 1, "a disk IOKit does not know gives no facts");
	}
	answers("open /dev/rdisk99s9 rw\n", 502, 501, "no only the user at the console", "a peer other than the console user is refused");
	answers("open /etc/master.passwd rw\n", 501, 501, "no not a raw disk node", "a path other than a raw disk node is refused");
	answers("open /dev/rdisk99s9 rwx\n", 501, 501, "no request is", "a mode other than rw or ro is refused");
	answers("gimme /dev/rdisk99s9\n", 501, 501, "no request is", "an unknown request is refused");
	answers("open /dev/rdisk0s1 rw\n", getuid(), getuid(), "no a system partition", "open of this Mac's EFI partition is refused (C1)");
	answers("open /dev/rdisk0 ro\n", getuid(), getuid(), "no a disk with partitions", "open of the whole boot disk is refused (I3)");
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}
