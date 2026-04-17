import std/[base64, httpclient, json, logging, sets, strutils, uri]

const
  GithubApiBase = "https://api.github.com/repos/"
  GithubSearchApiBase = "https://api.github.com/search/repositories"
  GithubCodeSearchApiBase = "https://api.github.com/search/code"
  GithubContentsPath = "/contents"
  GithubAcceptHeader = "application/vnd.github+json"
  GithubUserAgent = "ghsh"
  GithubEncodingBase64 = "base64"
  RepoPathSeparatorStr = "/"
  RepoPathSeparator = '/'
  LocalPathSeparator = '\\'
  ParentPathSegment = ".."
  CurrentPathSegment = "."
  FileKind = "file"
  DirectoryKind = "dir"
  SymlinkKind = "symlink"
  SubmoduleKind = "submodule"
  SearchItemsKey = "items"
  SearchStarsKey = "stargazers_count"
  SearchRepoUrlKey = "html_url"
  SearchFullNameKey = "full_name"
  SearchDescriptionKey = "description"
  SearchPathKey = "path"
  RepoQualifierPrefix = " repo:"
  SearchPerPageLimit = 100
  HttpStatusUnauthorized = "401"
  HttpStatusForbidden = "403"
  CodeSearchAuthHint = "Set GITHUB_TOKEN to enable code search."

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

  RepoSearchResult* = object
    fullName*: string
    description*: string
    stars*: int
    url*: string

  GrepMatch* = object
    path*: string
    lineNumber*: int
    lineText*: string

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
  let normalizedSlashes = rawPath.replace(LocalPathSeparator, RepoPathSeparator)

  for part in normalizedSlashes.split(RepoPathSeparator):
    if part.len == 0 or part == CurrentPathSegment:
      continue
    if part == ParentPathSegment:
      if parts.len > 0:
        discard parts.pop()
      continue
    parts.add(part)

  result = parts.join(RepoPathSeparatorStr)

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

proc switchRepository*(session: var GhShSession, repoSlug: string) =
  let (owner, repo) = parseRepoSlug(repoSlug)
  session.owner = owner
  session.repo = repo
  session.cwd = ""

proc entryKindFromApi(kind: string): EntryKind =
  case kind
  of FileKind:
    ekFile
  of DirectoryKind:
    ekDir
  of SymlinkKind:
    ekSymlink
  of SubmoduleKind:
    ekSubmodule
  else: ekUnknown

proc encodePathSegments(path: string): string =
  let cleaned = normalizeRepoPath(path)
  if cleaned.len == 0:
    return ""

  var encoded: seq[string] = @[]
  for segment in cleaned.split(RepoPathSeparator):
    encoded.add(encodeUrl(segment))
  result = encoded.join(RepoPathSeparatorStr)

proc buildContentsUrl(session: GhShSession, path: string): string =
  let encodedPath = encodePathSegments(path)
  var base = GithubApiBase & session.owner & "/" & session.repo & GithubContentsPath
  if encodedPath.len > 0:
    base &= RepoPathSeparatorStr & encodedPath
  if session.gitRef.len > 0:
    base &= "?ref=" & encodeUrl(session.gitRef)
  result = base

proc requestJson(url: string, token: string): JsonNode =
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "User-Agent": GithubUserAgent,
    "Accept": GithubAcceptHeader
  })

  if token.len > 0:
    client.headers["Authorization"] = "Bearer " & token

  let body = client.getContent(url)
  result = parseJson(body)

proc buildRepoSearchUrl(query: string, perPage: int): string =
  GithubSearchApiBase & "?q=" & encodeUrl(query) & "&per_page=" & $perPage

proc buildCodeSearchUrl(session: GhShSession, query: string, perPage: int, page: int): string =
  let scopedQuery = query & RepoQualifierPrefix & session.owner & "/" & session.repo
  GithubCodeSearchApiBase & "?q=" & encodeUrl(scopedQuery) & "&per_page=" & $perPage & "&page=" & $page

proc shouldFallbackFromCodeSearch(errorMessage: string): bool =
  let message = errorMessage.toLowerAscii()
  message.contains(HttpStatusUnauthorized) or message.contains(HttpStatusForbidden)

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
  if itemType != FileKind:
    raise newException(ValueError, "path is not a regular file: /" & absolutePath)

  let encoding = payload{"encoding"}.getStr()
  if encoding != GithubEncodingBase64:
    raise newException(ValueError, "unsupported file encoding: " & encoding)

  let encodedContent = payload{"content"}.getStr().replace("\n", "")
  result = decode(encodedContent)

proc collectFilePaths(session: GhShSession, path: string, files: var seq[string]) =
  var rootSession = session
  rootSession.cwd = ""

  for entry in listDirectory(rootSession, path):
    case entry.kind
    of ekDir:
      collectFilePaths(rootSession, entry.path, files)
    of ekFile:
      files.add(entry.path)
    else:
      discard

proc collectGrepMatches(session: GhShSession, filePaths: seq[string], needle: string, maxMatches: int): seq[GrepMatch] =
  var rootSession = session
  rootSession.cwd = ""

  for filePath in filePaths:
    let text = readFileText(rootSession, filePath)
    var lineNumber = 1

    for line in text.splitLines():
      if line.contains(needle):
        result.add GrepMatch(path: filePath, lineNumber: lineNumber, lineText: line)
        if result.len >= maxMatches:
          return
      inc(lineNumber)

proc searchRepositories*(session: GhShSession, query: string, limit = 10): seq[RepoSearchResult] =
  if query.strip().len == 0:
    raise newException(ValueError, "find requires a non-empty query")

  let payload = requestJson(buildRepoSearchUrl(query, max(limit, 1)), session.token)
  let items = payload{SearchItemsKey}
  if items.kind != JArray:
    raise newException(ValueError, "unexpected GitHub search response")

  for item in items:
    result.add RepoSearchResult(
      fullName: item{SearchFullNameKey}.getStr(),
      description: item{SearchDescriptionKey}.getStr(),
      stars: item{SearchStarsKey}.getInt(0),
      url: item{SearchRepoUrlKey}.getStr()
    )

proc grepRepository*(session: GhShSession, pattern: string, maxMatches = 100): seq[GrepMatch] =
  let needle = pattern.strip()
  if needle.len == 0:
    raise newException(ValueError, "grep requires a non-empty pattern")

  let wantedMatches = max(maxMatches, 1)
  let perPage = min(wantedMatches, SearchPerPageLimit)

  try:
    var page = 1
    var matchedPaths: seq[string] = @[]
    var seenPaths = initHashSet[string]()

    while matchedPaths.len < wantedMatches:
      let payload = requestJson(buildCodeSearchUrl(session, needle, perPage, page), session.token)
      let items = payload{SearchItemsKey}
      if items.kind != JArray:
        raise newException(ValueError, "unexpected GitHub code search response")
      if items.len == 0:
        break

      for item in items:
        let path = item{SearchPathKey}.getStr()
        if path.len == 0 or seenPaths.contains(path):
          continue

        seenPaths.incl(path)
        matchedPaths.add(path)
        if matchedPaths.len >= wantedMatches:
          break

      if items.len < perPage:
        break
      inc(page)

    result = collectGrepMatches(session, matchedPaths, needle, maxMatches)
  except HttpRequestError as exc:
    if not shouldFallbackFromCodeSearch(exc.msg):
      raise

    error CodeSearchAuthHint
    var files: seq[string] = @[]
    collectFilePaths(session, "", files)
    result = collectGrepMatches(session, files, needle, maxMatches)

proc pathExistsAsDirectory*(session: GhShSession, userPath: string): bool =
  let absolutePath = resolveRepoPath(session.cwd, userPath)
  try:
    result = requestJson(buildContentsUrl(session, absolutePath), session.token).kind == JArray
  except HttpRequestError:
    return false
  except JsonParsingError:
    return false
  except ValueError:
    return false

proc changeDirectory*(session: var GhShSession, userPath: string): bool =
  let destination = resolveRepoPath(session.cwd, userPath)
  if destination.len == 0:
    session.cwd = ""
    return true

  if not pathExistsAsDirectory(session, destination):
    return false

  session.cwd = destination
  true
