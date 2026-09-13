#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <slurm/pmi2.h>

int main(int argc, char **argv)
{
	char path[PATH_MAX];
	char temporary_path[PATH_MAX];
	const char *job_id;
	FILE *record;
	int appnum;
	int rank;
	int rc;
	int size;
	int spawned;

	if (argc != 2)
		return 90;

	rc = PMI2_Init(&spawned, &size, &rank, &appnum);
	if (rc != PMI2_SUCCESS)
		return 91;
	if (PMI2_KVS_Fence() != PMI2_SUCCESS)
		return 92;

	job_id = getenv("SLURM_JOB_ID");
	if (!job_id)
		return 93;
	if (snprintf(path, sizeof(path), "%s/ready.%d", argv[1], rank) >=
	    (int) sizeof(path))
		return 94;
	if (snprintf(temporary_path, sizeof(temporary_path),
	    "%s/pending.%d.%d", argv[1], rank, getpid()) >=
	    (int) sizeof(temporary_path))
		return 95;
	record = fopen(temporary_path, "wx");
	if (!record)
		return 96;
	fprintf(record, "job_id=%s\n", job_id);
	fprintf(record, "rank=%d\n", rank);
	fprintf(record, "size=%d\n", size);
	fprintf(record, "spawned=%d\n", spawned);
	fprintf(record, "pid=%d\n", getpid());
	fprintf(record, "uid=%d\n", getuid());
	fprintf(record, "gid=%d\n", getgid());
	if (fclose(record) != 0)
		return 97;
	if (rename(temporary_path, path) != 0)
		return 98;

	sleep(120);
	if (PMI2_Finalize() != PMI2_SUCCESS)
		return 99;
	return 0;
}
