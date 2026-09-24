#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mpi.h>

#define SMD401_BCAST_VALUE 42
#define SMD401_RING_BASE 1000

struct communication_result {
	int bcast_value;
	int allreduce_sum;
	int ring_source;
	int ring_value;
};

static void mpi_fail(const char *stage, int rc)
{
	char message[MPI_MAX_ERROR_STRING];
	int length = 0;

	if (MPI_SUCCESS != MPI_Error_string(rc, message, &length)) {
		(void) snprintf(message, sizeof(message), "unknown MPI error");
		length = (int) strlen(message);
	}
	fprintf(stderr, "mpi_error stage=%s rc=%d message=%.*s\n", stage, rc,
	    length, message);
	(void) MPI_Abort(MPI_COMM_WORLD, rc);
	exit(1);
}

static void mpi_check(const char *stage, int rc)
{
	if (MPI_SUCCESS != rc)
		mpi_fail(stage, rc);
}

static void exercise_communication(int rank, int size,
	struct communication_result *result)
{
	int send_value = SMD401_RING_BASE + rank;
	int destination = (rank + 1) % size;

	result->bcast_value = (0 == rank) ? SMD401_BCAST_VALUE : 0;
	mpi_check("MPI_Bcast", MPI_Bcast(&result->bcast_value, 1, MPI_INT, 0,
	    MPI_COMM_WORLD));
	mpi_check("MPI_Allreduce", MPI_Allreduce(&rank, &result->allreduce_sum, 1,
	    MPI_INT, MPI_SUM, MPI_COMM_WORLD));
	result->ring_source = (rank + size - 1) % size;
	mpi_check("MPI_Sendrecv", MPI_Sendrecv(&send_value, 1, MPI_INT,
	    destination, 401, &result->ring_value, 1, MPI_INT,
	    result->ring_source, 401, MPI_COMM_WORLD, MPI_STATUS_IGNORE));
	mpi_check("MPI_Barrier", MPI_Barrier(MPI_COMM_WORLD));
}

static int validate_communication(int size,
	const struct communication_result *result)
{
	int expected_sum = size * (size - 1) / 2;
	int expected_ring = SMD401_RING_BASE + result->ring_source;

	if (SMD401_BCAST_VALUE != result->bcast_value ||
	    expected_sum != result->allreduce_sum ||
	    expected_ring != result->ring_value) {
		fprintf(stderr,
		    "mpi_error stage=value_check bcast=%d sum=%d ring=%d\n",
		    result->bcast_value, result->allreduce_sum,
		    result->ring_value);
		return 1;
	}
	return 0;
}

static int write_ready_record(const char *directory, const char *job_id,
	int rank, int size, const char *processor,
	const struct communication_result *result)
{
	char path[PATH_MAX];
	char temporary_path[PATH_MAX];
	FILE *record;

	if (snprintf(path, sizeof(path), "%s/ready.%d", directory, rank) >=
	    (int) sizeof(path))
		return 1;
	if (snprintf(temporary_path, sizeof(temporary_path),
	    "%s/pending.%d.%d", directory, rank, getpid()) >=
	    (int) sizeof(temporary_path))
		return 1;
	record = fopen(temporary_path, "wx");
	if (NULL == record)
		return 1;
	fprintf(record, "job_id=%s\n", job_id);
	fprintf(record, "rank=%d\n", rank);
	fprintf(record, "size=%d\n", size);
	fprintf(record, "bcast=%d\n", result->bcast_value);
	fprintf(record, "allreduce=%d\n", result->allreduce_sum);
	fprintf(record, "ring_from=%d\n", result->ring_source);
	fprintf(record, "ring_value=%d\n", result->ring_value);
	fprintf(record, "processor=%s\n", processor);
	fprintf(record, "pid=%d\n", getpid());
	fprintf(record, "uid=%d\n", getuid());
	fprintf(record, "gid=%d\n", getgid());
	if (0 != fclose(record))
		return 1;
	if (0 != rename(temporary_path, path))
		return 1;
	return 0;
}

int main(int argc, char **argv)
{
	struct communication_result result;
	char processor[MPI_MAX_PROCESSOR_NAME];
	const char *job_id;
	const char *launcher;
	int processor_length = 0;
	int rank = -1;
	int size = 0;
	int exit_code = 1;

	if (argc < 2)
		return 90;
	mpi_check("MPI_Init", MPI_Init(&argc, &argv));
	mpi_check("MPI_Comm_set_errhandler", MPI_Comm_set_errhandler(
	    MPI_COMM_WORLD, MPI_ERRORS_RETURN));
	mpi_check("MPI_Comm_rank", MPI_Comm_rank(MPI_COMM_WORLD, &rank));
	mpi_check("MPI_Comm_size", MPI_Comm_size(MPI_COMM_WORLD, &size));
	mpi_check("MPI_Get_processor_name", MPI_Get_processor_name(processor,
	    &processor_length));
	processor[processor_length] = '\0';
	if (2 != size) {
		fprintf(stderr, "mpi_error stage=size expected=2 actual=%d\n", size);
		goto finalize;
	}

	exercise_communication(rank, size, &result);
	if (0 != validate_communication(size, &result))
		goto finalize;
	job_id = getenv("SLURM_JOB_ID");
	launcher = (NULL == job_id) ? "local" : "slurm";
	if (NULL == job_id)
		job_id = "none";

	if (0 == strcmp(argv[1], "success")) {
		if (2 != argc) {
			exit_code = 91;
			goto finalize;
		}
		printf("mpi_runtime=PASS launcher=%s job_id=%s rank=%d size=%d "
		    "bcast=%d allreduce=%d ring_from=%d ring_value=%d "
		    "processor=%s ompi=%d.%d.%d\n",
		    launcher, job_id, rank, size, result.bcast_value,
		    result.allreduce_sum, result.ring_source, result.ring_value,
		    processor, OMPI_MAJOR_VERSION, OMPI_MINOR_VERSION,
		    OMPI_RELEASE_VERSION);
		fflush(stdout);
		exit_code = 0;
	} else if (0 == strcmp(argv[1], "hold")) {
		if (3 != argc || 0 == strcmp(job_id, "none")) {
			exit_code = 92;
			goto finalize;
		}
		if (0 != write_ready_record(argv[2], job_id, rank, size,
		    processor, &result)) {
			fprintf(stderr,
			    "mpi_error stage=write_ready_record rank=%d errno=%d\n",
			    rank, errno);
			goto finalize;
		}
		mpi_check("MPI_Barrier(hold)", MPI_Barrier(MPI_COMM_WORLD));
		sleep(120);
		exit_code = 0;
	} else {
		exit_code = 93;
	}

finalize:
	mpi_check("MPI_Finalize", MPI_Finalize());
	return exit_code;
}
