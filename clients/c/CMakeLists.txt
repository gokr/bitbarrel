cmake_minimum_required(VERSION 3.10)
project(bitbarrel-c VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# Options
option(BUILD_SHARED_LIBS "Build shared libraries" ON)
option(BUILD_TESTS "Build tests" ON)
option(BUILD_EXAMPLES "Build examples" ON)

# Find required packages
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)

# Include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Source files
set(SOURCES
    src/bitbarrel.c
    src/protocol.c
    src/websocket.c
    src/pubsub.c
    src/range.c
)

# Create library
add_library(bitbarrel ${SOURCES})

# Set library properties
set_target_properties(bitbarrel PROPERTIES
    PUBLIC_HEADER include/bitbarrel.h
    VERSION ${PROJECT_VERSION}
    SOVERSION 1
)

# Link libraries
target_link_libraries(bitbarrel
    PUBLIC
        Threads::Threads
        OpenSSL::SSL
        OpenSSL::Crypto
)

# Installation
include(GNUInstallDirs)

install(TARGETS bitbarrel
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# Install header
install(FILES include/bitbarrel.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# pkg-config file
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/bitbarrel.pc.in"
    "${CMAKE_CURRENT_BINARY_DIR}/bitbarrel.pc"
    @ONLY
)

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/bitbarrel.pc"
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig
)

# Examples
if(BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

# Tests
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# Print configuration
message(STATUS "")
message(STATUS "BitBarrel C Library Configuration:")
message(STATUS "  Version: ${PROJECT_VERSION}")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Shared libs: ${BUILD_SHARED_LIBS}")
message(STATUS "  Build tests: ${BUILD_TESTS}")
message(STATUS "  Build examples: ${BUILD_EXAMPLES}")
message(STATUS "")
