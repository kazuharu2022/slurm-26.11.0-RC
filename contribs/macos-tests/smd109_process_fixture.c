#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int _write_record(const char *record_dir, const char *name,
			 pid_t pid, pid_t ppid, pid_t pgid, pid_t sid)
{
	char path[PATH_MAX];
	int fd;

	if (snprintf(path, sizeof(path), "%s/%s", record_dir, name) >=
	    (int) sizeof(path))
		return -1;
	fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (fd < 0)
		return -1;
	if (dprintf(fd, "pid=%ld\nppid=%ld\npgid=%ld\nsid=%ld\n",
		    (long) pid, (long) ppid, (long) pgid, (long) sid) < 0) {
		close(fd);
		return -1;
	}
	if (fsync(fd) < 0) {
		close(fd);
		return -1;
	}
	return close(fd);
}

static int _write_ready(const char *record_dir)
{
	char path[PATH_MAX];
	int fd;

	if (snprintf(path, sizeof(path), "%s/ready", record_dir) >=
	    (int) sizeof(path))
		return -1;
	fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (fd < 0)
		return -1;
	if (dprintf(fd, "ready\n") < 0) {
		close(fd);
		return -1;
	}
	return close(fd);
}

static void _ignore_termination_signals(void)
{
	signal(SIGHUP, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);
}

static void _bounded_pause(unsigned int seconds)
{
	for (unsigned int elapsed = 0; elapsed < seconds; elapsed++)
		sleep(1);
}

int main(int argc, char **argv)
{
	const char *record_dir;
	char *endptr = NULL;
	unsigned long timeout_value;
	unsigned int timeout;
	char escaped_path[PATH_MAX];
	pid_t coordinator, ignorer, zombie, first_child;
	int status;

	if (argc != 3)
		return 90;
	record_dir = argv[1];
	errno = 0;
	timeout_value = strtoul(argv[2], &endptr, 10);
	if (errno || !endptr || *endptr || timeout_value < 30 ||
	    timeout_value > 600)
		return 91;
	timeout = (unsigned int) timeout_value;

	coordinator = getpid();
	if (_write_record(record_dir, "coordinator.txt", coordinator,
			  getppid(), getpgrp(), getsid(0)) < 0)
		return 92;

	ignorer = fork();
	if (ignorer < 0)
		return 93;
	if (ignorer == 0) {
		_ignore_termination_signals();
		if (_write_record(record_dir, "ignorer.txt", getpid(),
				  getppid(), getpgrp(), getsid(0)) < 0)
			_exit(94);
		_bounded_pause(timeout);
		_exit(0);
	}

	zombie = fork();
	if (zombie < 0)
		return 95;
	if (zombie == 0) {
		if (_write_record(record_dir, "zombie.txt", getpid(),
				  getppid(), getpgrp(), getsid(0)) < 0)
			_exit(96);
		_exit(23);
	}

	first_child = fork();
	if (first_child < 0)
		return 97;
	if (first_child == 0) {
		pid_t escaped;
		struct timespec settle = { .tv_sec = 0, .tv_nsec = 500000000L };

		if (setsid() < 0)
			_exit(98);
		escaped = fork();
		if (escaped < 0)
			_exit(99);
		if (escaped > 0)
			_exit(0);
		_ignore_termination_signals();
		nanosleep(&settle, NULL);
		if (_write_record(record_dir, "escaped.txt", getpid(),
				  getppid(), getpgrp(), getsid(0)) < 0)
			_exit(100);
		_bounded_pause(timeout);
		_exit(0);
	}
	if (waitpid(first_child, &status, 0) != first_child)
		return 101;
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		return 102;

	if (snprintf(escaped_path, sizeof(escaped_path), "%s/escaped.txt",
		     record_dir) >= (int) sizeof(escaped_path))
		return 103;
	for (int attempt = 0; attempt < 50; attempt++) {
		if (access(escaped_path, R_OK) == 0)
			break;
		if (attempt == 49)
			return 104;
		struct timespec poll = { .tv_sec = 0, .tv_nsec = 100000000L };
		nanosleep(&poll, NULL);
	}
	if (_write_ready(record_dir) < 0)
		return 105;

	_bounded_pause(timeout);
	return 0;
}
