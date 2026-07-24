//! FFI bridge from Swift to local ASR models.
//!
//! # Contract
//!
//! - All strings are UTF-8 unless noted. Interior NULs in model output are
//!   replaced with `U+FFFD` before being returned across the boundary.
//! - `len` is the number of `f32` samples (not bytes). Caller must pin the
//!   buffer for the duration of the call (Swift's `withUnsafeBufferPointer`
//!   already does this).
//! - Memory allocated by Rust (the `handle`, `text`, and `error` fields in the
//!   result structs) must be freed by the matching Rust free function. Swift
//!   must never call `free()` directly.
//! - Every `extern "C"` entry point catches Rust panics so unwinding does not
//!   cross the FFI boundary (UB). Panics are converted to error strings.
//!   NOTE: `catch_unwind` only catches *Rust* panics; a native abort from
//!   ONNX Runtime (C++) or a signal still terminates the process.
//! - `ParakeetHandle` is safe to share between threads. Concurrent calls to
//!   `parakeet_transcribe` with the same handle are serialized by an internal
//!   mutex. If a panic inside inference poisons the lock, subsequent
//!   `parakeet_transcribe` calls return an error — the model's internal
//!   session state is considered inconsistent and the handle should be
//!   destroyed and recreated.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::Mutex;

use parakeet_rs::{Nemotron, ParakeetTDT, Transcriber};

const MODEL_KIND_PARAKEET_TDT: i32 = 0;
const MODEL_KIND_NEMOTRON: i32 = 1;
const SAMPLE_RATE: u32 = 16_000;
const CHANNELS: u16 = 1;

#[repr(C)]
pub struct ParakeetResult {
    pub text: *mut c_char,
    pub error: *mut c_char,
}

#[repr(C)]
pub struct ParakeetCreateResult {
    pub handle: *mut ParakeetHandle,
    pub error: *mut c_char,
}

pub struct ParakeetHandle {
    model: Mutex<AsrModel>,
}

enum AsrModel {
    ParakeetTdt(ParakeetTDT),
    Nemotron(Nemotron),
}

impl AsrModel {
    fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        match self {
            Self::ParakeetTdt(model) => model
                .transcribe_samples(samples.to_vec(), SAMPLE_RATE, CHANNELS, None)
                .map(|result| result.text)
                .map_err(|err| format!("Parakeet transcription failed: {err}")),
            Self::Nemotron(model) => model
                .transcribe_audio(samples)
                .map_err(|err| format!("Nemotron transcription failed: {err}")),
        }
    }
}

/// Allocate a NUL-terminated C string from `value`, sanitising interior NULs.
///
/// `CString::new` rejects interior NULs; rather than truncate or substitute a
/// sentinel (which hides real content), we replace each `\0` with `U+FFFD`
/// so the text survives the round-trip with a visible marker at the violation.
fn to_c_string(value: &str) -> *mut c_char {
    let sanitized: String = value
        .chars()
        .map(|c| if c == '\0' { '\u{FFFD}' } else { c })
        .collect();
    // Sanitisation guarantees no interior NULs, so unwrap is infallible here.
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("<ffi string encode error>").unwrap())
        .into_raw()
}

fn result_ok(text: String) -> ParakeetResult {
    ParakeetResult {
        text: to_c_string(text.trim()),
        error: std::ptr::null_mut(),
    }
}

fn result_err(message: &str) -> ParakeetResult {
    ParakeetResult {
        text: std::ptr::null_mut(),
        error: to_c_string(message),
    }
}

fn create_ok(handle: *mut ParakeetHandle) -> ParakeetCreateResult {
    ParakeetCreateResult {
        handle,
        error: std::ptr::null_mut(),
    }
}

fn create_err(message: &str) -> ParakeetCreateResult {
    ParakeetCreateResult {
        handle: std::ptr::null_mut(),
        error: to_c_string(message),
    }
}

/// Load a local ASR model from disk.
///
/// On success, `handle` is non-null and `error` is null. On failure, `handle`
/// is null and `error` carries the underlying error message. The caller must
/// free the result with `parakeet_create_result_free` in either case; on
/// success, the handle is additionally freed later with `parakeet_destroy`.
///
/// # Safety
///
/// `model_path` and `language` must be valid NUL-terminated UTF-8 C strings,
/// or null. `language` is only used by Nemotron; null means model default.
#[no_mangle]
pub unsafe extern "C" fn parakeet_create(
    model_path: *const c_char,
    model_kind: i32,
    language: *const c_char,
) -> ParakeetCreateResult {
    catch_unwind(AssertUnwindSafe(|| {
        if model_path.is_null() {
            return create_err("null model path");
        }

        // SAFETY: caller guarantees `model_path` is a valid NUL-terminated C string.
        let path = unsafe { CStr::from_ptr(model_path) };
        let path_str = match path.to_str() {
            Ok(value) => value,
            Err(err) => return create_err(&format!("model path is not valid UTF-8: {err}")),
        };

        let language = if language.is_null() {
            None
        } else {
            // SAFETY: caller guarantees `language` is a valid NUL-terminated C string.
            let language = unsafe { CStr::from_ptr(language) };
            match language.to_str() {
                Ok("") => None,
                Ok(value) => Some(value),
                Err(err) => return create_err(&format!("language is not valid UTF-8: {err}")),
            }
        };

        let model = match model_kind {
            MODEL_KIND_PARAKEET_TDT => {
                match ParakeetTDT::from_pretrained(Path::new(path_str), None) {
                    Ok(model) => AsrModel::ParakeetTdt(model),
                    Err(err) => {
                        return create_err(&format!("Failed to load Parakeet model: {err}"));
                    }
                }
            }
            MODEL_KIND_NEMOTRON => {
                let mut model = match Nemotron::from_pretrained(Path::new(path_str), None) {
                    Ok(model) => model,
                    Err(err) => {
                        return create_err(&format!("Failed to load Nemotron model: {err}"));
                    }
                };
                if let Some(language) = language {
                    if let Err(err) = model.set_target_lang(language) {
                        return create_err(&format!("Failed to set Nemotron language: {err}"));
                    }
                }
                AsrModel::Nemotron(model)
            }
            other => return create_err(&format!("unsupported model kind: {other}")),
        };

        let boxed = Box::new(ParakeetHandle {
            model: Mutex::new(model),
        });
        create_ok(Box::into_raw(boxed))
    }))
    .unwrap_or_else(|_| create_err("Rust panicked during parakeet_create"))
}

/// # Safety
///
/// `handle` must be either null or a pointer returned by `parakeet_create`
/// that has not been destroyed. Called at most once per handle.
#[no_mangle]
pub unsafe extern "C" fn parakeet_destroy(handle: *mut ParakeetHandle) {
    // Destructor must not unwind across FFI.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return;
        }
        // SAFETY: handle was obtained from `Box::into_raw` in `parakeet_create`
        // and has not been freed before. Caller is responsible for calling this
        // exactly once per successful `parakeet_create`.
        unsafe {
            drop(Box::from_raw(handle));
        }
    }));
}

/// Transcribe a pinned buffer of `f32` samples. Blocks until inference completes.
///
/// Thread-safe: concurrent calls on the same handle are serialised by an
/// internal mutex. Returns an empty `text` on zero-length input.
///
/// # Safety
///
/// - `handle` must be null or a pointer returned by `parakeet_create`.
/// - If `len > 0`, `samples` must point to at least `len` contiguous `f32`
///   values pinned for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn parakeet_transcribe(
    handle: *mut ParakeetHandle,
    samples: *const f32,
    len: usize,
) -> ParakeetResult {
    catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return result_err("null handle");
        }
        // Zero-length input is a normal outcome (short press), not an error.
        if len == 0 {
            return result_ok(String::new());
        }
        if samples.is_null() {
            return result_err("null samples");
        }

        // SAFETY: caller pins `samples` for `len` f32 values for the duration
        // of this call. Swift's `withUnsafeBufferPointer` enforces this.
        let slice = unsafe { std::slice::from_raw_parts(samples, len) };

        // SAFETY: handle is non-null (checked above) and was produced by
        // `parakeet_create`. We access `model` through a shared reference so
        // that concurrent callers serialise via the mutex rather than racing.
        let handle_ref = unsafe { &*handle };
        let mut model = match handle_ref.model.lock() {
            Ok(guard) => guard,
            // A poisoned lock means a prior inference panicked while holding
            // partial state (`prev_state`, ONNX session internal frames).
            // Reusing the model is unsound; surface the error and let the
            // caller destroy + recreate the handle.
            Err(_) => {
                return result_err(
                    "ASR model is poisoned after a prior panic; destroy and recreate the handle",
                );
            }
        };

        match model.transcribe(slice) {
            Ok(text) => result_ok(text),
            Err(err) => result_err(&err),
        }
    }))
    .unwrap_or_else(|_| result_err("Rust panicked during parakeet_transcribe"))
}

/// # Safety
///
/// `result` must be a value produced by `parakeet_transcribe`. The string
/// pointers are consumed; callers must not use them after this returns.
#[no_mangle]
pub unsafe extern "C" fn parakeet_result_free(result: ParakeetResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !result.text.is_null() {
            // SAFETY: pointer was produced by `CString::into_raw` in `to_c_string`.
            unsafe {
                drop(CString::from_raw(result.text));
            }
        }
        if !result.error.is_null() {
            // SAFETY: pointer was produced by `CString::into_raw` in `to_c_string`.
            unsafe {
                drop(CString::from_raw(result.error));
            }
        }
    }));
}

/// Free the error string in a `ParakeetCreateResult`.
///
/// The `handle` field is NOT freed here — on success, the caller retains
/// ownership of the handle and must free it separately via `parakeet_destroy`.
///
/// # Safety
///
/// `result` must be a value produced by `parakeet_create`. The error pointer
/// is consumed; callers must not use it after this returns.
#[no_mangle]
pub unsafe extern "C" fn parakeet_create_result_free(result: ParakeetCreateResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !result.error.is_null() {
            // SAFETY: pointer was produced by `CString::into_raw` in `to_c_string`.
            unsafe {
                drop(CString::from_raw(result.error));
            }
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: read a `*mut c_char` back into an owned `String` and free it.
    unsafe fn take_c_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        CString::from_raw(ptr).into_string().expect("utf-8")
    }

    #[test]
    fn to_c_string_preserves_ascii() {
        let ptr = to_c_string("hello");
        let s = unsafe { take_c_string(ptr) };
        assert_eq!(s, "hello");
    }

    #[test]
    fn to_c_string_replaces_interior_nul() {
        let ptr = to_c_string("hel\0lo\0!");
        let s = unsafe { take_c_string(ptr) };
        assert_eq!(s, "hel\u{FFFD}lo\u{FFFD}!");
    }

    #[test]
    fn to_c_string_allows_empty() {
        let ptr = to_c_string("");
        let s = unsafe { take_c_string(ptr) };
        assert_eq!(s, "");
    }

    #[test]
    fn to_c_string_preserves_unicode() {
        let ptr = to_c_string("héllo 🎤");
        let s = unsafe { take_c_string(ptr) };
        assert_eq!(s, "héllo 🎤");
    }

    #[test]
    fn result_free_is_safe_on_null_fields() {
        unsafe {
            parakeet_result_free(ParakeetResult {
                text: std::ptr::null_mut(),
                error: std::ptr::null_mut(),
            });
        }
    }

    #[test]
    fn result_free_drops_text_and_error() {
        // Just has to not panic / leak detectably.
        let r = ParakeetResult {
            text: to_c_string("ok"),
            error: to_c_string("also set"),
        };
        unsafe { parakeet_result_free(r) };
    }

    #[test]
    fn transcribe_null_handle_returns_error() {
        let r = unsafe { parakeet_transcribe(std::ptr::null_mut(), std::ptr::null(), 0) };
        assert!(r.text.is_null());
        assert!(!r.error.is_null());
        let msg = unsafe { CStr::from_ptr(r.error).to_str().unwrap().to_owned() };
        assert!(msg.contains("null handle"), "unexpected message: {msg}");
        unsafe { parakeet_result_free(r) };
    }

    // Full zero-sample path with a real handle is covered via integration
    // tests (requires the model). Here we only assert that the null-handle
    // guard fires before we ever look at `len == 0`, so passing null is safe.
    #[test]
    fn transcribe_null_handle_is_safe_with_zero_len() {
        let r = unsafe { parakeet_transcribe(std::ptr::null_mut(), std::ptr::null(), 0) };
        assert!(r.text.is_null());
        assert!(!r.error.is_null());
        unsafe { parakeet_result_free(r) };
    }

    /// Compile-time check that `ParakeetHandle` is thread-safe. If a future
    /// version of `transcribe-rs` or `ort` drops `Send` on `Session`, this
    /// fails to compile — exactly when we'd want to know.
    #[test]
    fn parakeet_handle_is_send_and_sync() {
        fn assert_send<T: Send>() {}
        fn assert_sync<T: Sync>() {}
        assert_send::<ParakeetHandle>();
        assert_sync::<ParakeetHandle>();
    }

    #[test]
    fn create_null_path_returns_error() {
        let r =
            unsafe { parakeet_create(std::ptr::null(), MODEL_KIND_PARAKEET_TDT, std::ptr::null()) };
        assert!(r.handle.is_null());
        assert!(!r.error.is_null());
        let msg = unsafe { CStr::from_ptr(r.error).to_str().unwrap().to_owned() };
        assert!(msg.contains("null model path"), "unexpected message: {msg}");
        unsafe { parakeet_create_result_free(r) };
    }

    #[test]
    fn create_missing_path_returns_error_with_underlying_message() {
        let path = CString::new("/definitely/does/not/exist/parakeet").unwrap();
        let r =
            unsafe { parakeet_create(path.as_ptr(), MODEL_KIND_PARAKEET_TDT, std::ptr::null()) };
        assert!(r.handle.is_null());
        assert!(!r.error.is_null());
        let msg = unsafe { CStr::from_ptr(r.error).to_str().unwrap().to_owned() };
        assert!(
            msg.starts_with("Failed to load Parakeet model"),
            "expected underlying error forwarding, got: {msg}"
        );
        unsafe { parakeet_create_result_free(r) };
    }

    #[test]
    fn create_invalid_model_kind_returns_error() {
        let path = CString::new("/tmp").unwrap();
        let r = unsafe { parakeet_create(path.as_ptr(), 99, std::ptr::null()) };
        assert!(r.handle.is_null());
        assert!(!r.error.is_null());
        let msg = unsafe { CStr::from_ptr(r.error).to_str().unwrap().to_owned() };
        assert!(
            msg.contains("unsupported model kind: 99"),
            "unexpected message: {msg}"
        );
        unsafe { parakeet_create_result_free(r) };
    }

    #[test]
    fn create_rejects_invalid_language_utf8() {
        let path = CString::new("/tmp").unwrap();
        let language = [0xFFu8, 0];
        let r = unsafe {
            parakeet_create(path.as_ptr(), MODEL_KIND_NEMOTRON, language.as_ptr().cast())
        };
        assert!(r.handle.is_null());
        assert!(!r.error.is_null());
        let msg = unsafe { CStr::from_ptr(r.error).to_str().unwrap().to_owned() };
        assert!(
            msg.contains("language is not valid UTF-8"),
            "unexpected message: {msg}"
        );
        unsafe { parakeet_create_result_free(r) };
    }

    #[test]
    fn destroy_is_safe_on_null() {
        unsafe { parakeet_destroy(std::ptr::null_mut()) };
    }

    #[test]
    fn create_result_free_is_safe_on_null_error() {
        let r = ParakeetCreateResult {
            handle: std::ptr::null_mut(),
            error: std::ptr::null_mut(),
        };
        unsafe { parakeet_create_result_free(r) };
    }
}
