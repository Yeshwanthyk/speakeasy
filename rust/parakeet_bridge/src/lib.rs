use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

use ndarray::{aview1, ArrayView2};
use transcribe_rs::engines::parakeet::ParakeetModel;

#[repr(C)]
pub struct ParakeetResult {
    pub text: *mut c_char,
    pub error: *mut c_char,
}

pub struct ParakeetHandle {
    model: ParakeetModel,
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

    let model = match ParakeetModel::new(Path::new(path_str), true) {
        Ok(model) => model,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(ParakeetHandle { model }))
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

    let model = unsafe { &mut (*handle).model };

    let waveforms = match ArrayView2::from_shape((1, len), slice) {
        Ok(view) => view.into_dyn(),
        Err(err) => {
            return result_err(&format!("Invalid waveform shape: {err}"));
        }
    };
    let lens = [len as i64];
    let waveforms_len = aview1(&lens).into_dyn();

    match model.recognize_batch(&waveforms, &waveforms_len) {
        Ok(mut results) => match results.pop() {
            Some(result) => result_ok(result.text),
            None => result_err("Parakeet transcription returned no result"),
        },
        Err(err) => result_err(&format!("Parakeet transcription failed: {err}")),
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
