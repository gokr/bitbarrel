#!/bin/bash
## Cleanup script for HugeBarrel stress test

## Remove old test database
if [ -d "stress_test_db" ]; then
    echo "Removing old stress_test_db..."
    rm -rf stress_test_db
    echo "✓ Cleaned up"
fi

## Also clean up any test databases from test runs
if [ -d "/tmp/bitbarrel_huge_compaction_test" ]; then
    echo "Removing test directory..."
    rm -rf /tmp/bitbarrel_huge_compaction_test
fi

echo "Ready for fresh stress test run!"