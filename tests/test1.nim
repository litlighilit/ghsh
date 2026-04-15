import unittest
import std/strutils
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
