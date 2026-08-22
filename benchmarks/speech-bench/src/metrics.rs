use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::config::ExecutionMode;
use crate::fixtures::{Corpus, FixtureBucket};
use crate::protocol::{Record, RunStart, RunStatus, SampleStatus, PROTOCOL_SCHEMA};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AggregateMetrics {
    pub samples_total: u64,
    pub samples_ok: u64,
    pub samples_failed: u64,
    pub driver_errors: u64,
    pub wall_p50_ms: Option<f64>,
    pub wall_p95_ms: Option<f64>,
    pub realtime_factor_p50: Option<f64>,
    pub realtime_factor_p95: Option<f64>,
    pub first_hypothesis_p50_ms: Option<f64>,
    pub first_commit_p50_ms: Option<f64>,
    pub release_to_final_p50_ms: Option<f64>,
    pub release_to_final_p95_ms: Option<f64>,
    pub finalize_p95_ms: Option<f64>,
    pub model_load_p50_ms: Option<f64>,
    pub peak_rss_bytes: Option<u64>,
    pub corpus_micro_wer: Option<f64>,
    pub corpus_reference_words: u64,
    pub corpus_word_errors: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Comparison {
    pub comparable: bool,
    pub candidate_key: Option<String>,
    pub baseline_key: Option<String>,
    pub passed: bool,
    pub failures: Vec<String>,
}

pub fn aggregate(records: &[Record]) -> AggregateMetrics {
    let mut wall = Vec::new();
    let mut realtime_factor = Vec::new();
    let mut first_hypothesis = Vec::new();
    let mut first_commit = Vec::new();
    let mut release_to_final = Vec::new();
    let mut finalize = Vec::new();
    let mut model_load = Vec::new();
    let mut peak_rss = None;
    let mut metrics = AggregateMetrics::default();

    for record in records {
        match record {
            Record::RunStart(start) => model_load.push(start.engine.startup.model_load_ms),
            Record::Sample(sample) => {
                metrics.samples_total += 1;
                if sample.status == SampleStatus::Ok {
                    metrics.samples_ok += 1;
                } else {
                    metrics.samples_failed += 1;
                }
                if let Some(value) = sample.wall_ms.filter(|value| value.is_finite()) {
                    wall.push(value);
                }
                if let Some(value) = sample.realtime_factor.filter(|value| value.is_finite()) {
                    realtime_factor.push(value);
                }
                if let Some(stream) = sample.stream {
                    if let Some(value) =
                        stream.first_hypothesis_ms.filter(|value| value.is_finite())
                    {
                        first_hypothesis.push(value);
                    }
                    if let Some(value) = stream.first_commit_ms.filter(|value| value.is_finite()) {
                        first_commit.push(value);
                    }
                    if stream.release_to_final_ms.is_finite() {
                        release_to_final.push(stream.release_to_final_ms);
                    }
                    if stream.finalize_ms.is_finite() {
                        finalize.push(stream.finalize_ms);
                    }
                }
                if let Some(score) = &sample.score {
                    metrics.corpus_reference_words += score.lexical.reference_words;
                    metrics.corpus_word_errors += score.lexical.edits.errors();
                }
            }
            Record::RunEnd(end) => {
                if let Some(value) = end.peak_rss_bytes {
                    peak_rss = Some(peak_rss.map_or(value, |existing: u64| existing.max(value)));
                }
            }
            Record::DriverError(_) => metrics.driver_errors += 1,
        }
    }

    metrics.wall_p50_ms = percentile(&mut wall, 0.50);
    metrics.wall_p95_ms = percentile(&mut wall, 0.95);
    metrics.realtime_factor_p50 = percentile(&mut realtime_factor, 0.50);
    metrics.realtime_factor_p95 = percentile(&mut realtime_factor, 0.95);
    metrics.first_hypothesis_p50_ms = percentile(&mut first_hypothesis, 0.50);
    metrics.first_commit_p50_ms = percentile(&mut first_commit, 0.50);
    metrics.release_to_final_p50_ms = percentile(&mut release_to_final, 0.50);
    metrics.release_to_final_p95_ms = percentile(&mut release_to_final, 0.95);
    metrics.finalize_p95_ms = percentile(&mut finalize, 0.95);
    metrics.model_load_p50_ms = percentile(&mut model_load, 0.50);
    metrics.peak_rss_bytes = peak_rss;
    metrics.corpus_micro_wer = (metrics.corpus_reference_words > 0)
        .then(|| metrics.corpus_word_errors as f64 / metrics.corpus_reference_words as f64);
    metrics
}

pub fn compare(candidate_records: &[Record], baseline_records: &[Record]) -> Comparison {
    compare_with_allowed_changes(candidate_records, baseline_records, &[])
}

pub fn compare_with_allowed_changes(
    candidate_records: &[Record],
    baseline_records: &[Record],
    allowed_config_changes: &[String],
) -> Comparison {
    let candidate_start = first_start(candidate_records);
    let baseline_start = first_start(baseline_records);
    let key_result = validate_allowed_changes(allowed_config_changes);
    if let Err(error) = key_result {
        return Comparison {
            comparable: false,
            candidate_key: None,
            baseline_key: None,
            passed: false,
            failures: vec![error],
        };
    }
    let mut evidence_failures = validate_evidence(candidate_records)
        .into_iter()
        .map(|failure| format!("candidate: {failure}"))
        .collect::<Vec<_>>();
    evidence_failures.extend(
        validate_evidence(baseline_records)
            .into_iter()
            .map(|failure| format!("baseline: {failure}")),
    );
    if !evidence_failures.is_empty() {
        return Comparison {
            comparable: false,
            candidate_key: candidate_start
                .map(|start| comparison_key(start, allowed_config_changes)),
            baseline_key: baseline_start.map(|start| comparison_key(start, allowed_config_changes)),
            passed: false,
            failures: evidence_failures,
        };
    }
    let candidate_key = candidate_start.map(|start| comparison_key(start, allowed_config_changes));
    let baseline_key = baseline_start.map(|start| comparison_key(start, allowed_config_changes));
    if candidate_key.is_none() || baseline_key.is_none() || candidate_key != baseline_key {
        return Comparison {
            comparable: false,
            candidate_key,
            baseline_key,
            passed: false,
            failures: vec!["host/model/corpus/config/build fingerprints do not match".into()],
        };
    }

    let candidate = aggregate(candidate_records);
    let baseline = aggregate(baseline_records);
    let mut failures = Vec::new();
    if candidate.samples_failed > 0 || candidate.driver_errors > 0 {
        failures.push(format!(
            "candidate has {} failed samples and {} driver errors",
            candidate.samples_failed, candidate.driver_errors
        ));
    }
    if allowed_config_changes
        .iter()
        .any(|value| value == "execution.mode")
    {
        if let (Some(candidate), Some(baseline)) =
            (candidate.release_to_final_p95_ms, baseline.wall_p95_ms)
        {
            let required_improvement = (baseline * 0.20).min(50.0);
            if candidate > baseline - required_improvement {
                failures.push(format!(
                    "streaming release-to-final p95 is not materially better: candidate {candidate:.2} ms, batch {baseline:.2} ms"
                ));
            }
        }
    } else {
        check_upper_regression(
            "warm p50",
            candidate.wall_p50_ms,
            baseline.wall_p50_ms,
            0.05,
            10.0,
            &mut failures,
        );
        check_upper_regression(
            "warm p95",
            candidate.wall_p95_ms,
            baseline.wall_p95_ms,
            0.10,
            25.0,
            &mut failures,
        );
    }
    check_upper_regression(
        "process-cold model load p50",
        candidate.model_load_p50_ms,
        baseline.model_load_p50_ms,
        0.15,
        500.0,
        &mut failures,
    );
    if let (Some(candidate), Some(baseline)) = (candidate.peak_rss_bytes, baseline.peak_rss_bytes) {
        let allowed = baseline.saturating_add(((baseline as f64 * 0.10) as u64).max(128 << 20));
        if candidate > allowed {
            failures.push(format!(
                "peak RSS regressed: candidate {candidate} bytes, baseline {baseline} bytes, allowed {allowed} bytes"
            ));
        }
    }
    if let (Some(candidate), Some(baseline)) =
        (candidate.corpus_micro_wer, baseline.corpus_micro_wer)
    {
        if candidate > baseline + 0.005 {
            failures.push(format!(
                "corpus micro-WER regressed: candidate {candidate:.4}, baseline {baseline:.4}"
            ));
        }
    }

    Comparison {
        comparable: true,
        candidate_key,
        baseline_key,
        passed: failures.is_empty(),
        failures,
    }
}

pub fn validate_evidence(records: &[Record]) -> Vec<String> {
    let mut failures = Vec::new();
    if records.is_empty() {
        return vec!["result is empty".into()];
    }

    let mut starts: HashMap<&str, Vec<&RunStart>> = HashMap::new();
    let mut ends = HashMap::<&str, Vec<&crate::protocol::RunEnd>>::new();
    let mut samples = HashMap::<&str, Vec<&crate::protocol::SampleRecord>>::new();
    for record in records {
        let (schema, run_id) = match record {
            Record::RunStart(value) => {
                starts.entry(&value.run_id).or_default().push(value);
                (&value.schema, value.run_id.as_str())
            }
            Record::Sample(value) => {
                samples.entry(&value.run_id).or_default().push(value);
                (&value.schema, value.run_id.as_str())
            }
            Record::RunEnd(value) => {
                ends.entry(&value.run_id).or_default().push(value);
                (&value.schema, value.run_id.as_str())
            }
            Record::DriverError(value) => {
                failures.push(format!(
                    "run {:?} has driver error: {}",
                    value.run_id, value.message
                ));
                (&value.schema, value.run_id.as_str())
            }
        };
        if schema != PROTOCOL_SCHEMA {
            failures.push(format!("run {run_id:?} has unsupported schema {schema:?}"));
        }
    }

    for run_id in starts.keys().chain(ends.keys()).chain(samples.keys()) {
        let start_count = starts.get(run_id).map_or(0, Vec::len);
        let end_count = ends.get(run_id).map_or(0, Vec::len);
        if start_count != 1 {
            failures.push(format!(
                "run {run_id:?} has {start_count} start records; expected 1"
            ));
        }
        if end_count != 1 {
            failures.push(format!(
                "run {run_id:?} has {end_count} end records; expected 1"
            ));
        }
    }

    let Some(first_start) = records.iter().find_map(|record| match record {
        Record::RunStart(start) => Some(start.as_ref()),
        _ => None,
    }) else {
        failures.push("result has no run start".into());
        return failures;
    };

    for run_starts in starts.values() {
        for start in run_starts {
            if start.config_sha256 != first_start.config_sha256
                || start.corpus != first_start.corpus
                || start.config.execution.repetitions != first_start.config.execution.repetitions
            {
                failures.push("run starts do not share one config and corpus identity".into());
            }
        }
    }

    if first_start.corpus.fixture_count != first_start.corpus.fixture_ids.len()
        || first_start
            .corpus
            .fixture_ids
            .iter()
            .collect::<HashSet<_>>()
            .len()
            != first_start.corpus.fixture_ids.len()
    {
        failures.push("corpus fixture identity is incomplete or duplicated".into());
    }

    let mut cells = HashSet::new();
    for (run_id, run_samples) in &samples {
        let Some(start) = starts
            .get(run_id)
            .and_then(|values| values.first())
            .copied()
        else {
            continue;
        };
        for sample in run_samples {
            if !start.corpus.fixture_ids.contains(&sample.fixture_id) {
                failures.push(format!(
                    "run {run_id:?} contains unexpected fixture {:?}",
                    sample.fixture_id
                ));
            }
            if sample.repetition >= start.config.execution.repetitions {
                failures.push(format!(
                    "run {run_id:?} contains unexpected repetition {}",
                    sample.repetition
                ));
            }
            if !cells.insert((sample.fixture_id.as_str(), sample.repetition)) {
                failures.push(format!(
                    "duplicate fixture/repetition cell {:?}/{}",
                    sample.fixture_id, sample.repetition
                ));
            }
            if let Some(score) = &sample.score {
                if score.lexical.normalization_version != start.corpus.normalization_version
                    || score.punctuation_sensitive.normalization_version
                        != start.corpus.normalization_version
                {
                    failures.push(format!(
                        "sample {:?} normalization does not match its corpus identity",
                        sample.fixture_id
                    ));
                }
            }
            if sample.status == SampleStatus::Ok {
                if sample.wall_ms.is_none()
                    || sample.realtime_factor.is_none()
                    || sample.native.is_none()
                    || sample.text_sha256.is_none()
                    || sample.score.is_none()
                {
                    failures.push(format!(
                        "sample {:?} is missing required metrics",
                        sample.fixture_id
                    ));
                }
                if matches!(
                    start.config.execution.mode,
                    ExecutionMode::StreamingAccelerated | ExecutionMode::StreamingRealtime
                ) && sample.stream.is_none()
                {
                    failures.push(format!(
                        "streaming sample {:?} is missing stream metrics",
                        sample.fixture_id
                    ));
                }
            }
        }
        if let Some(end) = ends.get(run_id).and_then(|values| values.first()) {
            if end.status != RunStatus::Ok {
                failures.push(format!("run {run_id:?} ended with status {:?}", end.status));
            }
            if end.samples_completed != run_samples.len() as u64 {
                failures.push(format!(
                    "run {run_id:?} end count does not match sample records"
                ));
            }
            if end.peak_rss_bytes.is_none() {
                failures.push(format!("run {run_id:?} is missing peak RSS evidence"));
            }
        }
    }

    let expected_cells =
        first_start.corpus.fixture_count * first_start.config.execution.repetitions as usize;
    if cells.len() != expected_cells {
        failures.push(format!(
            "result has {} unique fixture/repetition cells; expected {expected_cells}",
            cells.len()
        ));
    }
    failures
}

fn first_start(records: &[Record]) -> Option<&RunStart> {
    records.iter().find_map(|record| match record {
        Record::RunStart(start) => Some(start.as_ref()),
        _ => None,
    })
}

fn comparison_key(start: &RunStart, allowed_config_changes: &[String]) -> String {
    let mut value = serde_json::json!({
        "protocol": start.schema,
        "harness": start.harness_version,
        "repository_commit": start.environment.repository_commit,
        "repository_dirty_hash": start.environment.repository_dirty_hash,
        "os": start.environment.operating_system,
        "architecture": start.environment.architecture,
        "hardware_model": start.environment.hardware_model,
        "logical_cpu_count": start.environment.logical_cpu_count,
        "memory_bytes": start.environment.memory_bytes,
        "production_lock": start.environment.production_lock_sha256,
        "benchmark_lock": start.environment.benchmark_lock_sha256,
        "runtime_version": start.engine.runtime_version,
        "header_hash": start.engine.header_hash,
        "model_sha256": start.engine.model_sha256,
        "model_architecture": start.engine.architecture,
        "model_variant": start.engine.variant,
        "actual_backend": start.engine.actual_backend,
        "device": start.engine.device,
        "corpus_id": start.corpus.corpus_id,
        "manifest_sha256": start.corpus.manifest_sha256,
        "normalization": start.corpus.normalization_version,
        "config": {
            "model": start.config.model,
            "session": start.config.session,
            "run": start.config.run,
            "stream": start.config.stream,
            "execution": {
                "mode": start.config.execution.mode,
                "repetitions": start.config.execution.repetitions,
                "warmup_samples": start.config.execution.warmup_samples,
                "order_seed": start.config.execution.order_seed,
            }
        }
    });
    for path in allowed_config_changes {
        match path.as_str() {
            "build.repository" => {
                value["repository_commit"] = serde_json::Value::Null;
                value["repository_dirty_hash"] = serde_json::Value::Null;
            }
            "build.lockfiles" => {
                value["production_lock"] = serde_json::Value::Null;
                value["benchmark_lock"] = serde_json::Value::Null;
            }
            _ => remove_json_path(&mut value["config"], path),
        }
        if path == "model.backend" || path == "model.gpu_device" {
            value["actual_backend"] = serde_json::Value::Null;
            value["device"] = serde_json::Value::Null;
        }
        if path == "model.path" || path == "model.catalog_id" {
            value["model_sha256"] = serde_json::Value::Null;
            value["model_architecture"] = serde_json::Value::Null;
            value["model_variant"] = serde_json::Value::Null;
        }
    }
    let bytes = serde_json::to_vec(&value).expect("comparison identity is serializable");
    hex::encode(Sha256::digest(bytes))
}

fn validate_allowed_changes(values: &[String]) -> Result<(), String> {
    const ALLOWED: &[&str] = &[
        "build.repository",
        "build.lockfiles",
        "model.backend",
        "model.gpu_device",
        "model.path",
        "model.catalog_id",
        "session.threads",
        "session.kv_type",
        "session.context",
        "run.timestamps",
        "run.punctuation",
        "run.inverse_text_normalization",
        "run.language",
        "run.keep_special_tags",
        "run.speculative_drafts",
        "stream.commit_policy",
        "stream.stable_prefix_agreement",
        "stream.feed_chunk_ms",
        "stream.family",
        "stream.attention_context_right",
        "stream.left_ms",
        "stream.chunk_ms",
        "stream.right_ms",
        "execution.mode",
    ];
    for value in values {
        if !ALLOWED.contains(&value.as_str()) {
            return Err(format!("unsupported allowed config change {value:?}"));
        }
    }
    Ok(())
}

fn remove_json_path(value: &mut serde_json::Value, path: &str) {
    let mut parts = path.split('.');
    let Some(section) = parts.next() else {
        return;
    };
    let Some(field) = parts.next() else {
        return;
    };
    if parts.next().is_none() {
        if let Some(object) = value
            .get_mut(section)
            .and_then(serde_json::Value::as_object_mut)
        {
            object.remove(field);
        }
    }
}

fn percentile(values: &mut [f64], quantile: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let rank = (quantile * values.len() as f64).ceil() as usize;
    Some(values[rank.saturating_sub(1).min(values.len() - 1)])
}

fn check_upper_regression(
    name: &str,
    candidate: Option<f64>,
    baseline: Option<f64>,
    relative: f64,
    absolute_ms: f64,
    failures: &mut Vec<String>,
) {
    if let (Some(candidate), Some(baseline)) = (candidate, baseline) {
        let allowed = baseline + (baseline * relative).max(absolute_ms);
        if candidate > allowed {
            failures.push(format!(
                "{name} regressed: candidate {candidate:.2} ms, baseline {baseline:.2} ms, allowed {allowed:.2} ms"
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incomplete_evidence_cannot_pass_comparison() {
        let comparison = compare(&[], &[]);

        assert!(!comparison.comparable);
        assert!(!comparison.passed);
        assert!(comparison
            .failures
            .iter()
            .any(|failure| failure.contains("result is empty")));
    }

    #[test]
    fn percentile_uses_nearest_rank() {
        let mut values = vec![5.0, 1.0, 4.0, 2.0, 3.0];
        assert_eq!(percentile(&mut values, 0.5), Some(3.0));
        assert_eq!(percentile(&mut values, 0.95), Some(5.0));
    }

    #[test]
    fn bucket_aggregation_groups_by_fixture_bucket() {
        use crate::fixtures::{Corpus, Fixture, FixtureBucket, FixtureManifest};
        use crate::protocol::{Record, SampleRecord, SampleStatus};

        fn fixture(id: &str, bucket: FixtureBucket) -> Fixture {
            Fixture {
                id: id.to_string(),
                audio: std::path::PathBuf::from(format!("{id}.wav")),
                audio_sha256: "0".repeat(64),
                reference: "reference".to_string(),
                sample_rate_hz: 16_000,
                channels: 1,
                frames: 16_000,
                duration_ms: 1_000,
                bucket,
                locale: "en".to_string(),
                conditions: vec![],
                tags: vec![],
                include_in_wer: true,
            }
        }

        fn sample(fixture_id: &str, wall_ms: f64) -> Record {
            Record::Sample(Box::new(SampleRecord {
                schema: "s".to_string(),
                run_id: "run".to_string(),
                fixture_id: fixture_id.to_string(),
                repetition: 0,
                status: SampleStatus::Ok,
                audio_ms: 1_000.0,
                wall_ms: Some(wall_ms),
                realtime_factor: Some(wall_ms / 1_000.0),
                native: None,
                stream: None,
                detected_language: None,
                actual_timestamp_kind: None,
                text_sha256: None,
                score: None,
                truncated: false,
                error: None,
            }))
        }

        let manifest = FixtureManifest {
            schema: "s".to_string(),
            corpus_id: "corpus".to_string(),
            normalization_version: "v1".to_string(),
            fixtures: vec![
                fixture("short-a", FixtureBucket::Short),
                fixture("long-a", FixtureBucket::Long),
                fixture("long-b", FixtureBucket::Long),
                fixture("long-c", FixtureBucket::Long),
            ],
        };
        let fixtures = manifest
            .fixtures
            .iter()
            .map(|definition| crate::fixtures::ValidatedFixture {
                audio_path: definition.audio.clone(),
                definition: definition.clone(),
            })
            .collect();
        let corpus = Corpus {
            manifest: manifest.clone(),
            manifest_path: std::path::PathBuf::from("manifest.json"),
            manifest_sha256: String::new(),
            fixtures,
        };

        let records = vec![
            sample("short-a", 100.0),
            sample("long-a", 900.0),
            sample("long-b", 1_000.0),
            sample("long-c", 1_100.0),
        ];
        let sweep = aggregate_by_bucket(&records, &corpus);

        assert_eq!(sweep.len(), 2);
        let short = &sweep[&FixtureBucket::Short];
        let long = &sweep[&FixtureBucket::Long];
        assert_eq!(short.wall_p50_ms, Some(100.0));
        assert_eq!(long.wall_p50_ms, Some(1_000.0));
        assert_eq!(long.samples_ok, 3);
    }
}


/// Per-utterance-length aggregation: joins sample records with their
/// fixture buckets and aggregates each bucket separately, so latency
/// growth as utterances grow is visible instead of blended into one
/// corpus-wide number.
pub fn aggregate_by_bucket(
    records: &[Record],
    corpus: &Corpus,
) -> BTreeMap<FixtureBucket, AggregateMetrics> {
    let mut bucket_by_fixture: HashMap<&str, FixtureBucket> = HashMap::new();
    for fixture in &corpus.fixtures {
        bucket_by_fixture.insert(
            fixture.definition.id.as_str(),
            fixture.definition.bucket,
        );
    }

    let mut grouped: BTreeMap<FixtureBucket, Vec<Record>> = BTreeMap::new();
    for record in records {
        if let Record::Sample(sample) = record {
            if let Some(bucket) = bucket_by_fixture.get(sample.fixture_id.as_str()) {
                grouped.entry(*bucket).or_default().push(record.clone());
            }
        }
    }

    grouped
        .into_iter()
        .map(|(bucket, records)| (bucket, aggregate(&records)))
        .collect()
}
