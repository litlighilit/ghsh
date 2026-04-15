import unittest
import std/strutils
import ghsh/cli
import ghsh/submodule

suite "ghsh core":
  test "welcome text is descriptive":
    check getWelcomeMessage().contains("ghsh")

  test "parse valid owner repo slug":
    let parsed = parseRepoSlug("nim-lang/Nim")
    check parsed.owner == "nim-lang"
    check parsed.repo == "Nim"

  test "reject invalid owner repo slug":
    expect(ValueError):
      discard parseRepoSlug("nim-lang")
    expect(ValueError):
      discard parseRepoSlug("/Nim")

  test "normalize repository paths":
    check normalizeRepoPath("src//lib/./system") == "src/lib/system"
    check normalizeRepoPath("/src/../tests") == "tests"
    check normalizeRepoPath("\\src\\core") == "src/core"

  test "resolve relative and absolute paths":
    check resolveRepoPath("", "src") == "src"
    check resolveRepoPath("src", "lib") == "src/lib"
    check resolveRepoPath("src/lib", "../tests") == "src/tests"
    check resolveRepoPath("src/lib", "/docs") == "docs"

  test "init session defaults":
    let session = initSession("nim-lang/Nim")
    check session.owner == "nim-lang"
    check session.repo == "Nim"
    check session.gitRef == "HEAD"
    check session.cwd == ""

  test "parse CLI defaults to repl":
    let config = parseCli(@["nim-lang/Nim"])
    check config.repoSlug == "nim-lang/Nim"
    check config.command == ckRepl
    check config.argument == ""
    check config.gitRef == "HEAD"

  test "parse CLI command and options":
    let config = parseCli(@["--ref=main", "--token=secret", "nim-lang/Nim", "ls", "lib"])
    check config.gitRef == "main"
    check config.token == "secret"
    check config.repoSlug == "nim-lang/Nim"
    check config.command == ckLs
    check config.argument == "lib"

  test "parse CLI find command with multi-word query":
    let config = parseCli(@["nim-lang/Nim", "find", "shell", "tooling"])
    check config.command == ckFind
    check config.argument == "shell tooling"

  test "parse CLI grep command":
    let config = parseCli(@["nim-lang/Nim", "grep", "proc", "initSession"])
    check config.command == ckGrep
    check config.argument == "proc initSession"

  test "parse CLI less command":
    let config = parseCli(@["nim-lang/Nim", "less", "README.md"])
    check config.command == ckLess
    check config.argument == "README.md"

  test "parse CLI less command with spaced path":
    let config = parseCli(@["nim-lang/Nim", "less", "docs", "user guide.md"])
    check config.command == ckLess
    check config.argument == "docs user guide.md"

  test "parse CLI switch command":
    let config = parseCli(@["nim-lang/Nim", "switch", "tree-sitter/tree-sitter"])
    check config.command == ckSwitch
    check config.argument == "tree-sitter/tree-sitter"
