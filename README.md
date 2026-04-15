
# ghsh

[![Test](https://github.com/litlighilit/ghsh/actions/workflows/ci.yml/badge.svg)](https://github.com/litlighilit/ghsh/actions/workflows/ci.yml)
[![Docs](https://github.com/litlighilit/ghsh/actions/workflows/docs.yml/badge.svg)](https://github.com/litlighilit/ghsh/actions/workflows/docs.yml)
<!--[![Commits](https://img.shields.io/github/last-commit/litlighilit/ghsh?style=flat)](https://github.com/litlighilit/ghsh/commits/)-->

---

[Docs](https://litlighilit.github.io/ghsh/)

ghsh is a shell-like command-line client for browsing GitHub repository contents.
It supports interactive navigation and one-shot commands for listing directories
and reading files directly from the GitHub Contents API.

## Features

- Browse a repository in REPL mode with ls, cd, pwd, and cat commands.
- Run one-shot commands for scripting: ls, cat, pwd.
- Select any git ref with --ref.
- Authenticate with a token using --token or GITHUB_TOKEN.

## Install

```bash
nimble install
```

Or build locally:

```bash
nimble build
```

## Usage

Start interactive mode:

```bash
ghsh nim-lang/Nim
```

List directory contents:

```bash
ghsh nim-lang/Nim ls lib
```

Print a file:

```bash
ghsh nim-lang/Nim cat README.md
```

Use a branch or commit:

```bash
ghsh --ref=devel nim-lang/Nim ls
```

Use a token to avoid low unauthenticated rate limits:

```bash
ghsh --token=$GITHUB_TOKEN nim-lang/Nim ls
```

## Development

Run tests:

```bash
nimble test
```





