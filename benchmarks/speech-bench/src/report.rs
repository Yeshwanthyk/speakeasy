use std::fmt::Write as _;

use crate::metrics::{AggregateMetrics, Comparison};

pub fn markdown(
    title: &str,
    metrics: &AggregateMetrics,
    comparison: Option<&Comparison>,
) -> String {
    let mut output = String::new();
    writeln!(output, "# {title}\n").expect("write string");
    writeln!(output, "| Metric | Result |").expect("write string");
    writeln!(output, "|---|---:|").expect("write string");
    row(&mut output, "Samples", metrics.samples_total.to_string());
    row(&mut output, "Successful", metrics.samples_ok.to_string());
    row(&mut output, "Failed", metrics.samples_failed.to_string());
    row(
        &mut output,
        "Driver errors",
        metrics.driver_errors.to_string(),
    );
    row(&mut output, "Wall p50", format_ms(metrics.wall_p50_ms));
    row(&mut output, "Wall p95", format_ms(metrics.wall_p95_ms));
    row(
        &mut output,
        "RTF p50",
        format_number(metrics.realtime_factor_p50),
    );
    row(
        &mut output,
        "RTF p95",
        format_number(metrics.realtime_factor_p95),
    );
    row(
        &mut output,
        "First hypothesis p50",
        format_ms(metrics.first_hypothesis_p50_ms),
    );
    row(
        &mut output,
        "First commit p50",
        format_ms(metrics.first_commit_p50_ms),
    );
    row(
        &mut output,
        "Release-to-final p50",
        format_ms(metrics.release_to_final_p50_ms),
    );
    row(
        &mut output,
        "Release-to-final p95",
        format_ms(metrics.release_to_final_p95_ms),
    );
    row(
        &mut output,
        "Finalize p95",
        format_ms(metrics.finalize_p95_ms),
    );
    row(
        &mut output,
        "Model load p50",
        format_ms(metrics.model_load_p50_ms),
    );
    row(
        &mut output,
        "Peak RSS",
        metrics
            .peak_rss_bytes
            .map(|value| format!("{:.1} MiB", value as f64 / (1_u64 << 20) as f64))
            .unwrap_or_else(|| "n/a".into()),
    );
    row(
        &mut output,
        "Corpus micro-WER",
        metrics
            .corpus_micro_wer
            .map(|value| format!("{:.2}%", value * 100.0))
            .unwrap_or_else(|| "n/a".into()),
    );

    if let Some(comparison) = comparison {
        writeln!(output, "\n## Baseline comparison\n").expect("write string");
        if !comparison.comparable {
            writeln!(output, "**Incomparable.** Fingerprints do not match.").expect("write string");
        } else if comparison.passed {
            writeln!(output, "**Passed** all regression gates.").expect("write string");
        } else {
            writeln!(output, "**Failed** regression gates:").expect("write string");
        }
        for failure in &comparison.failures {
            writeln!(output, "- {failure}").expect("write string");
        }
    }

    output
}

fn row(output: &mut String, label: &str, value: String) {
    writeln!(output, "| {label} | {value} |").expect("write string");
}

fn format_ms(value: Option<f64>) -> String {
    value
        .map(|value| format!("{value:.2} ms"))
        .unwrap_or_else(|| "n/a".into())
}

fn format_number(value: Option<f64>) -> String {
    value
        .map(|value| format!("{value:.3}"))
        .unwrap_or_else(|| "n/a".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_calls_out_incomparable_results() {
        let comparison = Comparison {
            comparable: false,
            candidate_key: Some("a".into()),
            baseline_key: Some("b".into()),
            passed: false,
            failures: vec!["fingerprints differ".into()],
        };
        let output = markdown("Test", &AggregateMetrics::default(), Some(&comparison));

        assert!(output.contains("**Incomparable.**"));
        assert!(output.contains("fingerprints differ"));
    }
}
