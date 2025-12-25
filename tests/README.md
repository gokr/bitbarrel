# BitBarrel Test Suite

Test utilities and documentation are in `CLAUDE.md`.

## Running Tests

```bash
nimble test     # Run all tests
```

Specific categories:
```bash
nimble testStorage       # Storage layer
nimble testKeydir        # KeyDir index
nimble testIntegration   # Integration tests
nimble testRecovery      # Recovery system
nimble testAPI           # API tests
nimble testUnit          # Unit tests
nimble testSystem        # System/integration
nimble testHugeBarrel    # HugeBarrel features
```

## Test Organization

```
tests/
├── api/               # High-level Barrel API
│   ├── core/          # CRUD, TTL, refs
│   ├── error/         # Error handling
│   └── range/         # Range queries
├── config/            # Configuration
├── docs/              # Documentation examples
├── hugebarrel/        # HugeBarrel feature tests
├── io/                # I/O layer (buffers, protocol)
├── recovery/          # Recovery, hints, compaction
├── system/
│   ├── concurrency/   # Thread safety
│   ├── integration/   # End-to-end workflows
│   └── stress/        # Memory/filesystem stress
└── unit/              # Low-level component tests
    ├── compression/
    ├── keydir/
    └── storage/
```
