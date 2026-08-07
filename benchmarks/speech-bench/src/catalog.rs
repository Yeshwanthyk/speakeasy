use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::environment::sha256_file;
use serde::{Deserialize, Serialize};

pub const CATALOG_SCHEMA: &str = "speakeasy.speech-bench.catalog.v1";
pub const CATALOG_PATH: &str = "benchmarks/models/catalog.json";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelCatalog {
    pub schema: String,
    pub models: Vec<CatalogModel>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CatalogModel {
    pub id: String,
    pub name: String,
    pub family: String,
    pub license: String,
    pub native_streaming: bool,
    pub artifact: CatalogArtifact,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CatalogArtifact {
    pub repository: String,
    pub revision: String,
    pub filename: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ArtifactIdentity {
    pub catalog_id: String,
    pub expected_bytes: u64,
    pub actual_bytes: u64,
    pub expected_sha256: String,
    pub actual_sha256: String,
    pub verified: bool,
}

impl ModelCatalog {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = fs::read(path)
            .map_err(|error| format!("failed to read model catalog {}: {error}", path.display()))?;
        let catalog: Self = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid model catalog {}: {error}", path.display()))?;
        catalog.validate()?;
        Ok(catalog)
    }

    pub fn find(&self, id: &str) -> Result<&CatalogModel, String> {
        self.models
            .iter()
            .find(|model| model.id == id)
            .ok_or_else(|| format!("unknown model catalog id {id:?}"))
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema != CATALOG_SCHEMA {
            return Err(format!(
                "unsupported model catalog schema {:?}; expected {CATALOG_SCHEMA:?}",
                self.schema
            ));
        }
        if self.models.is_empty() {
            return Err("model catalog must contain at least one model".into());
        }
        for (index, model) in self.models.iter().enumerate() {
            if model.id.trim().is_empty()
                || model.name.trim().is_empty()
                || model.family.trim().is_empty()
                || model.license.trim().is_empty()
            {
                return Err(format!(
                    "model catalog entry {index} has an empty identity field"
                ));
            }
            if model.artifact.repository.trim().is_empty()
                || model.artifact.revision.len() != 40
                || !model
                    .artifact
                    .revision
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || model.artifact.filename.trim().is_empty()
                || model.artifact.bytes == 0
                || !is_sha256(&model.artifact.sha256)
            {
                return Err(format!(
                    "model catalog entry {:?} has invalid artifact metadata",
                    model.id
                ));
            }
            if model.artifact.filename.contains('/') || model.artifact.filename.contains('\\') {
                return Err(format!(
                    "model {:?} artifact filename must be a file name",
                    model.id
                ));
            }
            if self.models[..index]
                .iter()
                .any(|other| other.id == model.id)
            {
                return Err(format!("duplicate model catalog id {:?}", model.id));
            }
        }
        Ok(())
    }
}

impl CatalogModel {
    pub fn url(&self) -> String {
        format!(
            "https://huggingface.co/{}/resolve/{}/{}?download=true",
            self.artifact.repository, self.artifact.revision, self.artifact.filename
        )
    }

    pub fn default_path(&self) -> Result<PathBuf, String> {
        let home = std::env::var_os("HOME").ok_or("HOME is not set; cannot choose model path")?;
        Ok(PathBuf::from(home)
            .join(".cache/wisp/benchmark-models")
            .join(&self.artifact.filename))
    }

    pub fn verify(&self, path: &Path) -> Result<ArtifactIdentity, String> {
        let metadata = fs::metadata(path).map_err(|error| {
            format!(
                "failed to inspect model artifact {}: {error}",
                path.display()
            )
        })?;
        if !metadata.is_file() {
            return Err(format!("model artifact is not a file: {}", path.display()));
        }
        let actual_sha256 = sha256_file(path)?;
        let identity = ArtifactIdentity {
            catalog_id: self.id.clone(),
            expected_bytes: self.artifact.bytes,
            actual_bytes: metadata.len(),
            expected_sha256: self.artifact.sha256.to_ascii_lowercase(),
            actual_sha256,
            verified: false,
        };
        if identity.actual_bytes != identity.expected_bytes {
            return Err(format!(
                "model {:?} byte count mismatch: expected {}, got {}",
                self.id, identity.expected_bytes, identity.actual_bytes
            ));
        }
        if identity.actual_sha256 != identity.expected_sha256 {
            return Err(format!(
                "model {:?} SHA-256 mismatch: expected {}, got {}",
                self.id, identity.expected_sha256, identity.actual_sha256
            ));
        }
        Ok(ArtifactIdentity {
            verified: true,
            ..identity
        })
    }
}

pub fn download(
    model: &CatalogModel,
    output: Option<&Path>,
    force: bool,
) -> Result<PathBuf, String> {
    let output = output.map(Path::to_owned).unwrap_or(model.default_path()?);
    if output.exists() && !force {
        return Err(format!(
            "refusing to overwrite existing artifact {}; pass --force to replace it",
            output.display()
        ));
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }
    let partial = output.with_extension("download.part");
    let _ = fs::remove_file(&partial);
    let status = Command::new("curl")
        .args(["--fail", "--location", "--retry", "3", "--output"])
        .arg(&partial)
        .arg(model.url())
        .status()
        .map_err(|error| format!("failed to launch curl: {error}"))?;
    if !status.success() {
        let _ = fs::remove_file(&partial);
        return Err(format!(
            "curl failed while downloading model {:?}",
            model.id
        ));
    }
    if let Err(error) = model.verify(&partial) {
        let _ = fs::remove_file(&partial);
        return Err(format!(
            "downloaded model {:?} failed verification: {error}",
            model.id
        ));
    }
    fs::rename(&partial, &output).map_err(|error| {
        let _ = fs::remove_file(&partial);
        format!(
            "failed to install downloaded model {}: {error}",
            output.display()
        )
    })?;
    Ok(output)
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_catalog_contains_every_requested_candidate() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../models/catalog.json");
        let catalog = ModelCatalog::load(&path).expect("catalog");
        let ids: Vec<_> = catalog
            .models
            .iter()
            .map(|model| model.id.as_str())
            .collect();
        assert_eq!(ids.len(), 6);
        assert!(ids.contains(&"moonshine-streaming-small-q8_0"));
        assert!(ids.contains(&"moonshine-streaming-medium-q8_0"));
        assert!(ids.contains(&"parakeet-tdt-ctc-110m-q8_0"));
        assert!(ids.contains(&"cohere-transcribe-03-2026-q4_k_m"));
        assert!(ids.contains(&"parakeet-tdt-1.1b-q8_0"));
        assert!(ids.contains(&"whisper-small-q4_k_m"));
    }

    #[test]
    fn verification_requires_exact_bytes_and_sha256() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("model.gguf");
        fs::write(&path, b"abc").expect("write");
        let model = CatalogModel {
            id: "test".into(),
            name: "Test".into(),
            family: "test".into(),
            license: "MIT".into(),
            native_streaming: false,
            artifact: CatalogArtifact {
                repository: "test/repo".into(),
                revision: "0123456789012345678901234567890123456789".into(),
                filename: "model.gguf".into(),
                bytes: 3,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
            },
        };
        let identity = model.verify(&path).expect("verify");
        assert!(identity.verified);
        assert_eq!(identity.actual_bytes, 3);
    }
}
