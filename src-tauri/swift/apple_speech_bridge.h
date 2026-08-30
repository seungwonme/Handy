#ifndef apple_speech_bridge_h
#define apple_speech_bridge_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char* transcript;
    int success;
    char* error_message;
} AppleSpeechResponse;

int is_apple_speech_available(void);

AppleSpeechResponse* apple_speech_transcribe(
    const float* samples,
    int sample_count,
    int sample_rate,
    const char* locale,
    const char* context
);

void free_apple_speech_response(AppleSpeechResponse* response);

#ifdef __cplusplus
}
#endif

#endif
