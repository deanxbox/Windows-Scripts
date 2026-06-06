# JSON to TOON Performance Design

## Goal

Improve `ConvertTo-Toon.ps1` for both large individual JSON documents and collections of many JSON files while preserving official TOON compatibility, bounded-memory conversion, structured results, and safe overwrite behavior.

## Confirmed Official CLI Behavior

The official `@toon-format/cli` streams JSON input and TOON output. For JSON-to-TOON conversion:

- JSON is parsed incrementally.
- TOON lines are written incrementally.
- Peak memory scales primarily with nested structure depth rather than total document size.
- Arbitrary nested JSON and top-level arrays are supported.
- `--stats` must remain disabled because token statistics require building the full encoded output.

Therefore, no custom streaming JSON parser or TOON encoder is required.

## Dependency Model

Add a repository-local Node package:

```json
{
  "private": true,
  "devDependencies": {
    "@toon-format/cli": "2.3.0"
  }
}
```

Version `2.3.0`, the current stable release as of June 6, 2026, will be pinned in both `package.json` and the generated lockfile.

Executable resolution order:

1. Repository-local TOON executable beneath `node_modules/.bin`.
2. `npx --no-install @toon-format/cli` when the local package exists but direct executable resolution is unavailable.
3. Existing `npx @toon-format/cli` behavior as a compatibility fallback when dependencies have not been installed.

The result and error output will identify which execution mode was used when dependency resolution fails.

## Concurrency Interface

Add:

```powershell
[ValidateRange(0, 64)]
[int]$ThrottleLimit = 0
```

Semantics:

- `0`: automatic concurrency.
- `1`: sequential conversion.
- `2` through `64`: explicit maximum concurrent conversions.

Automatic concurrency is:

```text
min(number of source files, logical processor count, 8)
```

At least one worker is always used.

Parallelism applies across files. A single JSON file is converted by one official CLI process, whose internal streaming handles large-file memory efficiency. The script will not split one JSON document into independently encoded fragments because doing so could change TOON array lengths, schemas, ordering, and canonical output.

## Parallel Execution Architecture

Discovery and destination mapping remain deterministic and run before conversion starts.

Each conversion becomes an independent work item containing:

- Source path
- Final destination path
- Temporary destination path
- CLI executable and argument mode
- Overwrite permission

PowerShell runspaces will process work items with the selected throttle limit. Runspaces are preferred over `Start-Job` because they have substantially lower startup and serialization overhead.

Results will be returned in source discovery order, regardless of completion order. Each result retains:

- `SourcePath`
- `DestinationPath`
- `Succeeded`
- `Error`

Optional timing metadata will be added:

- `DurationMilliseconds`

This supports performance measurement without changing success semantics.

## Atomic Output Handling

Each worker writes to a uniquely named temporary file in the final destination directory:

```text
.<destination-name>.<guid>.tmp
```

On successful CLI completion:

1. Verify the temporary file exists.
2. If the final destination exists:
   - Fail unless `-Force` was supplied.
   - With `-Force`, replace the final destination.
3. Move the completed temporary file to the final `.toon` path.

On any failure:

- Remove only the worker's verified temporary file.
- Preserve any existing final destination.
- Return a failed structured result.

Writing the temporary file in the destination directory ensures the final move stays on the same filesystem and can use atomic rename semantics.

## Validation and Error Handling

Before starting workers:

1. Resolve the input path.
2. Discover JSON source files.
3. Resolve the CLI execution mode.
4. Compute all final destination paths.
5. Detect duplicate destinations before conversion.
6. Reject existing destinations unless `-Force` is supplied.
7. Calculate the effective throttle limit.

Failures during preflight are terminating invocation errors. Worker failures remain per-file structured results and cause direct script execution to return exit code `1`.

The script must not:

- Evaluate user paths as PowerShell command text.
- Run `--stats`.
- delete an existing destination before a successful temporary conversion exists.
- leave temporary files after handled failures.
- recursively rediscover files inside a nested output directory.

## Testing

Pester tests will be written before implementation changes.

New coverage:

- Automatic throttle calculation is capped by file count, processor count, and eight.
- Explicit `-ThrottleLimit 1` runs sequentially.
- Explicit values above one permit concurrent work.
- Result ordering matches discovery ordering even when workers finish out of order.
- Multiple worker failures are individually reported.
- A successful conversion atomically publishes the temporary output.
- CLI failure removes its temporary output.
- `-Force` preserves the old destination when conversion fails.
- Duplicate destination mapping is rejected before conversion.
- The local pinned executable is preferred over fallback `npx`.
- Fallback `npx` remains supported when local dependencies are absent.
- Paths containing spaces continue to work in parallel mode.
- A large nested JSON integration fixture converts successfully without `--stats`.

The fake CLI used by tests will support configurable delays, failure modes, invocation logging, and temporary-output creation. Tests will verify actual overlap using timestamps or synchronized marker files rather than relying only on elapsed wall-clock assumptions.

## Documentation

Update `Readme.md` with:

- `npm install` as the recommended setup step for the pinned CLI.
- Automatic parallel conversion behavior.
- `-ThrottleLimit 1` for sequential conversion.
- Explicit throttle examples.
- Explanation that one large file uses official streaming while multiple files use parallel workers.
- Warning that `--stats` is intentionally not exposed for large-file memory efficiency.
- Compatibility fallback behavior when local dependencies are absent.

## Completion Criteria

1. All converter and repository Pester tests pass.
2. PSScriptAnalyzer reports no diagnostics for the converter and its tests.
3. A real multi-file conversion succeeds through the pinned local CLI.
4. A real large nested JSON fixture converts successfully.
5. Direct failed execution returns exit code `1`.
6. No temporary output files remain after tested failures.
7. CodeRabbit review is run when its CLI is available.
8. Codex Security reviews external process arguments, temporary files, overwrite races, output containment, and untrusted JSON handling.
