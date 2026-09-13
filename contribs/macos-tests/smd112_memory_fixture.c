#define _DARWIN_C_SOURCE

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MIB_BYTES (1024ULL * 1024ULL)
#define MAX_SAFE_MIB 1024ULL

static int parse_uint(const char *text, unsigned long long *value)
{
	char *end = NULL;
	unsigned long long parsed;

	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno != 0 || !end || *end != '\0')
		return -1;
	*value = parsed;
	return 0;
}

static int make_path(char *path, size_t size, const char *record_dir,
			const char *kind, unsigned long long stage_mib)
{
	int length;

	if (stage_mib > 0)
		length = snprintf(path, size, "%s/%s-%04llu", record_dir,
				kind, stage_mib);
	else
		length = snprintf(path, size, "%s/%s", record_dir, kind);
	return length < 0 || (size_t) length >= size ? -1 : 0;
}

static int write_stage(const char *record_dir,
			unsigned long long stage_mib)
{
	char path[PATH_MAX];
	char temp[PATH_MAX];
	FILE *stream;
	int length;

	if (make_path(path, sizeof(path), record_dir, "stage", stage_mib) != 0)
		return -1;
	length = snprintf(temp, sizeof(temp), "%s.tmp.%ld", path,
			(long) getpid());
	if (length < 0 || (size_t) length >= sizeof(temp))
		return -1;
	stream = fopen(temp, "w");
	if (!stream)
		return -1;
	if (fprintf(stream, "pid=%ld\nallocated_mib=%llu\n", (long) getpid(),
			stage_mib) < 0 || fflush(stream) != 0 || fclose(stream) != 0) {
		(void) unlink(temp);
		return -1;
	}
	if (rename(temp, path) != 0) {
		(void) unlink(temp);
		return -1;
	}
	return 0;
}

static int wait_for_marker(const char *record_dir, const char *kind,
			unsigned long long stage_mib, unsigned long long timeout)
{
	struct timespec delay = { .tv_sec = 0, .tv_nsec = 100000000L };
	char path[PATH_MAX];
	unsigned long long attempt;

	if (make_path(path, sizeof(path), record_dir, kind, stage_mib) != 0)
		return -1;
	for (attempt = 0; attempt < timeout * 10ULL; attempt++) {
		if (access(path, F_OK) == 0)
			return 0;
		if (errno != ENOENT)
			return -1;
		(void) nanosleep(&delay, NULL);
	}
	errno = ETIMEDOUT;
	return -1;
}

int main(int argc, char **argv)
{
	unsigned long long max_mib;
	unsigned long long stage_mib;
	unsigned long long timeout;
	unsigned long long current_mib;
	size_t allocation_size;
	size_t page_size;
	volatile unsigned char *memory;

	if (argc != 5 || parse_uint(argv[2], &max_mib) != 0 ||
	    parse_uint(argv[3], &stage_mib) != 0 ||
	    parse_uint(argv[4], &timeout) != 0) {
		(void) fprintf(stderr,
			"usage: %s RECORD_DIR MAX_MIB STAGE_MIB TIMEOUT_SECONDS\n",
			argv[0]);
		return 90;
	}
	if (max_mib == 0 || max_mib > MAX_SAFE_MIB || stage_mib == 0 ||
	    max_mib % stage_mib != 0 || timeout == 0 || timeout > 180) {
		(void) fprintf(stderr, "unsafe or invalid allocation parameters\n");
		return 91;
	}
	if (max_mib > (unsigned long long) SIZE_MAX / MIB_BYTES) {
		(void) fprintf(stderr, "allocation size overflow\n");
		return 92;
	}
	page_size = (size_t) sysconf(_SC_PAGESIZE);
	if (page_size == 0 || page_size == (size_t) -1) {
		(void) fprintf(stderr, "sysconf(_SC_PAGESIZE): %s\n",
			strerror(errno));
		return 93;
	}
	allocation_size = (size_t) (max_mib * MIB_BYTES);
	memory = mmap(NULL, allocation_size, PROT_READ | PROT_WRITE,
			MAP_ANON | MAP_PRIVATE, -1, 0);
	if (memory == MAP_FAILED) {
		(void) fprintf(stderr, "mmap(%llu MiB): %s\n", max_mib,
			strerror(errno));
		return 94;
	}

	(void) printf("fixture_pid=%ld\n", (long) getpid());
	(void) printf("page_size=%lu\n", (unsigned long) page_size);
	(void) printf("max_mib=%llu\n", max_mib);
	(void) fflush(stdout);

	for (current_mib = stage_mib; current_mib <= max_mib;
	     current_mib += stage_mib) {
		size_t begin = (size_t) ((current_mib - stage_mib) * MIB_BYTES);
		size_t end = (size_t) (current_mib * MIB_BYTES);
		size_t offset;

		for (offset = begin; offset < end; offset += page_size)
			memory[offset] = (unsigned char) ((offset / page_size) % 251U + 1U);
		memory[end - 1] = (unsigned char) (current_mib % 251U + 1U);
		if (write_stage(argv[1], current_mib) != 0) {
			(void) fprintf(stderr, "write stage %llu: %s\n", current_mib,
				strerror(errno));
			(void) munmap((void *) memory, allocation_size);
			return 95;
		}
		(void) printf("stage_mib=%llu status=TOUCHED\n", current_mib);
		(void) fflush(stdout);
		if (current_mib < max_mib &&
		    wait_for_marker(argv[1], "ack", current_mib, timeout) != 0) {
			(void) fprintf(stderr, "wait ack %llu: %s\n", current_mib,
				strerror(errno));
			(void) munmap((void *) memory, allocation_size);
			return 96;
		}
	}
	if (wait_for_marker(argv[1], "release", 0, timeout) != 0) {
		(void) fprintf(stderr, "wait release: %s\n", strerror(errno));
		(void) munmap((void *) memory, allocation_size);
		return 97;
	}
	if (munmap((void *) memory, allocation_size) != 0) {
		(void) fprintf(stderr, "munmap: %s\n", strerror(errno));
		return 98;
	}
	(void) printf("SMD112_ALLOCATOR_PASS max_mib=%llu\n", max_mib);
	return 0;
}
