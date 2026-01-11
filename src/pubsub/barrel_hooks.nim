## Barrel Hooks - Integration point for k/v change events
##
## Provides a global registry of event hooks that are triggered
## when keys are set or deleted in a Barrel.

import std/[locks, algorithm]
import strformat
import ./pubsub

type
  ## Event hook type: called when k/v changes occur
  ##
  ## Parameters:
  ## - barrelName: Name/ID of the barrel
  ## - key: The key that was modified
  ## - changeType: What type of change (set or delete)
  ## - value: The new value (empty for delete)
  ##
  ## Must be {.gcsafe.} as hooks may be called from multiple threads
  BarrelEventHook* = proc(barrelName: string, key: string,
                          changeType: KvChangeType,
                          value: string) {.gcsafe.}

  ## Hook registration record
  HookRegistration* = ref HookRegistrationObj
  HookRegistrationObj = object
    id*: string               ## Hook ID for unregistration
    hook*: BarrelEventHook   ## The hook procedure
    priority*: int           ## Higher priority = called earlier
    enabled*: bool           ## Whether the hook is active

  ## Hooks registry (singleton)
  BarrelHooksRegistry* = ref BarrelHooksRegistryObj
  BarrelHooksRegistryObj = object
    hooks*: seq[HookRegistration]  ## All registered hooks
    hooksLock*: Lock
    seqCounter*: int               ## For generating hook IDs
    seqLock*: Lock

var
  ## Global registry for k/v change hooks
  hooksRegistry*: BarrelHooksRegistry
  registryInitialized = false

proc getHooksRegistry*(): BarrelHooksRegistry {.gcsafe.} =
  ## Get or create the global hooks registry

  {.gcsafe.}:
    if not registryInitialized:
      hooksRegistry = BarrelHooksRegistry(
        hooks: @[],
        hooksLock: Lock(),
        seqCounter: 0,
        seqLock: Lock()
      )
      initLock(hooksRegistry.hooksLock)
      initLock(hooksRegistry.seqLock)
      registryInitialized = true
    return hooksRegistry

proc generateHookId*(registry: BarrelHooksRegistry): string =
  ## Generate a unique hook ID

  withLock registry.seqLock:
    registry.seqCounter += 1
    result = "hook_" & $registry.seqCounter

proc registerBarrelHook*(hook: BarrelEventHook,
                          enabled: bool = true,
                          priority: int = 0): string =
  ## Register a callback for k/v change events
  ##
  ## Parameters:
  ##   - hook: The hook procedure to call on k/v changes
  ##   - enabled: Whether the hook is initially active
  ##   - priority: Higher priority hooks are called earlier
  ##
  ## Returns: Hook ID for later unregistration

  let registry = getHooksRegistry()
  let hookId = registry.generateHookId()

  let registration = HookRegistration(
    id: hookId,
    hook: hook,
    priority: priority,
    enabled: enabled
  )

  withLock registry.hooksLock:
    registry.hooks.add(registration)

    # Sort by priority (higher first) - need to copy and replace because of withLock
    var sorted = registry.hooks
    proc cmpPriority(a, b: HookRegistration): int = cmp(b.priority, a.priority)
    sorted.sort(cmpPriority)
    registry.hooks = sorted

  return hookId

proc unregisterBarrelHook*(hookId: string): bool =
  ## Unregister a k/v change hook
  ##
  ## Returns: true if hook was found and removed

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    for i, reg in registry.hooks:
      if reg.id == hookId:
        registry.hooks.delete(i)
        return true

  return false

proc enableHook*(hookId: string): bool =
  ## Enable a previously disabled hook
  ##
  ## Returns: true if hook was found and enabled

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    for reg in registry.hooks:
      if reg.id == hookId:
        reg.enabled = true
        return true

  return false

proc disableHook*(hookId: string): bool =
  ## Disable a hook (remains registered but won't be called)
  ##
  ## Returns: true if hook was found and disabled

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    for reg in registry.hooks:
      if reg.id == hookId:
        reg.enabled = false
        return true

  return false

proc triggerBarrelHooks*(barrelName: string, key: string,
                         changeType: KvChangeType,
                         value: string) {.gcsafe.} =
  ## Trigger all registered k/v change hooks
  ##
  ## This is called from barrel.nim when a set() or delete() completes

  let registry = getHooksRegistry()

  var hooksToCall: seq[BarrelEventHook]

  withLock registry.hooksLock:
    for reg in registry.hooks:
      if reg.enabled:
        hooksToCall.add(reg.hook)

  # Call hooks outside the lock to avoid deadlock
  for hook in hooksToCall:
    try:
      hook(barrelName, key, changeType, value)
    except CatchableError as e:
      # Log error but continue with other hooks
      echo fmt"[BarrelHooks] Hook error for {barrelName}:{key}: {e.msg}"

proc clearAllHooks*(): void =
  ## Clear all registered hooks (for testing only)

  let registry = getHooksRegistry()
  withLock registry.hooksLock:
    registry.hooks.setLen(0)
  withLock registry.seqLock:
    registry.seqCounter = 0

proc getHookCount*(): int =
  ## Get the number of registered hooks
  let registry = getHooksRegistry()
  withLock registry.hooksLock:
    return registry.hooks.len

proc listHooks*(): seq[HookRegistration] =
  ## List all registered hooks
  let registry = getHooksRegistry()
  withLock registry.hooksLock:
    return registry.hooks
