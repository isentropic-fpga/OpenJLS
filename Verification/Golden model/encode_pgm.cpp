// Copyright (C) 2026 Vitor Mendes Camilo
// SPDX-License-Identifier: GPL-3.0-only
// CharLS reference encoder with a LIMIT-based allocation. The upstream CLI's
// estimated_destination_size() can be too small for expanding 16-bit images.
#include <charls/jpegls_encoder.hpp>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) try {
    if (argc != 3) throw std::runtime_error("usage: encode_pgm input.pgm output.jls");
    std::ifstream input(argv[1], std::ios::binary);
    auto token = [&]() {
        std::string s;
        input >> std::ws;
        while (input.peek() == '#') {
            input.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
            input >> std::ws;
        }
        if (!(input >> s)) throw std::runtime_error("truncated PGM header");
        return s;
    };
    if (token() != "P5") throw std::runtime_error("expected binary grayscale PGM");
    const auto width = static_cast<uint32_t>(std::stoul(token()));
    const auto height = static_cast<uint32_t>(std::stoul(token()));
    const auto maxval = std::stoul(token());
    if (!width || !height || width > 65535 || height > 65535 || maxval < 255 || maxval > 65535 || (maxval & (maxval + 1)))
        throw std::runtime_error("expected 8..16-bit full-range PGM");
    int bpp = 0;
    for (auto value = maxval; value; value >>= 1) ++bpp;
    const int separator = input.get();
    if (separator == EOF || !std::isspace(static_cast<unsigned char>(separator)))
        throw std::runtime_error("missing PGM separator");
    if (separator == '\r' && input.peek() == '\n') input.get();
    const size_t pixels = static_cast<size_t>(width) * height;
    std::vector<uint8_t> source(pixels * (bpp > 8 ? 2 : 1));
    if (!input.read(reinterpret_cast<char*>(source.data()), source.size()))
        throw std::runtime_error("truncated PGM pixels");
    // CharLS takes native-endian samples; PGM samples are big endian.
    const uint16_t native = 1;
    if (bpp > 8 && *reinterpret_cast<const uint8_t*>(&native))
        for (size_t i = 0; i < source.size(); i += 2) std::swap(source[i], source[i + 1]);
    charls::jpegls_encoder encoder;
    encoder.frame_info({width, height, bpp, 1});
    // <=64 coded bits/pixel; at most nine stuffed bytes plus frame markers.
    if (pixels > (std::numeric_limits<size_t>::max() - 1024) / 9)
        throw std::runtime_error("image too large");
    std::vector<uint8_t> destination(9 * pixels + 1024);
    encoder.destination(destination);
    const size_t count = encoder.encode(source);
    std::ofstream output(argv[2], std::ios::binary);
    if (!output.write(reinterpret_cast<const char*>(destination.data()), count))
        throw std::runtime_error("cannot write JLS output");
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}
