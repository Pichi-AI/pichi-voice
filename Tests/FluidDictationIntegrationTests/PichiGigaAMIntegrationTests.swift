import Foundation
@testable import FluidVoice_Debug
import XCTest

final class PichiGigaAMIntegrationTests: XCTestCase {
    @MainActor
    func testGigaAMIsRussianUniversalAndUsesItsOwnProvider() throws {
        let model = SettingsStore.SpeechModel.gigaam
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.requiresAppleSilicon)
        XCTAssertFalse(model.hasPerformanceRatings)
        XCTAssertEqual(model.provider, .pichi)
        XCTAssertEqual(model.analyticsDescriptor.model, "gigaam-v3-eou")
        XCTAssertTrue(SettingsStore.SpeechModel.availableModels.contains(model))
        let russian = try XCTUnwrap(VoiceEngineLanguageCatalog.language(id: "ru", availableModels: [model]))
        XCTAssertEqual(VoiceEngineLanguageCatalog.routes(for: russian, availableModels: [model]).map(\.model), [model])
        XCTAssertNil(VoiceEngineLanguageCatalog.language(id: "en", availableModels: [model]))
    }

    @MainActor
    func testLocalAPIKeepsGigaAMResponseForAudioPath() async throws {
        var receivedURL: URL?
        let controller = InferenceAPIController { url in
            receivedURL = url
            return .init(text: "Обсудили план встречи.", confidence: 0.9, sampleCount: 16_000, provider: "Pichi GigaAM v3")
        }
        let payload = try JSONSerialization.data(withJSONObject: ["path": "/tmp/synthetic-meeting.wav"])
        let response = await controller.handle(.init(
            method: "POST", path: "/v1/transcribe", query: [:],
            headers: ["content-type": "application/json"], body: payload
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(receivedURL?.path, "/tmp/synthetic-meeting.wav")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(result["text"] as? String, "Обсудили план встречи.")
        XCTAssertEqual(result["provider"] as? String, "Pichi GigaAM v3")
        XCTAssertEqual(result["sampleCount"] as? Int, 16_000)
    }

    @MainActor
    func testInvalidBase64DoesNotStartInference() async throws {
        var called = false
        let controller = InferenceAPIController { _ in
            called = true
            return .init(text: "", confidence: 0, sampleCount: 0, provider: "Pichi GigaAM v3")
        }
        let payload = try JSONSerialization.data(withJSONObject: ["audioBase64": "not base64!"])
        let response = await controller.handle(.init(
            method: "POST", path: "/v1/transcribe", query: [:],
            headers: ["content-type": "application/json"], body: payload
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(called)
    }
}
