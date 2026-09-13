# Named-model generated consumers

```sh
bash Tests/NamedModels/smoke.sh
bash Tests/NamedModels/entry-points.sh
```

The generator emits paired named and legacy schemas from the same fixtures.
The script builds them as a separate `GeneratedModels` library and imports that
library from an executable, so public types, initializers, and `Sendable`
conformances must actually work across a module boundary.

The consumer exercises empty/singleton/nested objects, optional-null distinction,
typed arrays/dictionaries/extras, required-only properties, arbitrary JSON field
labels, semantic discriminator cases, distinct equal-shaped union payloads,
first-valid `anyOf` selection, scalar aliases, prefix arrays, and recursive
struct/class/union/dynamic-reference output. Positive and invalid nested inputs
are checked against the real runtime; validation definitions must also be equal
between representations.

String-enum fixtures compile both named and unchanged tuple output. Public
consumers exercise explicit, inferred, and nullable roots; `RawRepresentable`,
`Hashable`, and `Sendable`; `draft`/`inProgress`/`done` cases; reference reuse versus
distinct equal definitions; arrays, dictionaries, additional properties, and
optional nullable enum fields (`T??`). They also cover enum-valued reference
specialization, validation-only `const`/`pattern` refinements, the first enum bound
of `allOf` (not a minimized intersection), and separate typed enum payloads in
`anyOf`/`oneOf`, including overlap and first-valid branch behavior.

Raw string comparisons use explicit Unicode-scalar arrays. Composed/decomposed
spellings remain distinct enum cases and `Set` entries, while public raw
initializers and parsed outputs must preserve each spelling exactly. Absent
normalization variants must be rejected. Empty/digit/punctuation/keyword/escaped
values and generated-member name collisions compile; byte-identical duplicates
share a case while both `/enum/<index>` overrides are consumed. Reserved member
overrides are rejected. Empty, null-only, mixed non-string, const-only, and
unconstrained schemas retain their legacy representations. Curated valid and
invalid inputs check actual validation and `parseAndValidate` in both modes,
not just generated text.

The entry-point script compiles CLI output in a separate `GeneratedCLI` library,
including tuple output, and imports target-local plugin output from a separate
`PluginModels` library. It checks configured enum type names and `/enum/<index>`
case names, mode-switch configuration invalidation and restoration, and the
existing configuration-only plugin target. The OpenAPI options fixture verifies
enum field overrides using original `#/components/schemas/...` selectors alongside
its object and union overrides.

Generation is repeated with a relocated retrieval URI and the same logical
document name to detect checkout-dependent output. Inline linked-list and mutual
object cycles must fail under `.valueTypes` and compile under the explicit
`.immutableClasses` policy. Compiler-negative consumers verify that required
nullable constructor arguments cannot be omitted and the legacy public
`Reference1` adapter is unavailable in named mode.

The script uses the published `swift-json-schema` runtime required by the root
package (0.14.0 or later). For upstream development it can reuse
`JSON_SCHEMA_RUNTIME_PATH` or the root editable runtime checkout through
`Tests/Support/runtime.sh`; neither override is required.

For full keyword and reference parity, run
`Tests/Conformance/run.sh --compare-models --recursive-objects immutable-classes`.
The official meta-schema and design-token plugin examples opt into model mode
using their target-local configuration files.
