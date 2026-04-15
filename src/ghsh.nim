import std/[algorithm, os, strutils]
import ghsh/submodule

type
  CliOptions = object
    gitRef: string
    token: string

proc printUsage() =
  echo "ghsh - interactive shell for browsing GitHub repositories"
  echo ""
  echo "Usage:"
  echo "  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo>"
  echo "  ghsh [--ref=<git-ref>] [--token=<token>] <owner/repo> <command> [path]"
  echo ""
  echo "Commands:"
  echo "  repl          Start interactive shell mode (default)"
  echo "  ls [path]     List files in the current directory or path"
  echo "  cat <path>    Print file contents"
  echo "  pwd           Print current repository path"
  echo ""
  echo "Examples:"
  echo "  ghsh nim-lang/Nim"
  echo "  ghsh nim-lang/Nim ls lib"
  echo "  ghsh --ref=devel nim-lang/Nim cat README.md"

proc parseArgs(argv: seq[string]): tuple[options: CliOptions, positional: seq[string]] =
  var options = CliOptions(gitRef: "HEAD", token: getEnv("GITHUB_TOKEN", ""))
  var positional: seq[string] = @[]

  for arg in argv:
    if arg == "-h" or arg == "--help":
      printUsage()
      quit(0)
    elif arg.startsWith("--ref="):
      options.gitRef = arg[6 .. ^1]
    elif arg == "--ref":
      raise newException(ValueError, "--ref requires a value, use --ref=<git-ref>")
    elif arg.startsWith("--token="):
      options.token = arg[8 .. ^1]
    elif arg == "--token":
      raise newException(ValueError, "--token requires a value, use --token=<token>")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unknown option: " & arg)
    else:
      positional.add(arg)

  result = (options, positional)

proc entryLabel(kind: EntryKind): string =
  case kind
  of ekDir: "d"
  of ekFile: "f"
  of ekSymlink: "l"
  of ekSubmodule: "m"
  of ekUnknown: "?"

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
    let marker = entryLabel(entry.kind)
    echo marker & "  " & align($entry.size, 8) & "  " & entry.name

proc cwdLabel(session: GhShSession): string =
  if session.cwd.len == 0:
    "/"
  else:
    "/" & session.cwd

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
    stdout.write(session.owner & "/" & session.repo & ":" & cwdLabel(session) & "$ ")
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

    try:
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
          stderr.writeLine("error: directory not found: " & target)
      of "cat":
        runCat(session, arg)
      of "exit", "quit":
        break
      else:
        stderr.writeLine("error: unknown command: " & command)
    except CatchableError as exc:
      stderr.writeLine("error: " & exc.msg)

when isMainModule:
  try:
    let (options, positional) = parseArgs(commandLineParams())
    if positional.len == 0:
      printUsage()
      quit(1)

    let repoSlug = positional[0]
    var session = initSession(repoSlug, options.gitRef, options.token)

    if positional.len == 1:
      runRepl(session)
      quit(0)

    let command = positional[1].toLowerAscii()
    let arg = if positional.len > 2: positional[2] else: ""

    case command
    of "repl":
      runRepl(session)
    of "ls":
      runLs(session, arg)
    of "cat":
      runCat(session, arg)
    of "pwd":
      echo cwdLabel(session)
    else:
      raise newException(ValueError, "unknown command: " & command)
  except CatchableError as exc:
    stderr.writeLine("error: " & exc.msg)
    quit(1)
