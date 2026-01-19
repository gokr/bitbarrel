#include <bitbarrel.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

int main(void) {
    printf("BitBarrel C Library Build Test\n");
    printf("==============================\n\n");

    // Test library initialization
    BBResult result = bb_init();
    assert(result == BB_OK);
    printf("✓ Library initialized\n");

    // Test default config
    BBConfig config = bb_config_default();
    assert(config.url != NULL);
    assert(config.timeout_ms == 5000);
    assert(config.max_retries == 3);
    assert(config.enable_auto_reconnect == true);
    printf("✓ Default configuration created\n");

    // Test client creation
    BBClient* client = bb_client_create(&config);
    assert(client != NULL);
    printf("✓ Client created\n");

    // Cleanup without connecting (server may not be running)
    bb_client_destroy(client);
    bb_cleanup();
    printf("✓ Cleanup successful\n");

    printf("\n✓ All build tests passed! Library compiles correctly.\n");
    return 0;
}
