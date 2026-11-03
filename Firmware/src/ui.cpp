#include "ui.h"

// Black glass, warm white type, one orange for what is live: the recording
// and the charge. Same rule as the phone app's monochrome page.
static const uint16_t kInk = lgfx::color565(245, 242, 237);
static const uint16_t kSecondary = lgfx::color565(142, 142, 147);
static const uint16_t kTertiary = lgfx::color565(72, 72, 76);
static const uint16_t kMark = lgfx::color565(250, 92, 15);

// The parrot's yellow, for the mascot only.
static const uint16_t kMascot = lgfx::color565(236, 186, 64);

static const int kEdge = 10;

// MARK: Fonts

// Noto Sans TC rendered to M5GFX's anti-aliased VLW format (tools/make_fonts.py)
// and linked in by PlatformIO's embed_files. The efont bitmaps had no
// anti-aliasing and looked jagged on this screen.
#define EMBEDDED_FONT(name)                                          \
  extern const uint8_t name##_start[] asm("_binary_fonts_" #name "_vlw_start"); \
  extern const uint8_t name##_end[] asm("_binary_fonts_" #name "_vlw_end");
EMBEDDED_FONT(body)
EMBEDDED_FONT(label)
EMBEDDED_FONT(title)
EMBEDDED_FONT(clock)

struct EmbeddedFont {
  lgfx::PointerWrapper data;
  lgfx::VLWfont font;
  void load(const uint8_t* start, const uint8_t* end) {
    data.set(start, end - start);
    font.loadFont(&data);
  }
};
static EmbeddedFont bodyFont, labelFont, titleFont, clockFont;

void loadFonts() {
  bodyFont.load(body_start, body_end);
  labelFont.load(label_start, label_end);
  titleFont.load(title_start, title_end);
  clockFont.load(clock_start, clock_end);
}
static const int kTitleY = 52;

// Punctuation that must not start a line; it hangs on the line before.
static bool isClosingPunctuation(const char* p) {
  static const char* marks[] = {"，", "。", "、", "？", "！", "；", "：", "」", "』", "）", "…", ",", ".", "?", "!"};
  for (const char* mark : marks) {
    if (strncmp(p, mark, strlen(mark)) == 0) return true;
  }
  return false;
}

static int utf8Length(const char* p) {
  unsigned char lead = (unsigned char)*p;
  if (lead >= 0xF0) return 4;
  if (lead >= 0xE0) return 3;
  if (lead >= 0xC0) return 2;
  return 1;
}

// Draws `text` wrapped to `width`, `lineHeight` apart, at most `maxLines`
// lines; a cut ends in "…". Returns the y below the last line.
static int drawWrapped(M5Canvas& c, const char* text, int x, int y, int width,
                       int lineHeight, int maxLines) {
  char line[160];
  int lines = 0;
  const char* p = text;
  while (*p && lines < maxLines) {
    size_t length = 0;
    const char* lineStart = p;
    while (*p && *p != '\n') {
      int bytes = utf8Length(p);
      if (length + bytes >= sizeof(line) - 4) break;
      memcpy(line + length, p, bytes);
      line[length + bytes] = 0;
      if (c.textWidth(line) > width && !(length > 0 && isClosingPunctuation(p))) {
        line[length] = 0;
        // Inside an English word: break at the last space instead.
        if (isalnum((unsigned char)*p) && length > 0 && isalnum((unsigned char)line[length - 1])) {
          char* space = strrchr(line, ' ');
          if (space && space > line) {
            size_t keep = space - line;
            p = lineStart + keep + 1;
            length = keep;
            line[length] = 0;
          }
        }
        break;
      }
      length += bytes;
      p += bytes;
    }
    line[length] = 0;
    bool last = lines == maxLines - 1;
    if (last && *p && *p != '\n') {
      // Make room for the ellipsis.
      while (length > 0 && c.textWidth(line) + c.textWidth("…") > width) {
        do { length--; } while (length > 0 && ((unsigned char)line[length] & 0xC0) == 0x80);
        line[length] = 0;
      }
      strcat(line, "…");
    }
    c.drawString(line, x, y);
    y += lineHeight;
    lines++;
    if (*p == '\n') p++;
    if (p == lineStart) break;
  }
  return y;
}

// `compact` leaves out the percentage when a label takes the top left.
static void drawBattery(M5Canvas& c, int level, bool charging, bool compact) {
  if (level < 0) return;
  const int w = 22, h = 11;
  const int x = c.width() - kEdge - w - 2, y = 10;
  c.drawRoundRect(x, y, w, h, 3, kTertiary);
  c.fillRect(x + w, y + 3, 2, h - 6, kTertiary);
  int fill = (w - 4) * level / 100;
  if (fill > 0) c.fillRoundRect(x + 2, y + 2, max(fill, 2), h - 4, 1, level <= 15 ? kMark : kSecondary);

  char text[8];
  snprintf(text, sizeof(text), "%d%%", level);
  if (compact) text[0] = 0;
  c.setFont(&labelFont.font);
  c.setTextColor(kSecondary);
  c.setTextDatum(middle_right);
  int textRight = x - 5;
  if (charging) {
    // A small bolt where the charge comes in.
    int bx = x - 9, by = y + h / 2;
    c.fillTriangle(bx + 2, by - 6, bx - 2, by + 1, bx + 1, by + 1, kMark);
    c.fillTriangle(bx - 1, by - 1, bx + 2, by - 1, bx - 2, by + 6, kMark);
    textRight = bx - 6;
  }
  c.drawString(text, textRight, y + h / 2 + 1);
  c.setTextDatum(top_left);
}

static void drawTitle(M5Canvas& c, const char* title) {
  c.setFont(&titleFont.font);
  c.setTextColor(kInk);
  c.drawString(title, kEdge, kTitleY);
}

static void drawBody(M5Canvas& c, const char* text, uint16_t color, int y, int maxLines) {
  c.setFont(&bodyFont.font);
  c.setTextColor(color);
  drawWrapped(c, text, kEdge, y, c.width() - kEdge * 2, 24, maxLines);
}

static void drawLevels(M5Canvas& c, const float* levels, int centerY) {
  const int bar = 3, gap = 2;
  int x = (c.width() - (kLevelBars * (bar + gap) - gap)) / 2;
  for (int i = 0; i < kLevelBars; i++, x += bar + gap) {
    float level = levels ? levels[i] : 0;
    int half = 1 + (int)(level * 24);
    // Older bars fade so the newest sound reads first.
    uint16_t color = i >= kLevelBars - 6 ? kInk : kSecondary;
    c.fillRoundRect(x, centerY - half, bar, half * 2, 1, color);
  }
}

// A small live label top left: an orange dot and what is happening.
static void drawLive(M5Canvas& c, const char* label) {
  c.fillCircle(kEdge + 3, 16, 3, kMark);
  c.setFont(&labelFont.font);
  c.setTextColor(kSecondary);
  c.setTextDatum(middle_left);
  c.drawString(label, kEdge + 11, 17);
  c.setTextDatum(top_left);
}

// The screen's copy in the phone app's language.
static const char* tr(const UIModel& m, const char* chinese, const char* english) {
  return m.english ? english : chinese;
}

static void drawRecording(M5Canvas& c, const UIModel& m) {
  drawLive(c, tr(m, "錄音中", "Recording"));

  uint32_t seconds = m.recordingMs / 1000;
  char clock[12];
  snprintf(clock, sizeof(clock), "%u:%02u", seconds / 60, seconds % 60);
  // Each digit in a cell of the same width, so the clock doesn't shift as it ticks.
  c.setFont(&clockFont.font);
  c.setTextColor(kInk);
  c.setTextDatum(top_center);
  int digit = c.textWidth("0"), colon = c.textWidth(":");
  int width = 0;
  for (const char* p = clock; *p; p++) width += *p == ':' ? colon : digit;
  int x = (c.width() - width) / 2;
  for (const char* p = clock; *p; p++) {
    int cell = *p == ':' ? colon : digit;
    char one[2] = {*p, 0};
    c.drawString(one, x + cell / 2, 52);
    x += cell;
  }
  c.setTextDatum(top_left);

  drawLevels(c, m.levels, 140);

  c.setFont(&bodyFont.font);
  c.setTextColor(kSecondary);
  c.setTextDatum(top_center);
  c.drawString(m.latched ? tr(m, "再按一下送出", "Tap to send") : tr(m, "放開就送出", "Release to send"),
               c.width() / 2, 196);
  c.setTextDatum(top_left);
}

// The parrot: it says back what you said. One cell is one square of `scale`.
static void drawMascot(M5Canvas& c, int x, int y, int scale) {
  static const char* rows[] = {
      "......####........",
      ".....######.......",
      ".....###.#####....",
      ".....######..#....",
      "....#######.......",
      "...########.......",
      "...#######........",
      "..######..........",
      ".####.#.#.........",
      "####..............",
  };
  for (int row = 0; row < 10; row++) {
    for (int col = 0; rows[row][col]; col++) {
      if (rows[row][col] == '#') c.fillRect(x + col * scale, y + row * scale, scale, scale, kMascot);
    }
  }
}

static void drawCheck(M5Canvas& c, int x, int y) {
  c.drawWideLine(x, y + 5, x + 4, y + 9, 2, kMark);
  c.drawWideLine(x + 4, y + 9, x + 11, y, 2, kMark);
}

void drawUI(M5Canvas& c, const UIModel& m) {
  c.fillScreen(TFT_BLACK);
  c.setTextDatum(top_left);
  bool labelled = m.screen == Screen::Recording || m.screen == Screen::Finding || m.screen == Screen::Done;
  drawBattery(c, m.battery, m.charging, labelled);

  bool companion = m.screen == Screen::Waiting || m.screen == Screen::Ready || m.screen == Screen::Transcribing;
  if (companion) drawMascot(c, kEdge - 2, 8, 2);

  switch (m.screen) {
    case Screen::Waiting:
      drawTitle(c, tr(m, "等待連線", "Waiting"));
      drawBody(c, tr(m, "在 iPhone 上\n打開 Stick", "Open Stick\non your iPhone"), kSecondary, kTitleY + 40, 3);
      break;

    case Screen::Ready:
      drawTitle(c, tr(m, "按住說話", "Ready"));
      drawBody(c, tr(m, "或點一下開始，\n再點一下送出", "Hold to talk.\nOr tap, talk,\ntap to send."), kSecondary,
               kTitleY + 40, 3);
      if (m.lastText && *m.lastText) {
        c.drawFastHLine(kEdge, 154, c.width() - kEdge * 2, kTertiary);
        drawBody(c, m.lastText, kTertiary, 166, 2);
      }
      break;

    case Screen::Recording:
      drawRecording(c, m);
      break;

    case Screen::Transcribing: {
      if (m.waitingForPhone) {
        drawTitle(c, tr(m, "送出中", "Sending"));
        drawBody(c, tr(m, "等手機連上", "Waiting for\nthe phone"), kSecondary, kTitleY + 40, 2);
        break;
      }
      drawTitle(c, tr(m, "轉寫中", "Writing"));
      char length[32];
      snprintf(length, sizeof(length), tr(m, "%.1f 秒的錄音", "%.1f s recorded"), m.recordedSeconds);
      drawBody(c, length, kSecondary, kTitleY + 40, 1);
      break;
    }

    case Screen::Done:
      drawCheck(c, kEdge, 12);
      c.setFont(&labelFont.font);
      c.setTextColor(kSecondary);
      c.setTextDatum(middle_left);
      c.drawString(tr(m, "已送出", "Sent"), kEdge + 17, 17);
      c.setTextDatum(top_left);
      drawBody(c, m.detail, kInk, 44, 8);
      break;

    case Screen::Failed:
      drawTitle(c, tr(m, "沒成功", "Failed"));
      drawBody(c, m.detail, kSecondary, kTitleY + 40, 6);
      break;

    case Screen::Finding:
      drawLive(c, tr(m, "響鈴中", "Ringing"));
      drawTitle(c, tr(m, "在這裡", "I'm here"));
      drawBody(c, tr(m, "按一下就停", "Press to stop"), kSecondary, kTitleY + 40, 2);
      break;
  }
}
