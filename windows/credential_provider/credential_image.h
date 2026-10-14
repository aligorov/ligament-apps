#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <stdexcept>
#include <vector>

namespace ligament {
namespace credential_image_detail {

inline void AppendBigEndian(std::vector<uint8_t>& bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value >> 24));
    bytes.push_back(static_cast<uint8_t>(value >> 16));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
    bytes.push_back(static_cast<uint8_t>(value));
}

inline uint32_t PngCrc32(const uint8_t* bytes, size_t size) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < size; ++i) {
        crc ^= bytes[i];
        for (unsigned bit = 0; bit < 8; ++bit) {
            const uint32_t mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

inline void AppendPngChunk(std::vector<uint8_t>& png, const char (&type)[5],
                           const std::vector<uint8_t>& data) {
    AppendBigEndian(png, static_cast<uint32_t>(data.size()));
    const size_t crcStart = png.size();
    for (size_t i = 0; i < 4; ++i) png.push_back(static_cast<uint8_t>(type[i]));
    png.insert(png.end(), data.begin(), data.end());
    AppendBigEndian(png, PngCrc32(png.data() + crcStart, data.size() + 4));
}

} // namespace credential_image_detail

// Encodes only opaque, top-down BGRA DIB pixels. Each uint32_t is 0xAARRGGBB;
// row padding is specified in pixels. The caller owns at least
// (height - 1) * stridePixels + width source pixels. No Win32/COM/WIC is used.
// The 4096-pixel dimension limit bounds allocations for this credential image
// helper. Invalid dimensions, stride, nonopaque pixels, or allocation failure
// return an empty vector. PNG uses RGBA8 with lossless, stored DEFLATE blocks.
inline std::vector<uint8_t> EncodeOpaqueBgraPng(const uint32_t* pixels,
                                              unsigned width,
                                              unsigned height,
                                              unsigned stridePixels) {
    constexpr size_t kMaxDimension = 4096;
    constexpr size_t kMaxSourcePixels = kMaxDimension * kMaxDimension;
    if (!pixels || width == 0 || height == 0 || width > kMaxDimension ||
        height > kMaxDimension || stridePixels < width) {
        return {};
    }
    // Check the last row offset before any pointer arithmetic, including when
    // size_t is 32 bits. Bound padded source storage to the same image budget.
    const size_t rowsBeforeLast = static_cast<size_t>(height) - 1;
    if (rowsBeforeLast != 0 &&
        static_cast<size_t>(stridePixels) >
            (kMaxSourcePixels - width) / rowsBeforeLast) {
        return {};
    }
    const size_t sourcePixels = rowsBeforeLast * stridePixels + width;
    if (sourcePixels > kMaxSourcePixels ||
        sourcePixels > (std::numeric_limits<size_t>::max)() / sizeof(uint32_t)) {
        return {};
    }

    try {
        const size_t rowBytes = static_cast<size_t>(width) * 4 + 1;
        const size_t rawSize = rowBytes * height;
        std::vector<uint8_t> raw(rawSize);
        uint32_t adlerA = 1;
        uint32_t adlerB = 0;
        size_t offset = 0;
        for (unsigned y = 0; y < height; ++y) {
            raw[offset++] = 0; // PNG filter: None.
            const uint32_t* row = pixels + static_cast<size_t>(y) * stridePixels;
            for (unsigned x = 0; x < width; ++x) {
                const uint32_t pixel = row[x];
                if ((pixel >> 24) != 255u) return {};
                raw[offset++] = static_cast<uint8_t>(pixel >> 16);
                raw[offset++] = static_cast<uint8_t>(pixel >> 8);
                raw[offset++] = static_cast<uint8_t>(pixel);
                raw[offset++] = 255;
            }
        }
        for (uint8_t byte : raw) {
            adlerA = (adlerA + byte) % 65521u;
            adlerB = (adlerB + adlerA) % 65521u;
        }

        constexpr size_t kBlockSize = 65535;
        const size_t blocks = (rawSize + kBlockSize - 1) / kBlockSize;
        const size_t zlibSize = 2 + rawSize + blocks * 5 + 4;
        if (zlibSize > (std::numeric_limits<uint32_t>::max)()) return {};
        std::vector<uint8_t> compressed;
        compressed.reserve(zlibSize);
        compressed.push_back(0x78); // DEFLATE, 32 KiB window.
        compressed.push_back(0x01); // No compression, valid FCHECK.
        for (size_t start = 0; start < rawSize;) {
            const size_t remaining = rawSize - start;
            const uint16_t length = static_cast<uint16_t>(
                remaining < kBlockSize ? remaining : kBlockSize);
            const uint16_t inverseLength = static_cast<uint16_t>(~length);
            // BTYPE=00; stored blocks always finish at a byte boundary.
            compressed.push_back(remaining <= kBlockSize ? 0x01 : 0x00);
            compressed.push_back(static_cast<uint8_t>(length));
            compressed.push_back(static_cast<uint8_t>(length >> 8));
            compressed.push_back(static_cast<uint8_t>(inverseLength));
            compressed.push_back(static_cast<uint8_t>(inverseLength >> 8));
            compressed.insert(compressed.end(), raw.begin() + start,
                              raw.begin() + start + length);
            start += length;
        }
        using namespace credential_image_detail;
        AppendBigEndian(compressed, (adlerB << 16) | adlerA);

        std::vector<uint8_t> png;
        png.reserve(8 + 25 + 12 + compressed.size() + 12);
        const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
        png.insert(png.end(), signature, signature + sizeof(signature));
        std::vector<uint8_t> ihdr;
        ihdr.reserve(13);
        AppendBigEndian(ihdr, width);
        AppendBigEndian(ihdr, height);
        ihdr.insert(ihdr.end(), {8, 6, 0, 0, 0}); // RGBA8, no interlacing.
        AppendPngChunk(png, "IHDR", ihdr);
        AppendPngChunk(png, "IDAT", compressed);
        AppendPngChunk(png, "IEND", {});
        return png;
    } catch (const std::bad_alloc&) {
        return {};
    } catch (const std::length_error&) {
        return {};
    }
}

} // namespace ligament
