## BitBarrel Library and CLI Entry Point
##
## Provides both library functionality and CLI interface
## When imported as a library, exports high-level and low-level APIs
## When run as binary, starts the CLI application

# Library exports
import bitbarrel/[types, simpleapi, lowlevelapi]
import storage

# Export everything users might need
export types, simpleapi, lowlevelapi, storage

# Convenience aliases for common operations
proc openDatabase*(path: string, config: SimpleConfig = defaultConfig()): SimpleBB =
  ## Alias for simpleapi.open - convenient top-level function
  simpleapi.open(path, config)

proc newDatabaseConfig*(): SimpleConfig =
  ## Alias for defaultConfig - create new configuration
  defaultConfig()

# Binary mode - only when executed directly
when isMainModule:
  import cli/main
  main()