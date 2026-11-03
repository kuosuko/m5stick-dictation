#pragma once
#include <stdint.h>
#include <stddef.h>

// IMA ADPCM, 4:1, low nibble first. Same encoder as Shared/IMAADPCM.swift.
struct AdpcmState {
  int predictor = 0;
  int index = 0;
};

// Encodes `count` samples into `out` ((count + 1) / 2 bytes) and advances
// `state`. An odd count is padded with the last sample repeated.
size_t adpcmEncode(const int16_t* samples, size_t count, AdpcmState& state, uint8_t* out);
