import std/[base64, httpclient, json, strutils, uri]

type
  EntryKind* = enum
    ekFile,
    ekDir,
    ekSymlink,
    ekSubmodule,
    ekUnknown

  RepoEntry* = object
    name*: string
    path*: string
    size*: int
    kind*: EntryKind

  GhShSession* = object
    owner*: string
    repo*: string
    gitRef*: string
    cwd*: string
    token*: string

proc getWelcomeMessage*(): string =
  "ghsh: interactive shell for GitHub repository contents"

proc parseRepoSlug*(slug: string): tuple[owner: string, repo: string] =
  let cleaned = slug.strip()
  let parts = cleaned.split("/")
  if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
    raise newException(ValueError, "repository must look like owner/repo")
  result = (parts[0], parts[1])

proc normalizeRepoPath*(rawPath: string): string =
  var parts: seq[string] = @[]
  let normalizedSlashes = rawPath.replace('\\', '/')

  for part in normalizedSlashes.split('/'):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      if parts.len > 0:
        discard parts.pop()
      continue
    parts.add(part)

  result = parts.join("/")

proc resolveRepoPath*(cwd: string, userPath: string): string =
  let cleanedCwd = normalizeRepoPath(cwd)
  if userPath.len == 0:
    return cleanedCwd

  if userPath.startsWith("/"):
    return normalizeRepoPath(userPath)

  if cleanedCwd.len == 0:
    return normalizeRepoPath(userPath)

  normalizeRepoPath(cleanedCwd & "/" & userPath)

proc initSession*(repoSlug: string, gitRef = "HEAD", token = ""): GhShSession =
  let (owner, repo) = parseRepoSlug(repoSlug)
  result = GhShSession(owner: owner, repo: repo, gitRef: gitRef, cwd: "", token: token)

proc entryKindFromApi(kind: string): EntryKind =
  case kind
  of "file": ekFile
  of "dir": ekDir
  of "symlink": ekSymlink
  of "submodule": ekSubmodule
  else: ekUnknown

proc encodePathSegments(path: string): string =
  let cleaned = normalizeRepoPath(path)
  if cleaned.len == 0:
    return ""

  var encoded: seq[string] = @[]
  for segment in cleaned.split('/'):
    encoded.add(encodeUrl(segment))
  result = encoded.join("/")

proc buildContentsUrl(session: GhShSession, path: string): string =
  let encodedPath = encodePathSegments(path)
  var base = "https://api.github.com/repos/" & session.owner & "/" & session.repo & "/contents"
  if encodedPath.len > 0:
    base &= "/" & encodedPath
  if session.gitRef.len > 0:
    base &= "?ref=" & encodeUrl(session.gitRef)
  result = base

proc requestJson(url: string, token: string): JsonNode =
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "User-Agent": "ghsh",
    "Accept": "application/vnd.github+json"
  })

  if token.len > 0:
    client.headers["Authorization"] = "Bearer " & token

  let body = client.getContent(url)
  result = parseJson(body)

proc listDirectory*(session: GhShSession, userPath = ""): seq[RepoEntry] =
  let absolutePath = resolveRepoPath(session.cwd, userPath)
  let payload = requestJson(buildContentsUrl(session, absolutePath), session.token)

  if payload.kind != JArray:
    raise newException(ValueError, "path is not a directory: /" & absolutePath)

  for item in payload:
    result.add RepoEntry(
      name: item{"name"}.getStr(),
      path: item{"path"}.getStr(),
      size: item{"size"}.getInt(0),
      kind: entryKindFromApi(item{"type"}.getStr())
    )

proc readFileText*(session: GhShSession, userPath: string): string =
  let absolutePath = resolveRepoPath(session.cwd, userPath)
  if absolutePath.len == 0:
    raise newException(ValueError, "cannot read repository root as file")

  let payload = requestJson(buildContentsUrl(session, absolutePath), session.token)
  if payload.kind != JObject:
    raise newException(ValueError, "path is not a file: /" & absolutePath)

  let itemType = payload{"type"}.getStr()
  if itemType != "file":
    raise newException(ValueError, "path is not a regular file: /" & absolutePath)

  let encoding = payload{"encoding"}.getStr()
  if encoding != "base64":
    raise newException(ValueError, "unsupported file encoding: " & encoding)

  let encodedContent = payload{"content"}.getStr().replace("\n", "")
  result = decode(encodedContent)

proc pathExistsAsDirectory*(session: GhShSession, userPath: string): bool =
  try:
    discard listDirectory(session, userPath)
    true
  except CatchableError:
    false

proc changeDirectory*(session: var GhShSession, userPath: string): bool =
  let destination = resolveRepoPath(session.cwd, userPath)
  if destination.len == 0:
    session.cwd = ""
    return true

  if not pathExistsAsDirectory(session, destination):
    return false

  session.cwd = destination
  true
