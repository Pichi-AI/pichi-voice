#include "PichiRussianMorphology.h"
#include "libmorph/rus.h"
#include <cstring>
#include <set>
#include <string>

extern "C" int pichi_russian_word_forms(const char *word, size_t word_length,
                                        char *output, size_t capacity,
                                        size_t *written, size_t *form_count) {
    if (written == nullptr || form_count == nullptr) return -1;
    *written = 0;
    *form_count = 0;
    if (word == nullptr || word_length == 0 || word_length > 128 ||
        std::memchr(word, '\0', word_length) != nullptr || output == nullptr) return -1;
    try {
        IMlmaMb *api = nullptr;
        if (mlmaruGetAPI(LIBMORPH_API_4_MAGIC ":utf-8", reinterpret_cast<void **>(&api)) != 0 ||
            api == nullptr) return -3;
        // Upstream instances and dictionary tables are immutable. Attach/Detach
        // are no-ops; every analysis buffer is owned by this synchronous call.
        SLemmInfoA lemmas[64]{};
        int count = api->Lemmatize(word, word_length, lemmas, 64, nullptr, 0, nullptr, 0,
                                   sfIgnoreCapitals | sfHardForms);
        if (count < 0 || count > 64) return -3;
        if (count == 0) return 0;
        std::set<std::string> forms;
        for (int index = 0; index < count; ++index) {
            for (unsigned form = 0; form < 256; ++form) {
                char buffer[8192]{};
                int remaining = api->BuildForm(buffer, sizeof(buffer), lemmas[index].nlexid,
                                               static_cast<formid_t>(form));
                if (remaining < 0) return -3;
                const char *cursor = buffer;
                const char *end = buffer + sizeof(buffer);
                while (remaining-- > 0) {
                    if (cursor >= end) return -3;
                    size_t length = strnlen(cursor, static_cast<size_t>(end - cursor));
                    if (length == 0 || length > 256 || cursor + length == end) return -3;
                    forms.emplace(cursor, length);
                    if (forms.size() > 512) return -2;
                    cursor += length + 1;
                }
            }
        }
        if (forms.empty()) return -3;
        size_t required = 0;
        for (const auto &form : forms) required += form.size() + 1;
        if (required > capacity) return -2;
        for (const auto &form : forms) {
            std::memcpy(output + *written, form.c_str(), form.size() + 1);
            *written += form.size() + 1;
        }
        *form_count = forms.size();
        return 1;
    } catch (...) {
        // No exception or partially generated word list crosses the C boundary.
        return -3;
    }
}
