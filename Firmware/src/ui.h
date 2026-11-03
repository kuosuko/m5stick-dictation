#pragma once
#include <M5Unified.h>

enum class Screen { Waiting, Ready, Recording, Transcribing, Done, Failed, Finding };

static const int kLevelBars = 22;

// Everything the screen shows; main.cpp owns the state, ui.cpp only draws.
struct UIModel {
  Screen screen = Screen::Waiting;
  const char* detail = "";     // phone's text for Done / Failed
  const char* lastText = "";   // last thing sent, shown faintly while ready
  bool latched = false;        // tap-started recording, ends on the next tap
  bool waitingForPhone = false;  // recorded after waking; the phone isn't back yet
  uint32_t recordingMs = 0;
  float recordedSeconds = 0;   // length of the recording being transcribed
  const float* levels = nullptr;  // kLevelBars values 0…1, oldest first
  int battery = -1;
  bool charging = false;
  bool english = false;        // the screen's language, from the phone app
};

// Call once before the first drawUI().
void loadFonts();
void drawUI(M5Canvas& canvas, const UIModel& model);
