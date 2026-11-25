/*
 * platform: macOS-only -- built with tools/volicon.c itself included (CoreGraphics and ImageIO)
 * usage: volicon-reps
 *        linuxfs-volicon's same_reps: the composite's representations are BASE's exactly, as a set matched one to one in
 *        both directions, so a duplicate in one cannot stand in for a missing one. Prints "ok - ..." or "not ok - ..."
 *        lines (tests/volicon-test.sh numbers them); exits 1 on any "not ok".
 */
#define main volicon_main
#include "../tools/volicon.c"
#undef main

static int bad;

static void is(int got, int want, const char *what)
{
	printf("%s - same_reps: %s\n", got == want ? "ok" : "not ok", what);
	bad |= got != want;
}

int main(void)
{
	struct rep a = { 32, 32, 72 }, b = { 32, 32, 144 }, c = { 16, 16, 72 };
	struct rep ab[2] = { a, b }, ba[2] = { b, a }, aa[2] = { a, a }, abc[3] = { a, b, c };

	is(same_reps(ab, 2, ba, 2), 1, "the same set in another order matches");
	is(same_reps(ab, 2, aa, 2), 0, "a duplicate in the output does not stand in for a missing representation");
	is(same_reps(aa, 2, ab, 2), 0, "nor a duplicate in the base for one the output has extra");
	is(same_reps(aa, 2, aa, 2), 1, "the same duplicates on both sides match");
	is(same_reps(ab, 2, abc, 3), 0, "an extra representation does not match");
	is(same_reps(ab, 2, ab, 1), 0, "a missing one does not match");
	return bad;
}
