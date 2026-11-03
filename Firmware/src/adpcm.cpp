#include "adpcm.h"

static const int8_t kIndexTable[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};

static const int16_t kStepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
    3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

static uint8_t encodeSample(int16_t sample, AdpcmState& state) {
  int step = kStepTable[state.index];
  int diff = sample - state.predictor;
  int code = 0;
  if (diff < 0) {
    code = 8;
    diff = -diff;
  }
  int delta = step >> 3;
  if (diff >= step) { code |= 4; diff -= step; delta += step; }
  step >>= 1;
  if (diff >= step) { code |= 2; diff -= step; delta += step; }
  step >>= 1;
  if (diff >= step) { code |= 1; delta += step; }

  int predicted = state.predictor + ((code & 8) ? -delta : delta);
  state.predictor = predicted < -32768 ? -32768 : (predicted > 32767 ? 32767 : predicted);
  int index = state.index + kIndexTable[code];
  state.index = index < 0 ? 0 : (index > 88 ? 88 : index);
  return (uint8_t)code;
}

size_t adpcmEncode(const int16_t* samples, size_t count, AdpcmState& state, uint8_t* out) {
  size_t written = 0;
  for (size_t i = 0; i < count; i += 2) {
    uint8_t low = encodeSample(samples[i], state);
    uint8_t high = encodeSample(i + 1 < count ? samples[i + 1] : samples[count - 1], state);
    out[written++] = low | (high << 4);
  }
  return written;
}
