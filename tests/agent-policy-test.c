/*
 * linuxfs-agent's pure choices, called directly: which request lines it accepts, and which disks the login sweep
 * mounts. usage: agent-policy-test
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

/* LINE parsed: the verb and BSD it gives, "" for either when it is refused; the result is "VERB BSD" or "refused". */
static const char *parsed(const char *line, char *out, size_t len)
{
	char buf[256], *verb = NULL, *bsd = NULL;

	snprintf(buf, sizeof(buf), "%s", line);
	if (agent_parse_request(buf, &verb, &bsd) != 0)
		snprintf(out, len, "refused");
	else
		snprintf(out, len, "%s %s", verb, bsd);
	return out;
}

static void is_parsed(const char *line, const char *want, const char *what)
{
	char out[300];

	parsed(line, out, sizeof(out));
	is(strcmp(out, want) == 0, 1, what);
}

int main(void)
{
	is_parsed("find\tdisk9", "find disk9", "find BSD is a request");
	is_parsed("save\tdisk9s1", "save disk9s1", "save BSD is a request");
	is_parsed("forget\tdisk9s1", "forget disk9s1", "forget BSD is a request");
	is_parsed("offer\tdisk10s2", "offer disk10s2", "offer BSD is a request");
	is_parsed("find\tdisk9\n", "find disk9", "a trailing newline is dropped");
	is_parsed("find", "refused", "a line with no BSD name is refused");
	is_parsed("find\t", "refused", "so is an empty BSD name");
	is_parsed("", "refused", "an empty line is refused");
	is_parsed("\tdisk9", "refused", "so is one with no verb");
	is_parsed("delete\tdisk9", "refused", "an unknown verb is refused");
	is_parsed("finder\tdisk9", "refused", "a verb that only starts like ours is refused");
	is_parsed("find\tdisk9\textra", "refused", "a third field is refused");
	is_parsed("find\t../etc", "refused", "a BSD name that is not one is refused");
	is_parsed("find disk9", "refused", "a space is not the separator");

	is(agent_sweeps("linuxfs_ext4", 0), 1, "the sweep takes a linuxfs_ disk with no volume path");
	is(agent_sweeps("linuxfs_apfs", 0), 1, "whatever its filesystem");
	is(agent_sweeps("linuxfs_ext4", 1), 0, "not one that is already mounted");
	is(agent_sweeps("hfs", 0), 0, "not the Mac's own filesystems");
	is(agent_sweeps("ntfs", 0), 0, "not NTFS the Mac reads");
	is(agent_sweeps("", 0), 0, "not a disk with no kind");
	is(agent_sweeps(NULL, 0), 0, "nor a missing one");
	is(agent_sweeps("linuxfs", 0), 0, "a kind that only starts like ours is not ours");
	{
		/* spec: tools/agent.c -- the sweep skips a volume /etc/fstab keeps from mounting by itself (linuxfs ignore) */
		const char *f = "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF none linuxfs_ext4 rw,noauto # linuxfs\n"
				"LABEL=my\\040data none linuxfs_ntfs rw,noauto # linuxfs\nLABEL=Mac none hfs rw,noauto\n";
		size_t n = strlen(f);

		is(agent_sweeps_volume("linuxfs_ext4", 0, f, n, "0123ABCD-4567-89EF-0123-456789ABCDEF", "x"), 0, "not a volume with linuxfs's noauto entry for its UUID");
		is(agent_sweeps_volume("linuxfs_ntfs", 0, f, n, NULL, "my data"), 0, "nor one with an entry for its volume name");
		is(agent_sweeps_volume("linuxfs_ext4", 0, f, n, "FFFFFFFF-4567-89EF-0123-456789ABCDEF", "Mac"), 1, "another program's entry does not count");
		is(agent_sweeps_volume("linuxfs_ext4", 0, "", 0, NULL, NULL), 1, "with no fstab, a linuxfs_ disk with no volume path is swept");
		is(agent_sweeps_volume("linuxfs_ext4", 1, "", 0, NULL, NULL), 0, "but not one already mounted");
		is(agent_sweeps_volume("hfs", 0, "", 0, NULL, NULL), 0, "nor the Mac's own");
	}
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}
