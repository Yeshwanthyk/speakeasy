use std::fs;
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use speech_bench::catalog::{download, ModelCatalog, CATALOG_PATH};
use speech_bench::config::BenchmarkConfig;
use speech_bench::environment::{discover_repo_root, EnvironmentFingerprint};
use speech_bench::fixtures::Corpus;
use speech_bench::metrics::{aggregate, aggregate_by_bucket, compare_with_allowed_changes};
use speech_bench::report::{length_sweep, markdown};
use speech_bench::runner::{
    default_result_path, default_worker_path, read_results, run as run_benchmark, write_results,
    RunRequest,
};

#[derive(Debug, Parser)]
#[command(name = "speech-bench", about = "Speakeasy speech benchmark driver")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// List the pinned model catalog without downloading artifacts.
    Catalog,
    /// Download one pinned model and verify it before installing it.
    Download {
        model: String,
        #[arg(long)]
        output: Option<PathBuf>,
        #[arg(long)]
        force: bool,
    },
    /// Verify an existing model against its pinned catalog entry.
    VerifyArtifact { model: String, path: PathBuf },
    /// Validate a benchmark configuration without loading a model.
    Validate { config: PathBuf },
    /// Validate a fixture manifest and every referenced WAV.
    ValidateFixtures { manifest: PathBuf },
    /// Print the comparable configuration and environment fingerprints.
    Fingerprint { config: PathBuf },
    /// Run a benchmark through isolated worker processes.
    Run {
        config: PathBuf,
        #[arg(long)]
        worker: Option<PathBuf>,
        #[arg(long)]
        output: Option<PathBuf>,
        #[arg(long)]
        baseline: Option<PathBuf>,
        #[arg(long = "allow-change", visible_alias = "allow-config-change")]
        allowed_config_changes: Vec<String>,
    },
    /// Aggregate an existing JSONL result file per fixture length bucket.
    Sweep { results: PathBuf, manifest: PathBuf },
    /// Compare two existing JSONL result files.
    Compare {
        candidate: PathBuf,
        baseline: PathBuf,
        #[arg(long = "allow-change", visible_alias = "allow-config-change")]
        allowed_config_changes: Vec<String>,
    },
}

fn main() {
    if let Err(error) = run() {
        eprintln!("speech-bench: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let cli = Cli::parse();
    match cli.command {
        Command::Catalog => {
            let catalog = load_catalog()?;
            for model in catalog.models {
                println!(
                    "{}\t{}\t{}\t{} bytes\tstreaming={}",
                    model.id,
                    model.family,
                    model.license,
                    model.artifact.bytes,
                    model.native_streaming
                );
            }
        }
        Command::Download {
            model,
            output,
            force,
        } => {
            let catalog = load_catalog()?;
            let model = catalog.find(&model)?;
            let path = download(model, output.as_deref(), force)?;
            println!("verified and installed {} at {}", model.id, path.display());
        }
        Command::VerifyArtifact { model, path } => {
            let catalog = load_catalog()?;
            let model = catalog.find(&model)?;
            let identity = model.verify(&path)?;
            println!(
                "verified {}: {} bytes sha256={}",
                identity.catalog_id, identity.actual_bytes, identity.actual_sha256
            );
        }
        Command::Validate { config } => {
            let config = BenchmarkConfig::load(&config)?;
            validate_catalog_reference(&config)?;
            println!("valid {} ({})", config.preset, config.schema);
        }
        Command::ValidateFixtures { manifest } => {
            let corpus = Corpus::load(&manifest)?;
            println!(
                "valid {} ({} fixtures, {})",
                corpus.manifest.corpus_id,
                corpus.fixtures.len(),
                corpus.manifest_sha256
            );
        }
        Command::Fingerprint { config } => {
            let config = BenchmarkConfig::load(&config)?;
            validate_catalog_reference(&config)?;
            let current = std::env::current_dir()
                .map_err(|error| format!("failed to read current directory: {error}"))?;
            let repo_root = discover_repo_root(&current)?;
            let benchmark_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let environment = EnvironmentFingerprint::collect(&repo_root, &benchmark_root);
            let value = serde_json::json!({
                "config_sha256": config.fingerprint()?,
                "environment": environment,
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&value)
                    .map_err(|error| format!("failed to serialize fingerprint: {error}"))?
            );
        }
        Command::Run {
            config,
            worker,
            output,
            baseline,
            allowed_config_changes,
        } => run_and_report(config, worker, output, baseline, allowed_config_changes)?,
        Command::Sweep { results, manifest } => {
            let records = read_results(&results)?;
            let corpus = Corpus::load(&manifest)?;
            let sweep = aggregate_by_bucket(&records, &corpus);
            print!("{}", markdown_length_sweep(&sweep));
        }
        Command::Compare {
            candidate,
            baseline,
            allowed_config_changes,
        } => {
            let candidate_records = read_results(&candidate)?;
            let baseline_records = read_results(&baseline)?;
            let comparison = compare_with_allowed_changes(
                &candidate_records,
                &baseline_records,
                &allowed_config_changes,
            );
            let report = markdown(
                "Speakeasy benchmark comparison",
                &aggregate(&candidate_records),
                Some(&comparison),
            );
            print!("{report}");
            if !comparison.comparable || !comparison.passed {
                return Err("comparison did not pass".into());
            }
        }
    }
    Ok(())
}

fn markdown_length_sweep(
    sweep: &std::collections::BTreeMap<speech_bench::fixtures::FixtureBucket, speech_bench::metrics::AggregateMetrics>,
) -> String {
    length_sweep(sweep)
}

fn load_catalog() -> Result<ModelCatalog, String> {
    let current = std::env::current_dir()
        .map_err(|error| format!("failed to read current directory: {error}"))?;
    let repo_root = discover_repo_root(&current)?;
    ModelCatalog::load(&repo_root.join(CATALOG_PATH))
}

fn validate_catalog_reference(config: &BenchmarkConfig) -> Result<(), String> {
    if let Some(catalog_id) = &config.model.catalog_id {
        let catalog = load_catalog()?;
        catalog.find(catalog_id)?;
    }
    Ok(())
}

fn run_and_report(
    config_path: PathBuf,
    worker_path: Option<PathBuf>,
    output_path: Option<PathBuf>,
    baseline_path: Option<PathBuf>,
    allowed_config_changes: Vec<String>,
) -> Result<(), String> {
    let config = BenchmarkConfig::load(&config_path)?;
    let current = std::env::current_dir()
        .map_err(|error| format!("failed to read current directory: {error}"))?;
    let repo_root = discover_repo_root(&current)?;
    let output_path =
        output_path.unwrap_or_else(|| default_result_path(&repo_root, &config.preset));
    let worker_path = worker_path.map_or_else(default_worker_path, Ok)?;
    if !worker_path.is_file() {
        return Err(format!(
            "worker executable not found at {}; build both release binaries first",
            worker_path.display()
        ));
    }

    let result = run_benchmark(&RunRequest {
        config_path,
        worker_path,
    })?;
    write_results(&output_path, &result.records)?;
    let metrics = aggregate(&result.records);
    let comparison = baseline_path
        .as_deref()
        .map(read_results)
        .transpose()?
        .map(|baseline| {
            compare_with_allowed_changes(&result.records, &baseline, &allowed_config_changes)
        });
    let report = markdown(
        &format!("Speakeasy benchmark: {}", config.preset),
        &metrics,
        comparison.as_ref(),
    );
    let report_path = output_path.with_extension("md");
    fs::write(&report_path, &report)
        .map_err(|error| format!("failed to write {}: {error}", report_path.display()))?;

    println!("{report}");
    println!("Results: {}", output_path.display());
    println!("Report: {}", report_path.display());

    if result.had_failures {
        return Err("one or more benchmark workers failed".into());
    }
    if comparison
        .as_ref()
        .is_some_and(|comparison| !comparison.comparable || !comparison.passed)
    {
        return Err("baseline comparison did not pass".into());
    }
    Ok(())
}
