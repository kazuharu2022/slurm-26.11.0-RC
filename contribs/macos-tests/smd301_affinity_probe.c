/*****************************************************************************\
 * smd301_affinity_probe.c - observe macOS thread affinity policy in a Slurm job
 *****************************************************************************/

#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/thread_policy.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const char *_env_or_unset(const char *name)
{
	const char *value = getenv(name);

	return value ? value : "UNSET";
}

int main(void)
{
	thread_affinity_policy_data_t policy = { 0 };
	mach_msg_type_number_t count = THREAD_AFFINITY_POLICY_COUNT;
	boolean_t get_default = FALSE;
	kern_return_t kr;
	void *strict_get_symbol;
	void *strict_set_symbol;
	int logical_cpus = 0;
	size_t logical_cpus_size = sizeof(logical_cpus);

	kr = thread_policy_get(mach_thread_self(), THREAD_AFFINITY_POLICY,
			       (thread_policy_t) &policy, &count, &get_default);
	if ((kr != KERN_SUCCESS) && (kr != KERN_NOT_SUPPORTED)) {
		fprintf(stderr, "AFFINITY_PROBE_ERROR thread_policy_get=%d:%s\n",
			kr, mach_error_string(kr));
		return 2;
	}

	strict_get_symbol = dlsym(RTLD_DEFAULT, "sched_getaffinity");
	strict_set_symbol = dlsym(RTLD_DEFAULT, "sched_setaffinity");
	if (strict_get_symbol || strict_set_symbol) {
		fprintf(stderr,
			"AFFINITY_PROBE_ERROR unexpected strict affinity symbol\n");
		return 4;
	}

	if (sysctlbyname("hw.logicalcpu", &logical_cpus, &logical_cpus_size,
			 NULL, 0) != 0) {
		fprintf(stderr, "AFFINITY_PROBE_ERROR sysctlbyname errno=%d\n",
			errno);
		return 3;
	}

	if (kr == KERN_NOT_SUPPORTED) {
		printf("AFFINITY_PROBE pid=%d mach_affinity_get=NOT_SUPPORTED(46) "
		       "affinity_tag=UNOBSERVABLE strict_set_symbol=ABSENT "
		       "strict_get_symbol=ABSENT logical_cpus=%d "
		       "slurm_cpu_bind=%s slurm_cpu_bind_list=%s "
		       "slurm_localid=%s\n",
		       getpid(), logical_cpus, _env_or_unset("SLURM_CPU_BIND"),
		       _env_or_unset("SLURM_CPU_BIND_LIST"),
		       _env_or_unset("SLURM_LOCALID"));
	} else {
		printf("AFFINITY_PROBE pid=%d mach_affinity_get=SUPPORTED "
		       "affinity_tag=%d get_default=%d strict_set_symbol=ABSENT "
		       "strict_get_symbol=ABSENT logical_cpus=%d "
		       "slurm_cpu_bind=%s slurm_cpu_bind_list=%s "
		       "slurm_localid=%s\n",
		       getpid(), policy.affinity_tag, get_default, logical_cpus,
		       _env_or_unset("SLURM_CPU_BIND"),
		       _env_or_unset("SLURM_CPU_BIND_LIST"),
		       _env_or_unset("SLURM_LOCALID"));
	}
	return 0;
}
