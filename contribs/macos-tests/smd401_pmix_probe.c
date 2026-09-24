#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <pmix.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define SMD401_VALUE 42U

static int pmix_error(const char *stage, pmix_status_t rc)
{
	fprintf(stderr, "pmix_error stage=%s rc=%d message=%s\n", stage,
	    (int) rc, PMIx_Error_string(rc));
	return 1;
}

static int get_job_size(const pmix_proc_t *self, uint32_t *size)
{
	pmix_proc_t wildcard;
	pmix_status_t rc;
	pmix_value_t *value = NULL;

	PMIX_PROC_CONSTRUCT(&wildcard);
	PMIX_LOAD_PROCID(&wildcard, self->nspace, PMIX_RANK_WILDCARD);
	rc = PMIx_Get(&wildcard, PMIX_JOB_SIZE, NULL, 0, &value);
	PMIX_PROC_DESTRUCT(&wildcard);
	if (PMIX_SUCCESS != rc)
		return pmix_error("PMIx_Get(PMIX_JOB_SIZE)", rc);
	if (NULL == value || PMIX_UINT32 != value->type) {
		fprintf(stderr, "pmix_error stage=job_size_type type=%d\n",
		    NULL == value ? -1 : (int) value->type);
		if (NULL != value)
			PMIX_VALUE_RELEASE(value);
		return 1;
	}
	*size = value->data.uint32;
	PMIX_VALUE_RELEASE(value);
	return 0;
}

static int fence_job(const pmix_proc_t *self)
{
	pmix_proc_t wildcard;
	pmix_status_t rc;

	PMIX_PROC_CONSTRUCT(&wildcard);
	PMIX_LOAD_PROCID(&wildcard, self->nspace, PMIX_RANK_WILDCARD);
	rc = PMIx_Fence(&wildcard, 1, NULL, 0);
	PMIX_PROC_DESTRUCT(&wildcard);
	if (PMIX_SUCCESS != rc)
		return pmix_error("PMIx_Fence", rc);
	return 0;
}

static int run_success(const pmix_proc_t *self, uint32_t size)
{
	const char *job_id;
	pmix_proc_t rank_zero;
	pmix_status_t rc;
	pmix_value_t put_value;
	pmix_value_t *get_value = NULL;

	memset(&put_value, 0, sizeof(put_value));
	put_value.type = PMIX_UINT32;
	put_value.data.uint32 = SMD401_VALUE;
	if (0 == self->rank) {
		rc = PMIx_Put(PMIX_GLOBAL, "smd401.value", &put_value);
		if (PMIX_SUCCESS != rc)
			return pmix_error("PMIx_Put", rc);
	}
	rc = PMIx_Commit();
	if (PMIX_SUCCESS != rc)
		return pmix_error("PMIx_Commit", rc);
	if (0 != fence_job(self))
		return 1;

	PMIX_PROC_CONSTRUCT(&rank_zero);
	PMIX_LOAD_PROCID(&rank_zero, self->nspace, 0);
	rc = PMIx_Get(&rank_zero, "smd401.value", NULL, 0, &get_value);
	PMIX_PROC_DESTRUCT(&rank_zero);
	if (PMIX_SUCCESS != rc)
		return pmix_error("PMIx_Get(smd401.value)", rc);
	if (NULL == get_value || PMIX_UINT32 != get_value->type ||
	    SMD401_VALUE != get_value->data.uint32) {
		fprintf(stderr, "pmix_error stage=value_check type=%d value=%" PRIu32
		    "\n", NULL == get_value ? -1 : (int) get_value->type,
		    NULL == get_value ? 0U : get_value->data.uint32);
		if (NULL != get_value)
			PMIX_VALUE_RELEASE(get_value);
		return 1;
	}
	PMIX_VALUE_RELEASE(get_value);

	job_id = getenv("SLURM_JOB_ID");
	if (NULL == job_id) {
		fprintf(stderr, "pmix_error stage=SLURM_JOB_ID_missing\n");
		return 1;
	}
	printf("pmix_runtime=PASS job_id=%s nspace=%s rank=%" PRIu32
	    " size=%" PRIu32 " value=%u fence=PASS\n", job_id,
	    self->nspace, (uint32_t) self->rank, size, SMD401_VALUE);
	fflush(stdout);
	return 0;
}

static int write_ready_record(const pmix_proc_t *self, uint32_t size,
    const char *directory)
{
	char path[PATH_MAX];
	char temporary_path[PATH_MAX];
	const char *job_id;
	FILE *record;
	int rank = (int) self->rank;

	job_id = getenv("SLURM_JOB_ID");
	if (NULL == job_id)
		return 1;
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
	fprintf(record, "nspace=%s\n", self->nspace);
	fprintf(record, "rank=%d\n", rank);
	fprintf(record, "size=%" PRIu32 "\n", size);
	fprintf(record, "fence=PASS\n");
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
	pmix_proc_t self;
	pmix_status_t rc;
	uint32_t size;
	int result = 1;

	if (argc < 2)
		return 90;
	PMIX_PROC_CONSTRUCT(&self);
	rc = PMIx_Init(&self, NULL, 0);
	if (PMIX_SUCCESS != rc) {
		PMIX_PROC_DESTRUCT(&self);
		return pmix_error("PMIx_Init", rc);
	}
	if (0 != get_job_size(&self, &size))
		goto finalize;

	if (0 == strcmp(argv[1], "success")) {
		if (2 != argc || 0 != run_success(&self, size))
			goto finalize;
		result = 0;
	} else if (0 == strcmp(argv[1], "hold")) {
		if (3 != argc || 0 != fence_job(&self) ||
		    0 != write_ready_record(&self, size, argv[2]))
			goto finalize;
		sleep(120);
		result = 0;
	} else {
		result = 91;
	}

finalize:
	rc = PMIx_Finalize(NULL, 0);
	PMIX_PROC_DESTRUCT(&self);
	if (PMIX_SUCCESS != rc)
		return pmix_error("PMIx_Finalize", rc);
	return result;
}
