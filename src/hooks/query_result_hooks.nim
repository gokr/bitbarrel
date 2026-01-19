## Query Result Hooks - Plugin system for transforming query results
##
## Provides a global registry of plugins that can transform query results
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

  PluginRegistration* = ref PluginRegistrationObj
  PluginRegistrationObj = object
    id*: string               ## Internal ID for unregistration
    name*: string             ## Public name for client selection (required, unique)
    hook*: QueryResultHook    ## The hook procedure
    kind*: HookKind           ## Which operation types this plugin supports
    description*: string      ## Plugin description

  PluginRegistry* = ref PluginRegistryObj
  PluginRegistryObj = object
    plugins*: seq[PluginRegistration]
    pluginsLock*: Lock
    nameIndex*: Table[string, PluginRegistration]  ## Quick lookup by name
    seqCounter*: int                                   ## For generating plugin IDs
    seqLock*: Lock

var
  pluginsRegistry*: PluginRegistry
  registryInitialized = false

proc getPluginsRegistry*(): PluginRegistry {.gcsafe.} =
  ## Get or create the global plugins registry

  {.gcsafe.}:
    if not registryInitialized:
      pluginsRegistry = PluginRegistry(
        plugins: @[],
        pluginsLock: Lock(),
        nameIndex: initTable[string, PluginRegistration](),
        seqCounter: 0,
        seqLock: Lock()
      )
      initLock(pluginsRegistry.pluginsLock)
      initLock(pluginsRegistry.seqLock)
      registryInitialized = true
    return pluginsRegistry

proc generatePluginId*(registry: PluginRegistry): string =
  ## Generate a unique plugin ID

  withLock registry.seqLock:
    registry.seqCounter += 1
    result = "plugin_" & $registry.seqCounter

proc registerPlugin*(name: string, hook: QueryResultHook, kind: HookKind,
                     description: string = ""): string =
  ## Register a query result plugin
  ##
  ## Parameters:
  ##   - name: Unique name for client selection
  ##   - hook: The hook procedure to call on query results
  ##   - kind: Which query types this plugin supports
  ##   - description: Description of what the plugin does
  ##
  ## Returns: Plugin ID for later unregistration
  ##
  ## Raises: ValueError if name already exists

  let registry = getPluginsRegistry()

  # Check for name uniqueness
  withLock registry.pluginsLock:
    if name in registry.nameIndex:
      raise newException(ValueError, fmt("Plugin name already exists: {name}"))

  let pluginId = registry.generatePluginId()

  let registration = PluginRegistration(
    id: pluginId,
    name: name,
    hook: hook,
    kind: kind,
    description: description
  )

  withLock registry.pluginsLock:
    registry.plugins.add(registration)
    registry.nameIndex[name] = registration

  return pluginId

proc unregisterPlugin*(pluginId: string): bool =
  ## Unregister a plugin by ID
  ##
  ## Returns: true if plugin was found and removed

  let registry = getPluginsRegistry()

  withLock registry.pluginsLock:
    for i, reg in registry.plugins:
      if reg.id == pluginId:
        registry.plugins.delete(i)
        if reg.name in registry.nameIndex:
          registry.nameIndex.del(reg.name)
        return true

  return false

proc unregisterPluginByName*(name: string): bool =
  ## Unregister a plugin by name
  ##
  ## Returns: true if plugin was found and removed

  let registry = getPluginsRegistry()

  withLock registry.pluginsLock:
    if name in registry.nameIndex:
      let reg = registry.nameIndex[name]
      for i, r in registry.plugins:
        if r.id == reg.id:
          registry.plugins.delete(i)
          break
      registry.nameIndex.del(name)
      return true

  return false

proc getPluginByName*(name: string): Option[PluginRegistration] =
  ## Get a plugin by name
  ##
  ## Returns: The plugin registration or none if not found

  let registry = getPluginsRegistry()

  withLock registry.pluginsLock:
    if name in registry.nameIndex:
      return some(registry.nameIndex[name])

  return none(PluginRegistration)

proc listPlugins*(): seq[PluginRegistration] =
  ## List all registered plugins
  ##
  ## Returns: Copy of all plugin registrations

  let registry = getPluginsRegistry()

  withLock registry.pluginsLock:
    result = registry.plugins

proc isPluginCompatible*(plugin: PluginRegistration, queryKind: HookKind): bool =
  ## Check if plugin is compatible with the query type
  ##
  ## A plugin is compatible if:
  ## - Its kind matches the query kind exactly
  ## - Its kind is hkAny (compatible with all)
  ## - The query kind is hkAny (not used in practice, but for completeness)

  result = plugin.kind == hkAny or queryKind == hkAny or plugin.kind == queryKind

proc applyQueryResultPlugins*(pluginNames: seq[string], metadata: HookMetadata,
                             items: var seq[(string, string)],
                             nextCursor: var string,
                             hasMore: var bool): bool =
  ## Apply query result plugins to transform query results
  ##
  ## Parameters:
  ##   - pluginNames: Names of plugins to apply (in order)
  ##   - metadata: Query metadata
  ##   - items: Query results (modifiable)
  ##   - nextCursor: Cursor for next page (modifiable)
  ##   - hasMore: Whether more items available (modifiable)
  ##
  ## Returns: true if all plugins were found and applied, false otherwise
  ##
  ## Plugins are executed in the order specified by the client.
  ## Returns false if any plugin name is not found or if plugin kind doesn't match.

  if pluginNames.len == 0:
    return true

  let registry = getPluginsRegistry()

  # Collect plugins to call (outside the lock)
  var pluginsToCall: seq[QueryResultHook]

  withLock registry.pluginsLock:
    for name in pluginNames:
      if name notin registry.nameIndex:
        return false
      let plugin = registry.nameIndex[name]
      if not plugin.isPluginCompatible(metadata.hookKind):
        return false
      pluginsToCall.add(plugin.hook)

  # Call plugins outside the lock to avoid deadlock
  for hook in pluginsToCall:
    try:
      hook(metadata, items, nextCursor, hasMore)
    except CatchableError as e:
      echo fmt"[QueryResultHooks] Hook error for {metadata.barrelName}: {e.msg}"

  return true

proc clearAllPlugins*(): void =
  ## Clear all registered plugins (for testing only)

  let registry = getPluginsRegistry()
  withLock registry.pluginsLock:
    registry.plugins.setLen(0)
    registry.nameIndex.clear()
  withLock registry.seqLock:
    registry.seqCounter = 0

proc getPluginCount*(): int =
  ## Get the number of registered plugins
  let registry = getPluginsRegistry()
  withLock registry.pluginsLock:
    return registry.plugins.len
