import Foundation

private typealias ResponsePointer = UnsafeMutablePointer<AppleSpeechResponse>

@_cdecl("is_apple_speech_available")
public func isAppleSpeechAvailable() -> Int32 {
    return 0
}

@_cdecl("apple_speech_transcribe")
public func appleSpeechTranscribe(
    _ samples: UnsafePointer<Float>?,
    sampleCount: Int32,
    sampleRate: Int32,
    locale: UnsafePointer<CChar>?,
    context: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<AppleSpeechResponse> {
    let responsePtr = ResponsePointer.allocate(capacity: 1)
    responsePtr.initialize(to: AppleSpeechResponse(transcript: nil, success: 0, error_message: nil))
    responsePtr.pointee.error_message = strdup(
        "Apple Speech is not available in this build (SDK requirement not met)."
    )
    return responsePtr
}

@_cdecl("free_apple_speech_response")
public func freeAppleSpeechResponse(_ response: UnsafeMutablePointer<AppleSpeechResponse>?) {
    guard let response else { return }
    if let transcript = response.pointee.transcript {
        free(UnsafeMutablePointer(mutating: transcript))
    }
    if let errorMessage = response.pointee.error_message {
        free(UnsafeMutablePointer(mutating: errorMessage))
    }
    response.deallocate()
}
