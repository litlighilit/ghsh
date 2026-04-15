import std/[algorithm, httpclient, json, os, parseopt, strutils]

import ./submodule

const
  DefaultGitRef = "HEAD"
  GithubTokenEnvVar = "GITHUB_TOKEN"
  RepositorySeparator = "/"
  ErrorPrefix = "error: "
  PromptSuffix = "$ "
  CommandRepl = "repl"
  CommandLs = "ls"
  CommandCat = "cat"
  CommandPwd = "pwd"
  HelpLongOption = "help"
  RefLongOption = "ref"
  TokenLongOption = "token"
  HelpShortOption = 'h'
  UsageText = """
ghsh - interactive shell for browsing GitHub repositories

Usage:
  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo>
  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo> <command> [path]

Commands:
  repl          Start interactive shell mode (default)
  ls [path]     List files in the current directory or path
  cat <path>    Print file contents
  pwd           Print current repository path

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
    ckPwd

  CliConfig* = object
    gitRef*: string
    token*: string
    repoSlug*: string
    command*: CommandKind
    argument*: string

proc printUsage*() =
  echo UsageText

proc parseCommandKind(commandName: string): CommandKind =
  case commandName.toLowerAscii()
  of CommandRepl:
    ckRepl
  of CommandLs:
    ckLs
  of CommandCat:
    ckCat
  of CommandPwd:
    ckPwd
  else:
    raise newException(ValueError, "unknown command: " & commandName)

proc parseCli*(argv: seq[string]): CliConfig =
  result.gitRef = DefaultGitRef
  result.token = getEnv(GithubTokenEnvVar, "")

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
    result.argument = positional[2]

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

proc runLs(session: GhShSession, pathArg = "") =
  let entries = listDirectory(session, pathArg)
  printEntries(entries)

proc runCat(session: GhShSession, pathArg: string) =
  if pathArg.len == 0:
    raise newException(ValueError, "cat requires a file path")
  stdout.write(readFileText(session, pathArg))

proc runRepl(session: var GhShSession) =
  echo "Connected to " & session.owner & "/" & session.repo & " @ " & session.gitRef
  echo "Type 'help' for commands."

  while true:
    stdout.write(session.owner & RepositorySeparator & session.repo & ":" & cwdLabel(session) & PromptSuffix)
    stdout.flushFile()

    var line = ""
    if not stdin.readLine(line):
      break

    let commandLine = line.strip()
    if commandLine.len == 0:
      continue

    let parts = commandLine.splitWhitespace()
    let command = parts[0].toLowerAscii()
    let arg = if parts.len > 1: parts[1] else: ""

    case command
    of "help":
      echo "Commands: ls [path], cd [path], cat <path>, pwd, help, exit"
    of "pwd":
      echo cwdLabel(session)
    of "ls":
      runLs(session, arg)
    of "cd":
      let target = if arg.len == 0: "/" else: arg
      if not changeDirectory(session, target):
        stderr.writeLine(ErrorPrefix & "directory not found: " & target)
    of "cat":
      runCat(session, arg)
    of "exit", "quit":
      break
    else:
      stderr.writeLine(ErrorPrefix & "unknown command: " & command)

proc reportError(message: string) =
  stderr.writeLine(ErrorPrefix & message)

proc runCommand(config: CliConfig) =
  var session = initSession(config.repoSlug, config.gitRef, config.token)

  case config.command
  of ckRepl:
    runRepl(session)
  of ckLs:
    runLs(session, config.argument)
  of ckCat:
    runCat(session, config.argument)
  of ckPwd:
    echo cwdLabel(session)

proc runCli*(argv: seq[string]) =
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
