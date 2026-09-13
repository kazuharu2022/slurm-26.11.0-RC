#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <src/common/log.h>
#include <src/common/pack.h>
#include <src/common/slurm_protocol_socket.h>
#include <src/common/xmalloc.h>

#include <check.h>


START_TEST(test_pack)
{
	buf_t *buffer;
	uint16_t test16 = 1234, out16;
	uint32_t test32 = 5678, out32, byte_cnt;
	char testbytes[] = "TEST BYTES", *outbytes;
	char teststring[] = "TEST STRING",  *outstring = NULL;
	char *nullstr = NULL;
	char *data;
	int data_size;
	long double test_double = 1340664754944.2132312, test_double2;
	uint64_t test64;

	buffer = init_buf (0);
        pack16(test16, buffer);
        pack32(test32, buffer);
	pack64((uint64_t)test_double, buffer);

        packstr(testbytes, buffer);
        packstr(teststring, buffer);
	packstr(nullstr, buffer);

	packstr("literal", buffer);
	packstr("", buffer);

        data_size = get_buf_offset(buffer);
        printf("wrote %d bytes\n", data_size);

	/* Pull data off old buffer, destroy it, and create a new one */
	data = xfer_buf_data(buffer);
	buffer = create_buf(data, data_size);

        unpack16(&out16, buffer);
	info("out16 =%d", out16);
	info("test16=%d", test16);
	ck_assert_msg(out16 == test16, "un/pack16");

        unpack32(&out32, buffer);
	ck_assert_msg(out32 == test32, "un/pack32");

  	unpack64(&test64, buffer);
	test_double2 = (long double)test64;
	ck_assert_msg((uint64_t)test_double2 == (uint64_t)test_double, "un/pack double as a uint64");
	/* info("Original\t %Lf", test_double); */
	/* info("uint64\t %ld", test64); */
	/* info("converted LD\t %Lf", test_double2); */

	unpackmem_ptr(&outbytes, &byte_cnt, buffer);
	ck_assert_msg( ( strcmp(testbytes, outbytes) == 0 ) , "un/packstr_ptr");

	unpackstr_xmalloc(&outstring, &byte_cnt, buffer);
	ck_assert_msg(strcmp(teststring, outstring) == 0, "un/packstr_xmalloc");
	xfree(outstring);

	unpackstr_xmalloc(&nullstr, &byte_cnt, buffer);
	ck_assert_msg(nullstr == NULL, "un/packstr of null string.");

	unpackstr_xmalloc(&outstring, &byte_cnt, buffer);
	ck_assert_msg(strcmp("literal", outstring) == 0,
			"un/packstr of string literal");
	xfree(outstring);

	unpackstr_xmalloc(&outstring, &byte_cnt, buffer);
	ck_assert_msg(strcmp("", outstring) == 0, "un/packstr of string \"\" ");

	xfree(outstring);
	free_buf(buffer);
}
END_TEST

START_TEST(test_slurm_addr_ipv4_wire_family)
{
	buf_t *buffer = init_buf(0);
	slurm_addr_t input = { 0 }, output = { 0 };
	struct sockaddr_in *input4 = (struct sockaddr_in *) &input;
	struct sockaddr_in *output4 = (struct sockaddr_in *) &output;
	uint16_t wire_family = 0;

	input4->sin_family = AF_INET;
	input4->sin_port = htons(6818);
	ck_assert_int_eq(inet_pton(AF_INET, "192.0.2.10", &input4->sin_addr), 1);

	slurm_pack_addr(&input, buffer);
	set_buf_offset(buffer, 0);
	ck_assert_int_eq(unpack16(&wire_family, buffer), SLURM_SUCCESS);
	ck_assert_uint_eq(wire_family, 2);

	set_buf_offset(buffer, 0);
	ck_assert_int_eq(slurm_unpack_addr_no_alloc(&output, buffer),
			 SLURM_SUCCESS);
	ck_assert_int_eq(output.ss_family, AF_INET);
	ck_assert_uint_eq(output4->sin_port, input4->sin_port);
	ck_assert_int_eq(memcmp(&output4->sin_addr, &input4->sin_addr,
				sizeof(input4->sin_addr)), 0);

	free_buf(buffer);
}
END_TEST

START_TEST(test_slurm_addr_ipv6_wire_family)
{
	buf_t *buffer = init_buf(0);
	slurm_addr_t input = { 0 }, output = { 0 };
	struct sockaddr_in6 *input6 = (struct sockaddr_in6 *) &input;
	struct sockaddr_in6 *output6 = (struct sockaddr_in6 *) &output;
	uint16_t wire_family = 0;

	input6->sin6_family = AF_INET6;
	input6->sin6_port = htons(6818);
	ck_assert_int_eq(inet_pton(AF_INET6, "fd40:534d:4406:1::128",
				    &input6->sin6_addr), 1);

	slurm_pack_addr(&input, buffer);
	set_buf_offset(buffer, 0);
	ck_assert_int_eq(unpack16(&wire_family, buffer), SLURM_SUCCESS);
	/* Linux's historical value is the platform-independent wire value. */
	ck_assert_uint_eq(wire_family, 10);

	set_buf_offset(buffer, 0);
	ck_assert_int_eq(slurm_unpack_addr_no_alloc(&output, buffer),
			 SLURM_SUCCESS);
	ck_assert_int_eq(output.ss_family, AF_INET6);
	ck_assert_uint_eq(output6->sin6_port, input6->sin6_port);
	ck_assert_int_eq(memcmp(&output6->sin6_addr, &input6->sin6_addr,
				sizeof(input6->sin6_addr)), 0);

	free_buf(buffer);
}
END_TEST

int main(void)
{
	int number_failed;

	log_options_t log_opts = LOG_OPTS_INITIALIZER;
	log_opts.stderr_level = LOG_LEVEL_DEBUG5;
	log_init("pack-test", log_opts, 0, NULL);

	Suite *s = suite_create("pack");
	TCase *tc_core = tcase_create("pack");

	tcase_add_test(tc_core, test_pack);
	tcase_add_test(tc_core, test_slurm_addr_ipv4_wire_family);
	tcase_add_test(tc_core, test_slurm_addr_ipv6_wire_family);

	suite_add_tcase(s, tc_core);

	SRunner *sr = srunner_create(s);

	srunner_run_all(sr, CK_ENV);
	number_failed = srunner_ntests_failed(sr);
	srunner_free(sr);

	return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
