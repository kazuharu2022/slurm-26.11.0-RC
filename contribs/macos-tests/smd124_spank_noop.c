#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#include <slurm/spank.h>

SPANK_PLUGIN(smd124_noop, 1);

static const char *_context_name(void)
{
	switch (spank_context()) {
	case S_CTX_LOCAL:
		return "local";
	case S_CTX_REMOTE:
		return "remote";
	case S_CTX_ALLOCATOR:
		return "allocator";
	case S_CTX_SLURMD:
		return "slurmd";
	case S_CTX_JOB_SCRIPT:
		return "job_script";
	case S_CTX_ERROR:
	default:
		return "error";
	}
}

static int _record(spank_t sp, int ac, char **av, const char *callback,
		   int task_item_valid)
{
	uint32_t job_id = 0;
	int task_id = -1;
	int fd;

	if ((ac != 1) || !av || !av[0] || !av[0][0])
		return ESPANK_ERROR;

	(void) spank_get_item(sp, S_JOB_ID, &job_id);
	if (task_item_valid)
		(void) spank_get_item(sp, S_TASK_ID, &task_id);

	fd = open(av[0], O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd < 0)
		return ESPANK_ERROR;

	if (dprintf(fd,
		    "callback=%s context=%s job_id=%u task_id=%d euid=%u egid=%u pid=%u\n",
		    callback, _context_name(), job_id, task_id,
		    (unsigned int) geteuid(), (unsigned int) getegid(),
		    (unsigned int) getpid()) < 0) {
		(void) close(fd);
		return ESPANK_ERROR;
	}

	if (close(fd) < 0)
		return ESPANK_ERROR;
	return ESPANK_SUCCESS;
}

#define RECORD_CALLBACK(name, task_valid) \
	int name(spank_t sp, int ac, char **av) \
	{ \
		return _record(sp, ac, av, #name, task_valid); \
	}

RECORD_CALLBACK(slurm_spank_init, 0)
RECORD_CALLBACK(slurm_spank_job_prolog, 0)
RECORD_CALLBACK(slurm_spank_init_post_opt, 0)
RECORD_CALLBACK(slurm_spank_local_user_init, 0)
RECORD_CALLBACK(slurm_spank_user_init, 0)
RECORD_CALLBACK(slurm_spank_task_init_privileged, 1)
RECORD_CALLBACK(slurm_spank_task_init, 1)
RECORD_CALLBACK(slurm_spank_task_post_fork, 1)
RECORD_CALLBACK(slurm_spank_task_exit, 1)
RECORD_CALLBACK(slurm_spank_job_epilog, 0)
RECORD_CALLBACK(slurm_spank_exit, 0)
