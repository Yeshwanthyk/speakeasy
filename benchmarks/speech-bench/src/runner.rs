use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use wait_timeout::ChildExt;

use crate::config::{BenchmarkConfig, ExecutionMode};
use crate::engine::resolve_path;
use crate::environment::discover_repo_root;
use crate::fixtures::Corpus;
use crate::protocol::{
    write_jsonl, DriverError, DriverErrorKind, Record, RunStatus, PROTOCOL_SCHEMA,
};

#[derive(Clone, Debug)]
pub struct RunRequest {
    pub config_path: PathBuf,
    pub worker_path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct RunResult {
    pub records: Vec<Record>,
    pub had_failures: bool,
}

#[derive(Clone, Debug)]
struct WorkerJob {
    run_id: String,
    fixture_id: Option<String>,
    repetition: Option<u32>,
    skip_warmup: bool,
}

pub fn run(request: &RunRequest) -> Result<RunResult, String> {
    let config = BenchmarkConfig::load(&request.config_path)?;
    let current = std::env::current_dir()
        .map_err(|error| format!("failed to read current directory: {error}"))?;
    let repo_root = discover_repo_root(&current)?;
    let manifest_path = resolve_path(&config.corpus_manifest, &repo_root)?;
    let corpus = Corpus::load(&manifest_path)?;
    let timestamp = unix_ms();
    let jobs = build_jobs(&config, &corpus, timestamp);
    let timeout = Duration::from_secs(config.execution.timeout_seconds);
    let mut records = Vec::new();
    let mut had_failures = false;

    for job in jobs {
        let mut command = Command::new(&request.worker_path);
        command
            .arg("--config")
            .arg(&request.config_path)
            .arg("--run-id")
            .arg(&job.run_id);
        if let Some(fixture_id) = &job.fixture_id {
            command.arg("--fixture-id").arg(fixture_id);
        }
        if let Some(repetition) = job.repetition {
            command.arg("--repetition").arg(repetition.to_string());
        }
        if job.skip_warmup {
            command.arg("--skip-warmup");
        }

        let outcome = run_child(command, timeout);
        match outcome {
            Ok(mut outcome) => {
                for record in &mut outcome.records {
                    if let Record::RunEnd(end) = record {
                        end.peak_rss_bytes = Some(outcome.peak_rss_bytes);
                        if end.status != RunStatus::Ok {
                            had_failures = true;
                        }
                    }
                }
                if !outcome.stderr.trim().is_empty() {
                    eprintln!(
                        "worker {} diagnostics:\n{}",
                        job.run_id,
                        outcome.stderr.trim()
                    );
                }
                records.extend(outcome.records);
            }
            Err(error) => {
                had_failures = true;
                records.push(Record::DriverError(DriverError {
                    schema: PROTOCOL_SCHEMA.into(),
                    run_id: job.run_id,
                    kind: error.kind,
                    duration_ms: error.duration_ms,
                    message: error.message,
                }));
            }
        }
    }

    Ok(RunResult {
        records,
        had_failures,
    })
}

pub fn write_results(path: &Path, records: &[Record]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }
    let mut file = File::create(path)
        .map_err(|error| format!("failed to create {}: {error}", path.display()))?;
    for record in records {
        write_jsonl(record, &mut file)?;
    }
    Ok(())
}

pub fn read_results(path: &Path) -> Result<Vec<Record>, String> {
    let file = File::open(path)
        .map_err(|error| format!("failed to open result {}: {error}", path.display()))?;
    let mut records = Vec::new();
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(|error| {
            format!(
                "failed to read result {} line {}: {error}",
                path.display(),
                index + 1
            )
        })?;
        if line.trim().is_empty() {
            continue;
        }
        records.push(serde_json::from_str(&line).map_err(|error| {
            format!(
                "invalid result {} line {}: {error}",
                path.display(),
                index + 1
            )
        })?);
    }
    Ok(records)
}

pub fn default_worker_path() -> Result<PathBuf, String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("failed to locate benchmark executable: {error}"))?;
    let worker_name = if cfg!(windows) {
        "speech-bench-worker.exe"
    } else {
        "speech-bench-worker"
    };
    Ok(executable.with_file_name(worker_name))
}

pub fn default_result_path(repo_root: &Path, preset: &str) -> PathBuf {
    repo_root
        .join("benchmarks/results")
        .join(format!("{}-{preset}.jsonl", unix_ms()))
}

fn build_jobs(config: &BenchmarkConfig, corpus: &Corpus, timestamp: u64) -> Vec<WorkerJob> {
    if config.execution.mode != ExecutionMode::ProcessCold {
        return vec![WorkerJob {
            run_id: format!("{timestamp}-warm"),
            fixture_id: None,
            repetition: None,
            skip_warmup: false,
        }];
    }

    let mut jobs = Vec::new();
    for repetition in 0..config.execution.repetitions {
        for fixture in &corpus.fixtures {
            jobs.push(WorkerJob {
                run_id: format!("{timestamp}-cold-{repetition}-{}", fixture.definition.id),
                fixture_id: Some(fixture.definition.id.clone()),
                repetition: Some(repetition),
                skip_warmup: true,
            });
        }
    }
    jobs
}

#[derive(Debug)]
struct ChildOutcome {
    records: Vec<Record>,
    stderr: String,
    peak_rss_bytes: u64,
}

struct ChildFailure {
    kind: DriverErrorKind,
    duration_ms: u64,
    message: String,
}

fn run_child(mut command: Command, timeout: Duration) -> Result<ChildOutcome, ChildFailure> {
    let started = Instant::now();
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| ChildFailure {
        kind: DriverErrorKind::Spawn,
        duration_ms: elapsed_u64(started),
        message: format!("failed to spawn worker: {error}"),
    })?;
    let pid = child.id();
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let stdout_reader = thread::spawn(move || read_all(stdout));
    let stderr_reader = thread::spawn(move || read_all(stderr));
    let stop_sampling = Arc::new(AtomicBool::new(false));
    let peak_rss = Arc::new(AtomicU64::new(0));
    let sampler = spawn_rss_sampler(pid, Arc::clone(&stop_sampling), Arc::clone(&peak_rss));

    let status = child.wait_timeout(timeout).map_err(|error| ChildFailure {
        kind: DriverErrorKind::Crash,
        duration_ms: elapsed_u64(started),
        message: format!("failed while waiting for worker: {error}"),
    })?;
    let timed_out = status.is_none();
    let status = if let Some(status) = status {
        status
    } else {
        let _ = child.kill();
        child.wait().map_err(|error| ChildFailure {
            kind: DriverErrorKind::Timeout,
            duration_ms: elapsed_u64(started),
            message: format!("worker timed out and could not be reaped: {error}"),
        })?
    };
    stop_sampling.store(true, Ordering::Relaxed);
    let _ = sampler.join();
    let stdout = stdout_reader
        .join()
        .unwrap_or_else(|_| Err("stdout reader panicked".into()))
        .map_err(|message| ChildFailure {
            kind: DriverErrorKind::Protocol,
            duration_ms: elapsed_u64(started),
            message,
        })?;
    let stderr = stderr_reader
        .join()
        .unwrap_or_else(|_| Err("stderr reader panicked".into()))
        .map_err(|message| ChildFailure {
            kind: DriverErrorKind::Protocol,
            duration_ms: elapsed_u64(started),
            message,
        })?;

    if timed_out {
        return Err(ChildFailure {
            kind: DriverErrorKind::Timeout,
            duration_ms: elapsed_u64(started),
            message: format!("worker exceeded {} second timeout", timeout.as_secs()),
        });
    }
    if !status.success() {
        return Err(ChildFailure {
            kind: DriverErrorKind::Crash,
            duration_ms: elapsed_u64(started),
            message: format!(
                "worker exited with {status}: {}",
                tail(&stderr, 4_096).trim()
            ),
        });
    }

    let records = parse_jsonl(&stdout).map_err(|message| ChildFailure {
        kind: DriverErrorKind::Protocol,
        duration_ms: elapsed_u64(started),
        message,
    })?;
    Ok(ChildOutcome {
        records,
        stderr,
        peak_rss_bytes: peak_rss.load(Ordering::Relaxed),
    })
}

fn parse_jsonl(value: &str) -> Result<Vec<Record>, String> {
    value
        .lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            serde_json::from_str(line)
                .map_err(|error| format!("invalid worker JSONL line {}: {error}", index + 1))
        })
        .collect()
}

fn read_all(mut reader: impl Read) -> Result<String, String> {
    let mut value = String::new();
    reader
        .read_to_string(&mut value)
        .map_err(|error| format!("failed to read child output: {error}"))?;
    Ok(value)
}

fn spawn_rss_sampler(
    pid: u32,
    stop: Arc<AtomicBool>,
    peak: Arc<AtomicU64>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            if let Some(bytes) = process_rss_bytes(pid) {
                peak.fetch_max(bytes, Ordering::Relaxed);
            }
            thread::sleep(Duration::from_millis(20));
        }
    })
}

fn process_rss_bytes(pid: u32) -> Option<u64> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let kibibytes = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .ok()?;
    kibibytes.checked_mul(1_024)
}

fn unix_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| u64::try_from(duration.as_millis()).ok())
        .unwrap_or(0)
}

fn elapsed_u64(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn tail(value: &str, max_chars: usize) -> &str {
    let start = value
        .char_indices()
        .rev()
        .nth(max_chars)
        .map_or(0, |(index, _)| index);
    &value[start..]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_rejects_non_json_diagnostics_on_stdout() {
        let error = parse_jsonl("native log\n").unwrap_err();
        assert!(error.contains("line 1"));
    }

    #[test]
    fn child_timeout_is_bounded() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 2"]);

        let error = run_child(command, Duration::from_millis(20)).unwrap_err();

        assert_eq!(error.kind, DriverErrorKind::Timeout);
    }
}
