# Examples CMakeLists.txt

# Basic example
add_executable(basic_example basic_example.c)
target_link_libraries(basic_example bitbarrel)

# Pub/Sub example
add_executable(pubsub_example pubsub_example.c)
target_link_libraries(pubsub_example bitbarrel)

# Install examples
install(TARGETS basic_example pubsub_example
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}/bitbarrel-examples
)
