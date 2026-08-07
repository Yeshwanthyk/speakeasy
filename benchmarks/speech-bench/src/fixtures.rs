use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::score::NORMALIZATION_VERSION;

pub const FIXTURE_SCHEMA: &str = "speakeasy.fixtures.v1";
pub const REQUIRED_SAMPLE_RATE_HZ: u32 = 16_000;
pub const REQUIRED_CHANNELS: u16 = 1;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FixtureManifest {
    pub schema: String,
    pub corpus_id: String,
    pub normalization_version: String,
    pub fixtures: Vec<Fixture>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Fixture {
    pub id: String,
    pub audio: PathBuf,
    pub audio_sha256: String,
    pub reference: String,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub frames: u64,
    pub duration_ms: u64,
    pub bucket: FixtureBucket,
    pub locale: String,
    #[serde(default)]
    pub conditions: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "default_include_in_wer")]
    pub include_in_wer: bool,
}

fn default_include_in_wer() -> bool {
    true
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FixtureBucket {
    Short,
    Medium,
    Long,
    Control,
}

#[derive(Clone, Debug)]
pub struct ValidatedFixture {
    pub definition: Fixture,
    pub audio_path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct Corpus {
    pub manifest: FixtureManifest,
    pub manifest_path: PathBuf,
    pub manifest_sha256: String,
    pub fixtures: Vec<ValidatedFixture>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedAudio {
    pub samples: Vec<f32>,
    pub sample_rate_hz: u32,
    pub duration_ms: f64,
}

impl Corpus {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = fs::read(path).map_err(|error| {
            format!(
                "failed to read fixture manifest {}: {error}",
                path.display()
            )
        })?;
        let manifest_sha256 = hex::encode(Sha256::digest(&bytes));
        let manifest: FixtureManifest = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid fixture manifest {}: {error}", path.display()))?;
        manifest.validate()?;

        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        let mut fixtures = Vec::with_capacity(manifest.fixtures.len());
        for fixture in &manifest.fixtures {
            let audio_path = resolve_fixture_path(parent, &fixture.audio)?;
            let actual_hash = sha256_file(&audio_path)?;
            if actual_hash != fixture.audio_sha256.to_ascii_lowercase() {
                return Err(format!(
                    "fixture {:?} hash mismatch: expected {}, got {actual_hash}",
                    fixture.id, fixture.audio_sha256
                ));
            }

            let audio = decode_wav(&audio_path)?;
            if audio.sample_rate_hz != fixture.sample_rate_hz {
                return Err(format!(
                    "fixture {:?} sample rate mismatch: manifest {}, WAV {}",
                    fixture.id, fixture.sample_rate_hz, audio.sample_rate_hz
                ));
            }
            if audio.samples.len() as u64 != fixture.frames {
                return Err(format!(
                    "fixture {:?} frame count mismatch: manifest {}, WAV {}",
                    fixture.id,
                    fixture.frames,
                    audio.samples.len()
                ));
            }
            if (audio.duration_ms.round() as i128 - fixture.duration_ms as i128).abs() > 1 {
                return Err(format!(
                    "fixture {:?} duration mismatch: manifest {} ms, WAV {:.3} ms",
                    fixture.id, fixture.duration_ms, audio.duration_ms
                ));
            }

            fixtures.push(ValidatedFixture {
                definition: fixture.clone(),
                audio_path,
            });
        }

        Ok(Self {
            manifest,
            manifest_path: path.to_owned(),
            manifest_sha256,
            fixtures,
        })
    }
}

impl FixtureManifest {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != FIXTURE_SCHEMA {
            return Err(format!(
                "unsupported fixture schema {:?}; expected {FIXTURE_SCHEMA:?}",
                self.schema
            ));
        }
        if self.corpus_id.trim().is_empty() {
            return Err("corpus_id must not be empty".into());
        }
        if self.normalization_version != NORMALIZATION_VERSION {
            return Err(format!(
                "unsupported normalization_version {:?}; expected {:?}",
                self.normalization_version, NORMALIZATION_VERSION
            ));
        }
        if self.fixtures.is_empty() {
            return Err("fixture manifest must contain at least one fixture".into());
        }

        let mut ids = HashSet::with_capacity(self.fixtures.len());
        for fixture in &self.fixtures {
            fixture.validate()?;
            if !ids.insert(&fixture.id) {
                return Err(format!("duplicate fixture id {:?}", fixture.id));
            }
        }
        Ok(())
    }
}

impl Fixture {
    fn validate(&self) -> Result<(), String> {
        if self.id.trim().is_empty() {
            return Err("fixture id must not be empty".into());
        }
        if self.audio.as_os_str().is_empty() {
            return Err(format!(
                "fixture {:?} audio path must not be empty",
                self.id
            ));
        }
        if self.audio_sha256.len() != 64
            || !self
                .audio_sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(format!(
                "fixture {:?} audio_sha256 must contain 64 hexadecimal characters",
                self.id
            ));
        }
        if self.sample_rate_hz != REQUIRED_SAMPLE_RATE_HZ {
            return Err(format!(
                "fixture {:?} must declare {REQUIRED_SAMPLE_RATE_HZ} Hz audio",
                self.id
            ));
        }
        if self.channels != REQUIRED_CHANNELS {
            return Err(format!("fixture {:?} must declare mono audio", self.id));
        }
        if self.frames == 0 || self.duration_ms == 0 {
            return Err(format!(
                "fixture {:?} frames and duration_ms must be greater than zero",
                self.id
            ));
        }
        if self.bucket == FixtureBucket::Control && self.include_in_wer {
            return Err(format!(
                "control fixture {:?} must set include_in_wer to false",
                self.id
            ));
        }
        Ok(())
    }
}

pub fn decode_wav(path: &Path) -> Result<DecodedAudio, String> {
    let mut reader = hound::WavReader::open(path)
        .map_err(|error| format!("failed to open WAV {}: {error}", path.display()))?;
    let spec = reader.spec();
    if spec.channels != REQUIRED_CHANNELS {
        return Err(format!(
            "WAV {} has {} channels; expected mono",
            path.display(),
            spec.channels
        ));
    }
    if spec.sample_rate != REQUIRED_SAMPLE_RATE_HZ {
        return Err(format!(
            "WAV {} is {} Hz; expected {REQUIRED_SAMPLE_RATE_HZ} Hz",
            path.display(),
            spec.sample_rate
        ));
    }

    let samples = match spec.sample_format {
        hound::SampleFormat::Float if spec.bits_per_sample == 32 => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("failed to decode WAV {}: {error}", path.display()))?,
        hound::SampleFormat::Int if (8..=32).contains(&spec.bits_per_sample) => {
            let scale = 2_f32.powi(i32::from(spec.bits_per_sample) - 1);
            reader
                .samples::<i32>()
                .map(|sample| sample.map(|value| value as f32 / scale))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| format!("failed to decode WAV {}: {error}", path.display()))?
        }
        _ => {
            return Err(format!(
                "WAV {} uses unsupported {:?}/{}-bit samples",
                path.display(),
                spec.sample_format,
                spec.bits_per_sample
            ));
        }
    };
    if samples.is_empty() {
        return Err(format!("WAV {} contains no samples", path.display()));
    }
    if samples.iter().any(|sample| !sample.is_finite()) {
        return Err(format!(
            "WAV {} contains non-finite samples",
            path.display()
        ));
    }

    let duration_ms = samples.len() as f64 * 1_000.0 / f64::from(spec.sample_rate);
    Ok(DecodedAudio {
        samples,
        sample_rate_hz: spec.sample_rate,
        duration_ms,
    })
}

fn resolve_fixture_path(parent: &Path, audio: &Path) -> Result<PathBuf, String> {
    if audio.is_absolute() {
        return Ok(audio.to_owned());
    }
    if audio
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(format!(
            "fixture audio path {} must not escape the manifest directory",
            audio.display()
        ));
    }
    Ok(parent.join(audio))
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path)
        .map_err(|error| format!("failed to read fixture audio {}: {error}", path.display()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_wav(path: &Path, sample_rate: u32, channels: u16) {
        let spec = hound::WavSpec {
            channels,
            sample_rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).expect("create WAV");
        for _ in 0..sample_rate / 10 * u32::from(channels) {
            writer.write_sample(0_i16).expect("write sample");
        }
        writer.finalize().expect("finalize WAV");
    }

    #[test]
    fn decodes_supported_mono_wav() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("fixture.wav");
        write_wav(&path, REQUIRED_SAMPLE_RATE_HZ, REQUIRED_CHANNELS);

        let audio = decode_wav(&path).expect("decode WAV");

        assert_eq!(audio.samples.len(), 1_600);
        assert_eq!(audio.sample_rate_hz, REQUIRED_SAMPLE_RATE_HZ);
        assert!((audio.duration_ms - 100.0).abs() < f64::EPSILON);
    }

    #[test]
    fn rejects_stereo_and_wrong_sample_rate() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let stereo = directory.path().join("stereo.wav");
        let wrong_rate = directory.path().join("wrong-rate.wav");
        write_wav(&stereo, REQUIRED_SAMPLE_RATE_HZ, 2);
        write_wav(&wrong_rate, 48_000, REQUIRED_CHANNELS);

        assert!(decode_wav(&stereo).unwrap_err().contains("expected mono"));
        assert!(decode_wav(&wrong_rate)
            .unwrap_err()
            .contains("expected 16000 Hz"));
    }

    #[test]
    fn rejects_normalization_version_mismatch_before_execution() {
        let manifest = FixtureManifest {
            schema: FIXTURE_SCHEMA.into(),
            corpus_id: "test".into(),
            normalization_version: "different-scorer".into(),
            fixtures: Vec::new(),
        };

        assert!(manifest
            .validate()
            .unwrap_err()
            .contains(NORMALIZATION_VERSION));
    }

    #[test]
    fn rejects_hash_mismatch_before_accepting_corpus() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let audio = directory.path().join("fixture.wav");
        write_wav(&audio, REQUIRED_SAMPLE_RATE_HZ, REQUIRED_CHANNELS);
        let manifest = FixtureManifest {
            schema: FIXTURE_SCHEMA.into(),
            corpus_id: "test".into(),
            normalization_version: "wer-en-v1".into(),
            fixtures: vec![Fixture {
                id: "short-001".into(),
                audio: "fixture.wav".into(),
                audio_sha256: "0".repeat(64),
                reference: "hello".into(),
                sample_rate_hz: REQUIRED_SAMPLE_RATE_HZ,
                channels: REQUIRED_CHANNELS,
                frames: 1_600,
                duration_ms: 100,
                bucket: FixtureBucket::Short,
                locale: "en-US".into(),
                conditions: vec![],
                tags: vec![],
                include_in_wer: true,
            }],
        };
        let manifest_path = directory.path().join("manifest.json");
        fs::write(
            &manifest_path,
            serde_json::to_vec(&manifest).expect("serialize manifest"),
        )
        .expect("write manifest");

        assert!(Corpus::load(&manifest_path)
            .unwrap_err()
            .contains("hash mismatch"));
    }
}
