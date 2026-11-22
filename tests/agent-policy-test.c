/*
 * linuxfs-agent's choices, called directly: which disks it probes, which it takes from the Mac, and which
 * probe answers it claims a disk for. usage: agent-policy-test
 */
#define LINUXFS_AGENT_NO_MAIN
#include "../tools/agent.c"

static int tapno, failures;

static void is(int got, int want, const char *what)
{
	tapno++;
	printf("%sok %d - %s\n", got == want ? "" : "not ", tapno, what);
	failures += got != want;
}

int main(void)
{
	is(agent_action(1, NULL, 0, 0, 1, 1), ACT_PROBE, "a leaf the Mac finds no filesystem on is probed");
	is(agent_action(0, NULL, 0, 0, 1, 1), ACT_NONE, "a disk with partitions is not (its partitions are)");
	is(agent_action(1, NULL, 1, 0, 1, 1), ACT_NONE, "a mounted volume is left alone");
	is(agent_action(1, "hfs", 0, 1, 1, 1), ACT_NONE, "HFS+ is never taken");
	is(agent_action(1, "apfs", 0, 1, 1, 1), ACT_NONE, "APFS is never taken");
	is(agent_action(1, "msdos", 0, 1, 1, 1), ACT_NONE, "FAT is never taken");
	is(agent_action(1, "exfat", 0, 1, 1, 1), ACT_NONE, "exFAT is never taken");
	is(agent_action(1, "ntfs", 0, 0, 1, 1), ACT_NONE, "NTFS stays the Mac's with NTFSTakeover off");
	is(agent_action(1, "ntfs", 0, 1, 1, 1), ACT_TAKEOVER, "NTFS is taken over with NTFSTakeover on");
	is(agent_action(1, "ntfs", 1, 1, 1, 1), ACT_NONE, "an NTFS volume the Mac has already mounted is left alone");
	is(agent_action(1, "ntfs", 0, 1, 0, 1), ACT_NONE, "NTFSTakeover with Automount off leaves NTFS to the Mac (review I4)");
	is(agent_action(1, NULL, 0, 0, 0, 1), ACT_NONE, "with Automount off, nothing is probed or claimed");
	is(agent_action(1, "ntfs", 0, 1, 1, 0), ACT_NONE, "NTFS on internal media (Boot Camp) is never taken over (M8)");
	is(agent_action(1, NULL, 0, 0, 1, 0), ACT_PROBE, "an internal Linux partition is still probed");
	is(agent_claims("ext4\tdata"), 1, "ext4 is claimed");
	is(agent_claims("btrfs\t"), 1, "btrfs is claimed");
	is(agent_claims("xfs\tx"), 1, "xfs is claimed");
	is(agent_claims("f2fs\t"), 1, "f2fs is claimed");
	is(agent_claims("apfs\tTime Machine"), 1, "APFS is claimed (10.9 cannot read it)");
	is(agent_claims("apfs\tFused\tfusion-main 00112233445566778899aabbccddeeff"), 1, "a Fusion container's main device is claimed");
	is(agent_claims("apfs\t\tfusion-tier2 00112233445566778899aabbccddeeff"), 1, "and its second device (automount of either mounts both, once both are here)");
	is(agent_claims("ntfs3\t"), 0, "NTFS is not claimed at peek (the Mac reads it)");
	is(agent_claims("vfat\tSTICK"), 0, "FAT is not claimed");
	is(agent_claims("exfat\t"), 0, "exFAT is not claimed");
	is(agent_claims("unknown"), 0, "an unknown filesystem is not claimed");
	is(agent_claims("ext4x\t"), 0, "a name that only starts like ours is not claimed");
	{
		char hint[64];
		char ans1[] = "remember\nlinuxfs-test\n", ans2[] = "once\npass\nwith newline", ans3[] = "maybe\nx\n";
		const char *pw = NULL;
		int remember = -1;

		is(agent_hint("linuxfs: wrong password for /dev/disk4s1 (hint: test)\n", hint, sizeof(hint)) &&
		   strcmp(hint, "test") == 0, 1, "the CLI's wrong-password message gives the volume's hint");
		is(agent_hint("linuxfs: /dev/disk4s1 is an encrypted volume; give its password\n", hint, sizeof(hint)), 0,
		   "and no hint when it names none");
		is(agent_parse_answer(ans1, strlen(ans1), &remember, &pw) == 0 && remember == 1 && strcmp(pw, "linuxfs-test") == 0, 1,
		   "the password dialog's answer: remember it, and the password (its trailing newline dropped)");
		is(agent_parse_answer(ans2, strlen(ans2), &remember, &pw) == 0 && remember == 0 && strcmp(pw, "pass\nwith newline") == 0, 1,
		   "once: not remembered; a password may hold a newline");
		is(agent_parse_answer(ans3, strlen(ans3), &remember, &pw), -1, "an answer that is neither is refused");
	}
	{
		/* review M6: a disk linuxfs's lklfuse holds (its lock taken) is not the Mac's to mount */
		char dir[] = "/tmp/agent-policy.XXXXXX", lock[128];
		int fd;

		mkdtemp(dir);
		is(agent_holds(dir, "disk5s1"), 0, "a disk with no lock file is not linuxfs's");
		snprintf(lock, sizeof(lock), "%s/linuxfs-rdisk5s1.lock", dir);
		fd = open(lock, O_RDWR | O_CREAT, 0644);
		is(agent_holds(dir, "disk5s1"), 0, "nor one whose lock nobody holds");
		flock(fd, LOCK_EX);
		is(agent_holds(dir, "disk5s1"), 1, "one whose lock lklfuse holds is (M6)");
		is(agent_holds(dir, "disk5s2"), 0, "and only that one");
		close(fd);
		unlink(lock);
		rmdir(dir);
	}
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}
