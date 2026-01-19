## Query Result Hooks - Hook system for transforming query results
##
## Provides a global registry of hooks that can transform query results
## from range and prefix queries before they are returned to the client.

import std/[locks, options, strformat, tables]

type
  HookKind* = enum
    hkRangeQuery    ## Range query items (cmdRangeQuery)
    hkPrefixQuery   ## Prefix query items (cmdPrefixQuery)
    hkAny           ## Applicable to all operations

  HookMetadata* = object
    barrelName*: string     ## Which barrel was queried
    clientId*: string       ## WebSocket client ID
    hookKind*: HookKind     ## Which hook type is being called

  QueryResultHook* = proc(metadata: HookMetadata,
                          items: var seq[(string, string)],
                          nextCursor: var string,
                          hasMore: var bool) {.gcsafe.}

  HookRegistration* = ref HookRegistrationObj
  HookRegistrationObj = object
    id*: string               ## Internal ID for unregistration
    name*: string             ## Public name for client selection (required, unique)
    hook*: QueryResultHook    ## The hook procedure
    kind*: HookKind           ## Which operation types this hook supports
    description*: string      ## Hook description

  HookRegistry* = ref HookRegistryObj
  HookRegistryObj = object
    hooks*: seq[HookRegistration]
    hooksLock*: Lock
    nameIndex*: Table[string, HookRegistration]  ## Quick lookup by name
    seqCounter*: int                               ## For generating hook IDs
    seqLock*: Lock

var
  hooksRegistry*: HookRegistry
  registryInitialized = false

proc getHooksRegistry*(): HookRegistry {.gcsafe.} =
  ## Get or create the global hooks registry

  {.gcsafe.}:
    if not registryInitialized:
      hooksRegistry = HookRegistry(
        hooks: @[],
        hooksLock: Lock(),
        nameIndex: initTable[string, HookRegistration](),
        seqCounter: 0,
        seqLock: Lock()
      )
      initLock(hooksRegistry.hooksLock)
      initLock(hooksRegistry.seqLock)
      registryInitialized = true
    return hooksRegistry

proc generateHookId*(registry: HookRegistry): string =
  ## Generate a unique hook ID

  withLock registry.seqLock:
    registry.seqCounter += 1
    result = "hook_" & $registry.seqCounter

proc registerHook*(name: string, hook: QueryResultHook, kind: HookKind,
                   description: string = ""): string =
  ## Register a query result hook
  ##
  ## Parameters:
  ##   - name: Unique name for client selection
  ##   - hook: The hook procedure to call on query results
  ##   - kind: Which query types this hook supports
  ##   - description: Description of what the hook does
  ##
  ## Returns: Hook ID for later unregistration
  ##
  ## Raises: ValueError if name already exists

  let registry = getHooksRegistry()

  # Check for name uniqueness
  withLock registry.hooksLock:
    if name in registry.nameIndex:
      raise newException(ValueError, fmt("Hook name already exists: {name}"))

  let hookId = registry.generateHookId()

  let registration = HookRegistration(
    id: hookId,
    name: name,
    hook: hook,
    kind: kind,
    description: description
  )

  withLock registry.hooksLock:
    registry.hooks.add(registration)
    registry.nameIndex[name] = registration

  return hookId

proc unregisterHook*(hookId: string): bool =
  ## Unregister a hook by ID
  ##
  ## Returns: true if hook was found and removed

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    for i, reg in registry.hooks:
      if reg.id == hookId:
        registry.hooks.delete(i)
        if reg.name in registry.nameIndex:
          registry.nameIndex.del(reg.name)
        return true

  return false

proc unregisterHookByName*(name: string): bool =
  ## Unregister a hook by name
  ##
  ## Returns: true if hook was found and removed

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    if name in registry.nameIndex:
      let reg = registry.nameIndex[name]
      for i, r in registry.hooks:
        if r.id == reg.id:
          registry.hooks.delete(i)
          break
      registry.nameIndex.del(name)
      return true

  return false

proc getHookByName*(name: string): Option[HookRegistration] =
  ## Get a hook by name
  ##
  ## Returns: The hook registration or none if not found

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    if name in registry.nameIndex:
      return some(registry.nameIndex[name])

  return none(HookRegistration)

proc listHooks*(): seq[HookRegistration] =
  ## List all registered hooks
  ##
  ## Returns: Copy of all hook registrations

  let registry = getHooksRegistry()

  withLock registry.hooksLock:
    result = registry.hooks

proc isHookCompatible*(hook: HookRegistration, queryKind: HookKind): bool =
  ## Check if hook is compatible with the query type
  ##
  ## A hook is compatible if:
  ## - Its kind matches the query kind exactly
  ## - Its kind is hkAny (compatible with all)
  ## - The query kind is hkAny (not used in practice, but for completeness)

  result = hook.kind == hkAny or queryKind == hkAny or hook.kind == queryKind

proc applyQueryResultHooks*(hookNames: seq[string], metadata: HookMetadata,
                           items: var seq[(string, string)],
                          nextCursor: var string,
                          hasMore: var bool): bool =
  ## Apply query result hooks to transform query results
  ##
  ## Parameters:
  ##   - hookNames: Names of hooks to apply (in order)
  ##   - metadata: Query metadata
  ##   - items: Query results (modifiable)
  ##   - nextCursor: Cursor for next page (modifiable)
  ##   - hasMore: Whether more items available (modifiable)
  ##
  ## Returns: true if all hooks were found and applied, false otherwise
  ##
  ## Hooks are executed in the order specified by the client.
  ## Returns false if any hook name is not found or if hook kind doesn't match.

  if hookNames.len == 0:
    return true

  let registry = getHooksRegistry()

  # Collect hooks to call (outside the lock)
  var hooksToCall: seq[QueryResultHook]

  withLock registry.hooksLock:
    for name in hookNames:
      if name notin registry.nameIndex:
        return false
      let hook = registry.nameIndex[name]
      if not hook.isHookCompatible(metadata.hookKind):
        return false
      hooksToCall.add(hook.hook)

  # Call hooks outside the lock to avoid deadlock
  for hookProc in hooksToCall:
    try:
      hookProc(metadata, items, nextCursor, hasMore)
    except CatchableError as e:
      echo fmt"[QueryResultHooks] Hook error for {metadata.barrelName}: {e.msg}"

  return true

proc clearAllHooks*(): void =
  ## Clear all registered hooks (for testing only)

  let registry = getHooksRegistry()
  withLock registry.hooksLock:
    registry.hooks.setLen(0)
    registry.nameIndex.clear()
  withLock registry.seqLock:
    registry.seqCounter = 0

proc getHookCount*(): int =
  ## Get the number of registered hooks
  let registry = getHooksRegistry()
  withLock registry.hooksLock:
    return registry.hooks.len
