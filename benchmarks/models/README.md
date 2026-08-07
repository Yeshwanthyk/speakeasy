# Pinned model catalog

[`catalog.json`](catalog.json) is the only model source of truth for the
compact benchmark candidates. Each entry pins a Hugging Face repository,
40-character revision, filename, exact byte count, and SHA-256 of the GGUF.
The SHA-256 values are the file LFS object IDs exposed by the pinned revision.

The harness never downloads models during tests or config validation. Use the
`speech-bench download <catalog-id>` command deliberately; it downloads to a
temporary sibling, verifies byte count and SHA-256, then installs the artifact.
Use `verify-artifact` for an artifact obtained by another approved channel.

The catalog is evaluation metadata, not an application model allowlist or a
promotion decision. Keep model licenses and attribution with any eventual
redistribution path.
