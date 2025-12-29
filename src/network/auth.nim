## JWT Authentication Module for BitBarrel
##
## Provides token generation and verification for static-secret JWT authentication.
## Uses HS256 algorithm with a configurable secret.

import std/[times, strformat, options, tables, strutils, json]
import jwt

type
  Role* = enum
    rAdmin = "admin"
    rReadWrite = "readwrite"
    rReadonly = "readonly"

  AuthSession* = object
    username*: string
    roles*: seq[Role]
    authenticated*: bool
    issuedAt*: int64
    expiresAt*: int64

  AuthConfig* = object
    enabled*: bool
    secret*: string
    users*: Table[string, seq[Role]]
    defaultTokenExpiryHours*: int

  AuthError* = object of CatchableError

const
  MinSecretLength = 32

proc parseRole*(s: string): Role =
  case s.toLowerAscii()
  of "admin": result = rAdmin
  of "readwrite": result = rReadWrite
  of "readonly": result = rReadonly
  else: raise newException(AuthError, fmt("Invalid role: {s}"))

proc generateToken*(config: AuthConfig, username: string): string =
  ## Generate a JWT token for the given username
  if not config.enabled:
    raise newException(AuthError, "Authentication is disabled")

  if username notin config.users:
    raise newException(AuthError, fmt("User not found: {username}"))

  if config.secret.len < MinSecretLength:
    raise newException(AuthError, "Invalid secret (too short)")

  let roles = config.users[username]
  var roleStrs: seq[string] = @[]
  for r in roles:
    roleStrs.add($r)

  let now = getTime().toUnix()
  let expiresAt = now + (config.defaultTokenExpiryHours * 3600)

  var token = toJWT(%*{
    "header": {
      "alg": "HS256",
      "typ": "JWT"
    },
    "claims": {
      "sub": username,
      "roles": %*roleStrs,
      "iat": now,
      "exp": expiresAt
    }
  })
  token.sign(config.secret)
  result = $token

proc verifyToken*(config: AuthConfig, tokenStr: string): AuthSession =
  ## Verify a JWT token and extract session data
  ##
  ## Returns AuthSession with authenticated=true if token is valid
  ## Returns AuthSession with authenticated=false if authentication is disabled
  ## Raises AuthError if token is invalid, expired, or user not found
  if not config.enabled:
    return AuthSession(authenticated: false)

  if config.secret.len < MinSecretLength:
    raise newException(AuthError, "Invalid secret configuration")

  try:
    let jwt = tokenStr.toJWT()
    if not jwt.verify(config.secret, HS256):
      raise newException(AuthError, "Invalid token signature")

    jwt.verifyTimeClaims()

    let claims = jwt.claims
    if not claims.hasKey("sub") or not claims.hasKey("roles"):
      raise newException(AuthError, "Invalid token claims")

    let username = claims["sub"].node.getStr()
    if username notin config.users:
      raise newException(AuthError, fmt("User not found: {username}"))

    let roleNodes = claims["roles"].node.getElems()
    var roles: seq[Role] = @[]
    for node in roleNodes:
      roles.add(parseRole(node.getStr()))

    let issuedAt = if claims.hasKey("iat"): claims["iat"].node.getStr().parseInt() else: 0
    let expiresAt = if claims.hasKey("exp"): claims["exp"].node.getStr().parseInt() else: 0

    return AuthSession(
      username: username,
      roles: roles,
      authenticated: true,
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
  except AuthError:
    raise
  except Exception as e:
    raise newException(AuthError, fmt("Token verification failed: {e.msg}"))

proc hasPermission*(authSession: AuthSession, requiredRoles: set[Role]): bool =
  ## Check if the auth session has any of the required roles
  if not authSession.authenticated:
    return false

  for role in authSession.roles:
    if role in requiredRoles:
      return true
  return false

proc canManageBarrels*(authSession: AuthSession): bool =
  ## Check if user can manage barrels (create, open, drop)
  if not authSession.authenticated:
    return true
  authSession.hasPermission({rAdmin})

proc canWriteData*(authSession: AuthSession): bool =
  ## Check if user can write data (SET, DELETE)
  if not authSession.authenticated:
    return true
  authSession.hasPermission({rAdmin, rReadWrite})

proc canReadData*(authSession: AuthSession): bool =
  ## Check if user can read data (GET, EXISTS, COUNT, RANGE_QUERY, PREFIX_QUERY)
  if not authSession.authenticated:
    return true
  authSession.hasPermission({rAdmin, rReadWrite, rReadonly})
