#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int wait_child(pid_t pid, const char *label)
{
	int status = 0;

	if (waitpid(pid, &status, 0) != pid) {
		perror("waitpid");
		return 1;
	}
	if (WIFEXITED(status)) {
		printf("%s_exit=%d\n", label, WEXITSTATUS(status));
		return WEXITSTATUS(status);
	}
	if (WIFSIGNALED(status)) {
		printf("%s_signal=%d\n", label, WTERMSIG(status));
		return 128 + WTERMSIG(status);
	}
	printf("%s_status=unexpected\n", label);
	return 1;
}

int main(void)
{
	const char script[] = "#!/bin/sh\nprintf 'SMD407_DEV_FD_SCRIPT_PASS\\n'\n";
	char template[] = "/tmp/slurm-smd407-dev-fd-XXXXXX";
	char path[64];
	struct stat fd_stat = {0};
	struct stat path_stat = {0};
	pid_t pid;
	ssize_t written;
	int fd;
	int path_len;
	int access_rc;
	int access_errno;
	int direct_rc;
	int shell_rc;
	int shell_closed_fd_rc;
	int shell_c_rc;

	if ((fd = mkstemp(template)) < 0) {
		perror("mkstemp");
		return 1;
	}
	if (unlink(template) < 0) {
		perror("unlink");
		return 1;
	}
	written = write(fd, script, sizeof(script) - 1);
	if (written < 0 || (size_t) written != sizeof(script) - 1) {
		perror("write");
		return 1;
	}
	if (fchmod(fd, S_IRUSR | S_IXUSR) < 0) {
		perror("fchmod");
		return 1;
	}
	if (lseek(fd, 0, SEEK_SET) < 0) {
		perror("lseek");
		return 1;
	}
	path_len = snprintf(path, sizeof(path), "/dev/fd/%d", fd);
	if (path_len < 0 || (size_t) path_len >= sizeof(path)) {
		fprintf(stderr, "path truncated\n");
		return 1;
	}
	if (fstat(fd, &fd_stat) < 0) {
		perror("fstat");
		return 1;
	}
	if (stat(path, &path_stat) < 0) {
		perror("stat");
		return 1;
	}
	errno = 0;
	access_rc = access(path, R_OK | X_OK);
	access_errno = errno;
	printf("path=%s fd_mode=%04o path_mode=%04o access_rx_rc=%d access_rx_errno=%d access_rx_error=%s\n",
	       path, fd_stat.st_mode & 07777, path_stat.st_mode & 07777,
	       access_rc, access_errno, strerror(access_errno));

	if ((pid = fork()) < 0) {
		perror("fork direct");
		return 1;
	} else if (pid == 0) {
		execl(path, path, (char *) NULL);
		fprintf(stderr, "direct_exec_errno=%d direct_exec_error=%s\n",
			errno, strerror(errno));
		_exit(127);
	}
	direct_rc = wait_child(pid, "direct");

	if (lseek(fd, 0, SEEK_SET) < 0) {
		perror("lseek before shell");
		return 1;
	}
	if ((pid = fork()) < 0) {
		perror("fork shell");
		return 1;
	} else if (pid == 0) {
		execl("/bin/sh", "sh", path, (char *) NULL);
		fprintf(stderr, "shell_exec_errno=%d shell_exec_error=%s\n",
			errno, strerror(errno));
		_exit(127);
	}
	shell_rc = wait_child(pid, "shell");

	if ((pid = fork()) < 0) {
		perror("fork shell closed fd");
		return 1;
	} else if (pid == 0) {
		close(fd);
		execl("/bin/sh", "sh", path, (char *) NULL);
		fprintf(stderr, "shell_closed_fd_exec_errno=%d shell_closed_fd_exec_error=%s\n",
			errno, strerror(errno));
		_exit(127);
	}
	shell_closed_fd_rc = wait_child(pid, "shell_closed_fd");

	if ((pid = fork()) < 0) {
		perror("fork shell -c");
		return 1;
	} else if (pid == 0) {
		close(fd);
		execl("/bin/sh", "sh", "-c", script, "smd407-probe",
		      (char *) NULL);
		fprintf(stderr, "shell_c_exec_errno=%d shell_c_exec_error=%s\n",
			errno, strerror(errno));
		_exit(127);
	}
	shell_c_rc = wait_child(pid, "shell_c");

	close(fd);
	return (access_rc < 0 && direct_rc == 127 && shell_rc == 0 &&
		shell_closed_fd_rc != 0 && shell_c_rc == 0) ? 0 : 1;
}
