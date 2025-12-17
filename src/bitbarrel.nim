## BitBarrel Library and CLI Entry Point
##
## Provides both library functionality and CLI interface
## When imported as a library, exports high-level and low-level APIs
## When run as binary, starts the CLI application

# Library exports
import bitbarrel/[types, config, barrel, lowlevelapi]
import storage

# Export everything users might need
export types, config, barrel, lowlevelapi, storage

# Convenience aliases for common operations
proc openDatabase*(path: string, config: BarrelConfig = defaultBarrelConfig()): Barrel =
  ## Alias for barrel.openBarrel - convenient top-level function
  barrel.openBarrel(path, config)

proc newDatabaseConfig*(): BarrelConfig =
  ## Alias for defaultBarrelConfig - create new configuration
  defaultBarrelConfig()

# Binary mode - only when executed directly
when isMainModule:
  import cli/main
  main()