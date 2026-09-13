#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;

struct limit_entry {
	const char *name;
	int resource;
};

static void print_value(rlim_t value)
{
	if (value == RLIM_INFINITY)
		(void) printf("infinity");
	else
		(void) printf("%llu", (unsigned long long) value);
}

int main(int argc, char **argv)
{
	static const struct limit_entry limits[] = {
		{ "CPU", RLIMIT_CPU },
		{ "CORE", RLIMIT_CORE },
		{ "STACK", RLIMIT_STACK },
		{ "NOFILE", RLIMIT_NOFILE },
	};
	const char *job_id;
	const char *step_id;
	size_t env_count = 0;
	size_t i;
	char **entry;

	if (argc != 2) {
		(void) fprintf(stderr, "usage: %s ROLE\n", argv[0]);
		return 90;
	}

	job_id = getenv("SLURM_JOB_ID");
	step_id = getenv("SLURM_STEP_ID");
	(void) printf("smd110_schema=1\n");
	(void) printf("role=%s\n", argv[1]);
	(void) printf("job_id=%s\n", job_id ? job_id : "none");
	(void) printf("step_id=%s\n", step_id ? step_id : "none");
	(void) printf("uid=%lu\n", (unsigned long) getuid());
	(void) printf("gid=%lu\n", (unsigned long) getgid());

	for (i = 0; i < sizeof(limits) / sizeof(limits[0]); i++) {
		struct rlimit value;

		if (getrlimit(limits[i].resource, &value) != 0) {
			(void) fprintf(stderr, "getrlimit(%s): %s\n",
				limits[i].name, strerror(errno));
			return 91;
		}
		(void) printf("limit=%s soft=", limits[i].name);
		print_value(value.rlim_cur);
		(void) printf(" hard=");
		print_value(value.rlim_max);
		(void) printf("\n");
	}

	for (entry = environ; entry && *entry; entry++) {
		if (strncmp(*entry, "SLURM_RLIMIT_", 13) == 0)
			env_count++;
	}
	(void) printf("slurm_rlimit_env_count=%lu\n", (unsigned long) env_count);
	(void) printf("SMD110_PROBE_PASS role=%s\n", argv[1]);
	return 0;
}
