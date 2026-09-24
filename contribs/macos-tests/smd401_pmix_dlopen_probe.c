#include <dlfcn.h>
#include <stdio.h>

typedef const char *(*pmix_get_version_fn_t)(void);

int main(int argc, char **argv)
{
	pmix_get_version_fn_t get_version;
	const char *error;
	void *handle;

	if (argc != 2) {
		fprintf(stderr, "usage: %s LIBRARY\n", argv[0]);
		return 64;
	}

	handle = dlopen(argv[1], RTLD_LAZY | RTLD_GLOBAL);
	if (!handle) {
		fprintf(stderr, "result=LOAD_FAILED target=%s error=%s\n",
			argv[1], dlerror());
		return 2;
	}

	dlerror();
	get_version = (pmix_get_version_fn_t)dlsym(handle, "PMIx_Get_version");
	error = dlerror();
	if (error) {
		fprintf(stderr, "result=SYMBOL_FAILED target=%s error=%s\n",
			argv[1], error);
		dlclose(handle);
		return 3;
	}

	printf("result=LOAD_OK target=%s version=%s\n", argv[1],
	       get_version());
	dlclose(handle);
	return 0;
}
