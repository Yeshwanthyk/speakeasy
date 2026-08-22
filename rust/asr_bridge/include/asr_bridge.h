#ifndef SPEAKEASY_ASR_BRIDGE_H
#define SPEAKEASY_ASR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AsrHandle AsrHandle;

typedef enum AsrStatus {
    ASR_STATUS_OK = 0,
    ASR_STATUS_ERROR = 1,
    ASR_STATUS_CANCELLED = 2,
} AsrStatus;

typedef struct AsrTimings {
    double total_ms;
    double wait_ms;
    double audio_ms;
} AsrTimings;

typedef struct AsrResult {
    char *text;
    char *error;
    AsrStatus status;
    /* Populated only when status == ASR_STATUS_OK; zeroed otherwise. */
    AsrTimings timings;
} AsrResult;

typedef struct AsrCreateResult {
    AsrHandle *handle;
    char *error;
} AsrCreateResult;

AsrCreateResult asr_create(const char *model_path);
void asr_create_result_free(AsrCreateResult result);
void asr_destroy(AsrHandle *handle);
bool asr_cancel(AsrHandle *handle, uint64_t run_id);
AsrResult asr_transcribe(
    AsrHandle *handle,
    const float *samples,
    size_t length,
    uint64_t run_id
);
void asr_result_free(AsrResult result);

#ifdef __cplusplus
}
#endif

#endif
