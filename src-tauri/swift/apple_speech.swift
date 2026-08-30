import AVFoundation
import Foundation
import Speech

private typealias ResponsePointer = UnsafeMutablePointer<AppleSpeechResponse>

private func duplicateCString(_ text: String) -> UnsafeMutablePointer<CChar>? {
    return text.withCString { basePointer in
        guard let duplicated = strdup(basePointer) else {
            return nil
        }
        return duplicated
    }
}

@available(macOS 13.0, *)
private func bcp47(_ locale: Locale) -> String { locale.identifier(.bcp47) }

@_cdecl("is_apple_speech_available")
public func isAppleSpeechAvailable() -> Int32 {
    guard #available(macOS 26.0, *) else {
        return 0
    }
    return 1
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

    guard #available(macOS 26.0, *) else {
        responsePtr.pointee.error_message = duplicateCString(
            "Apple Speech requires macOS 26 or newer."
        )
        return responsePtr
    }
    guard let samples, sampleCount > 0, sampleRate > 0 else {
        responsePtr.pointee.error_message = duplicateCString("Apple Speech received empty audio.")
        return responsePtr
    }

    let localeID = locale.map { String(cString: $0) } ?? "ko-KR"
    let contextText = context.map { String(cString: $0) } ?? ""
    var contextTerms: [String] = []
    for raw in contextText.split(whereSeparator: \.isNewline) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { continue }
        contextTerms.append(term)
        if contextTerms.count == 100 { break }
    }
    let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(sampleCount)))
    let rate = sampleRate
    let terms = Array(contextTerms)

    let semaphore = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable {
        var transcript: String?
        var error: String?
    }
    let box = ResultBox()

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        do {
            box.transcript = try await transcribeSamples(
                samples: pcm,
                sampleRate: rate,
                localeID: localeID,
                context: terms
            )
        } catch {
            box.error = error.localizedDescription
        }
    }
    semaphore.wait()

    if let transcript = box.transcript {
        responsePtr.pointee.success = 1
        responsePtr.pointee.transcript = duplicateCString(transcript)
    } else {
        responsePtr.pointee.error_message = duplicateCString(
            box.error ?? "Apple Speech transcription failed."
        )
    }
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

@available(macOS 26.0, *)
private func transcribeSamples(
    samples: [Float],
    sampleRate: Int32,
    localeID: String,
    context: [String]
) async throws -> String {
    let wavURL = try writeTempWav(samples: samples, sampleRate: sampleRate)
    defer { try? FileManager.default.removeItem(at: wavURL) }

    let locale = try await resolveLocale(localeID)
    var preset = SpeechTranscriber.Preset.timeIndexedTranscriptionWithAlternatives
    preset.attributeOptions.insert(.audioTimeRange)
    preset.reportingOptions.remove(.fastResults)
    let transcriber = SpeechTranscriber(locale: locale, preset: preset)
    try await ensureModel(for: transcriber, locale: locale)

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if !context.isEmpty {
        let analysisContext = AnalysisContext()
        analysisContext.contextualStrings[.general] = context
        try await analyzer.setContext(analysisContext)
    }

    let collector = Task { () throws -> [String] in
        var parts: [String] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(text)
            }
        }
        return parts
    }

    let audioFile = try AVAudioFile(forReading: wavURL)
    if let last = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collector.value.joined(separator: " ")
}

@available(macOS 26.0, *)
private func resolveLocale(_ identifier: String) async throws -> Locale {
    let requested = Locale(identifier: identifier)
    let wanted = bcp47(requested).lowercased()
    let supported = await SpeechTranscriber.supportedLocales
    if let match = supported.first(where: { bcp47($0).lowercased() == wanted }) {
        return match
    }
    let language = requested.language.languageCode?.identifier.lowercased()
    if let language, let match = supported.first(where: {
        $0.language.languageCode?.identifier.lowercased() == language
    }) {
        return match
    }
    throw NSError(
        domain: "AppleSpeech",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey: "Unsupported speech locale: \(identifier)",
        ]
    )
}

@available(macOS 26.0, *)
private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let installed = await SpeechTranscriber.installedLocales
    if installed.contains(where: { bcp47($0).lowercased() == bcp47(locale).lowercased() }) {
        return
    }
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
}

private func writeTempWav(
    samples: [Float],
    sampleRate: Int32
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("handy-apple-speech-\(UUID().uuidString).wav")
    let count = samples.count
    let dataSize = UInt32(count * 2)
    var header = Data()
    func appendASCII(_ value: String) { header.append(contentsOf: value.utf8) }
    func appendU32(_ value: UInt32) {
        var little = value.littleEndian
        header.append(Data(bytes: &little, count: 4))
    }
    func appendU16(_ value: UInt16) {
        var little = value.littleEndian
        header.append(Data(bytes: &little, count: 2))
    }
    appendASCII("RIFF")
    appendU32(36 + dataSize)
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendU32(16)
    appendU16(1)
    appendU16(1)
    appendU32(UInt32(sampleRate))
    appendU32(UInt32(sampleRate) * 2)
    appendU16(2)
    appendU16(16)
    appendASCII("data")
    appendU32(dataSize)

    var pcm = Data(capacity: Int(dataSize))
    for index in 0..<count {
        let clipped = max(-1.0, min(1.0, samples[index]))
        var sample = Int16((clipped * Float(Int16.max)).rounded()).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    try (header + pcm).write(to: url)
    return url
}
