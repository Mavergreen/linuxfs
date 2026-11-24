/*
 * DYLD_INSERT_LIBRARIES test aid: says on stderr, once per call, every sigprocmask() that leaves SIGTERM blocked
 * (SIG_BLOCK or SIG_SETMASK with SIGTERM in the set). Darwin's longjmp is one: it restores the mask its setjmp saved.
 */
#include <signal.h>
#include <string.h>
#include <unistd.h>

static int probe_sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
	if (set && (how == SIG_BLOCK || how == SIG_SETMASK) && sigismember(set, SIGTERM))
		write(2, "SIGTERM-BLOCKED sigprocmask\n", 28);
	return sigprocmask(how, set, old);
}

__attribute__((used)) static const struct { const void *replacement, *replacee; } interpose[]
	__attribute__((section("__DATA,__interpose"))) = {{(const void *)probe_sigprocmask, (const void *)sigprocmask}};
