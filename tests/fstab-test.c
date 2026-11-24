/*
 * linuxfs's /etc/fstab entries, called directly: which specs and bundles may be written, how a label is escaped, what an
 * edit keeps and changes, and which volumes have an entry. usage: fstab-test
 */
#include <stdio.h>
#include <string.h>
#include "../tools/fstab.h"

static int tapno, failures;

static void is(int got, int want, const char *what)
{
	tapno++;
	printf("%sok %d - %s\n", got == want ? "" : "not ", tapno, what);
	if (got != want)
		printf("# got %d, want %d\n", got, want);
	failures += got != want;
}

static void iss(const char *got, const char *want, const char *what)
{
	int ok = got == want || (got && want && strcmp(got, want) == 0);

	tapno++;
	printf("%sok %d - %s\n", ok ? "" : "not ", tapno, what);
	if (!ok)
		printf("# got '%s', want '%s'\n", got ? got : "(null)", want ? want : "(null)");
	failures += !ok;
}

static char out[FSTAB_MAX + 2];

/* IN edited: the result as a string ("(refused)" for -1), *changed in CH */
static const char *edit(const char *in, const char *spec, const char *bundle, int *ch)
{
	long n = fstab_edit(in, strlen(in), spec, bundle, out, sizeof out, ch);

	if (n < 0)
		return "(refused)";
	out[n] = '\0';
	return out;
}

int main(void)
{
	static char big[FSTAB_MAX + 1];
	static const char *const ok_bundles[] = { "linuxfs_ext4", "linuxfs_btrfs", "linuxfs_xfs", "linuxfs_f2fs", "linuxfs_apfs", "linuxfs_ntfs" };
	char e[256], label[1100];
	int ch, i, all;
	const char *mine = "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF none linuxfs_ext4 rw,noauto # linuxfs\n";
	const char *other = "# a comment\nUUID=0123ABCD-4567-89EF-0123-456789ABCDEF none hfs rw,noauto\nLABEL=Backup none hfs ro\n";

	/* specs */
	iss(fstab_spec_refusal("UUID=0123ABCD-4567-89EF-0123-456789ABCDEF"), NULL, "a canonical uppercase UUID may be written");
	is(fstab_spec_refusal("UUID=0123abcd-4567-89ef-0123-456789abcdef") != NULL, 1, "a lowercase UUID is refused");
	is(fstab_spec_refusal("UUID=0123ABCD456789EF0123456789ABCDEF") != NULL, 1, "a UUID without its dashes is refused");
	is(fstab_spec_refusal("UUID=0123ABCD-4567-89EF-0123-456789ABCDE") != NULL, 1, "a short UUID is refused");
	is(fstab_spec_refusal("UUID=0123ABCD-4567-89EF-0123-456789ABCDEF0") != NULL, 1, "a long UUID is refused");
	is(fstab_spec_refusal("UUID=0123ABCD-4567-89EF-0123-456789ABCDEG") != NULL, 1, "a UUID with a letter past F is refused");
	is(fstab_spec_refusal("UUID=0123ABCD-4567-89EF-0123_456789ABCDEF") != NULL, 1, "a UUID with a dash elsewhere is refused");
	iss(fstab_spec_refusal("LABEL=my data"), NULL, "a label with a space may be written");
	iss(fstab_spec_refusal("LABEL=a\tb"), NULL, "a label with a tab may be written");
	iss(fstab_spec_refusal("LABEL=Donn\xc3\xa9" "es"), NULL, "a UTF-8 label may be written");
	is(fstab_spec_refusal("LABEL=") != NULL, 1, "an empty label is refused");
	is(fstab_spec_refusal("LABEL=a\nb") != NULL, 1, "a label with a newline is refused");
	is(fstab_spec_refusal("LABEL=a#b") != NULL, 1, "a label with # is refused");
	is(fstab_spec_refusal("LABEL=a\rb") != NULL, 1, "a label with a carriage return is refused");
	is(fstab_spec_refusal("LABEL=a\001b") != NULL, 1, "a label with another control byte is refused");
	is(fstab_spec_refusal("LABEL=a\177b") != NULL, 1, "a label with DEL is refused");
	is(fstab_spec_refusal("LABEL=a\\040b") != NULL, 1, "a label with a backslash is refused (it would read as an escape)");
	memset(label, 'x', sizeof label);
	memcpy(label, "LABEL=", 6);
	label[6 + 1000] = '\0';
	iss(fstab_spec_refusal(label), NULL, "a label of 1000 bytes may be written");
	label[6 + 1000] = 'x';
	label[6 + 1001] = '\0';
	is(fstab_spec_refusal(label) != NULL, 1, "one of 1001 bytes is refused");
	is(fstab_spec_refusal("DEV=/dev/disk2") != NULL, 1, "a spec other than UUID= or LABEL= is refused");
	is(fstab_spec_refusal("/dev/disk2s1") != NULL, 1, "a device path is refused");
	is(fstab_spec_refusal(NULL) != NULL, 1, "no spec is refused");

	/* bundles */
	for (all = 1, i = 0; i < 6; i++)
		all &= fstab_bundle_refusal(ok_bundles[i]) == NULL;
	is(all, 1, "the six bundles may be written");
	is(fstab_bundle_refusal("linuxfs_hfs") != NULL, 1, "another linuxfs_ name is refused");
	is(fstab_bundle_refusal("hfs") != NULL, 1, "the Mac's own filesystem is refused");
	is(fstab_bundle_refusal("linuxfs_ext4 rw") != NULL, 1, "a bundle with more after it is refused");
	is(fstab_bundle_refusal("../linuxfs_ext4") != NULL, 1, "a bundle with a directory is refused");
	is(fstab_bundle_refusal("") != NULL, 1, "an empty bundle is refused");
	is(fstab_bundle_refusal(NULL) != NULL, 1, "no bundle is refused");
	iss(fstab_bundle_for("ext4"), "linuxfs_ext4", "ext4 is linuxfs_ext4's");
	iss(fstab_bundle_for("ntfs3"), "linuxfs_ntfs", "ntfs3 is linuxfs_ntfs's");
	iss(fstab_bundle_for("apfs"), "linuxfs_apfs", "apfs is linuxfs_apfs's");
	iss(fstab_bundle_for("vfat"), NULL, "vfat is the Mac's");
	iss(fstab_bundle_for("exfat"), NULL, "exfat is the Mac's");
	iss(fstab_bundle_for("ntfs"), NULL, "a name the probe never gives has no bundle");

	/* escapes */
	is(fstab_escape("LABEL=my data", e, sizeof e), 0, "a label escapes");
	iss(e, "LABEL=my\\040data", "its space as \\040");
	is(fstab_escape("LABEL=a\tb c", e, sizeof e), 0, "a label with a tab escapes");
	iss(e, "LABEL=a\\011b\\040c", "its tab as \\011");
	is(fstab_escape("UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", e, sizeof e), 0, "a UUID escapes");
	iss(e, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "as itself");
	is(fstab_escape("LABEL=a#b", e, sizeof e), -1, "a refused spec does not escape");
	is(fstab_escape("LABEL=a b", e, 12), -1, "nor one that does not fit");

	/* edits */
	iss(edit("", "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "linuxfs_ext4", &ch), mine, "an add to an empty fstab writes the one line");
	is(ch, 1, "and changes it");
	iss(edit(mine, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "linuxfs_ext4", &ch), mine, "adding it again keeps the fstab as it is");
	is(ch, 0, "and says nothing changed");
	iss(edit(other, "LABEL=my data", "linuxfs_ntfs", &ch),
	    "# a comment\nUUID=0123ABCD-4567-89EF-0123-456789ABCDEF none hfs rw,noauto\nLABEL=Backup none hfs ro\n"
	    "LABEL=my\\040data none linuxfs_ntfs rw,noauto # linuxfs\n", "an add keeps every other line and appends, the label escaped");
	iss(edit("LABEL=Backup none hfs ro", "LABEL=x", "linuxfs_xfs", &ch), "LABEL=Backup none hfs ro\nLABEL=x none linuxfs_xfs rw,noauto # linuxfs\n",
	    "a last line with no newline gets one before the new line");
	iss(edit(mine, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "linuxfs_btrfs", &ch),
	    "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF none linuxfs_btrfs rw,noauto # linuxfs\n", "adding a spec with another bundle replaces its line");
	is(ch, 1, "and changes it");
	{
		char in[1024];

		snprintf(in, sizeof in, "%s%s", other, mine);
		iss(edit(in, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", NULL, &ch), other, "a remove takes only linuxfs's line, not the other entry for that UUID");
		is(ch, 1, "and changes it");
		iss(edit(other, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", NULL, &ch), other, "removing what is not there keeps the fstab");
		is(ch, 0, "and says nothing changed");
		snprintf(in, sizeof in, "LABEL=my\\040data none linuxfs_ext4 rw,noauto # linuxfs\n%sLABEL=my\\040data2 none linuxfs_ext4 rw,noauto # linuxfs\n", other);
		iss(edit(in, "LABEL=my data", NULL, &ch), "# a comment\nUUID=0123ABCD-4567-89EF-0123-456789ABCDEF none hfs rw,noauto\nLABEL=Backup none hfs ro\n"
		    "LABEL=my\\040data2 none linuxfs_ext4 rw,noauto # linuxfs\n", "a remove by label takes that label's line only, matched escaped");
		snprintf(in, sizeof in, "LABEL=x none hfs rw # linuxfs is not here\n");
		iss(edit(in, "LABEL=x", NULL, &ch), in, "a line that only mentions linuxfs is not linuxfs's");
	}
	iss(edit("", "LABEL=a#b", "linuxfs_ext4", &ch), "(refused)", "an edit with a refused spec is refused");
	iss(edit("", "LABEL=ab", "linuxfs_hfs", &ch), "(refused)", "an edit with a refused bundle is refused");
	memset(big, '#', FSTAB_MAX - 10);
	big[FSTAB_MAX - 11] = '\n';
	big[FSTAB_MAX - 10] = '\0';
	iss(edit(big, "LABEL=ab", "linuxfs_ext4", &ch), "(refused)", "an add that would make the fstab over 64 KiB is refused");
	is(fstab_edit("", 0, "LABEL=ab", "linuxfs_ext4", out, 10, &ch), -1, "so is one that does not fit OUT");

	/* lookups */
	{
		const char *f = "# x\nUUID=0123ABCD-4567-89EF-0123-456789ABCDEF none linuxfs_ext4 rw,noauto # linuxfs\n"
				"LABEL=my\\040data none linuxfs_ntfs rw,noauto # linuxfs\nLABEL=Backup none hfs rw,noauto\n";

		is(fstab_has_noauto(f, strlen(f), "0123ABCD-4567-89EF-0123-456789ABCDEF", NULL), 1, "a volume with linuxfs's UUID entry has one");
		is(fstab_has_noauto(f, strlen(f), "0123abcd-4567-89ef-0123-456789abcdef", "x"), 1, "matched in any case");
		is(fstab_has_noauto(f, strlen(f), NULL, "my data"), 1, "a volume with linuxfs's LABEL entry has one, the escape read");
		is(fstab_has_noauto(f, strlen(f), "", "Backup"), 0, "another program's entry is not linuxfs's");
		is(fstab_has_noauto(f, strlen(f), "FFFFFFFF-4567-89EF-0123-456789ABCDEF", "my"), 0, "another UUID or a label's prefix has none");
		is(fstab_has_noauto(f, (size_t)(strstr(f, "LABEL=my") - f), NULL, "my data"), 0, "only LEN bytes are read");
		is(fstab_has_noauto("", 0, NULL, NULL), 0, "an empty fstab has none");
	}
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}
