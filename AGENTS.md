# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## This project

- The library lives in the repository root (`kupas/mails`); the executable is
  `cmd/mails/` and only calls `@mailslib.main_cli()`. Keep logic in the library
  so it is testable without spawning the binary.
- `mails.toml` and `.env` are resolved **next to the executable**, not in a
  global config directory. Do not add XDG lookups; `--config` and
  `MAILS_CONFIG` are the only overrides.
- Passwords in the config are `enc:v1:` envelopes sealed with AES-256-GCM
  (`crypto.mbt`). Never write a plaintext password from code, logs or tests.
- IMAP lives in `imap.mbt` (protocol, IDLE, literals), MIME parsing in
  `mime.mbt`, rule matching in `filter.mbt`, and process execution in
  `action.mbt`. Keep those boundaries when adding features.
- The version is duplicated in `cli.mbt`, `moon.mod` and `npmjs/package.json`.
  CI (`Check version consistency`) and the release job fail if they differ, so
  bump all three together before tagging.
- `moon check --target native --deny-warn` and `moon test --target native` must
  both pass. Run `moon info && moon fmt` before finishing.
