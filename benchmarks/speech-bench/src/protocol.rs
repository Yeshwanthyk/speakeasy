use std::io::Write;

use serde::{Deserialize, Serialize};

use crate::config::BenchmarkConfig;
use crate::engine::{EngineIdentity, NativeTimings, StreamMetrics};
use crate::environment::EnvironmentFingerprint;
use crate::score::TranscriptScore;

pub const PROTOCOL_SCHEMA: &str = "speakeasy.speech-bench.result.v1";
pub const HARNESS_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Record {
    RunStart(Box<RunStart>),
    Sample(Box<SampleRecord>),
    RunEnd(RunEnd),
    DriverError(DriverError),
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RunStart {
    pub schema: String,
    pub harness_version: String,
    pub run_id: String,
    pub started_unix_ms: u64,
    pub config_sha256: String,
    pub config: BenchmarkConfig,
    pub environment: EnvironmentFingerprint,
    pub engine: EngineIdentity,
    pub corpus: CorpusIdentity,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CorpusIdentity {
    pub corpus_id: String,
    pub manifest_sha256: String,
    pub normalization_version: String,
    pub fixture_count: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SampleRecord {
    pub schema: String,
    pub run_id: String,
    pub fixture_id: String,
    pub repetition: u32,
    pub status: SampleStatus,
    pub audio_ms: f64,
    pub wall_ms: Option<f64>,
    pub realtime_factor: Option<f64>,
    pub native: Option<NativeTimings>,
    pub stream: Option<StreamMetrics>,
    pub detected_language: Option<String>,
    pub actual_timestamp_kind: Option<String>,
    pub text_sha256: Option<String>,
    pub score: Option<TranscriptScore>,
    pub truncated: bool,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SampleStatus {
    Ok,
    Error,
    Timeout,
    Crashed,
    Skipped,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunEnd {
    pub schema: String,
    pub run_id: String,
    pub status: RunStatus,
    pub samples_completed: u64,
    pub duration_ms: u64,
    pub peak_rss_bytes: Option<u64>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DriverError {
    pub schema: String,
    pub run_id: String,
    pub kind: DriverErrorKind,
    pub duration_ms: u64,
    pub message: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DriverErrorKind {
    Spawn,
    Timeout,
    Crash,
    Protocol,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Ok,
    Failed,
    Interrupted,
}

pub fn write_jsonl(record: &Record, mut writer: impl Write) -> Result<(), String> {
    serde_json::to_writer(&mut writer, record)
        .map_err(|error| format!("failed to serialize result record: {error}"))?;
    writer
        .write_all(b"\n")
        .map_err(|error| format!("failed to write result record: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonl_has_one_parseable_record_per_line() {
        let record = Record::RunEnd(RunEnd {
            schema: PROTOCOL_SCHEMA.into(),
            run_id: "run-1".into(),
            status: RunStatus::Ok,
            samples_completed: 0,
            duration_ms: 4,
            peak_rss_bytes: None,
            error: None,
        });
        let mut output = Vec::new();

        write_jsonl(&record, &mut output).expect("write record");

        assert_eq!(output.iter().filter(|byte| **byte == b'\n').count(), 1);
        let decoded: Record = serde_json::from_slice(&output).expect("decode record");
        assert_eq!(decoded, record);
    }
}
