# Tests CMakeLists.txt

# Create a simple test executable that verifies the library builds
# TODO: Implement comprehensive tests
add_executable(test_basic test_basic.c)
target_link_libraries(test_basic bitbarrel)
add_test(NAME test_basic COMMAND test_basic)

# Integration test that connects to a running server
add_executable(test_integration test_integration.c)
target_link_libraries(test_integration bitbarrel)
add_test(NAME test_integration COMMAND test_integration)

# Set test properties
set_tests_properties(
    test_basic
    PROPERTIES
    TIMEOUT 30
    ENVIRONMENT "LD_LIBRARY_PATH=${CMAKE_BINARY_DIR}"
)

set_tests_properties(
    test_integration
    PROPERTIES
    TIMEOUT 30
    ENVIRONMENT "LD_LIBRARY_PATH=${CMAKE_BINARY_DIR}"
)
