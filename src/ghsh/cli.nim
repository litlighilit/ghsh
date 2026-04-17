import std/[algorithm, httpclient, json, logging, os, osproc, parseopt, rdstdin, strutils, tables, tempfiles]

when not defined(windows):
  import std/linenoise

import ./submodule

const
  DefaultGitRef = "HEAD"
  GithubTokenEnvVar = "GITHUB_TOKEN"
  PagerEnvVar = "PAGER"
  RepositorySeparator = "/"
  ErrorPrefix = "error: "
  PromptSuffix = "$ "
  HistoryFileName = ".ghsh_history"
  HistoryMaxEntries = 500
  CommandRepl = "repl"
  CommandLs = "ls"
  CommandCd = "cd"
  CommandCat = "cat"
  CommandLess = "less"
  CommandPwd = "pwd"
  CommandFind = "find"
  CommandGrep = "grep"
  CommandSwitch = "switch"
  HelpLongOption = "help"
  RefLongOption = "ref"
  TokenLongOption = "token"
  HelpShortOption = 'h'
  RootPath = "/"
  SpaceSeparator = " "
  EmptyValue = ""
  FindResultLimit = 10
  GrepResultLimit = 100
  BuiltinPageSize = 30
  ReplHelpText = "Commands: ls [path], cd [path], cat <path>, less <path>, grep <text>, find <query>, switch <owner/repo>, pwd, help, exit"
  UsageText = """
ghsh - interactive shell for browsing GitHub repositories

Usage:
  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo>
  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo> <command> [path]

Commands:
  repl          Start interactive shell mode (default)
  ls [path]     List files in the current directory or path
  cat <path>    Print file contents
  less <path>   View file contents page by page
  pwd           Print current repository path
  grep <text>   Search text inside repository files
  find <query>  Search public repositories on GitHub
  switch <slug> Switch to another repository in REPL

Examples:
  ghsh nim-lang/Nim
  ghsh nim-lang/Nim ls lib
  ghsh --ref=devel nim-lang/Nim cat README.md
"""

type
  CommandKind* = enum
    ckRepl,
    ckLs,
    ckCat,
    ckLess,
    ckPwd,
    ckFind,
    ckGrep,
    ckSwitch

  CliConfig* = object
    gitRef*: string
    token*: string
    repoSlug*: string
    command*: CommandKind
    argument*: string

  ReplCache = object
    directoryEntries: Table[string, seq[RepoEntry]]

when not defined(windows):
  var gCompletionSession: ptr GhShSession
  var gCompletionCache: ptr ReplCache
  var gHistoryPath: string

var gLoggerInitialized = false

proc printUsage*() =
  echo UsageText

proc ensureLoggerInitialized() =
  if gLoggerInitialized:
    return
  addHandler(newConsoleLogger(fmtStr = "$msg"))
  gLoggerInitialized = true

proc parseCommandKind(commandName: string): CommandKind =
  case commandName.toLowerAscii()
  of CommandRepl:
    ckRepl
  of CommandLs:
    ckLs
  of CommandCat:
    ckCat
  of CommandLess:
    ckLess
  of CommandPwd:
    ckPwd
  of CommandFind:
    ckFind
  of CommandGrep:
    ckGrep
  of CommandSwitch:
    ckSwitch
  else:
    raise newException(ValueError, "unknown command: " & commandName)

proc initReplCache(): ReplCache =
  result.directoryEntries = initTable[string, seq[RepoEntry]]()

proc parseReplInput(inputLine: string): tuple[command: string, argument: string] =
  let trimmed = inputLine.strip()
  if trimmed.len == 0:
    return (EmptyValue, EmptyValue)

  let firstSpaceIndex = trimmed.find({' ', '\t'})
  if firstSpaceIndex < 0:
    return (trimmed, EmptyValue)

  let commandName = trimmed[0 ..< firstSpaceIndex]
  let argumentValue = trimmed[firstSpaceIndex + 1 .. ^1].strip()
  (commandName, argumentValue)

proc splitPathFragment(pathFragment: string): tuple[parentFragment: string, prefix: string, absolute: bool] =
  let absolutePath = pathFragment.startsWith(RepositorySeparator)
  let normalizedFragment = pathFragment.replace('\\', '/')
  let separatorIndex = normalizedFragment.rfind('/')

  if separatorIndex < 0:
    return (EmptyValue, normalizedFragment, absolutePath)

  if separatorIndex == normalizedFragment.high:
    return (normalizedFragment, EmptyValue, absolutePath)

  (normalizedFragment[0 .. separatorIndex], normalizedFragment[separatorIndex + 1 .. ^1], absolutePath)

proc listDirectoryCached(session: GhShSession, cache: var ReplCache, absolutePath: string): seq[RepoEntry] =
  if cache.directoryEntries.hasKey(absolutePath):
    return cache.directoryEntries[absolutePath]

  var rootSession = session
  rootSession.cwd = EmptyValue
  let fetchedEntries = listDirectory(rootSession, absolutePath)
  cache.directoryEntries[absolutePath] = fetchedEntries
  fetchedEntries

proc completePathArgument(session: GhShSession, cache: var ReplCache, commandName: string, argument: string): seq[string] =
  if commandName != CommandLs and commandName != CommandCd and commandName != CommandCat and commandName != CommandLess:
    return @[]

  let (parentFragment, prefix, isAbsolute) = splitPathFragment(argument)
  let absoluteParent =
    if isAbsolute:
      normalizeRepoPath(parentFragment)
    else:
      resolveRepoPath(session.cwd, parentFragment)

  let entries = listDirectoryCached(session, cache, absoluteParent)
  var matches: seq[string] = @[]

  for entry in entries:
    if not entry.name.startsWith(prefix):
      continue

    var suggestion =
      if parentFragment.len == 0:
        entry.name
      elif parentFragment.endsWith(RepositorySeparator):
        parentFragment & entry.name
      else:
        parentFragment & RepositorySeparator & entry.name

    if entry.kind == ekDir:
      suggestion &= RepositorySeparator
    if isAbsolute and not suggestion.startsWith(RepositorySeparator):
      suggestion = RepositorySeparator & suggestion
    matches.add(suggestion)

  if matches.len == 0:
    return @[]

  matches.sort(system.cmp[string])
  for match in matches:
    result.add(commandName & SpaceSeparator & match)

proc completeCommand(commandPrefix: string): seq[string] =
  let commands = @[CommandLs, CommandCd, CommandCat, CommandLess, CommandGrep, CommandFind, CommandSwitch, CommandPwd, "help", "exit", "quit"]
  var matches: seq[string] = @[]

  for commandName in commands:
    if commandName.startsWith(commandPrefix):
      matches.add(commandName)

  if matches.len == 0:
    return @[]

  matches.sort(system.cmp[string])
  result = matches

proc collectCompletionSuggestions(session: GhShSession, cache: var ReplCache, line: string): seq[string] =
  let hasTrailingSpace = line.len > 0 and line[^1].isSpaceAscii()
  let leftTrimmedLine = line.strip(leading = true, trailing = false)
  if leftTrimmedLine.len == 0:
    return completeCommand(EmptyValue)

  let firstSpaceIndex = leftTrimmedLine.find({' ', '\t'})
  if firstSpaceIndex < 0:
    return completeCommand(leftTrimmedLine.toLowerAscii())

  let commandName = leftTrimmedLine[0 ..< firstSpaceIndex].toLowerAscii()
  var argument = leftTrimmedLine[firstSpaceIndex + 1 .. ^1]
  if not hasTrailingSpace:
    argument = argument.strip()

  if argument.len == 0 and not hasTrailingSpace:
    return completeCommand(commandName)

  let pathSuggestions = completePathArgument(session, cache, commandName, argument)
  if pathSuggestions.len > 0:
    return pathSuggestions

  if argument.len == 0:
    return completeCommand(commandName)

  @[]

when not defined(windows):
  proc ghshCompletionCallback(line: cstring, completions: ptr Completions) {.cdecl.} =
    if gCompletionSession.isNil or gCompletionCache.isNil:
      return

    try:
      let suggestions = collectCompletionSuggestions(gCompletionSession[], gCompletionCache[], $line)
      for suggestion in suggestions:
        addCompletion(completions, suggestion.cstring)
    except HttpRequestError:
      discard
    except JsonParsingError:
      discard
    except ValueError:
      discard
    except OSError:
      discard

  proc initReplHistory() =
    gHistoryPath = getHomeDir() / HistoryFileName
    discard historySetMaxLen(HistoryMaxEntries)
    discard historyLoad(gHistoryPath.cstring)

  proc saveReplHistory() =
    if gHistoryPath.len > 0:
      discard historySave(gHistoryPath.cstring)

  proc addReplHistoryEntry(line: string) =
    if line.len > 0:
      discard historyAdd(line.cstring)

else:
  proc initReplHistory() =
    discard

  proc saveReplHistory() =
    discard

  proc addReplHistoryEntry(line: string) =
    discard line

proc runFind(session: GhShSession, query: string) =
  let results = searchRepositories(session, query, FindResultLimit)
  if results.len == 0:
    echo "no repositories found"
    return

  for repo in results:
    let description = if repo.description.len == 0: "(no description)" else: repo.description
    echo repo.fullName & " | ★" & $repo.stars
    echo "  " & repo.url
    echo "  " & description

proc runGrep(session: GhShSession, pattern: string) =
  let matches = grepRepository(session, pattern, GrepResultLimit)
  if matches.len == 0:
    echo "no matches found"
    return

  for match in matches:
    echo match.path & ":" & $match.lineNumber & ": " & match.lineText

proc defaultPagerCommand(): string =
  when defined(windows):
    "more"
  else:
    "less"

proc resolvePagerCommand(): string =
  let fromEnv = getEnv(PagerEnvVar, EmptyValue).strip()
  if fromEnv.len > 0 and fromEnv.find({' ', '\t'}) < 0:
    return fromEnv
  defaultPagerCommand()

proc runBuiltinPager(text: string) =
  let lines = text.splitLines()
  if lines.len == 0:
    return

  var shown = 0
  while shown < lines.len:
    let pageEnd = min(shown + BuiltinPageSize, lines.len)
    for index in shown ..< pageEnd:
      echo lines[index]

    shown = pageEnd
    if shown >= lines.len:
      break

    var input = EmptyValue
    if not readLineFromStdin("--More-- [Enter/q]: ", input):
      break
    if input.toLowerAscii().startsWith("q"):
      break

proc runLess(session: GhShSession, pathArg: string) =
  if pathArg.len == 0:
    raise newException(ValueError, "less requires a file path")

  let text = readFileText(session, pathArg)
  let pagerCommand = resolvePagerCommand()
  let (tempFile, tempPath) = createTempFile("ghsh_less_", ".tmp")
  try:
    tempFile.write(text)
    tempFile.close()

    let pager = startProcess(
      command = pagerCommand,
      args = @[tempPath],
      options = {poParentStreams, poUsePath}
    )
    try:
      let exitCode = waitForExit(pager)
      if exitCode != 0:
        raise newException(ValueError, "less exited with status " & $exitCode)
    finally:
      close(pager)
  except OSError as exc:
    if pagerCommand != defaultPagerCommand():
      error ErrorPrefix & "failed to launch pager from " & PagerEnvVar & ": " & exc.msg
    runBuiltinPager(text)
  finally:
    try:
      removeFile(tempPath)
    except OSError:
      discard

proc runSwitch(session: var GhShSession, cache: var ReplCache, repoSlug: string) =
  if repoSlug.strip().len == 0:
    raise newException(ValueError, "switch requires owner/repo")

  switchRepository(session, repoSlug)
  cache.directoryEntries.clear()
  echo "switched to " & session.owner & RepositorySeparator & session.repo

proc parseCli*(argv: seq[string]): CliConfig =
  result.gitRef = DefaultGitRef
  result.token = getEnv(GithubTokenEnvVar, EmptyValue)

  var positional: seq[string] = @[]
  for kind, key, val in getopt(argv, shortNoVal = {HelpShortOption}, longNoVal = @[HelpLongOption]):
    case kind
    of cmdEnd:
      break
    of cmdArgument:
      positional.add(key)
    of cmdShortOption, cmdLongOption:
      case key
      of $HelpShortOption, HelpLongOption:
        printUsage()
        quit(0)
      of RefLongOption:
        if val.len == 0:
          raise newException(ValueError, "--ref requires a value. Use --ref=<git-ref>.")
        result.gitRef = val
      of TokenLongOption:
        if val.len == 0:
          raise newException(ValueError, "--token requires a value. Use --token=<token>.")
        result.token = val
      else:
        let optionPrefix = if kind == cmdShortOption: "-" else: "--"
        raise newException(ValueError, "unknown option: " & optionPrefix & key)

  if positional.len == 0:
    raise newException(ValueError, "missing repository slug. Use <owner/repo>.")

  result.repoSlug = positional[0]
  if positional.len > 1:
    result.command = parseCommandKind(positional[1])
  else:
    result.command = ckRepl

  if positional.len > 2:
    result.argument = positional[2 .. ^1].join(SpaceSeparator)

proc entryLabel(kind: EntryKind): string =
  case kind
  of ekDir:
    "d"
  of ekFile:
    "f"
  of ekSymlink:
    "l"
  of ekSubmodule:
    "m"
  of ekUnknown:
    "?"

proc printEntries(entries: seq[RepoEntry]) =
  var sortedEntries = entries
  sortedEntries.sort(proc(a, b: RepoEntry): int =
    let aPriority = if a.kind == ekDir: 0 else: 1
    let bPriority = if b.kind == ekDir: 0 else: 1
    if aPriority != bPriority:
      return cmp(aPriority, bPriority)
    cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
  )

  for entry in sortedEntries:
    echo entryLabel(entry.kind) & "  " & align($entry.size, 8) & "  " & entry.name

proc cwdLabel(session: GhShSession): string =
  if session.cwd.len == 0:
    RepositorySeparator
  else:
    RepositorySeparator & session.cwd

proc runLs(session: GhShSession, pathArg = EmptyValue) =
  let entries = listDirectory(session, pathArg)
  printEntries(entries)

proc runCat(session: GhShSession, pathArg: string) =
  if pathArg.len == 0:
    raise newException(ValueError, "cat requires a file path")
  stdout.write(readFileText(session, pathArg))

proc runRepl(session: var GhShSession) =
  var cache = initReplCache()

  when not defined(windows):
    gCompletionSession = addr session
    gCompletionCache = addr cache
    setCompletionCallback(ghshCompletionCallback)
    initReplHistory()

  echo "Connected to " & session.owner & RepositorySeparator & session.repo & " @ " & session.gitRef
  echo "Type 'help' for commands."

  try:
    while true:
      var line = EmptyValue
      if not readLineFromStdin(session.owner & RepositorySeparator & session.repo & ":" & cwdLabel(session) & PromptSuffix, line):
        break

      when not defined(windows):
        addReplHistoryEntry(line)

      let commandLine = line.strip()
      if commandLine.len == 0:
        continue

      let (command, arg) = parseReplInput(commandLine)

      case command.toLowerAscii()
      of "help":
        echo ReplHelpText
      of CommandPwd:
        echo cwdLabel(session)
      of CommandLs:
        runLs(session, arg)
      of CommandCd:
        let target = if arg.len == 0: RootPath else: arg
        if not changeDirectory(session, target):
          warn ErrorPrefix & "directory not found: " & target
        else:
          cache.directoryEntries.clear()
      of CommandCat:
        runCat(session, arg)
      of CommandLess:
        runLess(session, arg)
      of CommandGrep:
        runGrep(session, arg)
      of CommandFind:
        runFind(session, arg)
      of CommandSwitch:
        runSwitch(session, cache, arg)
      of "exit", "quit":
        break
      else:
        warn ErrorPrefix & "unknown command: " & command
  finally:
    when not defined(windows):
      saveReplHistory()

proc reportError(message: string) =
  error ErrorPrefix & message

proc runCommand(config: CliConfig) =
  var session = initSession(config.repoSlug, config.gitRef, config.token)

  case config.command
  of ckRepl:
    runRepl(session)
  of ckLs:
    runLs(session, config.argument)
  of ckCat:
    runCat(session, config.argument)
  of ckLess:
    runLess(session, config.argument)
  of ckPwd:
    echo cwdLabel(session)
  of ckFind:
    runFind(session, config.argument)
  of ckGrep:
    runGrep(session, config.argument)
  of ckSwitch:
    var cache = initReplCache()
    runSwitch(session, cache, config.argument)

proc runCli*(argv: seq[string]) =
  ensureLoggerInitialized()
  try:
    runCommand(parseCli(argv))
  except ValueError as exc:
    reportError(exc.msg)
    quit(1)
  except KeyError as exc:
    reportError(exc.msg)
    quit(1)
  except OSError as exc:
    reportError(exc.msg)
    quit(1)
  except HttpRequestError as exc:
    reportError(exc.msg)
    quit(1)
  except JsonParsingError as exc:
    reportError(exc.msg)
    quit(1)
