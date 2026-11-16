// Needs the launchd test service (launchd-service/, plist installed with the tests) to be registered.
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <stdio.h>
#include <unistd.h>

#include "launchd-service/service.h"

// private API under test; declared here because the SDK does not ship it
xpc_endpoint_t xpc_endpoint_create_bs_named(const char* name, uint64_t flags, uint8_t* out_type);

int main(void) {
	char missing[160];
	snprintf(missing, sizeof(missing), "org.darlinghq.test.no-such-service.%ld", (long)getpid());

	uint8_t type = 0xAA;
	if (xpc_endpoint_create_bs_named(missing, 0, &type) != NULL) {
		fprintf(stderr, "FAIL: an endpoint was returned for a service that does not exist\n");
		return 1;
	}

	type = 0xAA;
	xpc_endpoint_t endpoint = xpc_endpoint_create_bs_named(TEST_SERVICE_NAME, 0, &type);
	if (endpoint == NULL) {
		fprintf(stderr, "FAIL: no endpoint for the registered service %s\n", TEST_SERVICE_NAME);
		return 1;
	}
	if (type == 0xAA) {
		fprintf(stderr, "FAIL: the out type parameter was left uninitialised\n");
		return 1;
	}

	dispatch_queue_t queue = dispatch_queue_create("bs-named", NULL);
	dispatch_semaphore_t replied = dispatch_semaphore_create(0);
	__block int reply_type_ok = 0;
	xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
	xpc_connection_resume(connection);

	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(message, MESSAGE_TYPE_KEY, test_service_message_type_hello);
	xpc_dictionary_set_string(message, HELLO_KEY, "hello through a bs-named endpoint");
	xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t reply) {
		reply_type_ok = xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
			xpc_dictionary_get_uint64(reply, MESSAGE_TYPE_KEY) == test_service_message_type_hello;
		dispatch_semaphore_signal(replied);
	});
	xpc_release(message);

	if (dispatch_semaphore_wait(replied, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
		fprintf(stderr, "FAIL: no reply from the service through its endpoint within 10 s\n");
		return 1;
	}
	if (!reply_type_ok) {
		fprintf(stderr, "FAIL: the reply was not the service's hello reply\n");
		return 1;
	}
	puts("PASS: bs-named endpoint reaches the registered service, missing service gives NULL");
	return 0;
}
