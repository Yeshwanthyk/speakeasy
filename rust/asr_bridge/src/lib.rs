//! Panic-safe C ABI for transcribe.cpp.
//!
//! Swift owns the PCM buffer and pins it for each synchronous call. Rust owns
//! the transcribe.cpp model/session and every string returned across the ABI.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use transcribe_cpp::{Model, RunOptions, Session};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AsrResult {
    pub text: *mut c_char,
    pub error: *mut c_char,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AsrCreateResult {
    pub handle: *mut AsrHandle,
    pub error: *mut c_char,
}

pub struct AsrHandle {
    session: Mutex<Session>,
}

static BACKEND_INIT: OnceLock<Result<(), String>> = OnceLock::new();

fn initialize_backend() -> Result<(), String> {
    BACKEND_INIT
        .get_or_init(|| {
            transcribe_cpp::init_logging();
            transcribe_cpp::init_backends_default()
                .map_err(|error| format!("Failed to initialize transcribe.cpp backends: {error}"))
        })
        .clone()
}

fn to_c_string(value: &str) -> *mut c_char {
    let sanitized = value.replace('\0', "\u{FFFD}");
    CString::new(sanitized)
        .expect("interior NULs were replaced")
        .into_raw()
}

fn result_ok(text: String) -> AsrResult {
    AsrResult {
        text: to_c_string(text.trim()),
        error: std::ptr::null_mut(),
    }
}

fn result_err(message: &str) -> AsrResult {
    AsrResult {
        text: std::ptr::null_mut(),
        error: to_c_string(message),
    }
}

fn create_ok(handle: *mut AsrHandle) -> AsrCreateResult {
    AsrCreateResult {
        handle,
        error: std::ptr::null_mut(),
    }
}

fn create_err(message: &str) -> AsrCreateResult {
    AsrCreateResult {
        handle: std::ptr::null_mut(),
        error: to_c_string(message),
    }
}

/// Load a GGUF speech-to-text model through transcribe.cpp.
///
/// # Safety
///
/// `model_path` must point to a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn asr_create(model_path: *const c_char) -> AsrCreateResult {
    catch_unwind(AssertUnwindSafe(|| {
        if model_path.is_null() {
            return create_err("null model path");
        }

        // SAFETY: guaranteed by the caller contract and checked for null above.
        let path = unsafe { CStr::from_ptr(model_path) };
        let path = match path.to_str() {
            Ok(value) => value,
            Err(error) => {
                return create_err(&format!("model path is not valid UTF-8: {error}"));
            }
        };

        if let Err(error) = initialize_backend() {
            return create_err(&error);
        }

        let model = match Model::load(Path::new(path)) {
            Ok(model) => model,
            Err(error) => return create_err(&format!("Failed to load GGUF model: {error}")),
        };
        let session = match model.session() {
            Ok(session) => session,
            Err(error) => {
                return create_err(&format!("Failed to create transcription session: {error}"));
            }
        };

        let handle = Box::new(AsrHandle {
            session: Mutex::new(session),
        });
        create_ok(Box::into_raw(handle))
    }))
    .unwrap_or_else(|_| create_err("Rust panicked during asr_create"))
}

/// # Safety
///
/// `handle` must be null or a pointer returned by `asr_create` that has not
/// already been destroyed.
#[no_mangle]
pub unsafe extern "C" fn asr_destroy(handle: *mut AsrHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return;
        }
        // SAFETY: guaranteed by the caller contract and checked for null above.
        unsafe { drop(Box::from_raw(handle)) };
    }));
}

/// Transcribe borrowed 16 kHz mono float32 PCM.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by `asr_create`.
/// - when `len > 0`, `samples` must point to `len` pinned `f32` values.
#[no_mangle]
pub unsafe extern "C" fn asr_transcribe(
    handle: *mut AsrHandle,
    samples: *const f32,
    len: usize,
) -> AsrResult {
    catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return result_err("null handle");
        }
        if len == 0 {
            return result_ok(String::new());
        }
        if samples.is_null() {
            return result_err("null samples");
        }

        // SAFETY: guaranteed by the caller contract and checked for null above.
        let samples = unsafe { std::slice::from_raw_parts(samples, len) };
        // SAFETY: guaranteed by the caller contract and checked for null above.
        let handle = unsafe { &*handle };
        let mut session = match handle.session.lock() {
            Ok(session) => session,
            Err(_) => {
                return result_err(
                    "ASR session is poisoned after a prior panic; destroy and recreate the handle",
                );
            }
        };

        match session.run(samples, &RunOptions::default()) {
            Ok(transcript) => result_ok(transcript.text),
            Err(error) => result_err(&format!("transcribe.cpp transcription failed: {error}")),
        }
    }))
    .unwrap_or_else(|_| result_err("Rust panicked during asr_transcribe"))
}

/// # Safety
///
/// `result` must come from `asr_transcribe` and must be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn asr_result_free(result: AsrResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !result.text.is_null() {
            // SAFETY: allocated by CString::into_raw in this library.
            unsafe { drop(CString::from_raw(result.text)) };
        }
        if !result.error.is_null() {
            // SAFETY: allocated by CString::into_raw in this library.
            unsafe { drop(CString::from_raw(result.error)) };
        }
    }));
}

/// Free the error string in an `AsrCreateResult`. The handle remains owned by
/// the caller and must be released with `asr_destroy`.
///
/// # Safety
///
/// `result` must come from `asr_create` and must be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn asr_create_result_free(result: AsrCreateResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !result.error.is_null() {
            // SAFETY: allocated by CString::into_raw in this library.
            unsafe { drop(CString::from_raw(result.error)) };
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn take_c_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        // SAFETY: test receives ownership from `to_c_string`.
        unsafe { CString::from_raw(ptr) }
            .into_string()
            .expect("valid UTF-8")
    }

    #[test]
    fn to_c_string_preserves_unicode_and_replaces_nul() {
        let value = unsafe { take_c_string(to_c_string("héllo\0🎤")) };
        assert_eq!(value, "héllo\u{FFFD}🎤");
    }

    #[test]
    fn result_free_accepts_null_fields() {
        unsafe {
            asr_result_free(AsrResult {
                text: std::ptr::null_mut(),
                error: std::ptr::null_mut(),
            });
        }
    }

    #[test]
    fn create_rejects_null_path() {
        let result = unsafe { asr_create(std::ptr::null()) };
        assert!(result.handle.is_null());
        assert!(!result.error.is_null());
        let message = unsafe { CStr::from_ptr(result.error) }
            .to_str()
            .expect("valid UTF-8");
        assert!(message.contains("null model path"));
        unsafe { asr_create_result_free(result) };
    }

    #[test]
    fn create_reports_missing_model() {
        let path = CString::new("/definitely/does/not/exist/model.gguf").expect("valid path");
        let result = unsafe { asr_create(path.as_ptr()) };
        assert!(result.handle.is_null());
        assert!(!result.error.is_null());
        let message = unsafe { CStr::from_ptr(result.error) }
            .to_str()
            .expect("valid UTF-8");
        assert!(message.contains("Failed to load GGUF model"));
        unsafe { asr_create_result_free(result) };
    }

    #[test]
    fn transcribe_rejects_null_handle() {
        let result = unsafe { asr_transcribe(std::ptr::null_mut(), std::ptr::null(), 0) };
        assert!(result.text.is_null());
        assert!(!result.error.is_null());
        unsafe { asr_result_free(result) };
    }

    #[test]
    fn destroy_accepts_null() {
        unsafe { asr_destroy(std::ptr::null_mut()) };
    }

    #[test]
    #[ignore = "requires SPEAKEASY_TEST_GGUF"]
    fn real_model_load_and_silent_run() {
        let path = std::env::var("SPEAKEASY_TEST_GGUF")
            .expect("set SPEAKEASY_TEST_GGUF to a compatible GGUF model");
        let path = CString::new(path).expect("model path must not contain NUL");
        let create = unsafe { asr_create(path.as_ptr()) };
        if !create.error.is_null() {
            let message = unsafe { CStr::from_ptr(create.error) }
                .to_string_lossy()
                .into_owned();
            unsafe { asr_create_result_free(create) };
            panic!("model load failed: {message}");
        }
        assert!(!create.handle.is_null());
        unsafe { asr_create_result_free(create) };

        let silence = vec![0.0_f32; 16_000];
        let result = unsafe { asr_transcribe(create.handle, silence.as_ptr(), silence.len()) };
        if !result.error.is_null() {
            let message = unsafe { CStr::from_ptr(result.error) }
                .to_string_lossy()
                .into_owned();
            unsafe { asr_result_free(result) };
            unsafe { asr_destroy(create.handle) };
            panic!("silent transcription failed: {message}");
        }
        assert!(!result.text.is_null());
        unsafe { asr_result_free(result) };
        unsafe { asr_destroy(create.handle) };
    }
}
