// Plain-guest probe (own code). A client object whose dealloc asserts "must be invalidated before deallocation"
// (the pattern of a service client) is captured by a connection event handler. The connection names a service that
// does not exist, so the handler gets XPC_ERROR_CONNECTION_INVALID. Scenario RESET: like handlers that break their own
// retain cycle, the handler replaces itself with xpc_connection_set_event_handler() and THEN invalidates the client.
// Scenario PLAIN: the handler just invalidates the client. Each case must dealloc the client exactly once, after it was
// invalidated, and not before the handler body finished.
#import <objc/NSObject.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile int g_bad, g_deallocs, g_handler_done;

@interface Client : NSObject { @public int invalidated; }
- (void)invalidate;
@end
@implementation Client
- (void)invalidate { invalidated = 1; }
- (void)dealloc {
	g_deallocs++;
	if (!invalidated) {
		fprintf(stderr, "FAIL: Client must be invalidated before deallocation (handler finished: %d)\n", g_handler_done);
		g_bad = 1;
	}
	[super dealloc];
}
@end

static int run(const char *label, int reset) {
	g_deallocs = 0; g_bad = 0; g_handler_done = 0;
	char name[128];
	snprintf(name, sizeof name, "org.darlinghq.test.handler-lifetime.%s.%d", label, (int)getpid());
	dispatch_queue_t q = dispatch_queue_create("probe", NULL);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	Client *client = [[Client alloc] init];
	xpc_connection_t conn = xpc_connection_create_mach_service(name, q, 0);
	xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
		if (event == XPC_ERROR_CONNECTION_INVALID) {
			if (reset) xpc_connection_set_event_handler(conn, ^(xpc_object_t e) {});
			[client invalidate];
			g_handler_done = 1;
			dispatch_semaphore_signal(done);
		}
	});
	[client release]; // the handler holds the only reference
	xpc_connection_resume(conn);
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
		fprintf(stderr, "FAIL: %s: no INVALID event within 10 s\n", label);
		return 1;
	}
	dispatch_sync(q, ^{});
	xpc_release(conn);
	usleep(300000); // let the connection's final internal release run
	dispatch_sync(q, ^{});
	if (g_deallocs != 1) { fprintf(stderr, "FAIL: %s: client dealloc count %d, expected 1\n", label, g_deallocs); return 1; }
	if (g_bad) return 1;
	printf("PASS: %s\n", label);
	return 0;
}

int main(void) {
	int rc = 0;
	rc |= run("plain", 0);
	rc |= run("reset", 1);
	return rc;
}
