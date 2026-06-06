# JSON to TOON Converter Design

## Goal

Add a PowerShell utility that converts one JSON file or a collection of JSON files to the TOON format using the official Node.js CLI.

## User Interface

The script will be named `ConvertTo-Toon.ps1`.

Examples:

```powershell
.\ConvertTo-Toon.ps1 -Path .\data.json
.\ConvertTo-Toon.ps1 -Path . -Recurse
.\ConvertTo-Toon.ps1 -Path . -Recurse -OutputDirectory .\toon-output
.\ConvertTo-Toon.ps1 -Path .\data.json -Force
```

Parameters:

- `Path`: Required file or directory path. Accepts pipeline input and aliases suitable for filesystem paths.
- `Recurse`: Includes JSON files in descendant directories when `Path` is a directory.
- `OutputDirectory`: Optional destination root. Without it, each `.toon` file is written beside its source JSON file.
- `Force`: Allows an existing destination file to be replaced.

## Conversion Dependency

The script will invoke the official CLI through:

```text
npx @toon-format/cli
```

This avoids implementing or maintaining the TOON grammar locally. Node.js/npm and `npx` must be available. The first invocation may download the package if it is not already cached.

The script will pass each input and output path as separate process arguments rather than constructing a shell command string. This prevents path quoting bugs and command injection.

## File Discovery and Output Mapping

For a file input:

- The input must have a `.json` extension.
- The default destination replaces `.json` with `.toon` in the same directory.
- With `OutputDirectory`, the destination is the named output directory plus the source filename with a `.toon` extension.

For a directory input:

- Discover `*.json` files in that directory.
- Include descendant directories only when `Recurse` is supplied.
- Without `OutputDirectory`, write each `.toon` beside its source.
- With `OutputDirectory`, preserve each source file's path relative to the input directory.
- Create required destination directories.
- Exclude files inside `OutputDirectory` when that directory is located beneath the input directory, preventing accidental rediscovery in future runs.

Destination paths are checked before conversion. Existing files cause a clear error result unless `Force` is supplied.

## Processing and Results

Each source file is processed independently so one failure does not hide the status of other files.

For each attempted conversion, emit a structured object containing:

- `SourcePath`
- `DestinationPath`
- `Succeeded`
- `Error`

Successful conversions have `Succeeded = $true` and no error text. Discovery, validation, process, and output failures have `Succeeded = $false` with actionable error text.

The script will use terminating errors for invalid top-level invocation conditions, such as:

- `Path` does not exist.
- A file input is not JSON.
- `npx` is unavailable.
- No JSON files are found.

Per-file failures are returned as result objects. If any conversion fails, the script will also produce a non-successful process exit status when run as a script, while retaining all emitted result objects.

## Validation and Error Handling

Before conversion:

1. Resolve and validate the input path.
2. Verify `npx` is available.
3. Discover source files.
4. Map and validate destination paths.

For each conversion:

1. Ensure the destination directory exists.
2. Invoke the official CLI with the source path and `-o` destination path.
3. Capture standard output, standard error, and exit code.
4. Verify a destination file was created.
5. Emit the structured result.

The script will not pre-parse and rewrite JSON because the official CLI owns JSON validation and TOON serialization. CLI errors will be surfaced without silently producing partial success.

## Testing

Pester tests will be written before production code and will cover:

- Single-file output beside the source.
- Directory discovery without recursion.
- Recursive discovery.
- Output-directory relative path preservation.
- Rejection of non-JSON file input.
- Missing input paths.
- No discovered JSON files.
- Existing output handling with and without `Force`.
- Missing `npx`.
- CLI failure reporting.
- Successful structured results.
- Paths containing spaces.

External CLI execution will be isolated behind a small internal function so Pester can validate path mapping and error behavior without requiring network access. A final integration check will use the actual CLI on a temporary JSON fixture when Node.js/npm are available.

## Documentation and Completion

`Readme.md` will gain installation requirements, examples, default output behavior, output-directory behavior, and overwrite semantics.

Completion requires:

1. PSScriptAnalyzer passes without unaddressed warnings.
2. All Pester tests pass.
3. A real JSON-to-TOON conversion succeeds.
4. Error and edge paths are reviewed.
5. A focused security review covers external process arguments, filesystem paths, overwrite behavior, and untrusted JSON input.
