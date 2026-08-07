# Speakeasy selected improvements: implementation DAG

Date: 2026-08-07
Branch: `perf/parakeet-benchmark-harness`

## Constraints

- Keep the current prepared capture and retained transcribe.cpp session.
- Add no mandatory model/LLM cleanup pass.
- Keep transcript processing bounded and deterministic.
- Keep audio callback work unchanged unless microphone routing requires a narrow seam.
- Persist no diagnostic transcript text and no audio.
- Promote no new model without artifact-integrity, quality, latency, and memory evidence.
- Preserve the existing capture-buffer WIP.

## DAG

```text
model research (#19) ───────────────> compact-model harness (#34) ───┐
                                                                    │
delivery scout (#20) -> persist-before-paste (#23)                  │
                                      ├-> typed delivery (#24)       │
                                      │      ├-> app-aware delivery (#30)
                                      │      └-> failed replay (#31) │
                                      └-> corrections/format (#27)   │
                                             └-> guards (#26)        │
                                                                    │
history scout (#22) + #24 + #27 + #26 -> history/stats (#28)       │
                                                                    │
lifecycle scout (#36) -> cancellation (#32) -> replay (#31)        │
                         ├-> model switching (#25)                  │
                         └-> invocation/microphone controls (#29)   │
                                                                    │
icons and atomic bundle (#33) --------------------------------------┤
                                                                    v
                                                   integration proof (#35)
```

## Acceptance summary

1. **Persist before delivery**: accepted text is recoverable even when Accessibility or paste fails.
2. **Typed delivery**: clipboard write and event-post outcomes are explicit; Copy Last and Paste Last need no retranscription.
3. **Transactional model switch**: verify, load, warm, swap, then persist; failure retains the known-good model.
4. **Deterministic text quality**: bounded exact corrections, spoken formatting, and typed degeneration rejection reasons.
5. **Structured local records**: 50 records, raw/final text, backend/outcome/timings; legacy migration.
6. **Private diagnostics**: bounded numeric/counter data only, with canary privacy tests.
7. **Cancellation/replay**: native timeout and user cancel cooperate; one bounded in-memory failed PCM slot is retryable only after native work settles.
8. **Invocation and microphones**: push-to-talk, hands-free, cancel, input selection, and non-backpressuring preview preserve the existing toggle path.
9. **Delivery quality**: target identity and clipboard restoration are best-effort and never overwrite a newer clipboard.
10. **Identity/build**: readable small icons and an atomically published, signed app bundle.
11. **Model ladder**: configs/catalog for the six candidates; no automatic production-catalog expansion.

## Deferred by request

- Further capture-buffer optimization.
- Startup-shell work.
- Upstream graph reuse.
- Ducking validation.
- Apple Speech model work.
