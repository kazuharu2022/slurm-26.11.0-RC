#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MEMORY_BYTES (128ULL * 1024ULL * 1024ULL)
#define IO_BYTES (32ULL * 1024ULL * 1024ULL)
#define IO_CHUNK (1024ULL * 1024ULL)
#define CPU_TARGET_NS (2ULL * 1000ULL * 1000ULL * 1000ULL)

static uint64_t timespec_ns(const struct timespec *ts)
{
	return ((uint64_t) ts->tv_sec * 1000000000ULL) +
	       (uint64_t) ts->tv_nsec;
}

static uint64_t timeval_us(const struct timeval *tv)
{
	return ((uint64_t) tv->tv_sec * 1000000ULL) +
	       (uint64_t) tv->tv_usec;
}

static int write_full(int fd, const void *buffer, size_t length)
{
	const unsigned char *cursor = buffer;

	while (length > 0) {
		ssize_t written = write(fd, cursor, length);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += written;
		length -= (size_t) written;
	}
	return 0;
}

static int read_full(int fd, void *buffer, size_t length)
{
	unsigned char *cursor = buffer;

	while (length > 0) {
		ssize_t got = read(fd, cursor, length);

		if (got < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (got == 0)
			return -1;
		cursor += got;
		length -= (size_t) got;
	}
	return 0;
}

int main(int argc, char **argv)
{
	volatile unsigned char *memory;
	unsigned char *io_buffer;
	struct timespec cpu_start, cpu_now, hold_time;
	struct rusage usage;
	long page_size;
	uint64_t offset;
	uint64_t checksum = 0;
	uint64_t user_us;
	uint64_t system_us;
	unsigned int hold_seconds;
	FILE *marker;
	int fd;

	if (argc != 4) {
		fprintf(stderr, "usage: %s MARKER IO_FILE HOLD_SECONDS\n", argv[0]);
		return 64;
	}
	if (sscanf(argv[3], "%u", &hold_seconds) != 1 || hold_seconds > 60) {
		fprintf(stderr, "invalid hold seconds: %s\n", argv[3]);
		return 64;
	}

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) {
		perror("sysconf(_SC_PAGESIZE)");
		return 1;
	}
	memory = malloc((size_t) MEMORY_BYTES);
	io_buffer = malloc((size_t) IO_CHUNK);
	if (!memory || !io_buffer) {
		perror("malloc");
		free((void *) memory);
		free(io_buffer);
		return 1;
	}

	for (offset = 0; offset < MEMORY_BYTES; offset += (uint64_t) page_size)
		memory[offset] = (unsigned char) ((offset / (uint64_t) page_size) & 0xffU);
	memset(io_buffer, 0x5a, (size_t) IO_CHUNK);

	fd = open(argv[2], O_CREAT | O_TRUNC | O_RDWR, 0600);
	if (fd < 0) {
		perror("open io file");
		return 1;
	}
	for (offset = 0; offset < IO_BYTES; offset += IO_CHUNK) {
		if (write_full(fd, io_buffer, (size_t) IO_CHUNK) != 0) {
			perror("write io file");
			close(fd);
			return 1;
		}
	}
	if (fsync(fd) != 0 || lseek(fd, 0, SEEK_SET) < 0) {
		perror("fsync/lseek io file");
		close(fd);
		return 1;
	}
	for (offset = 0; offset < IO_BYTES; offset += IO_CHUNK) {
		if (read_full(fd, io_buffer, (size_t) IO_CHUNK) != 0) {
			perror("read io file");
			close(fd);
			return 1;
		}
		checksum += io_buffer[offset % IO_CHUNK];
	}
	if (close(fd) != 0) {
		perror("close io file");
		return 1;
	}

	if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_start) != 0) {
		perror("clock_gettime start");
		return 1;
	}
	do {
		uint64_t i;

		for (i = 1; i <= 1000000ULL; i++)
			checksum = (checksum * 2862933555777941757ULL) + i;
		if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_now) != 0) {
			perror("clock_gettime current");
			return 1;
		}
	} while ((timespec_ns(&cpu_now) - timespec_ns(&cpu_start)) < CPU_TARGET_NS);

	if (getrusage(RUSAGE_SELF, &usage) != 0) {
		perror("getrusage");
		return 1;
	}
	user_us = timeval_us(&usage.ru_utime);
	system_us = timeval_us(&usage.ru_stime);

	marker = fopen(argv[1], "w");
	if (!marker) {
		perror("fopen marker");
		return 1;
	}
	fprintf(marker,
		"SMD304_SELF pid=%ld memory_bytes=%" PRIu64
		" write_bytes=%" PRIu64 " read_bytes=%" PRIu64
		" user_us=%" PRIu64 " system_us=%" PRIu64
		" maxrss_raw=%ld page_size=%ld checksum=%" PRIu64 "\n",
		(long) getpid(), MEMORY_BYTES, IO_BYTES, IO_BYTES, user_us,
		system_us, usage.ru_maxrss, page_size, checksum);
	if (fclose(marker) != 0) {
		perror("fclose marker");
		return 1;
	}
	printf(
		"SMD304_SELF pid=%ld memory_bytes=%" PRIu64
		" write_bytes=%" PRIu64 " read_bytes=%" PRIu64
		" user_us=%" PRIu64 " system_us=%" PRIu64
		" maxrss_raw=%ld page_size=%ld checksum=%" PRIu64 "\n",
		(long) getpid(), MEMORY_BYTES, IO_BYTES, IO_BYTES, user_us,
		system_us, usage.ru_maxrss, page_size, checksum);
	fflush(stdout);

	hold_time.tv_sec = (time_t) hold_seconds;
	hold_time.tv_nsec = 0;
	while (nanosleep(&hold_time, &hold_time) != 0 && errno == EINTR)
		;

	if (unlink(argv[2]) != 0) {
		perror("unlink io file");
		return 1;
	}
	printf("SMD304_DONE pid=%ld\n", (long) getpid());
	free((void *) memory);
	free(io_buffer);
	return 0;
}
