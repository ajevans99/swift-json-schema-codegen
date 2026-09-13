# Named-model generated consumers

```sh
bash Tests/NamedModels/smoke.sh
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
