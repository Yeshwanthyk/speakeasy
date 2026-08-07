use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use clap::Parser;
use speech_bench::config::{BenchmarkConfig, ExecutionMode};
use speech_bench::engine::{resolve_path, text_sha256, ParakeetEngine};
use speech_bench::environment::{discover_repo_root, EnvironmentFingerprint};
use speech_bench::fixtures::{decode_wav, Corpus};
use speech_bench::protocol::{
    write_jsonl, CorpusIdentity, Record, RunEnd, RunStart, RunStatus, SampleRecord, SampleStatus,
    HARNESS_VERSION, PROTOCOL_SCHEMA,
};
use speech_bench::score::score_transcript;

#[derive(Debug, Parser)]
#[command(
    name = "speech-bench-worker",
    about = "Isolated Speakeasy benchmark worker"
)]
struct Cli {
    #[arg(long)]
    config: PathBuf,
    #[arg(long)]
    run_id: Option<String>,
    #[arg(long)]
    fixture_id: Option<String>,
    #[arg(long)]
    repetition: Option<u32>,
    #[arg(long)]
    skip_warmup: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("speech-bench-worker: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let started = Instant::now();
    let cli = Cli::parse();
    let config = BenchmarkConfig::load(&cli.config)?;
    let config_sha256 = config.fingerprint()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock predates Unix epoch: {error}"))?;
    let run_id = cli
        .run_id
        .unwrap_or_else(|| format!("{}-{}", now.as_millis(), std::process::id()));
    let current = std::env::current_dir()
        .map_err(|error| format!("failed to read current directory: {error}"))?;
    let repo_root = discover_repo_root(&current)?;
    let benchmark_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let environment = EnvironmentFingerprint::collect(&repo_root, &benchmark_root);
    let manifest_path = resolve_path(&config.corpus_manifest, &repo_root)?;
    let corpus = Corpus::load(&manifest_path)?;
    if let Some(fixture_id) = &cli.fixture_id {
        if !corpus
            .fixtures
            .iter()
            .any(|fixture| &fixture.definition.id == fixture_id)
        {
            return Err(format!("fixture {fixture_id:?} is not in the corpus"));
        }
    }
    let mut engine = ParakeetEngine::load_production_parity(&config, &repo_root)?;

    if !cli.skip_warmup {
        for _ in 0..config.execution.warmup_samples {
            if matches!(
                config.execution.mode,
                ExecutionMode::StreamingAccelerated | ExecutionMode::StreamingRealtime
            ) {
                engine.run_streaming(&vec![0.0; 16_000], &config)?;
            } else {
                engine.warm_up()?;
            }
        }
    }

    let mut stdout = std::io::stdout().lock();
    write_jsonl(
        &Record::RunStart(Box::new(RunStart {
            schema: PROTOCOL_SCHEMA.into(),
            harness_version: HARNESS_VERSION.into(),
            run_id: run_id.clone(),
            started_unix_ms: u64::try_from(now.as_millis()).unwrap_or(u64::MAX),
            config_sha256,
            config: config.clone(),
            environment,
            engine: engine.identity().clone(),
            corpus: CorpusIdentity {
                corpus_id: corpus.manifest.corpus_id.clone(),
                manifest_sha256: corpus.manifest_sha256.clone(),
                normalization_version: corpus.manifest.normalization_version.clone(),
                fixture_count: corpus.fixtures.len(),
                fixture_ids: corpus
                    .fixtures
                    .iter()
                    .map(|fixture| fixture.definition.id.clone())
                    .collect(),
            },
        })),
        &mut stdout,
    )?;

    let mut samples_completed = 0_u64;
    let mut failed = false;
    let repetitions = cli.repetition.map_or_else(
        || (0..config.execution.repetitions).collect(),
        |value| vec![value],
    );
    for repetition in repetitions {
        for fixture_index in fixture_order(
            corpus.fixtures.len(),
            config.execution.order_seed ^ u64::from(repetition),
        ) {
            let fixture = &corpus.fixtures[fixture_index];
            if cli
                .fixture_id
                .as_ref()
                .is_some_and(|id| id != &fixture.definition.id)
            {
                continue;
            }
            let audio = decode_wav(&fixture.audio_path)?;
            let result = if matches!(
                config.execution.mode,
                ExecutionMode::StreamingAccelerated | ExecutionMode::StreamingRealtime
            ) {
                engine.run_streaming(&audio.samples, &config)
            } else {
                engine.run(&audio.samples)
            };
            let record = match result {
                Ok(output) => {
                    if output.truncated {
                        failed = true;
                    }
                    SampleRecord {
                        schema: PROTOCOL_SCHEMA.into(),
                        run_id: run_id.clone(),
                        fixture_id: fixture.definition.id.clone(),
                        repetition,
                        status: if output.truncated {
                            SampleStatus::Error
                        } else {
                            SampleStatus::Ok
                        },
                        audio_ms: audio.duration_ms,
                        wall_ms: Some(output.wall_ms),
                        realtime_factor: Some(output.wall_ms / audio.duration_ms),
                        native: Some(output.native),
                        stream: output.stream,
                        detected_language: output.detected_language,
                        actual_timestamp_kind: Some(output.actual_timestamp_kind),
                        text_sha256: Some(text_sha256(&output.text)),
                        score: fixture
                            .definition
                            .include_in_wer
                            .then(|| score_transcript(&fixture.definition.reference, &output.text)),
                        truncated: output.truncated,
                        error: output
                            .truncated
                            .then(|| "transcript was truncated".to_owned()),
                    }
                }
                Err(error) => {
                    failed = true;
                    SampleRecord {
                        schema: PROTOCOL_SCHEMA.into(),
                        run_id: run_id.clone(),
                        fixture_id: fixture.definition.id.clone(),
                        repetition,
                        status: SampleStatus::Error,
                        audio_ms: audio.duration_ms,
                        wall_ms: None,
                        realtime_factor: None,
                        native: None,
                        stream: None,
                        detected_language: None,
                        actual_timestamp_kind: None,
                        text_sha256: None,
                        score: None,
                        truncated: false,
                        error: Some(error),
                    }
                }
            };
            write_jsonl(&Record::Sample(Box::new(record)), &mut stdout)?;
            samples_completed += 1;
        }
    }

    write_jsonl(
        &Record::RunEnd(RunEnd {
            schema: PROTOCOL_SCHEMA.into(),
            run_id,
            status: if failed {
                RunStatus::Failed
            } else {
                RunStatus::Ok
            },
            samples_completed,
            duration_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            peak_rss_bytes: None,
            error: None,
        }),
        &mut stdout,
    )
}

fn fixture_order(count: usize, mut state: u64) -> Vec<usize> {
    let mut indices = (0..count).collect::<Vec<_>>();
    for index in (1..count).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let swap_index = (state as usize) % (index + 1);
        indices.swap(index, swap_index);
    }
    indices
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_order_is_seeded_and_complete() {
        let first = fixture_order(8, 42);
        assert_eq!(first, fixture_order(8, 42));
        assert_ne!(first, fixture_order(8, 43));

        let mut sorted = first;
        sorted.sort_unstable();
        assert_eq!(sorted, (0..8).collect::<Vec<_>>());
    }
}
