// Image decoding for the Android build: PNG only. Everything the app hands MapLibre is
// PNG (sprites, the traffic and OSM tiles of the loopback tile server), so libjpeg and
// libwebp are not built for Android; another format is reported as an error per image.
#include <mln/util/image.hpp>

#include <stdexcept>

namespace mln {

PremultipliedImage decodePNG(const uint8_t*, size_t);

PremultipliedImage decodeImage(const std::string& string) {
    const auto* data = reinterpret_cast<const uint8_t*>(string.data());
    if (string.size() >= 4 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') {
        return decodePNG(data, string.size());
    }
    throw std::runtime_error("unsupported image type (this build decodes PNG only)");
}

} // namespace mln
