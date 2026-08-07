use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const CONFIG_SCHEMA: &str = "speakeasy.speech-bench.config.v1";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct BenchmarkConfig {
    pub schema: String,
    pub preset: String,
    pub model: ModelConfig,
    pub session: SessionConfig,
    pub run: RunConfig,
    #[serde(default)]
    pub stream: StreamConfig,
    pub execution: ExecutionConfig,
    pub corpus_manifest: PathBuf,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ModelConfig {
    pub path: PathBuf,
    #[serde(default)]
    pub catalog_id: Option<String>,
    #[serde(default)]
    pub backend: Backend,
    #[serde(default)]
    pub gpu_device: u32,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Backend {
    #[default]
    Auto,
    Cpu,
    CpuAccel,
    Metal,
    Vulkan,
    Cuda,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SessionConfig {
    #[serde(default)]
    pub threads: u32,
    #[serde(default)]
    pub kv_type: KvType,
    #[serde(default)]
    pub context: u32,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum KvType {
    #[default]
    Auto,
    F16,
    F32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunConfig {
    #[serde(default)]
    pub task: Task,
    #[serde(default)]
    pub timestamps: TimestampMode,
    #[serde(default)]
    pub punctuation: Toggle,
    #[serde(default)]
    pub inverse_text_normalization: Toggle,
    pub language: Option<String>,
    #[serde(default)]
    pub keep_special_tags: bool,
    #[serde(default = "default_speculative_drafts")]
    pub speculative_drafts: i32,
}

fn default_speculative_drafts() -> i32 {
    -1
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Task {
    #[default]
    Transcribe,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TimestampMode {
    None,
    #[default]
    Auto,
    Segment,
    Word,
    Token,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Toggle {
    #[default]
    Default,
    Off,
    On,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct StreamConfig {
    #[serde(default)]
    pub commit_policy: CommitPolicy,
    #[serde(default)]
    pub stable_prefix_agreement: u32,
    #[serde(default = "default_feed_chunk_ms")]
    pub feed_chunk_ms: u32,
    #[serde(default)]
    pub family: StreamFamily,
    pub attention_context_right: Option<i32>,
    pub left_ms: Option<i32>,
    pub chunk_ms: Option<i32>,
    pub right_ms: Option<i32>,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            commit_policy: CommitPolicy::Auto,
            stable_prefix_agreement: 0,
            feed_chunk_ms: default_feed_chunk_ms(),
            family: StreamFamily::Auto,
            attention_context_right: None,
            left_ms: None,
            chunk_ms: None,
            right_ms: None,
        }
    }
}

fn default_feed_chunk_ms() -> u32 {
    100
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CommitPolicy {
    #[default]
    Auto,
    OnFinalize,
    StablePrefix,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StreamFamily {
    #[default]
    Auto,
    CacheAware,
    Buffered,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ExecutionConfig {
    #[serde(default)]
    pub mode: ExecutionMode,
    pub repetitions: u32,
    #[serde(default)]
    pub warmup_samples: u32,
    pub timeout_seconds: u64,
    pub order_seed: u64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    ProcessCold,
    #[default]
    Warm,
    StreamingAccelerated,
    StreamingRealtime,
}

impl BenchmarkConfig {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = fs::read(path)
            .map_err(|error| format!("failed to read config {}: {error}", path.display()))?;
        let config: Self = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid config {}: {error}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema != CONFIG_SCHEMA {
            return Err(format!(
                "unsupported config schema {:?}; expected {CONFIG_SCHEMA:?}",
                self.schema
            ));
        }
        if self.preset.trim().is_empty() {
            return Err("preset must not be empty".into());
        }
        if self.model.path.as_os_str().is_empty() {
            return Err("model.path must not be empty".into());
        }
        if self
            .model
            .catalog_id
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            return Err("model.catalog_id must not be empty".into());
        }
        if self.corpus_manifest.as_os_str().is_empty() {
            return Err("corpus_manifest must not be empty".into());
        }
        if self.execution.repetitions == 0 {
            return Err("execution.repetitions must be greater than zero".into());
        }
        if self.execution.timeout_seconds == 0 {
            return Err("execution.timeout_seconds must be greater than zero".into());
        }
        if self.session.threads > 256 {
            return Err("session.threads must be between 0 and 256".into());
        }
        if self.session.context > i32::MAX as u32 {
            return Err("session.context exceeds the native i32 limit".into());
        }
        if self.model.gpu_device > i32::MAX as u32 {
            return Err("model.gpu_device exceeds the native i32 limit".into());
        }
        if self.run.speculative_drafts < -1 {
            return Err("run.speculative_drafts must be -1 or greater".into());
        }
        if self.stream.feed_chunk_ms == 0 || self.stream.feed_chunk_ms > 10_000 {
            return Err("stream.feed_chunk_ms must be between 1 and 10000".into());
        }
        if self.stream.stable_prefix_agreement > 100 {
            return Err("stream.stable_prefix_agreement must be between 0 and 100".into());
        }
        match self.stream.family {
            StreamFamily::Auto => {
                if self.stream.attention_context_right.is_some()
                    || self.stream.left_ms.is_some()
                    || self.stream.chunk_ms.is_some()
                    || self.stream.right_ms.is_some()
                {
                    return Err(
                        "stream family-specific values require cache_aware or buffered".into(),
                    );
                }
            }
            StreamFamily::CacheAware => {
                if self.stream.left_ms.is_some()
                    || self.stream.chunk_ms.is_some()
                    || self.stream.right_ms.is_some()
                {
                    return Err("buffered window values require stream.family=buffered".into());
                }
            }
            StreamFamily::Buffered => {
                if self.stream.attention_context_right.is_some() {
                    return Err("attention_context_right requires stream.family=cache_aware".into());
                }
            }
        }
        Ok(())
    }

    pub fn fingerprint(&self) -> Result<String, String> {
        let canonical = serde_json::to_vec(self)
            .map_err(|error| format!("failed to serialize config: {error}"))?;
        Ok(hex::encode(Sha256::digest(canonical)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_config() -> BenchmarkConfig {
        BenchmarkConfig {
            schema: CONFIG_SCHEMA.into(),
            preset: "test".into(),
            model: ModelConfig {
                path: "model.gguf".into(),
                catalog_id: None,
                backend: Backend::Auto,
                gpu_device: 0,
            },
            session: SessionConfig {
                threads: 0,
                kv_type: KvType::Auto,
                context: 0,
            },
            run: RunConfig {
                task: Task::Transcribe,
                timestamps: TimestampMode::Auto,
                punctuation: Toggle::Default,
                inverse_text_normalization: Toggle::Default,
                language: None,
                keep_special_tags: false,
                speculative_drafts: -1,
            },
            stream: StreamConfig::default(),
            execution: ExecutionConfig {
                mode: ExecutionMode::Warm,
                repetitions: 1,
                warmup_samples: 1,
                timeout_seconds: 30,
                order_seed: 42,
            },
            corpus_manifest: "manifest.json".into(),
        }
    }

    #[test]
    fn configuration_round_trips_and_has_a_stable_fingerprint() {
        let config = valid_config();
        let json = serde_json::to_vec(&config).expect("serialize");
        let decoded: BenchmarkConfig = serde_json::from_slice(&json).expect("deserialize");

        assert_eq!(decoded, config);
        assert_eq!(
            decoded.fingerprint().unwrap(),
            config.fingerprint().unwrap()
        );
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let mut value = serde_json::to_value(valid_config()).expect("serialize");
        value["unexpected"] = serde_json::json!(true);

        let error = serde_json::from_value::<BenchmarkConfig>(value).unwrap_err();
        assert!(error.to_string().contains("unknown field"));
    }

    #[test]
    fn invalid_execution_values_are_rejected() {
        let mut config = valid_config();
        config.execution.repetitions = 0;
        assert!(config.validate().unwrap_err().contains("repetitions"));
    }
}
