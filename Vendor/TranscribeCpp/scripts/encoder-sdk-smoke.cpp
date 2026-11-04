// Synthetic packaged-SDK smoke. No audio devices, downloads or user data.
#include <CTranscribe/transcribe.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool okay, const char * message) {
    if (!okay) throw std::runtime_error(message);
}

int main(int argc, char ** argv) {
    transcribe_model * model = nullptr;
    transcribe_session * session = nullptr;
    try {
        require(transcribe_encoder_features_api_version() == 1, "Wrong encoder API version");
        require(transcribe_encoder_features_supported(nullptr) == 0, "Null model capability");
        require(transcribe_clear_encoder_features(nullptr) == TRANSCRIBE_ERR_INVALID_ARG, "Null clear");
        uint32_t frames = 9, dim = 9, rate = 9, hop = 9;
        uint64_t generation = 9;
        require(transcribe_get_encoder_features(nullptr, &frames, &dim, &rate, &hop, &generation, nullptr, 0) ==
                    TRANSCRIBE_ERR_INVALID_ARG, "Null snapshot");
        require(frames == 0 && dim == 0 && rate == 0 && hop == 0 && generation == 0, "Null metadata not cleared");
        if (argc == 1) {
            std::puts("{\"packaged_api_v1\":true,\"null_contract\":true,\"model_loaded\":false}");
            return 0;
        }
        require(argc == 3, "Usage: encoder-sdk-smoke [model.gguf cpu|metal]");
        transcribe_model_load_params load;
        transcribe_model_load_params_init(&load);
        const bool metal = std::strcmp(argv[2], "metal") == 0;
        require(metal || std::strcmp(argv[2], "cpu") == 0, "Unknown backend");
        load.backend = metal ? TRANSCRIBE_BACKEND_METAL : TRANSCRIBE_BACKEND_CPU;
        require(transcribe_model_load_file(argv[1], &load, &model) == TRANSCRIBE_OK, "Model load failed");
        const std::string backend = transcribe_model_backend(model);
        std::fprintf(stderr, "effective_backend=%s\n", backend.c_str());
        require(metal ? backend.rfind("MTL", 0) == 0 : backend == "CPU", "Wrong effective backend");
        require(transcribe_encoder_features_supported(model) == 1, "Model feature capability unavailable");
        transcribe_session_params sp;
        transcribe_session_params_init(&sp);
        sp.n_threads = 4;
        require(transcribe_session_init(model, &sp, &session) == TRANSCRIBE_OK, "Session init failed");
        transcribe_run_params run;
        transcribe_run_params_init(&run);
        run.language = "ru";
        std::vector<float> audio(16000);
        for (size_t i = 0; i < audio.size(); ++i) audio[i] = 0.05f * std::sin(2.0 * 3.141592653589793 * 250.0 * i / 16000.0);
        require(transcribe_clear_encoder_features(session) == TRANSCRIBE_OK, "Initial clear failed");
        require(transcribe_run(session, audio.data(), static_cast<int>(audio.size()), &run) == TRANSCRIBE_OK, "First run failed");
        require(transcribe_get_encoder_features(session, &frames, &dim, &rate, &hop, &generation, nullptr, 0) ==
                    TRANSCRIBE_OK, "Metadata failed");
        require(frames == 25 && dim == 768 && rate == 16000 && hop == 640 && generation > 0, "Wrong clock or shape");
        const uint64_t first_generation = generation;
        std::vector<float> owned(static_cast<size_t>(frames) * dim);
        require(transcribe_get_encoder_features(session, &frames, &dim, &rate, &hop, &generation, owned.data(), owned.size()) ==
                    TRANSCRIBE_OK, "Copy failed");
        require(std::all_of(owned.begin(), owned.end(), [](float x) { return std::isfinite(x); }), "Nonfinite features");
        require(std::any_of(owned.begin(), owned.end(), [](float x) { return std::abs(x) > 1e-8f; }), "Empty feature signal");
        const auto preserved = owned;
        require(transcribe_clear_encoder_features(session) == TRANSCRIBE_OK, "Second clear failed");
        require(transcribe_run(session, audio.data(), static_cast<int>(audio.size()), &run) == TRANSCRIBE_OK, "Second run failed");
        require(transcribe_get_encoder_features(session, &frames, &dim, &rate, &hop, &generation, nullptr, 0) ==
                    TRANSCRIBE_OK && generation > first_generation, "Generation did not advance");
        require(owned == preserved, "Caller copy changed");
        require(transcribe_clear_encoder_features(session) == TRANSCRIBE_OK, "Failure clear failed");
        require(transcribe_run(session, nullptr, 0, &run) == TRANSCRIBE_ERR_INVALID_ARG, "Invalid audio unexpectedly accepted");
        require(transcribe_get_encoder_features(session, &frames, &dim, &rate, &hop, &generation, nullptr, 0) ==
                    TRANSCRIBE_ERR_INVALID_ARG && frames == 0 && generation == 0, "Failed attempt exposed stale audio");
        transcribe_session_free(session); session = nullptr;
        transcribe_model_free(model); model = nullptr;
        std::printf("{\"packaged_api_v1\":true,\"effective_backend\":\"%s\",\"frames\":25,\"dimension\":768,"
                    "\"clock_hz\":16000,\"hop_samples\":640,\"owned_copy\":true,\"generation_advances\":true,"
                    "\"failed_attempt_clears\":true,\"model_unloaded\":true,\"synthetic_audio_seconds\":1}\n", backend.c_str());
        return 0;
    } catch (const std::exception & error) {
        transcribe_session_free(session);
        transcribe_model_free(model);
        std::fprintf(stderr, "SDK smoke failed: %s\n", error.what());
        return 1;
    }
}
