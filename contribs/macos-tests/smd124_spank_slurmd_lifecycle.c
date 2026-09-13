#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#include <slurm/spank.h>

SPANK_PLUGIN(smd124_slurmd_lifecycle, 1);

static int _record(int ac, char **av, const char *callback)
{
	int fd;

	if (spank_context() != S_CTX_SLURMD)
		return ESPANK_SUCCESS;
	if ((ac != 1) || !av || !av[0] || !av[0][0])
		return ESPANK_ERROR;

	fd = open(av[0], O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd < 0)
		return ESPANK_ERROR;

	if (dprintf(fd, "callback=%s context=slurmd euid=%u egid=%u pid=%u\n",
		    callback, (unsigned int) geteuid(), (unsigned int) getegid(),
		    (unsigned int) getpid()) < 0) {
		(void) close(fd);
		return ESPANK_ERROR;
	}
	if (close(fd) < 0)
		return ESPANK_ERROR;
	return ESPANK_SUCCESS;
}

int slurm_spank_init(spank_t sp, int ac, char **av)
{
	(void) sp;
	return _record(ac, av, "slurm_spank_init");
}

int slurm_spank_slurmd_exit(spank_t sp, int ac, char **av)
{
	(void) sp;
	return _record(ac, av, "slurm_spank_slurmd_exit");
}
