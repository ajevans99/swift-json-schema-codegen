import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct ModelNameAllocationTests {
  @Test func ordinaryPropertyNamesRemainInModelNamingContext() {
    let provenance = SchemaModelProvenance(
      identity: "item",
      origins: [
        .init(
          pointer: "/properties/components/properties/schemas/properties/item",
          documentURI: nil, logicalDocument: "model.schema.json", resource: "model.schema.json")
      ])
    let (name, context) = SchemaModelGraph.naming(provenance, object: true)
    expectNoDifference(name, "item")
    expectNoDifference(context, ["components", "schemas", "model.schema.json"])
  }

  @Test(arguments: [
    ("User", "User", "user"),
    ("HTTPServer", "HTTPServer", "httpServer"),
    ("URL2Value", "URL2Value", "url2Value"),
    ("someURLValue", "SomeUrlValue", "someUrlValue"),
    ("USER_NAME", "UserName", "userName"),
    ("user-name", "UserName", "userName"),
    ("user.name/path~part", "UserNamePathPart", "userNamePathPart"),
    ("  user   name\n", "UserName", "userName"),
    ("$id", "Id", "id"),
    ("`class`", "Class", "class"),
    ("naïve", "NaVe", "naVe"),
    ("café", "Caf", "caf"),
    ("日本語", "Model", "alternative"),
    ("💛", "Model", "alternative"),
    ("", "Model", "alternative"),
    ("_", "Model", "alternative"),
    ("---", "Model", "alternative"),
    ("123", "Model123", "alternative123"),
    ("123-user", "Model123User", "alternative123User"),
    ("v2_value", "V2Value", "v2Value"),
    ("alternative1", "Alternative1", "alternative1"),
    ("EventsItem", "EventsItem", "eventsItem"),
    ("__value", "Value", "value"),
    ("a\0b", "AB", "aB"),
  ])
  func normalization(preferred: String, type: String, enumCase: String) throws {
    let requests = [SchemaModelNameRequest(id: "model", preferredName: preferred)]
    expectNoDifference(try SchemaModelNames.typeNames(for: requests), ["model": type])
    expectNoDifference(try SchemaModelNames.caseNames(for: requests), ["model": enumCase])
  }

  @Test func requestDefaultsAndEmptyAllocation() throws {
    let request = SchemaModelNameRequest(id: "id", preferredName: "Name")
    expectNoDifference(request.context, [])
    expectNoDifference(request.explicitName, nil)
    expectNoDifference(request.pointer, "")
    expectNoDifference(request.documentURI, nil)
    expectNoDifference(try SchemaModelNames.typeNames(for: []), [:])
    expectNoDifference(try SchemaModelNames.caseNames(for: []), [:])
  }

  @Test(arguments: [
    "String", "Int", "Bool", "Double", "Array", "Dictionary", "Optional", "Void",
    "Never", "Any", "AnyObject", "Sendable", "Schemable", "JSONReference",
    "JSONValue", "JSONSchemaComponent", "JSONComponents", "JSONComposition",
    "JSONBooleanSchema", "JSONProperty", "JSONObject", "JSONArray", "JSONAnyValue",
    "JSONNull", "JSONBoolean", "JSONNumber", "JSONInteger", "JSONString",
    "Foundation", "Swift", "OrderedJSON", "JSONSchemaBuilder", "URL", "UUID",
    "Date", "Data", "Codable", "Result", "Self",
  ])
  func runtimeAndBuiltinTypesAreProtected(name: String) throws {
    let requests = [
      SchemaModelNameRequest(id: "model", preferredName: name, context: ["Document"])
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests), ["model": "Document" + name])
    #expect(throws: SchemaGenerationError.self) {
      try SchemaModelNames.typeNames(for: [
        SchemaModelNameRequest(id: "model", preferredName: "Other", explicitName: name)
      ])
    }
  }

  @Test func callerReservesRootNamespaceAndMembers() throws {
    let requests = [
      SchemaModelNameRequest(id: "root-like", preferredName: "Value", context: ["Nested"]),
      SchemaModelNameRequest(id: "namespace-like", preferredName: "Settings", context: ["Nested"]),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests, reserved: ["Value", "Settings"]),
      ["root-like": "NestedValue", "namespace-like": "NestedSettings"]
    )
    expectNoDifference(
      try SchemaModelNames.typeNames(for: [
        SchemaModelNameRequest(id: "value", preferredName: "Value")
      ]), ["value": "Value"]
    )
    expectNoDifference(
      try SchemaModelNames.caseNames(
        for: [SchemaModelNameRequest(id: "schema", preferredName: "schema", context: ["Response"])],
        reserved: ["schema"]
      ), ["schema": "responseSchema"]
    )
  }

  @Test(arguments: [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
    "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
    "where", "while", "as", "await", "false", "is", "nil", "self", "super",
    "throws", "true", "try", "any", "some",
  ])
  func caseKeywordsAreUnescaped(name: String) throws {
    expectNoDifference(
      try SchemaModelNames.caseNames(for: [
        SchemaModelNameRequest(id: "implicit", preferredName: name)
      ]), ["implicit": name]
    )
    expectNoDifference(
      try SchemaModelNames.caseNames(for: [
        SchemaModelNameRequest(id: "explicit", preferredName: "Other", explicitName: name)
      ]), ["explicit": name]
    )
  }

  @Test(arguments: ["ExactHTTPName", "_privateName", "some_NAME", "case", "__custom", "x09"])
  func explicitOverridesAreExact(name: String) throws {
    let requests = [
      SchemaModelNameRequest(
        id: "model", preferredName: "Ignored", context: ["IgnoredToo"], explicitName: name)
    ]
    expectNoDifference(try SchemaModelNames.typeNames(for: requests), ["model": name])
    expectNoDifference(try SchemaModelNames.caseNames(for: requests), ["model": name])
  }

  @Test(arguments: [
    "", "_", "123Name", "has-dash", "has space", "日本語", "naïve", "`class`", "Self",
    "Foo.Bar", "$name", "name\n", "_JSONSchemaCodegen", "_JSONSchemaCodegenAdapter",
  ])
  func illegalExplicitNamesAreLocatedErrors(name: String) throws {
    let uri = URL(string: "https://example.test/models.json")!
    let requests = [
      SchemaModelNameRequest(
        id: "model", preferredName: "Ignored", explicitName: name,
        pointer: "/$defs/Model", documentURI: uri)
    ]
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let failure = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests, []) })
      expectNoDifference(failure.pointer, "/$defs/Model")
      expectNoDifference(failure.documentURI, uri)
      #expect(failure.message.contains(String(reflecting: name)))
      #expect(failure.message.contains("https://example.test/models.json#/$defs/Model"))
    }
  }

  @Test func explicitNamesWinOverImplicitNames() throws {
    let requests = [
      SchemaModelNameRequest(id: "a", preferredName: "Record", context: ["Nested"]),
      SchemaModelNameRequest(id: "b", preferredName: "Other", explicitName: "Record"),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests), ["a": "NestedRecord", "b": "Record"])
    let cases = [
      SchemaModelNameRequest(id: "a", preferredName: "record", context: ["Nested"]),
      SchemaModelNameRequest(id: "b", preferredName: "Other", explicitName: "record"),
    ]
    expectNoDifference(
      try SchemaModelNames.caseNames(for: cases), ["a": "nestedRecord", "b": "record"])
  }

  @Test func explicitReservedNamesDoNotGetSuffixes() throws {
    let requests = [
      SchemaModelNameRequest(id: "model", preferredName: "Other", explicitName: "Chosen")
    ]
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let failure = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests, ["Chosen"]) })
      #expect(failure.message.contains("Chosen"))
      #expect(failure.message.contains("reserved"))
    }
  }

  @Test func duplicateExplicitNamesReportBothLocations() throws {
    let requests = [
      SchemaModelNameRequest(
        id: "first", preferredName: "First", explicitName: "Shared", pointer: "/$defs/A",
        documentURI: URL(string: "https://example.test/a.json")),
      SchemaModelNameRequest(
        id: "second", preferredName: "Second", explicitName: "Shared", pointer: "/$defs/B",
        documentURI: URL(string: "https://example.test/b.json")),
    ]
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let failure = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests, []) })
      #expect(failure.message.contains("Shared"))
      #expect(failure.message.contains("https://example.test/a.json#/$defs/A"))
      #expect(failure.message.contains("https://example.test/b.json#/$defs/B"))
      let reversed = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests.reversed(), []) })
      expectNoDifference(reversed, failure)
    }
  }

  @Test func identicalIDsCoalesceIncludingExplicitNames() throws {
    for explicitName in [nil, "Pinned"] {
      let request = SchemaModelNameRequest(
        id: "same", preferredName: "Example", context: ["Parent"], explicitName: explicitName)
      expectNoDifference(
        try SchemaModelNames.typeNames(for: [request, request]),
        ["same": explicitName ?? "Example"])
      expectNoDifference(
        try SchemaModelNames.caseNames(for: [request, request]),
        ["same": explicitName ?? "example"])
    }
  }

  @Test(arguments: [
    SchemaModelNameRequest(id: "same", preferredName: "Different"),
    SchemaModelNameRequest(id: "same", preferredName: "Original", context: ["Parent"]),
    SchemaModelNameRequest(id: "same", preferredName: "Original", explicitName: "Pinned"),
    SchemaModelNameRequest(id: "same", preferredName: "Original", pointer: "/other"),
    SchemaModelNameRequest(
      id: "same", preferredName: "Original", documentURI: URL(string: "https://example.test/a")),
  ])
  func conflictingIDMetadataIsRejected(conflict: SchemaModelNameRequest) throws {
    let requests = [SchemaModelNameRequest(id: "same", preferredName: "Original"), conflict]
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let failure = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests, []) })
      #expect(failure.message.contains("Conflicting naming metadata"))
      #expect(failure.message.contains("same"))
      #expect(failure.message.contains("Original"))
      let reversed = try #require(
        throws: SchemaGenerationError.self, performing: { try allocate(requests.reversed(), []) })
      expectNoDifference(reversed, failure)
    }
  }

  @Test func nearestContextWinsBeforeOuterContextOrDigest() throws {
    let requests = [
      SchemaModelNameRequest(
        id: "a", preferredName: "Address", context: ["shipping", "document"]),
      SchemaModelNameRequest(
        id: "b", preferredName: "Address", context: ["billing", "document"]),
      SchemaModelNameRequest(
        id: "c", preferredName: "ShippingAddress"),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests),
      ["a": "DocumentShippingAddress", "b": "BillingAddress", "c": "ShippingAddress"])
    expectNoDifference(
      try SchemaModelNames.caseNames(for: requests),
      ["a": "documentShippingAddress", "b": "billingAddress", "c": "shippingAddress"])
  }

  @Test func competingContextsAreAllocatedSimultaneously() throws {
    let requests = [
      SchemaModelNameRequest(id: "a", preferredName: "Part", context: ["Shared", "Left"]),
      SchemaModelNameRequest(id: "b", preferredName: "Part", context: ["Shared", "Right"]),
      SchemaModelNameRequest(id: "c", preferredName: "Other", context: ["Only"]),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests),
      ["a": "LeftSharedPart", "b": "RightSharedPart", "c": "Other"])
  }

  @Test func indistinguishableStemsUseSpecifiedUTF8Digest() throws {
    let requests = [
      SchemaModelNameRequest(id: "hello", preferredName: "hello"),
      SchemaModelNameRequest(id: "日本語", preferredName: "hello!"),
      SchemaModelNameRequest(id: "", preferredName: "hello?"),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests),
      ["hello": "Hello_a430d846", "日本語": "Hello_ee9ee2b5", "": "Hello_cbf29ce4"])
    expectNoDifference(
      try SchemaModelNames.caseNames(for: requests),
      ["hello": "hello_a430d846", "日本語": "hello_ee9ee2b5", "": "hello_cbf29ce4"])
  }

  @Test func unrelatedCollisionGroupsDoNotShareCounters() throws {
    let requests = [
      SchemaModelNameRequest(id: "source/a", preferredName: "Part"),
      SchemaModelNameRequest(id: "source/b", preferredName: "Part!"),
    ]
    let unrelated = [
      SchemaModelNameRequest(id: "different/a", preferredName: "Element"),
      SchemaModelNameRequest(id: "different/b", preferredName: "Element!"),
      SchemaModelNameRequest(id: "different/c", preferredName: "Element?"),
    ]
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let original = try allocate(requests, [])
      let expanded = try allocate(unrelated + requests.reversed(), [])
      expectNoDifference(
        expanded.filter { original[$0.key] != nil }, original)
      expectNoDifference(Set(expanded.values).count, 5)
    }
  }

  @Test func fixedWidthDigestRetainsLeadingZeroes() throws {
    let id = "logical-model:8cbc97bca0cb5772"
    let requests = [SchemaModelNameRequest(id: id, preferredName: "Part")]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests, reserved: ["Part"]),
      [id: "Part_02e6dfed"])
    expectNoDifference(
      try SchemaModelNames.caseNames(for: requests, reserved: ["part"]),
      [id: "part_02e6dfed"])
  }

  @Test func insufficientContextKeepsMeaningfulStemBeforeSuffix() throws {
    let requests = [
      SchemaModelNameRequest(
        id: "source/a", preferredName: "Part", context: ["", "💛", "Container"]),
      SchemaModelNameRequest(id: "source/b", preferredName: "part!", context: ["Container"]),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests),
      ["source/a": "ContainerPart_209d8eb0", "source/b": "ContainerPart_209d91b0"])
  }

  @Test func actualFNVPrefixCollisionExtendsBothSuffixes() throws {
    // These portable IDs share eight, but not nine, hex digits of their FNV-1a64 digests.
    let first = "logical-model:37dbd71a26a187a8"
    let second = "logical-model:f4e10fb4d817ac9c"
    let requests = [
      SchemaModelNameRequest(id: first, preferredName: "Part"),
      SchemaModelNameRequest(id: second, preferredName: "Part"),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests),
      [first: "Part_c0e154ce5", second: "Part_c0e154ce1"])
    expectNoDifference(
      try SchemaModelNames.caseNames(for: requests),
      [first: "part_c0e154ce5", second: "part_c0e154ce1"])
    expectNoDifference(
      try SchemaModelNames.typeNames(for: requests.reversed()),
      try SchemaModelNames.typeNames(for: requests))
  }

  @Test func suffixesExtendPastReservedOrExplicitSpellings() throws {
    let requests = [
      SchemaModelNameRequest(id: "hello", preferredName: "Hello"),
      SchemaModelNameRequest(id: "fixed", preferredName: "Other", explicitName: "Hello_a430d846"),
    ]
    expectNoDifference(
      try SchemaModelNames.typeNames(
        for: requests, reserved: ["Hello", "Hello_a430d8468"]),
      ["hello": "Hello_a430d84680", "fixed": "Hello_a430d846"])
  }

  @Test func exhaustedSuffixIsAnExplicitLocatedDiagnostic() throws {
    let digest = "a430d84680aabd0b"
    let reserved = Set((8...16).map { "Hello_" + digest.prefix($0) }).union(["Hello"])
    let requests = [
      SchemaModelNameRequest(id: "hello", preferredName: "Hello", pointer: "/$defs/Hello")
    ]
    let failure = try #require(
      throws: SchemaGenerationError.self,
      performing: { try SchemaModelNames.typeNames(for: requests, reserved: reserved) })
    expectNoDifference(failure.pointer, "/$defs/Hello")
    #expect(failure.message.contains("FNV-1a64 suffix exhausted"))
    #expect(failure.message.contains("Hello_a430d84680aabd0b"))
    #expect(failure.message.contains("#/$defs/Hello"))
    #expect(failure.message.contains("reserved"))
  }

  @Test func allocationsAreCompleteUniquePortableAndStable() throws {
    let names =
      (0...255).compactMap(UnicodeScalar.init).map(String.init)
      + [
        "", "💛", "日本語", "Part", "part", "Part!", "HTTPServer", "http_server",
        "String", "Value", "_JSONSchemaCodegenAdapter", "alternative1", "a-b", "a_b",
      ]
    let requests = names.enumerated().map { index, name in
      SchemaModelNameRequest(
        id: "logical-model:\(index)", preferredName: name,
        context: index.isMultiple(of: 3) ? ["Container"] : [],
        pointer: "/$defs/\(index)",
        documentURI: URL(fileURLWithPath: "/checkout-a/schema.json"))
    }
    for allocate in [SchemaModelNames.typeNames, SchemaModelNames.caseNames] {
      let allocated = try allocate(requests, ["Value"])
      expectNoDifference(Set(allocated.keys), Set(requests.map(\.id)))
      expectNoDifference(Set(allocated.values).count, requests.count)
      for name in allocated.values {
        #expect(name.wholeMatch(of: /[a-zA-Z_][a-zA-Z_0-9]*/) != nil)
        #expect(name != "_")
        #expect(name != "Self")
        #expect(!name.hasPrefix(SchemaModelNames.helperPrefix))
        #expect(!name.contains("checkout"))
        #expect(!name.contains("logical-model"))
      }
      expectNoDifference(try allocate(requests.reversed(), ["Value"]), allocated)
      let inserted = try allocate(
        [SchemaModelNameRequest(id: "unrelated", preferredName: "WhollyUnrelated")] + requests,
        ["Value"])
      expectNoDifference(inserted.filter { $0.key != "unrelated" }, allocated)
      let relocated = requests.map { request in
        SchemaModelNameRequest(
          id: request.id, preferredName: request.preferredName, context: request.context,
          pointer: "/different-diagnostic-pointer",
          documentURI: URL(fileURLWithPath: "/checkout-b/schema.json"))
      }
      expectNoDifference(try allocate(relocated, ["Value"]), allocated)
    }
  }
}
