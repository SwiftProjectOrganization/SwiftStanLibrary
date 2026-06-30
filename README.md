# SwiftStanLibrary

A reusable, distributable Swift library for orchestrating [cmdstan](https://mc-stan.org/docs/2_37/cmdstan-guide/) and generating Stan models from a Swift DSL. macOS 14+; Swift 6. No external dependencies.

Extracted and curated from [SwiftStan](https://github.com/SwiftProjectOrganization/SwiftStan), which also bundles a command-line tool. This package is library-only.

**Swift Package Manager:**
```swift
.package(url: "https://github.com/SwiftProjectOrganization/SwiftStanLibrary", from: "1.1.0")
```
**Xcode:** File → Add Package Dependencies → `https://github.com/SwiftProjectOrganization/SwiftStanLibrary` → add product `SwiftStan`.

## Products

- **`SwiftStan`** — the library module (import as `import SwiftStan`).

## Public API

### cmdstan commands (return `(status: String, error: String)`)

| Function | Description |
|---|---|
| `compile(model:arguments:cmdstan:verbose:install:force:)` | Compile a Stan model via `make` |
| `sample(model:arguments:cmdstan:verbose:nosummary:install:)` | Run HMC/NUTS sampling |
| `optimize(model:arguments:cmdstan:verbose:)` | MAP optimization |
| `pathfinder(model:arguments:cmdstan:verbose:)` | Pathfinder variational |
| `laplace(model:arguments:cmdstan:verbose:)` | Laplace approximation |
| `generated_Quantities(model:arguments:cmdstan:verbose:)` | Post-sampling generated quantities |
| `stansummary(model:arguments:cmdstan:verbose:)` | Run cmdstan's `stansummary` |
| `ulam(_:name:cmdstan:verbose:arguments:)` | DSL model → compile → sample (in-memory, no alist.R needed) |
| `ulamPipeline(model:cmdstan:verbose:force:arguments:)` | Full pipeline: alist→Stan→compile→sample |

All cmdstan commands take `cmdstan: String` (path to the cmdstan installation) and `model: String` (name of the case under `~/Documents/StanCases/`, configurable via `$STAN_CASES`). They return `(String, String)` — `.0` is a human-readable status, `.1` is an error message (`""` on success).

### File-translation commands (`throws → URL`)

| Function | Description |
|---|---|
| `stancode(model:verbose:)` | alist.R → Stan source (in-process, fast) |
| `stan2alist(model:verbose:force:)` | Stan source → alist.R (reverse) |
| `alist2dsl(model:verbose:)` | alist.R → Swift result-builder DSL driver |
| `csv2json(model:verbose:)` | CSV data file → data.json for cmdstan |
| `runinfo(model:verbose:)` | Clean and rewrite the cmdstan run-info JSON |

### Swift DSL (result-builder API)

Build Stan models directly in Swift without an R alist file:

```swift
import SwiftStan

let model = UlamModel(data: ["y": .integer([0,1,0,1,1]), "x": .real([1.0,2.0,3.0,4.0,5.0])]) {
  Likelihood("y", .bernoulli(p: "p"))
  Link(.logit, lhs: "p", rhs: "a + b*x")
  Prior("a", .normal(0, 1.5))
  Prior("b", .normal(0, 0.5))
}

let stanCode = try stancode(model)  // → Stan source String
```

### Path resolution

All commands read/write under `$STAN_CASES/<name>/{Preliminaries,Results}/` (default `~/Documents/StanCases/`). Use `casePaths(for: model)` to navigate the layout. Run info is accessible via `readRunInfo(dirUrl:modelName:)`.

## Constraints

- macOS 14+ only — the library shells out to `make`, `swiftc`, and cmdstan binaries via `Foundation.Process`.
- `dsl2stan` is **not** included (it requires the package source tree to recompile via `swiftc`). The in-process `stancode` path covers alist→Stan without `swiftc`.
- `$CMDSTAN` must point to a cmdstan installation; alternatively pass the path explicitly to each command.

## Building

```bash
swift build
swift test                              # unit tests only (no cmdstan required)
CMDSTAN=/path/to/cmdstan swift test    # unit + integration tests
```

## License

MIT — see [LICENSE](LICENSE).
