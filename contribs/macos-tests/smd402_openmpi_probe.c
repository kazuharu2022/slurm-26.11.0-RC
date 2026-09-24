#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <mpi.h>

#define SMD402_BCAST_VALUE 42
#define SMD402_RING_BASE 2000

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

static const char *byte_order(void)
{
	const unsigned int value = 1;

	return (*(const unsigned char *) &value == 1) ? "little" : "big";
}

static void exercise_communication(int rank, int size,
	struct communication_result *result)
{
	int send_value = SMD402_RING_BASE + rank;
	int destination = (rank + 1) % size;

	result->bcast_value = (0 == rank) ? SMD402_BCAST_VALUE : 0;
	mpi_check("MPI_Bcast", MPI_Bcast(&result->bcast_value, 1, MPI_INT, 0,
	    MPI_COMM_WORLD));
	mpi_check("MPI_Allreduce", MPI_Allreduce(&rank, &result->allreduce_sum, 1,
	    MPI_INT, MPI_SUM, MPI_COMM_WORLD));
	result->ring_source = (rank + size - 1) % size;
	mpi_check("MPI_Sendrecv", MPI_Sendrecv(&send_value, 1, MPI_INT,
	    destination, 402, &result->ring_value, 1, MPI_INT,
	    result->ring_source, 402, MPI_COMM_WORLD, MPI_STATUS_IGNORE));
	mpi_check("MPI_Barrier", MPI_Barrier(MPI_COMM_WORLD));
}

static int validate_communication(int size,
	const struct communication_result *result)
{
	int expected_sum = size * (size - 1) / 2;
	int expected_ring = SMD402_RING_BASE + result->ring_source;

	if (SMD402_BCAST_VALUE != result->bcast_value ||
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

static void print_record(const char *record, const char *launcher,
	const char *job_id, int rank, int size, const char *processor,
	const struct utsname *host, const struct communication_result *result)
{
	printf("mpi_%s=PASS launcher=%s job_id=%s rank=%d size=%d "
	    "bcast=%d allreduce=%d ring_from=%d ring_value=%d "
	    "processor=%s host=%s machine=%s endian=%s "
	    "pointer=%zu long=%zu int=%zu double=%zu pid=%d uid=%d gid=%d "
	    "ompi=%d.%d.%d\n",
	    record, launcher, job_id, rank, size, result->bcast_value,
	    result->allreduce_sum, result->ring_source, result->ring_value,
	    processor, host->nodename, host->machine, byte_order(),
	    sizeof(void *), sizeof(long), sizeof(int), sizeof(double), getpid(),
	    getuid(), getgid(), OMPI_MAJOR_VERSION, OMPI_MINOR_VERSION,
	    OMPI_RELEASE_VERSION);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	struct communication_result result;
	struct utsname host;
	char processor[MPI_MAX_PROCESSOR_NAME];
	const char *job_id;
	const char *launcher;
	int processor_length = 0;
	int rank = -1;
	int size = 0;
	int exit_code = 1;

	if (2 != argc)
		return 90;
	mpi_check("MPI_Init", MPI_Init(&argc, &argv));
	mpi_check("MPI_Comm_set_errhandler", MPI_Comm_set_errhandler(
	    MPI_COMM_WORLD, MPI_ERRORS_RETURN));
	mpi_check("MPI_Comm_rank", MPI_Comm_rank(MPI_COMM_WORLD, &rank));
	mpi_check("MPI_Comm_size", MPI_Comm_size(MPI_COMM_WORLD, &size));
	mpi_check("MPI_Get_processor_name", MPI_Get_processor_name(processor,
	    &processor_length));
	processor[processor_length] = '\0';
	if (0 != uname(&host)) {
		fprintf(stderr, "mpi_error stage=uname\n");
		goto finalize;
	}
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
		print_record("runtime", launcher, job_id, rank, size, processor,
		    &host, &result);
		exit_code = 0;
	} else if (0 == strcmp(argv[1], "hold")) {
		if (0 == strcmp(job_id, "none")) {
			exit_code = 91;
			goto finalize;
		}
		print_record("ready", launcher, job_id, rank, size, processor,
		    &host, &result);
		mpi_check("MPI_Barrier(hold)", MPI_Barrier(MPI_COMM_WORLD));
		sleep(120);
		exit_code = 0;
	} else {
		exit_code = 92;
	}

finalize:
	mpi_check("MPI_Finalize", MPI_Finalize());
	return exit_code;
}
