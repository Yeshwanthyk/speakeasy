use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use transcribe_cpp::{Model, ModelOptions, RunOptions, Session, SessionOptions};

use crate::catalog::{ArtifactIdentity, ModelCatalog, CATALOG_PATH};
use crate::config::{
    Backend, BenchmarkConfig, CommitPolicy as ConfigCommitPolicy, ExecutionMode, KvType,
    StreamFamily, Task as ConfigTask, TimestampMode, Toggle,
};
use crate::environment::sha256_file;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EngineIdentity {
    pub adapter: String,
    pub compiled_version: String,
    pub runtime_version: String,
    pub runtime_commit: String,
    pub header_hash: String,
    pub model_file_name: String,
    pub model_bytes: u64,
    pub model_sha256: String,
    #[serde(default)]
    pub artifact: Option<ArtifactIdentity>,
    pub architecture: String,
    pub variant: String,
    pub actual_backend: String,
    pub device: Option<DeviceIdentity>,
    pub device_error: Option<String>,
    pub capabilities: CapabilityIdentity,
    pub session_limits: SessionLimitIdentity,
    pub startup: StartupTimings,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeviceIdentity {
    pub name: String,
    pub description: String,
    pub kind: String,
    pub device_type: String,
    pub device_id: Option<String>,
    pub memory_total: u64,
    pub memory_free_after_load: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CapabilityIdentity {
    pub native_sample_rate: i32,
    pub languages: Vec<String>,
    pub translate_target_languages: Vec<String>,
    pub max_timestamp_kind: String,
    pub supports_language_detect: bool,
    pub supports_translate: bool,
    pub supports_streaming: bool,
    pub supports_spec_decode: bool,
    pub supports_pnc_toggle: bool,
    pub supports_itn_toggle: bool,
    pub supports_cancellation: bool,
    pub max_audio_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SessionLimitIdentity {
    pub effective_context: i32,
    pub effective_max_audio_ms: i64,
    pub max_kv_bytes: i64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StartupTimings {
    pub backend_initialization_ms: f64,
    pub model_load_ms: f64,
    pub session_creation_ms: f64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct NativeTimings {
    pub load_ms: f64,
    pub mel_ms: f64,
    pub encode_ms: f64,
    pub decode_ms: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RunOutput {
    pub text: String,
    pub detected_language: Option<String>,
    pub actual_timestamp_kind: String,
    pub wall_ms: f64,
    pub native: NativeTimings,
    pub truncated: bool,
    pub stream: Option<StreamMetrics>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StreamMetrics {
    pub first_hypothesis_ms: Option<f64>,
    pub first_commit_ms: Option<f64>,
    pub feed_compute_ms: f64,
    pub finalize_ms: f64,
    pub release_to_final_ms: f64,
    pub changed_revisions: u32,
}

pub struct ParakeetEngine {
    model: Model,
    session: Session,
    run_options: RunOptions,
    identity: EngineIdentity,
}

impl ParakeetEngine {
    pub fn load_production_parity(
        config: &BenchmarkConfig,
        repo_root: &Path,
    ) -> Result<Self, String> {
        Self::load(config, repo_root)
    }

    pub fn load(config: &BenchmarkConfig, repo_root: &Path) -> Result<Self, String> {
        let model_path = resolve_path(&config.model.path, repo_root)?;
        let metadata = fs::metadata(&model_path).map_err(|error| {
            format!("failed to inspect model {}: {error}", model_path.display())
        })?;
        if !metadata.is_file() {
            return Err(format!(
                "model path is not a file: {}",
                model_path.display()
            ));
        }
        let model_sha256 = sha256_file(&model_path)?;
        let artifact = if let Some(catalog_id) = &config.model.catalog_id {
            let catalog = ModelCatalog::load(&repo_root.join(CATALOG_PATH))?;
            Some(catalog.find(catalog_id)?.verify(&model_path)?)
        } else {
            None
        };

        transcribe_cpp::init_logging();
        let backend_started = Instant::now();
        transcribe_cpp::init_backends_default()
            .map_err(|error| format!("failed to initialize transcribe.cpp backends: {error}"))?;
        let backend_initialization_ms = elapsed_ms(backend_started);
        let requested_backend = native_backend(config.model.backend);
        if config.model.backend != Backend::Auto
            && !transcribe_cpp::backend_available(requested_backend)
        {
            return Err(format!(
                "requested backend {:?} is unavailable in this build/runtime",
                config.model.backend
            ));
        }

        let model_started = Instant::now();
        let model = Model::load_with(
            &model_path,
            &ModelOptions {
                backend: requested_backend,
                gpu_device: i32::try_from(config.model.gpu_device)
                    .map_err(|_| "model.gpu_device exceeds the native i32 limit")?,
            },
        )
        .map_err(|error| format!("failed to load model {}: {error}", model_path.display()))?;
        let model_load_ms = elapsed_ms(model_started);
        let capabilities = model.capabilities();
        validate_run_capabilities(config, &model, &capabilities)?;
        let run_options = native_run_options(config);

        let session_started = Instant::now();
        let session = model
            .session_with(&SessionOptions {
                n_threads: i32::try_from(config.session.threads)
                    .map_err(|_| "session.threads exceeds the native i32 limit")?,
                kv_type: native_kv_type(config.session.kv_type),
                n_ctx: i32::try_from(config.session.context)
                    .map_err(|_| "session.context exceeds the native i32 limit")?,
            })
            .map_err(|error| format!("failed to create transcription session: {error}"))?;
        let session_creation_ms = elapsed_ms(session_started);
        let limits = session
            .limits()
            .map_err(|error| format!("failed to query session limits: {error}"))?;
        let (device, device_error) = match model.device() {
            Ok(device) => (
                Some(DeviceIdentity {
                    name: device.name,
                    description: device.description,
                    kind: device.kind,
                    device_type: format!("{:?}", device.device_type).to_ascii_lowercase(),
                    device_id: device.device_id,
                    memory_total: device.memory_total,
                    memory_free_after_load: device.memory_free,
                }),
                None,
            ),
            Err(error) => (None, Some(error.to_string())),
        };

        let identity = EngineIdentity {
            adapter: "transcribe-cpp-0.1.3".into(),
            compiled_version: transcribe_cpp::compiled_version(),
            runtime_version: transcribe_cpp::version(),
            runtime_commit: transcribe_cpp::version_commit(),
            header_hash: transcribe_cpp::header_hash().into(),
            model_file_name: model_path
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_else(|| "model.gguf".into()),
            model_bytes: metadata.len(),
            model_sha256,
            artifact,
            architecture: model.arch(),
            variant: model.variant(),
            actual_backend: model.backend(),
            device,
            device_error,
            capabilities: CapabilityIdentity {
                native_sample_rate: capabilities.native_sample_rate,
                languages: capabilities.languages,
                translate_target_languages: capabilities.translate_target_languages,
                max_timestamp_kind: format!("{:?}", capabilities.max_timestamp_kind)
                    .to_ascii_lowercase(),
                supports_language_detect: capabilities.supports_language_detect,
                supports_translate: capabilities.supports_translate,
                supports_streaming: capabilities.supports_streaming,
                supports_spec_decode: capabilities.supports_spec_decode,
                supports_pnc_toggle: model.supports(transcribe_cpp::Feature::Pnc),
                supports_itn_toggle: model.supports(transcribe_cpp::Feature::Itn),
                supports_cancellation: model.supports(transcribe_cpp::Feature::Cancellation),
                max_audio_ms: capabilities.max_audio_ms,
            },
            session_limits: SessionLimitIdentity {
                effective_context: limits.effective_n_ctx,
                effective_max_audio_ms: limits.effective_max_audio_ms,
                max_kv_bytes: limits.max_kv_bytes,
            },
            startup: StartupTimings {
                backend_initialization_ms,
                model_load_ms,
                session_creation_ms,
            },
        };

        Ok(Self {
            model,
            session,
            run_options,
            identity,
        })
    }

    pub fn identity(&self) -> &EngineIdentity {
        &self.identity
    }

    pub fn warm_up(&mut self) -> Result<RunOutput, String> {
        self.run(&vec![0.0; 16_000])
    }

    pub fn run(&mut self, samples: &[f32]) -> Result<RunOutput, String> {
        let started = Instant::now();
        let transcript = self
            .session
            .run(samples, &self.run_options)
            .map_err(|error| format!("transcribe.cpp run failed: {error}"))?;
        let wall_ms = elapsed_ms(started);
        let truncated = self.session.was_truncated();

        Ok(RunOutput {
            text: transcript.text.trim().to_owned(),
            detected_language: transcript.language,
            actual_timestamp_kind: format!("{:?}", transcript.timestamp_kind).to_ascii_lowercase(),
            wall_ms,
            native: NativeTimings {
                load_ms: f64::from(transcript.timings.load_ms),
                mel_ms: f64::from(transcript.timings.mel_ms),
                encode_ms: f64::from(transcript.timings.encode_ms),
                decode_ms: f64::from(transcript.timings.decode_ms),
            },
            truncated,
            stream: None,
        })
    }

    pub fn run_streaming(
        &mut self,
        samples: &[f32],
        config: &BenchmarkConfig,
    ) -> Result<RunOutput, String> {
        if !self.identity.capabilities.supports_streaming {
            return Err("the model does not advertise streaming support".into());
        }
        let options = native_stream_options(config, &self.model)?;
        let chunk_samples =
            (u64::from(config.stream.feed_chunk_ms) * 16_000 / 1_000).max(1) as usize;
        let realtime = config.execution.mode == ExecutionMode::StreamingRealtime;
        let started = Instant::now();
        let mut stream = self
            .session
            .stream(&self.run_options, &options)
            .map_err(|error| format!("failed to begin stream: {error}"))?;
        let mut first_hypothesis_ms = None;
        let mut first_commit_ms = None;
        let mut feed_compute_ms = 0.0;
        let mut changed_revisions = 0_u32;
        let mut committed = String::new();
        let mut fed_samples = 0_usize;

        for chunk in samples.chunks(chunk_samples) {
            if realtime {
                fed_samples += chunk.len();
                sleep_until(
                    started,
                    Duration::from_secs_f64(fed_samples as f64 / 16_000.0),
                );
            }
            let feed_started = Instant::now();
            let update = stream
                .feed(chunk)
                .map_err(|error| format!("stream feed failed: {error}"))?;
            feed_compute_ms += elapsed_ms(feed_started);
            if update.result_changed {
                changed_revisions = changed_revisions.saturating_add(1);
                let text = stream.text();
                if first_hypothesis_ms.is_none() && !text.full.trim().is_empty() {
                    first_hypothesis_ms = Some(elapsed_ms(started));
                }
                if commits_must_be_append_only(config) && !text.committed.starts_with(&committed) {
                    return Err("stream committed text was not append-only".into());
                }
                if first_commit_ms.is_none() && !text.committed.trim().is_empty() {
                    first_commit_ms = Some(elapsed_ms(started));
                }
                committed = text.committed;
            }
        }

        let release_started = Instant::now();
        let finalize_started = Instant::now();
        let update = stream
            .finalize()
            .map_err(|error| format!("stream finalize failed: {error}"))?;
        let finalize_ms = elapsed_ms(finalize_started);
        if !update.is_final {
            return Err("stream finalize did not report a final update".into());
        }
        let text = stream.text();
        if commits_must_be_append_only(config) && !text.committed.starts_with(&committed) {
            return Err("final stream committed text was not append-only".into());
        }
        if first_hypothesis_ms.is_none() && !text.full.trim().is_empty() {
            first_hypothesis_ms = Some(elapsed_ms(started));
        }
        if first_commit_ms.is_none() && !text.committed.trim().is_empty() {
            first_commit_ms = Some(elapsed_ms(started));
        }
        let snapshot = stream.snapshot();
        let wall_ms = elapsed_ms(started);
        let release_to_final_ms = elapsed_ms(release_started);
        stream.reset();

        Ok(RunOutput {
            text: text.full.trim().to_owned(),
            detected_language: snapshot.language,
            actual_timestamp_kind: format!("{:?}", snapshot.timestamp_kind).to_ascii_lowercase(),
            wall_ms,
            native: NativeTimings {
                load_ms: f64::from(snapshot.timings.load_ms),
                mel_ms: f64::from(snapshot.timings.mel_ms),
                encode_ms: f64::from(snapshot.timings.encode_ms),
                decode_ms: f64::from(snapshot.timings.decode_ms),
            },
            truncated: false,
            stream: Some(StreamMetrics {
                first_hypothesis_ms,
                first_commit_ms,
                feed_compute_ms,
                finalize_ms,
                release_to_final_ms,
                changed_revisions,
            }),
        })
    }
}

fn commits_must_be_append_only(config: &BenchmarkConfig) -> bool {
    !config
        .model
        .catalog_id
        .as_deref()
        .is_some_and(|id| id.starts_with("moonshine-streaming-"))
}

fn native_backend(value: Backend) -> transcribe_cpp::Backend {
    match value {
        Backend::Auto => transcribe_cpp::Backend::Auto,
        Backend::Cpu => transcribe_cpp::Backend::Cpu,
        Backend::CpuAccel => transcribe_cpp::Backend::CpuAccel,
        Backend::Metal => transcribe_cpp::Backend::Metal,
        Backend::Vulkan => transcribe_cpp::Backend::Vulkan,
        Backend::Cuda => transcribe_cpp::Backend::Cuda,
    }
}

fn native_kv_type(value: KvType) -> transcribe_cpp::KvType {
    match value {
        KvType::Auto => transcribe_cpp::KvType::Auto,
        KvType::F16 => transcribe_cpp::KvType::F16,
        KvType::F32 => transcribe_cpp::KvType::F32,
    }
}

fn native_run_options(config: &BenchmarkConfig) -> RunOptions {
    RunOptions {
        task: match config.run.task {
            ConfigTask::Transcribe => transcribe_cpp::Task::Transcribe,
        },
        timestamps: match config.run.timestamps {
            TimestampMode::None => transcribe_cpp::TimestampKind::None,
            TimestampMode::Auto => transcribe_cpp::TimestampKind::Auto,
            TimestampMode::Segment => transcribe_cpp::TimestampKind::Segment,
            TimestampMode::Word => transcribe_cpp::TimestampKind::Word,
            TimestampMode::Token => transcribe_cpp::TimestampKind::Token,
        },
        pnc: match config.run.punctuation {
            Toggle::Default => transcribe_cpp::Pnc::Default,
            Toggle::Off => transcribe_cpp::Pnc::Off,
            Toggle::On => transcribe_cpp::Pnc::On,
        },
        itn: match config.run.inverse_text_normalization {
            Toggle::Default => transcribe_cpp::Itn::Default,
            Toggle::Off => transcribe_cpp::Itn::Off,
            Toggle::On => transcribe_cpp::Itn::On,
        },
        language: config.run.language.clone(),
        target_language: None,
        keep_special_tags: config.run.keep_special_tags,
        spec_k_drafts: config.run.speculative_drafts,
        family: None,
    }
}

fn native_stream_options(
    config: &BenchmarkConfig,
    model: &Model,
) -> Result<transcribe_cpp::StreamOptions, String> {
    use transcribe_cpp::sys::{
        TRANSCRIBE_EXT_KIND_PARAKEET_BUFFERED_STREAM, TRANSCRIBE_EXT_KIND_PARAKEET_STREAM,
    };

    if !matches!(
        config.execution.mode,
        ExecutionMode::StreamingAccelerated | ExecutionMode::StreamingRealtime
    ) {
        return Err("streaming requires a streaming execution mode".into());
    }
    let family = match config.stream.family {
        StreamFamily::Auto => None,
        StreamFamily::CacheAware => {
            if !model.accepts_ext(
                transcribe_cpp::ExtSlot::Stream,
                TRANSCRIBE_EXT_KIND_PARAKEET_STREAM,
            ) {
                return Err(
                    "the model does not accept the Parakeet cache-aware stream extension".into(),
                );
            }
            Some(transcribe_cpp::StreamExtension::ParakeetStream(
                transcribe_cpp::ParakeetStreamOptions {
                    att_context_right: config.stream.attention_context_right,
                },
            ))
        }
        StreamFamily::Buffered => {
            if !model.accepts_ext(
                transcribe_cpp::ExtSlot::Stream,
                TRANSCRIBE_EXT_KIND_PARAKEET_BUFFERED_STREAM,
            ) {
                return Err(
                    "the model does not accept the Parakeet buffered stream extension".into(),
                );
            }
            Some(transcribe_cpp::StreamExtension::ParakeetBuffered(
                transcribe_cpp::ParakeetBufferedStreamOptions {
                    left_ms: config.stream.left_ms,
                    chunk_ms: config.stream.chunk_ms,
                    right_ms: config.stream.right_ms,
                },
            ))
        }
    };
    Ok(transcribe_cpp::StreamOptions {
        commit_policy: match config.stream.commit_policy {
            ConfigCommitPolicy::Auto => transcribe_cpp::CommitPolicy::Auto,
            ConfigCommitPolicy::OnFinalize => transcribe_cpp::CommitPolicy::OnFinalize,
            ConfigCommitPolicy::StablePrefix => transcribe_cpp::CommitPolicy::StablePrefix,
        },
        stable_prefix_agreement_n: config.stream.stable_prefix_agreement,
        family,
    })
}

fn validate_run_capabilities(
    config: &BenchmarkConfig,
    model: &Model,
    capabilities: &transcribe_cpp::Capabilities,
) -> Result<(), String> {
    if config.run.punctuation != Toggle::Default && !model.supports(transcribe_cpp::Feature::Pnc) {
        return Err("the model does not support a runtime punctuation toggle".into());
    }
    if config.run.inverse_text_normalization != Toggle::Default
        && !model.supports(transcribe_cpp::Feature::Itn)
    {
        return Err("the model does not support inverse text normalization toggles".into());
    }
    if config.run.speculative_drafts > 0 && !capabilities.supports_spec_decode {
        return Err("the model does not support speculative decoding".into());
    }
    if let Some(language) = &config.run.language {
        if capabilities.languages.is_empty()
            || !capabilities
                .languages
                .iter()
                .any(|supported| supported.eq_ignore_ascii_case(language))
        {
            return Err(format!(
                "the model does not advertise language {language:?}"
            ));
        }
    }
    let requested_rank = timestamp_rank(config.run.timestamps);
    let maximum_rank = native_timestamp_rank(capabilities.max_timestamp_kind);
    if requested_rank > maximum_rank {
        return Err(format!(
            "requested {:?} timestamps exceed the model maximum {:?}",
            config.run.timestamps, capabilities.max_timestamp_kind
        ));
    }
    Ok(())
}

fn timestamp_rank(value: TimestampMode) -> u8 {
    match value {
        TimestampMode::None | TimestampMode::Auto => 0,
        TimestampMode::Segment => 1,
        TimestampMode::Word => 2,
        TimestampMode::Token => 3,
    }
}

fn native_timestamp_rank(value: transcribe_cpp::TimestampKind) -> u8 {
    match value {
        transcribe_cpp::TimestampKind::None | transcribe_cpp::TimestampKind::Auto => 0,
        transcribe_cpp::TimestampKind::Segment => 1,
        transcribe_cpp::TimestampKind::Word => 2,
        transcribe_cpp::TimestampKind::Token => 3,
    }
}

pub fn resolve_path(path: &Path, repo_root: &Path) -> Result<PathBuf, String> {
    let value = path.to_string_lossy();
    if value == "~" || value.starts_with("~/") {
        let home = std::env::var_os("HOME").ok_or("HOME is not set; cannot expand model path")?;
        let suffix = value.strip_prefix("~/").unwrap_or("");
        return Ok(PathBuf::from(home).join(suffix));
    }
    if path.is_absolute() {
        Ok(path.to_owned())
    } else {
        Ok(repo_root.join(path))
    }
}

fn elapsed_ms(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1_000.0
}

fn sleep_until(started: Instant, target: Duration) {
    if let Some(remaining) = target.checked_sub(started.elapsed()) {
        thread::sleep(remaining);
    }
}

pub fn text_sha256(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{
        ExecutionConfig, ModelConfig, RunConfig, SessionConfig, Task, CONFIG_SCHEMA,
    };

    fn production_config() -> BenchmarkConfig {
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
            stream: crate::config::StreamConfig::default(),
            execution: ExecutionConfig {
                mode: ExecutionMode::Warm,
                repetitions: 1,
                warmup_samples: 1,
                timeout_seconds: 30,
                order_seed: 1,
            },
            corpus_manifest: "manifest.json".into(),
        }
    }

    #[test]
    fn maps_all_typed_native_controls() {
        let mut config = production_config();
        config.run.timestamps = TimestampMode::None;
        config.run.punctuation = Toggle::Off;
        config.run.inverse_text_normalization = Toggle::On;
        config.run.keep_special_tags = true;
        config.run.speculative_drafts = 4;

        let options = native_run_options(&config);

        assert_eq!(options.timestamps, transcribe_cpp::TimestampKind::None);
        assert_eq!(options.pnc, transcribe_cpp::Pnc::Off);
        assert_eq!(options.itn, transcribe_cpp::Itn::On);
        assert!(options.keep_special_tags);
        assert_eq!(options.spec_k_drafts, 4);
        assert_eq!(
            native_backend(Backend::Metal),
            transcribe_cpp::Backend::Metal
        );
        assert_eq!(native_kv_type(KvType::F16), transcribe_cpp::KvType::F16);
    }

    #[test]
    fn resolves_repo_relative_and_home_paths() {
        let repo = Path::new("/tmp/repo");
        assert_eq!(
            resolve_path(Path::new("fixtures/a.wav"), repo).unwrap(),
            Path::new("/tmp/repo/fixtures/a.wav")
        );
        assert!(resolve_path(Path::new("~/model.gguf"), repo)
            .unwrap()
            .is_absolute());
    }

    #[test]
    #[ignore = "requires SPEAKEASY_ASR_MODEL and loads a real model"]
    fn loads_real_model_and_transcribes_silence() {
        let model = std::env::var("SPEAKEASY_ASR_MODEL").expect("SPEAKEASY_ASR_MODEL");
        let mut config = production_config();
        config.model.path = model.into();
        let mut engine =
            ParakeetEngine::load_production_parity(&config, Path::new("/")).expect("load model");

        let output = engine.warm_up().expect("transcribe silence");
        assert!(!output.truncated);
    }
}
