# Generated-code conformance

This harness generates Swift from the official JSON Schema Test Suite's
non-optional draft 2020-12 cases, compiles a separate consumer, and checks both
validation and typed `parseAndValidate` against each expected result. Generation,
compilation, and runtime failures all make the command fail; rejected schemas
are reported rather than silently skipped.

```sh
bash Tests/Conformance/run.sh

# Run selected keyword files while developing.
bash Tests/Conformance/run.sh type additionalProperties dynamicRef

# Select named output, explicitly allowing immutable classes for inline cycles.
bash Tests/Conformance/run.sh --output-style models \
  --recursive-objects immutable-classes

# Compile both representations, compare schemaValue, and check both parsers.
bash Tests/Conformance/run.sh --compare-models \
  --recursive-objects immutable-classes
```

The default remains tuple output. Named output without `--recursive-objects`
uses the strict value-type policy; representation-policy refusals remain
generation failures. Comparison mode generates both namespaces for every group,
requires structurally equal emitted validation schemas, and evaluates every
instance with both components. It therefore reports twice as many runtime
instance checks as there are unique fixture instances. This is independent of
the supported/failed schema-group count.

The harness looks for `.build/json-schema-test-suite`, then the test-suite
submodule in the resolved `swift-json-schema` checkout. To obtain an independent
fixture checkout (also useful with editable runtime dependencies):

```sh
git clone https://github.com/json-schema-org/JSON-Schema-Test-Suite.git \
  .build/json-schema-test-suite
```

To use a different checkout:

```sh
JSON_SCHEMA_TEST_SUITE=/path/to/JSON-Schema-Test-Suite \
  bash Tests/Conformance/run.sh
```

Remote fixtures with `http://localhost:1234/` identifiers are loaded from the
suite's `remotes` directory and supplied to the generator explicitly. Canonical
2020-12 meta-schema references use the pinned fixtures in `Examples/MetaSchemaExample`.
Nothing starts an HTTP server or retrieves schemas from the network. SwiftPM may need
to resolve package dependencies on the first run.

When developing against an unreleased runtime, the consumer uses the root
package's editable `Packages/swift-json-schema` checkout if present. Set
`JSON_SCHEMA_RUNTIME_PATH` to override that path explicitly. Without an override,
it uses the runtime dependency selected through `JSONSchemaCodegen`.

The fixture checkout determines the test-suite revision. The harness does not
claim that meta-schema self-validation alone proves specification conformance.
Rejection of a custom-dialect case in a default file is still reported as a
generation failure. Optional format assertions and other files under `optional`
are not included in the default run.

With test-suite revision `f6fd52a0a95472e079cbfc6ef7f089702b80e045` and the published
`swift-json-schema` 0.14.0 runtime (no editable overrides), both representations
generate 382 of 384 groups. All 1,296 unique
instances match validation and parsing expectations in both modes: 2,592 checks
and no emitted-schema differences. The two `vocabulary.json` groups use
custom `$schema` dialects, which are explicitly unsupported. Therefore the full
default command currently exits nonzero despite zero runtime mismatches; these
groups are not silently filtered from the result.
