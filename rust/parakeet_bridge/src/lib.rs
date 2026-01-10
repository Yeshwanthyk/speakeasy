use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

use transcribe_rs::engines::parakeet::{
    ParakeetEngine, ParakeetInferenceParams, ParakeetModelParams, TimestampGranularity,
};
use transcribe_rs::TranscriptionEngine;

#[repr(C)]
pub struct ParakeetResult {
    pub text: *mut c_char,
    pub error: *mut c_char,
}

pub struct ParakeetHandle {
    engine: ParakeetEngine,
}

fn to_c_string(value: &str) -> *mut c_char {
    match CString::new(value) {
        Ok(val) => val.into_raw(),
        Err(_) => CString::new("invalid string").unwrap().into_raw(),
    }
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

#[no_mangle]
pub extern "C" fn parakeet_create(model_path: *const c_char) -> *mut ParakeetHandle {
    if model_path.is_null() {
        return std::ptr::null_mut();
    }

    let path = unsafe { CStr::from_ptr(model_path) };
    let path_str = match path.to_str() {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut engine = ParakeetEngine::new();
    if engine
        .load_model_with_params(Path::new(path_str), ParakeetModelParams::int8())
        .is_err()
    {
        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(ParakeetHandle { engine }))
}

#[no_mangle]
pub extern "C" fn parakeet_destroy(handle: *mut ParakeetHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn parakeet_transcribe(
    handle: *mut ParakeetHandle,
    samples: *const f32,
    len: usize,
) -> ParakeetResult {
    if handle.is_null() {
        return result_err("null handle");
    }

    if samples.is_null() {
        return result_err("null samples");
    }

    let slice = unsafe { std::slice::from_raw_parts(samples, len) };
    if slice.is_empty() {
        return result_ok(String::new());
    }

    let params = ParakeetInferenceParams {
        timestamp_granularity: TimestampGranularity::Segment,
        ..Default::default()
    };

    let engine = unsafe { &mut (*handle).engine };
    match engine.transcribe_samples(slice.to_vec(), Some(params)) {
        Ok(result) => result_ok(result.text),
        Err(err) => result_err(&format!("Parakeet transcription failed: {}", err)),
    }
}

#[no_mangle]
pub extern "C" fn parakeet_result_free(result: ParakeetResult) {
    if !result.text.is_null() {
        unsafe {
            drop(CString::from_raw(result.text));
        }
    }

    if !result.error.is_null() {
        unsafe {
            drop(CString::from_raw(result.error));
        }
    }
}
