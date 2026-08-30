use anyhow::Result;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

#[repr(C)]
pub struct AppleSpeechResponse {
    pub transcript: *mut c_char,
    pub success: c_int,
    pub error_message: *mut c_char,
}

extern "C" {
    pub fn is_apple_speech_available() -> c_int;
    pub fn apple_speech_transcribe(
        samples: *const f32,
        sample_count: i32,
        sample_rate: i32,
        locale: *const c_char,
        context: *const c_char,
    ) -> *mut AppleSpeechResponse;
    pub fn free_apple_speech_response(response: *mut AppleSpeechResponse);
}

pub fn is_available() -> bool {
    unsafe { is_apple_speech_available() == 1 }
}

pub fn transcribe_samples(
    samples: &[f32],
    sample_rate: u32,
    locale: &str,
    custom_words: &[String],
) -> Result<String> {
    if samples.is_empty() {
        return Ok(String::new());
    }
    if samples.len() > i32::MAX as usize {
        anyhow::bail!("audio too long for Apple Speech");
    }

    let locale_c = CString::new(locale).map_err(|e| anyhow::anyhow!(e))?;
    let context = custom_words
        .iter()
        .filter(|word| !word.contains('\0'))
        .cloned()
        .collect::<Vec<_>>()
        .join("\n");
    let context_c = CString::new(context).map_err(|e| anyhow::anyhow!(e))?;

    let response_ptr = unsafe {
        apple_speech_transcribe(
            samples.as_ptr(),
            samples.len() as i32,
            sample_rate as i32,
            locale_c.as_ptr(),
            context_c.as_ptr(),
        )
    };
    if response_ptr.is_null() {
        anyhow::bail!("Null response from Apple Speech");
    }

    let response = unsafe { &*response_ptr };
    let result = if response.success == 1 {
        if response.transcript.is_null() {
            Ok(String::new())
        } else {
            let text = unsafe { CStr::from_ptr(response.transcript) }
                .to_string_lossy()
                .into_owned();
            Ok(text)
        }
    } else {
        let error = if response.error_message.is_null() {
            "Apple Speech transcription failed".to_string()
        } else {
            unsafe { CStr::from_ptr(response.error_message) }
                .to_string_lossy()
                .into_owned()
        };
        Err(anyhow::anyhow!(error))
    };

    unsafe { free_apple_speech_response(response_ptr) };
    result
}
