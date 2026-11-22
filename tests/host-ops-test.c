/* platform: host-agnostic */
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <lkl_host.h>

#define H lkl_host_ops

static int failures, tapno;

static void tap(int ok, const char *what)
{
	printf("%s %d - %s\n", ok ? "ok" : "not ok", ++tapno, what);
	fflush(stdout);
	if (!ok)
		failures++;
}

static void sem_basic(void)
{
	struct lkl_sem *s = H.sem_alloc(0);
	H.sem_up(s);
	H.sem_down(s);
	H.sem_free(s);
	tap(s != NULL, "sem_basic: up then down returns");
}

#define SEM_THREADS 16
#define SEM_ROUNDS 100000
static struct lkl_sem *contended;
static struct lkl_mutex *counter_lock;
static long counter;

static void contend(void *arg)
{
	(void)arg;
	for (int i = 0; i < SEM_ROUNDS; i++) {
		H.sem_down(contended);
		H.mutex_lock(counter_lock);
		counter++;
		H.mutex_unlock(counter_lock);
		H.sem_up(contended);
	}
}

static void sem_contention(void)
{
	lkl_thread_t t[SEM_THREADS];
	unsigned long long start = H.time();
	contended = H.sem_alloc(1);
	counter_lock = H.mutex_alloc(0);
	for (int i = 0; i < SEM_THREADS; i++)
		t[i] = H.thread_create(contend, NULL);
	for (int i = 0; i < SEM_THREADS; i++)
		H.thread_join(t[i]);
	H.sem_down(contended);
	int ok = counter == (long)SEM_THREADS * SEM_ROUNDS && H.time() - start < 30ULL * 1000000000ULL;
	H.sem_up(contended);
	H.sem_free(contended);
	H.mutex_free(counter_lock);
	tap(ok, "sem_contention: 16 threads x 100000 down/up, no lost wakeups, under 30 s");
}

static void mutex_recursive(void)
{
	struct lkl_mutex *m = H.mutex_alloc(1);
	H.mutex_lock(m);
	H.mutex_lock(m);
	H.mutex_unlock(m);
	H.mutex_unlock(m);
	H.mutex_free(m);
	tap(m != NULL, "mutex_recursive: lock twice, unlock twice");
}

static int joined_flag;
static void set_flag(void *arg) { *(int *)arg = 42; }

static void thread_create_join(void)
{
	lkl_thread_t t = H.thread_create(set_flag, &joined_flag);
	int r = t ? H.thread_join(t) : -1;
	tap(r == 0 && joined_flag == 42, "thread_create_join");
}

__attribute__((noinline)) static int recurse(int depth)
{
	volatile char pad[1024];
	int below;

	pad[depth % 1024] = (char)depth;
	below = depth ? recurse(depth - 1) : 0;
	return below + pad[depth % 1024];	/* use pad after the call: no tail call */
}

static int deep_ok;
static unsigned long seen_stack_size;
static void deep(void *arg)
{
	(void)arg;
	H.thread_stack(&seen_stack_size);
	recurse(6 * 1024);
	deep_ok = 1;
}

static void thread_stack_size(void)
{
	lkl_thread_t t = H.thread_create(deep, NULL);
	if (t)
		H.thread_join(t);
	tap(deep_ok, "thread_stack_size: 6 MiB of recursion in an LKL thread");
	tap(seen_stack_size >= 8UL * 1024 * 1024, "thread_stack reports at least 8 MiB");
}

static void stack_of_main(void)
{
	unsigned long size = 0;
	char here;
	char *base = H.thread_stack(&size);
	tap(base && size && &here >= base && &here < base + size,
	    "thread_stack: returned range contains a local of the calling thread");
}

static volatile int fired;
static volatile unsigned long long fired_at;
static void on_fire(void) { fired_at = H.time(); fired++; }

static void timer_oneshot(void)
{
	void *t = H.timer_alloc(on_fire);
	unsigned long long start = H.time();
	H.timer_set_oneshot(t, 20 * 1000000ULL);
	usleep(200 * 1000);
	unsigned long long late = fired_at - start;
	tap(fired == 1, "timer_oneshot: fires exactly once");
	tap(late >= 20 * 1000000ULL && late < 70 * 1000000ULL, "timer_oneshot: fires within 50 ms of 20 ms");
	H.timer_free(t);
}

static void *rearm_timer;
static volatile int rearms;
static void rearm(void)
{
	if (++rearms < 10000)
		H.timer_set_oneshot(rearm_timer, 1000);
}

static void timer_rearm_during_fire(void)
{
	rearm_timer = H.timer_alloc(rearm);
	H.timer_set_oneshot(rearm_timer, 1000);
	for (int i = 0; i < 300 && rearms < 10000; i++)
		usleep(100 * 1000);
	tap(rearms == 10000, "timer_rearm_during_fire: callback re-arms itself 10000 times");
	H.timer_free(rearm_timer);
}

static volatile int late_fires;
static void count_late(void) { late_fires++; }

static void timer_free_while_armed(void)
{
	void *t = H.timer_alloc(count_late);
	H.timer_set_oneshot(t, 50 * 1000000ULL);
	H.timer_free(t);
	usleep(200 * 1000);
	tap(late_fires == 0, "timer_free_while_armed: callback never runs after free");
}

static volatile int slow_started, slow_finished;
static void slow_callback(void)
{
	slow_started = 1;
	usleep(100 * 1000);
	slow_finished = 1;
}

static void timer_free_waits_for_running_callback(void)
{
	void *t = H.timer_alloc(slow_callback);
	H.timer_set_oneshot(t, 1000);
	for (int i = 0; i < 1000 && !slow_started; i++)
		usleep(1000);
	H.timer_free(t);
	tap(slow_started && slow_finished, "timer_free_while_firing: returns only after the running callback finishes");
}

static void *self_timer;
static volatile int self_freed;
static void free_self(void)
{
	H.timer_free(self_timer);	/* must not wait for itself */
	self_freed = 1;
}

static void timer_free_from_own_callback(void)
{
	self_timer = H.timer_alloc(free_self);
	H.timer_set_oneshot(self_timer, 1000);
	for (int i = 0; i < 1000 && !self_freed; i++)
		usleep(1000);
	tap(self_freed, "timer_free_from_own_callback: returns without deadlock");
}

static void *slow_timer;
static volatile int slow_fires, slow_running;
static void slow_count(void)
{
	slow_running = 1;
	usleep(50 * 1000);
	slow_fires++;
	slow_running = 0;
}

static void timer_rearm_from_other_thread_while_firing(void)
{
	slow_timer = H.timer_alloc(slow_count);
	H.timer_set_oneshot(slow_timer, 1000);
	for (int i = 0; i < 1000 && !slow_running; i++)
		usleep(1000);
	H.timer_set_oneshot(slow_timer, 1000000);	/* re-armed while the callback runs */
	usleep(300 * 1000);
	tap(slow_fires == 2, "timer_rearm_from_other_thread_while_firing: fires again after the running callback");
	H.timer_free(slow_timer);
}

static void time_monotonic(void)
{
	unsigned long long prev = H.time();
	int ok = prev > 0;
	for (int i = 0; ok && i < 1000000; i++) {
		unsigned long long now = H.time();
		ok = now >= prev;
		prev = now;
	}
	tap(ok, "time_monotonic: non-decreasing over 1e6 reads");
}

static void watchdog(int sig)
{
	static const char msg[] = "Bail out! watchdog: a case hung for 120 s\n";
	(void)sig;
	write(STDOUT_FILENO, msg, sizeof(msg) - 1);
	_exit(1);
}

int main(void)
{
	signal(SIGALRM, watchdog);
	alarm(120);	/* a lost wakeup or a deadlock fails the run instead of hanging it */
	sem_basic();
	sem_contention();
	mutex_recursive();
	thread_create_join();
	thread_stack_size();
	stack_of_main();
	timer_oneshot();
	timer_rearm_during_fire();
	timer_free_while_armed();
	timer_free_waits_for_running_callback();
	timer_free_from_own_callback();
	timer_rearm_from_other_thread_while_firing();
	time_monotonic();
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}

