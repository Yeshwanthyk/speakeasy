// Temporary smoke test: exercises the sweep CLI path end-to-end.
use std::path::PathBuf;

#[test]
fn sweep_cli_smoke() {
    let dir = tempfile::tempdir().expect("tempdir");
    let wav_dir = dir.path().join("wavs");
    std::fs::create_dir(&wav_dir).expect("wav dir");

    for (name, frames) in [("s.wav", 4_800u32), ("l.wav", 32_000)] {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 16_000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(wav_dir.join(name), spec).expect("create");
        for i in 0..frames {
            writer.write_sample(((i % 16) * 500) as i16).expect("sample");
        }
        writer.finalize().expect("finalize");
    }

    fn sha(path: &std::path::Path) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(std::fs::read(path).expect("read")))
    }

    let manifest = serde_json::json!({
        "schema": "speakeasy.fixtures.v1",
        "corpus_id": "smoke",
        "normalization_version": "wer-en-v1",
        "fixtures": [
            {"id":"s1","audio":"wavs/s.wav","audio_sha256":sha(&wav_dir.join("s.wav")),
             "reference":"hi","sample_rate_hz":16000,"channels":1,"frames":4800,
             "duration_ms":300,"bucket":"short","locale":"en"},
            {"id":"l1","audio":"wavs/l.wav","audio_sha256":sha(&wav_dir.join("l.wav")),
             "reference":"hello there","sample_rate_hz":16000,"channels":1,"frames":32000,
             "duration_ms":2000,"bucket":"long","locale":"en"}
        ]
    });
    let manifest_path = dir.path().join("manifest.json");
    std::fs::write(
        &manifest_path,
        serde_json::to_string_pretty(&manifest).expect("json"),
    )
    .expect("write");

    fn sample_record(fixture_id: &str, wall_ms: f64, audio_ms: f64) -> String {
        format!(
            r#"{{"type":"sample","schema":"x","run_id":"r","fixture_id":"{fixture_id}","repetition":0,"status":"ok","audio_ms":{audio_ms},"wall_ms":{wall_ms},"realtime_factor":{},"native":null,"stream":null,"detected_language":null,"actual_timestamp_kind":null,"text_sha256":null,"score":null,"truncated":false,"error":null}}"#,
            wall_ms / audio_ms
        )
    }
    let results_path: PathBuf = dir.path().join("results.jsonl");
    std::fs::write(
        &results_path,
        format!(
            "{}\n{}\n",
            sample_record("s1", 45.0, 300.0),
            sample_record("l1", 400.0, 2000.0)
        ),
    )
    .expect("write results");

    let records =
        speech_bench::runner::read_results(&results_path).expect("read results");
    let corpus = speech_bench::fixtures::Corpus::load(&manifest_path).expect("load corpus");
    let sweep =
        speech_bench::metrics::aggregate_by_bucket(&records, &corpus);
    assert_eq!(sweep.len(), 2, "short and long buckets both present");
    assert_eq!(
        sweep[&speech_bench::fixtures::FixtureBucket::Short].samples_ok,
        1
    );
    let report = speech_bench::report::length_sweep(&sweep);
    assert!(report.contains("| short |"));
    assert!(report.contains("| long |"));
}
