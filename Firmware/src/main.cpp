// StickDictation firmware for the M5StickS3: hold the front button to talk
// (or tap to start and tap again to send), audio goes to the phone over BLE
// as IMA ADPCM (PROTOCOL.md), the phone's replies show on the screen.
// Mirrors macOS/StickPeripheral.swift.
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <esp_pm.h>
#include <esp_cpu.h>
#include <esp_sleep.h>
#include <driver/rtc_io.h>
#include "adpcm.h"
#include "ui.h"

static const char* kName = "StickS3";
static const char* kServiceUUID = "5A1D0001-8F3C-4C59-9B0A-6D2E5A7C1E01";
static const char* kTxUUID = "5A1D0002-8F3C-4C59-9B0A-6D2E5A7C1E01";
static const char* kRxUUID = "5A1D0003-8F3C-4C59-9B0A-6D2E5A7C1E01";

static const uint32_t kSampleRate = 16000;
static const uint8_t kCodecADPCM = 1;
static const size_t kAudioHeader = 8;
static const uint32_t kShortestMs = 300;
// A press shorter than this latches recording on until the next press;
// a longer one is push-to-talk and ends on release.
static const uint32_t kTapMs = 400;
static const uint32_t kLongestMs = 120000;

enum : uint8_t { kStart = 0x01, kAudio = 0x02, kEnd = 0x03, kCancel = 0x04, kSettingsReport = 0x05, kSleeping = 0x06 };
enum : uint8_t { kTranscribing = 0x10, kDone = 0x11, kError = 0x12, kFind = 0x13, kSettingsWrite = 0x14 };

// MARK: Settings, written by the phone (PROTOCOL.md, SETTINGS)

enum : uint8_t {
  kKeyBrightness = 1,  // backlight 8–255
  kKeyDimAfter = 2,    // seconds idle before dimming, 0 = never
  kKeySleepAfter = 3,  // seconds idle before the screen turns off, 0 = never
  kKeyMicGain = 4,     // dB of digital gain after the +30 dB analog stage, 0–32
  kKeyFindVolume = 5,  // 0–190: louder on battery can brown the stick out
  kKeyTapToLatch = 6,  // 1 = a short press starts recording until the next press
  kKeyDeepSleepAfter = 7,  // seconds idle before deep sleep, 0 = never
  kKeyLanguage = 8,        // the screen's language: 0 = Chinese, 1 = English
};

struct Settings {
  uint8_t brightness = 120;
  uint8_t dimAfter = 20;
  uint8_t sleepAfter = 60;
  uint8_t micGain = 16;
  uint8_t findVolume = 150;
  uint8_t tapToLatch = 1;
  // Last: settings saved by older firmware are shorter and keep this default.
  // Booting again costs far less than waiting awake, so this is short.
  uint8_t deepSleepAfter = 15;
  // Follows the phone app's language; 0 = Chinese, 1 = English.
  uint8_t language = 0;
};
static Settings settings;
static Preferences store;
// A slider sends a write per step; flash is saved once it settles.
static uint32_t settingsChangedAt = 0;

static void loadSettings() {
  store.begin("stick", true);
  store.getBytes("settings", &settings, sizeof(settings));
  store.end();
}

static void saveSettings() {
  store.begin("stick", false);
  store.putBytes("settings", &settings, sizeof(settings));
  store.end();
}

// The last wake from deep sleep, in ms after reset; RTC memory so it survives
// the reset that reading it over USB causes. `wakelog` prints it.
struct WakeLog {
  uint32_t magic;
  uint32_t setup;   // setup() entered
  uint32_t begun;   // M5.begin() returned
  uint32_t recording;
  uint32_t connected;
  uint32_t sent;
};
RTC_NOINIT_ATTR static WakeLog wakeLog;
static const uint32_t kWakeLogMagic = 0x3A4E0002;
static bool wokeThisBoot = false;

// Why the last few boots happened (esp_reset_reason, esp_sleep_get_wakeup_cause),
// newest last; `boots` prints them. Telling a real wake from deep sleep apart
// from a reset needs the boots before the one that reads this over USB.
struct BootRecord {
  uint8_t reset;
  uint8_t wakeup;
};
RTC_NOINIT_ATTR static BootRecord boots[6];
RTC_NOINIT_ATTR static uint32_t bootsMagic;

static void recordBoot() {
  if (bootsMagic != 0xB0075001) {
    bootsMagic = 0xB0075001;
    memset(boots, 0xFF, sizeof(boots));
  }
  memmove(boots, boots + 1, sizeof(boots) - sizeof(BootRecord));
  boots[5] = {(uint8_t)esp_reset_reason(), (uint8_t)esp_sleep_get_wakeup_cause()};
}

static void noteWake(uint32_t WakeLog::*field) {
  if (!wokeThisBoot || wakeLog.magic != kWakeLogMagic || wakeLog.*field) return;
  wakeLog.*field = millis();
}

// MARK: BLE state, written from the NimBLE task

static NimBLEServer* server;
static NimBLECharacteristic* tx;
static NimBLECharacteristic* battery;
static volatile bool connected = false;
static volatile bool subscribed = false;
static volatile uint16_t peerMTU = 23;
static volatile uint16_t connHandle = 0;
// The app re-subscribes when it relaunches without the link dropping.
static volatile bool subscribedAgain = false;

struct PhoneMessage {
  uint8_t length;
  uint8_t bytes[200];
};
static QueueHandle_t inbox;

// MARK: Main-loop state

static M5Canvas canvas(&M5.Display);
static UIModel model;
static bool screenDirty = true;
static char detail[200] = "";
static char lastText[200] = "";
static uint8_t session = 0;
static uint16_t seq = 0;
static AdpcmState encoder;
static uint32_t recordingStart = 0;
static uint32_t lastFindChirp = 0;
static uint32_t lastBatteryCheck = 0;
// Silent samples at the start of the last recording, to measure how long the
// codec takes to wake when the mic was off between recordings.
static uint32_t leadingQuiet = 0;
static bool heardSound = false;

static float levels[kLevelBars];
static float loudest = 0;
// A `demo` screen is up: nothing records or sends until the next press.
static bool previewing = false;

enum class Backlight { On, Dim, Off };
static Backlight backlight = Backlight::On;
static uint32_t lastActivity = 0;

// Mic buffers: M5.Mic keeps one buffer recording and one queued, so after
// record() returns for buffer k, buffer k-2 is full.
static const size_t kMicChunk = 512;  // 32 ms
// Woken from deep sleep, the first two are 512 ms each, so the mic keeps
// recording through the rest of setup (fonts, BLE) before loop() takes over.
// At 256 ms a word went missing ("測試123.567").
static const size_t kMicBootChunk = 8192;
static const int kMicBuffers = 4;
static int16_t* micBuffers[kMicBuffers];  // PSRAM, kMicBootChunk each
static size_t micLength[kMicBuffers];
static int micQueued = 0;

// Raw samples not yet encoded and sent. In PSRAM, room for a whole recording:
// woken from deep sleep, the stick records before the phone has reconnected
// and sends everything once it has.
static const size_t kPendingCapacity = kSampleRate * (kLongestMs / 1000);
static int16_t* pending = nullptr;
static size_t pendingCount = 0;
// START has gone out for this session; until then audio only accumulates.
static bool startSent = false;
// Finished before the phone was there; delivered when it connects.
static bool endPending = false;
static uint32_t endPendingSince = 0;

// Notifications that didn't fit in NimBLE's buffers yet.
struct Packet {
  uint16_t length;
  uint8_t bytes[248];
};
static const int kOutboxSize = 96;
static Packet outbox[kOutboxSize];
static int outHead = 0, outCount = 0;

// MARK: Link speed

// The radio wakes at every connection event: 15–30 ms while audio flows,
// 100–150 ms (and may skip two) the rest of the time. Both inside what iOS
// accepts; replies wait at most ~450 ms when idle.
static bool fastLink = false;

static void setFastLink(bool fast) {
  if (!connected || fast == fastLink) return;
  fastLink = fast;
  if (fast) server->updateConnParams(connHandle, 12, 24, 0, 400);
  else server->updateConnParams(connHandle, 80, 120, 2, 600);
}

// MARK: Outgoing

static void pump() {
  while (outCount > 0) {
    if (!connected || !subscribed) {
      outCount = 0;
      return;
    }
    Packet& packet = outbox[outHead];
    if (!tx->notify(packet.bytes, packet.length)) return;
    outHead = (outHead + 1) % kOutboxSize;
    outCount--;
  }
}

static void send(const uint8_t* bytes, size_t length) {
  if (!connected || !subscribed) return;
  if (outCount == kOutboxSize) {
    // BLE has stalled for seconds; drop the oldest, the phone sees a gap.
    outHead = (outHead + 1) % kOutboxSize;
    outCount--;
  }
  Packet& packet = outbox[(outHead + outCount) % kOutboxSize];
  packet.length = length;
  memcpy(packet.bytes, bytes, length);
  outCount++;
  pump();
}

static void reportSettings() {
  uint8_t packet[] = {
      kSettingsReport, 0,
      kKeyBrightness, settings.brightness, kKeyDimAfter, settings.dimAfter,
      kKeySleepAfter, settings.sleepAfter, kKeyMicGain, settings.micGain,
      kKeyFindVolume, settings.findVolume, kKeyTapToLatch, settings.tapToLatch,
      kKeyDeepSleepAfter, settings.deepSleepAfter, kKeyLanguage, settings.language,
  };
  send(packet, sizeof(packet));
}

static size_t samplesPerPacket() {
  size_t payload = min<size_t>(peerMTU - 3, sizeof(Packet::bytes));
  return (max(payload, kAudioHeader + 2) - kAudioHeader) * 2;
}

static void sendAudio(const int16_t* samples, size_t count) {
  uint8_t packet[sizeof(Packet::bytes)];
  packet[0] = kAudio;
  packet[1] = session;
  packet[2] = seq & 0xFF;
  packet[3] = seq >> 8;
  uint16_t predictor = (uint16_t)(int16_t)encoder.predictor;
  packet[4] = predictor & 0xFF;
  packet[5] = predictor >> 8;
  packet[6] = (uint8_t)encoder.index;
  size_t written = adpcmEncode(samples, count, encoder, packet + kAudioHeader);
  send(packet, kAudioHeader + written);
  seq++;
}

static bool linkReady() { return connected && subscribed; }

static void flushAudio(bool all) {
  if (!linkReady() || !startSent) return;
  size_t chunk = samplesPerPacket();
  size_t offset = 0;
  // Only as much as the outbox takes; a backlog from before the phone
  // connected would overflow it and drop the oldest packets.
  while ((pendingCount - offset >= chunk || (all && pendingCount > offset)) && outCount < kOutboxSize - 2) {
    size_t count = min(chunk, pendingCount - offset);
    sendAudio(pending + offset, count);
    offset += count;
  }
  memmove(pending, pending + offset, (pendingCount - offset) * sizeof(int16_t));
  pendingCount -= offset;
}

// Level for the meter: -50…-10 dBFS onto 0…1.
static void countLeadingQuiet(const int16_t* samples, size_t count) {
  for (size_t i = 0; i < count && !heardSound; i++) {
    if (abs(samples[i]) > 8) heardSound = true;
    else leadingQuiet++;
  }
}

static float levelOf(const int16_t* samples, size_t count) {
  float sum = 0;
  for (size_t i = 0; i < count; i++) sum += (float)samples[i] * samples[i];
  float db = 10 * log10f(sum / count / (32768.0f * 32768.0f) + 1e-10f);
  return constrain((db + 50) / 40, 0.0f, 1.0f);
}

static void takeSamples(const int16_t* samples, size_t count) {
  countLeadingQuiet(samples, count);
  loudest = max(loudest, levelOf(samples, count));
  while (count > 0) {
    size_t room = kPendingCapacity - pendingCount;
    if (room == 0) return;  // two minutes unsent; kLongestMs ends it
    size_t take = min(room, count);
    memcpy(pending + pendingCount, samples, take * sizeof(int16_t));
    pendingCount += take;
    samples += take;
    count -= take;
    flushAudio(false);
  }
}

// MARK: Screen

static void wake() {
  lastActivity = millis();
  if (backlight == Backlight::On) return;
  if (backlight == Backlight::Off) M5.Display.wakeup();
  M5.Display.setBrightness(settings.brightness);
  backlight = Backlight::On;
}

static void dimWhenIdle() {
  Screen screen = model.screen;
  bool busy = screen == Screen::Recording || screen == Screen::Transcribing || screen == Screen::Finding;
  if (busy) lastActivity = millis();
  uint32_t idle = millis() - lastActivity;
  if (backlight == Backlight::On && settings.dimAfter && idle >= settings.dimAfter * 1000u) {
    M5.Display.setBrightness(max<int>(settings.brightness / 8, 4));
    backlight = Backlight::Dim;
  } else if (backlight != Backlight::Off && settings.sleepAfter && idle >= settings.sleepAfter * 1000u) {
    M5.Display.setBrightness(0);
    M5.Display.sleep();
    backlight = Backlight::Off;
  }
}

// `byUser` is false for link changes: a link that keeps dropping must not
// keep the stick awake (it did, screen lit, showing 等待連線 over and over).
static void show(Screen next, const char* text = "", bool byUser = true) {
  if (byUser) wake();
  if (next != Screen::Recording && next != Screen::Transcribing) setFastLink(false);
  model.screen = next;
  strlcpy(detail, text, sizeof(detail));
  screenDirty = true;
}

static void draw() {
  model.detail = detail;
  model.lastText = lastText;
  model.levels = levels;
  if (model.screen == Screen::Recording) model.recordingMs = millis() - recordingStart;
  drawUI(canvas, model);
  canvas.pushSprite(0, 0);
  screenDirty = false;
}

// MARK: Microphone

// M5Unified starts the ES8311 with the analog PGA at its minimum, the ADC's
// digital volume at +32 dB and another x16 in software: the first recordings
// clipped (peaks at full scale, 1–3% of samples) over a -28 dBFS hiss. Gain
// belongs before the converter: +30 dB analog, the rest digital, x1 in software.
static const uint8_t kES8311 = 0x18;
static const uint8_t kMicPGA = 0x1A;  // REG14: MIC1P/N, PGA 10 x 3 dB

static void applyMicGain() {
  // REG17: 0xBF is 0 dB, 0.5 dB a step.
  uint8_t volume = 0xBF + min<uint8_t>(settings.micGain, 32) * 2;
  M5.In_I2C.writeRegister8(kES8311, 0x14, kMicPGA, 400000);
  M5.In_I2C.writeRegister8(kES8311, 0x17, volume, 400000);
}

static void startMic() {
  auto config = M5.Mic.config();
  config.magnification = 1;
  M5.Mic.config(config);
  M5.Mic.begin();
  applyMicGain();
}

// MARK: Sound

static void setFinding(bool on) {
  if (!on) {
    if (model.screen != Screen::Finding) return;
    M5.Speaker.end();
    show(connected ? Screen::Ready : Screen::Waiting);
    return;
  }
  if (model.screen == Screen::Recording) return;
  // The mic and the speaker share the codec; only one runs at a time.
  M5.Mic.end();
  M5.Speaker.begin();
  M5.Speaker.setVolume(min<uint8_t>(settings.findVolume, 190));
  lastFindChirp = 0;
  show(Screen::Finding);
}

// tone() starts the speaker by itself if it isn't running, which takes the
// codec from the mic: a `demo find` preview chirping left the mic dead.
static void chirpIfFinding() {
  if (previewing || model.screen != Screen::Finding || millis() - lastFindChirp < 1000) return;
  lastFindChirp = millis();
  M5.Speaker.tone(3200, 120);
}

// MARK: Recording

static void sendStart() {
  uint8_t start[] = {kStart, session, kCodecADPCM, kSampleRate & 0xFF, kSampleRate >> 8};
  send(start, sizeof(start));
  startSent = true;
}

// The recording itself, without the screen: woken from deep sleep this runs
// before the display and fonts are set up.
static void beginSession() {
  // Whatever left the codec on the speaker, take it back.
  if (M5.Speaker.isRunning()) M5.Speaker.end();
  if (!M5.Mic.isRunning()) startMic();
  leadingQuiet = 0;
  heardSound = false;
  session++;
  seq = 0;
  encoder = AdpcmState();
  pendingCount = 0;
  startSent = false;
  endPending = false;
  model.waitingForPhone = false;
  if (linkReady()) sendStart();
  micQueued = 0;
  model.latched = false;
  for (float& level : levels) level = 0;
  loudest = 0;
  recordingStart = millis();
}

static void startRecording() {
  beginSession();
  setFastLink(true);
  show(Screen::Recording);
}

static void queueMic(size_t length = kMicChunk) {
  int slot = micQueued % kMicBuffers;
  micLength[slot] = length;
  M5.Mic.record(micBuffers[slot], length, kSampleRate);
  micQueued++;
  // Two behind the one just queued is full.
  if (micQueued >= 3) {
    int done = (micQueued - 3) % kMicBuffers;
    takeSamples(micBuffers[done], micLength[done]);
  }
}

static void deliverRecording();

static void finishRecording(bool keep) {
  while (M5.Mic.isRecording()) delay(1);
  for (int k = max(0, micQueued - 2); k < micQueued; k++) {
    takeSamples(micBuffers[k % kMicBuffers], micLength[k % kMicBuffers]);
  }
  uint32_t length = millis() - recordingStart;
  // The running I2S holds the CPU awake; the mic is off between recordings.
  M5.Mic.end();
  Serial.printf("stick: lead quiet %lu ms\n", leadingQuiet * 1000 / kSampleRate);
  if (!keep || length < kShortestMs) {
    if (startSent) {
      uint8_t cancel[] = {kCancel, session};
      send(cancel, sizeof(cancel));
    }
    pendingCount = 0;
    startSent = false;
    show(linkReady() ? Screen::Ready : Screen::Waiting);
    return;
  }
  model.recordedSeconds = length / 1000.0f;
  if (!linkReady()) {
    endPending = true;
    endPendingSince = millis();
    model.waitingForPhone = true;
    show(Screen::Transcribing);
    Serial.println("stick: recorded, waiting for the phone");
    return;
  }
  deliverRecording();
}

// Everything still buffered, then END.
static void deliverRecording() {
  if (!startSent) sendStart();
  uint32_t started = millis();
  while (pendingCount > 0 && linkReady() && millis() - started < 15000) {
    flushAudio(true);
    pump();
    if (pendingCount > 0) delay(5);
  }
  uint8_t end[] = {kEnd, session, (uint8_t)(seq & 0xFF), (uint8_t)(seq >> 8)};
  send(end, sizeof(end));
  endPending = false;
  model.waitingForPhone = false;
  noteWake(&WakeLog::sent);
  show(Screen::Transcribing);
  Serial.printf("stick: sent %u packets\n", seq);
}

static void recordWhileHeld() {
  uint32_t elapsed = millis() - recordingStart;
  bool released = !model.latched && !M5.BtnA.isPressed();
  if (released && elapsed < kTapMs && settings.tapToLatch) {
    model.latched = true;
    screenDirty = true;
  } else if (released || elapsed >= kLongestMs) {
    finishRecording(true);
  } else {
    queueMic();
    static uint32_t lastTick = 0;
    if (millis() - lastTick >= 100) {
      lastTick = millis();
      memmove(levels, levels + 1, (kLevelBars - 1) * sizeof(float));
      levels[kLevelBars - 1] = loudest;
      loudest = 0;
      draw();
    }
  }
}

// MARK: Incoming

static void applySettings(const uint8_t* pairs, size_t length) {
  for (size_t i = 0; i + 1 < length; i += 2) {
    uint8_t value = pairs[i + 1];
    switch (pairs[i]) {
      case kKeyBrightness: settings.brightness = max<uint8_t>(value, 8); break;
      case kKeyDimAfter: settings.dimAfter = value; break;
      case kKeySleepAfter: settings.sleepAfter = value; break;
      case kKeyMicGain: settings.micGain = min<uint8_t>(value, 32); break;
      case kKeyFindVolume: settings.findVolume = min<uint8_t>(value, 190); break;
      case kKeyTapToLatch: settings.tapToLatch = value ? 1 : 0; break;
      case kKeyDeepSleepAfter: settings.deepSleepAfter = value; break;
      case kKeyLanguage: settings.language = value == 1 ? 1 : 0; break;
    }
  }
  model.english = settings.language == 1;
  screenDirty = true;
  settingsChangedAt = millis() | 1;
  if (M5.Mic.isRunning()) applyMicGain();
  else M5.Speaker.setVolume(settings.findVolume);
  if (backlight == Backlight::On) backlight = Backlight::Dim;  // so wake() applies the new brightness
  wake();
  reportSettings();
}

static void saveSettingsWhenSettled() {
  if (!settingsChangedAt || millis() - settingsChangedAt < 1000) return;
  settingsChangedAt = 0;
  saveSettings();
  Serial.printf("stick: settings saved %u %u %u %u %u %u\n", settings.brightness, settings.dimAfter,
                settings.sleepAfter, settings.micGain, settings.findVolume, settings.tapToLatch);
}

static void handle(const PhoneMessage& message) {
  if (message.length < 2) return;
  uint8_t type = message.bytes[0];
  if (type == kFind) {
    setFinding(message.length >= 3 && message.bytes[2] != 0);
    return;
  }
  if (type == kSettingsWrite) {
    applySettings(message.bytes + 2, message.length - 2);
    return;
  }
  if (message.bytes[1] != session || model.screen == Screen::Recording) return;
  char text[200];
  size_t length = min<size_t>(message.length - 2, sizeof(text) - 1);
  memcpy(text, message.bytes + 2, length);
  text[length] = 0;
  switch (type) {
    case kTranscribing: show(Screen::Transcribing); break;
    case kDone:
      strlcpy(lastText, text, sizeof(lastText));
      show(Screen::Done, text);
      break;
    case kError: show(Screen::Failed, text); break;
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    connected = true;
    connHandle = info.getConnHandle();
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    connected = false;
    subscribed = false;
    peerMTU = 23;
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo& info) override { peerMTU = mtu; }
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* c, NimBLEConnInfo& info, uint16_t value) override {
    subscribed = value != 0;
    if (subscribed) subscribedAgain = true;
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue value = c->getValue();
    PhoneMessage message;
    message.length = min<size_t>(value.length(), sizeof(message.bytes));
    memcpy(message.bytes, value.data(), message.length);
    xQueueSend(inbox, &message, 0);
  }
};

static int batteryLevel() {
  int level = M5.Power.getBatteryLevel();
  return level < 0 ? -1 : min(level, 100);
}

static void startBLE() {
  inbox = xQueueCreate(8, sizeof(PhoneMessage));
  NimBLEDevice::init(kName);
  NimBLEDevice::setMTU(247);
  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* service = server->createService(kServiceUUID);
  tx = service->createCharacteristic(kTxUUID, NIMBLE_PROPERTY::NOTIFY);
  tx->setCallbacks(new TxCallbacks());
  NimBLECharacteristic* rx = service->createCharacteristic(
      kRxUUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rx->setCallbacks(new RxCallbacks());

  NimBLEService* batteryService = server->createService(NimBLEUUID((uint16_t)0x180F));
  battery = batteryService->createCharacteristic(
      NimBLEUUID((uint16_t)0x2A19), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  uint8_t level = max(model.battery, 0);
  battery->setValue(&level, 1);

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->setName(kName);
  // 20–30 ms: the phone finds a just-woken stick quickly.
  advertising->setMinInterval(32);
  advertising->setMaxInterval(48);
  advertising->addServiceUUID(kServiceUUID);
  advertising->start();
}

// One reading a minute for the last four hours, to measure battery life
// unplugged; `battlog` over serial prints it after plugging back in.
// Kept in RTC memory: plugging the USB cable back in resets the chip (the
// port's DTR/RTS), which wiped the first test's log. Power loss still clears it.
static const int kBatteryLogSize = 240;
static const uint32_t kBatteryLogMagic = 0x5B477E02;

// One minute of a battery test: the voltage, what the PMIC says powers the
// stick, whether we held it awake for USB, and how much of the minute the
// CPU was not light-sleeping.
struct BatteryMinute {
  uint16_t millivolts;
  uint16_t vbusMillivolts;
  uint8_t powerSource;  // M5PM1 PWR_SRC: bit0 5VIN, bit1 5VINOUT, bit2 VBAT
  uint8_t heldAwake;
  uint8_t awakePercent;
  uint8_t reserved;
};
RTC_NOINIT_ATTR static BatteryMinute batteryLog[kBatteryLogSize];
RTC_NOINIT_ATTR static int batteryLogCount;
RTC_NOINIT_ATTR static uint32_t batteryLogMagic;
static uint32_t lastBatteryLog = 0;
static bool onUSB = false;
static bool heldAwake = false;

// The CPU's cycle counter stops in light sleep, so the cycles counted over a
// minute at a fixed 80 MHz say how much of it was spent awake.
static uint64_t awakeCycles = 0;
static uint32_t lastCycleCount = 0;

static void countAwakeCycles() {
  uint32_t now = esp_cpu_get_cycle_count();
  if (lastCycleCount) awakeCycles += (uint32_t)(now - lastCycleCount);
  lastCycleCount = now;
}

static void logBattery() {
  if (batteryLogMagic != kBatteryLogMagic || batteryLogCount < 0 || batteryLogCount > kBatteryLogSize) {
    batteryLogMagic = kBatteryLogMagic;
    batteryLogCount = 0;
  }
  if (!lastBatteryLog) {
    lastBatteryLog = millis();
    awakeCycles = 0;
    return;
  }
  uint32_t elapsed = millis() - lastBatteryLog;
  if (elapsed < 60000) return;
  lastBatteryLog = millis();
  if (batteryLogCount == kBatteryLogSize) {
    memmove(batteryLog, batteryLog + 1, (kBatteryLogSize - 1) * sizeof(BatteryMinute));
    batteryLogCount--;
  }
  BatteryMinute& minute = batteryLog[batteryLogCount++];
  minute.millivolts = (uint16_t)M5.Power.getBatteryVoltage();
  minute.vbusMillivolts = (uint16_t)max<int>(M5.Power.getVBUSVoltage(), 0);
  minute.powerSource = (uint8_t)M5.Power.M5pm1.getPowerSource();
  minute.heldAwake = heldAwake;
  minute.awakePercent = (uint8_t)min<uint64_t>(awakeCycles * 100 / (80000ULL * elapsed), 255);
  awakeCycles = 0;
}

static void printBatteryLog() {
  Serial.printf("battlog %d minutes, now %lus up, vbus %dmV\n", batteryLogCount, millis() / 1000,
                (int)M5.Power.getVBUSVoltage());
  for (int i = 0; i < batteryLogCount; i++) {
    const BatteryMinute& m = batteryLog[i];
    Serial.printf("battlog %d %u mV, vbus %u, source %u, held %u, awake %u%%\n", i, m.millivolts,
                  m.vbusMillivolts, m.powerSource, m.heldAwake, m.awakePercent);
  }
}

// Light sleep powers down the USB serial port, so stay awake on USB power:
// flashing and logs keep working, and power is free then anyway.
static esp_pm_lock_handle_t stayAwake = nullptr;
// Kept awake on USB only while a computer is talking to it (flashing, logs):
// awake and charging at once, it used the whole charge current and got hot.
static uint32_t developingUntil = 0;
static const uint32_t kDevelopingMs = 600000;
// After a boot on USB power: long enough to start flashing. Short, because
// awake while charging is what made it hot.
static const uint32_t kHostSeenMs = 60000;
static bool developing() { return millis() < developingUntil; }

static void stayAwakeOnUSB() {
  onUSB = M5.Power.getVBUSVoltage() > 4000;
  bool hold = onUSB && developing();
  if (!stayAwake) esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "usb", &stayAwake);
  if (!stayAwake || hold == heldAwake) return;
  heldAwake = hold;
  if (hold) esp_pm_lock_acquire(stayAwake);
  else esp_pm_lock_release(stayAwake);
  Serial.printf("stick: %s\n", hold ? "computer on USB, staying awake" : "sleep allowed");
}

static void checkBattery() {
  logBattery();
  if (lastBatteryCheck && millis() - lastBatteryCheck < 30000) return;
  lastBatteryCheck = millis();
  stayAwakeOnUSB();
  int level = batteryLevel();
  bool charging = M5.Power.isCharging() == m5::Power_Class::is_charging;
  Serial.printf("stick: battery %d%% %dmV charging %d vbus %dmV\n", level,
                (int)M5.Power.getBatteryVoltage(), (int)charging, (int)M5.Power.getVBUSVoltage());
  if (charging != model.charging) {
    model.charging = charging;
    screenDirty = true;
  }
  if (level < 0 || level == model.battery) return;
  model.battery = level;
  uint8_t value = level;
  battery->setValue(&value, 1);
  if (connected) battery->notify();
  screenDirty = true;
}

// MARK: Development: serial commands for screenshots and previews

static void sendScreenshot() {
  Serial.printf("SHOT %d %d\n", canvas.width(), canvas.height());
  Serial.write((const uint8_t*)canvas.getBuffer(), canvas.width() * canvas.height() * 2);
  Serial.println();
  Serial.println("END");
}

// "demo <screen> [text]" puts a screen up without the phone.
static void preview(const String& line) {
  String rest = line.substring(5);
  int space = rest.indexOf(' ');
  String name = space < 0 ? rest : rest.substring(0, space);
  String text = space < 0 ? "" : rest.substring(space + 1);
  Screen next = Screen::Ready;
  previewing = true;
  if (name == "waiting") next = Screen::Waiting;
  else if (name == "rec" || name == "latched") {
    next = Screen::Recording;
    recordingStart = millis() - 7300;
    model.latched = name == "latched";
    for (int i = 0; i < kLevelBars; i++) levels[i] = 0.35f + 0.45f * fabsf(sinf(i * 0.7f)) * (i % 3 ? 1 : 0.5f);
  } else if (name == "tx") { next = Screen::Transcribing; model.recordedSeconds = 7.3f; }
  else if (name == "done") next = Screen::Done;
  else if (name == "fail") next = Screen::Failed;
  else if (name == "find") next = Screen::Finding;
  else if (name == "last") strlcpy(lastText, text.c_str(), sizeof(lastText));
  show(next, text.c_str());
  draw();
}

static void goToDeepSleep();

static void readSerialCommand() {
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch != '\n') { line += ch; continue; }
    line.trim();
    developingUntil = millis() + kDevelopingMs;
    if (line == "shot") sendScreenshot();
    else if (line.startsWith("demo ")) preview(line);
    else if (line == "battlog") printBatteryLog();
    else if (line == "battlog clear") batteryLogCount = 0;
    else if (line == "sleep") goToDeepSleep();
    else if (line == "boots") {
      for (const BootRecord& boot : boots) Serial.printf("boot reset %u wakeup %u\n", boot.reset, boot.wakeup);
    }
    else if (line == "wakelog") {
      Serial.printf("wakelog setup %lu, begun %lu, recording %lu, connected %lu, sent %lu ms after reset\n",
                    wakeLog.setup, wakeLog.begun, wakeLog.recording, wakeLog.connected, wakeLog.sent);
    }
    line = "";
  }
}

// MARK: Deep sleep


// Idle on battery, the stick turns everything off and sleeps until the front
// button is pressed. Waking it records at once; the phone reconnects (iOS
// holds a pending connection) and gets the recording when it does.
static void goToDeepSleep() {
  Serial.println("stick: deep sleep");
  if (linkReady()) {
    uint8_t bye[] = {kSleeping, 0};
    send(bye, sizeof(bye));
    for (int i = 0; i < 20 && outCount > 0; i++) {
      pump();
      delay(10);
    }
    delay(150);
  }
  M5.Mic.end();
  M5.Speaker.end();
  M5.Display.setBrightness(0);
  M5.Display.sleep();
  M5.Display.waitDisplay();
  M5.Power.setExtOutput(false);
  // Wait for the finger to lift, or the press itself would wake it again.
  while (digitalRead(GPIO_NUM_11) == LOW) delay(10);
  wakeLog = {kWakeLogMagic, 0, 0, 0, 0, 0};
  // Light sleep's tickless idle leaves a timer wakeup armed; deep sleep kept
  // it and woke up within a second (seen as wakeup cause 4, the timer).
  esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
  rtc_gpio_pullup_en(GPIO_NUM_11);
  rtc_gpio_pulldown_dis(GPIO_NUM_11);
  esp_sleep_enable_ext0_wakeup(GPIO_NUM_11, 0);
  Serial.println("stick: sleeping now");
  Serial.flush();
  delay(20);
  esp_deep_sleep_start();
}

static void sleepWhenIdle() {
  if (heldAwake || !settings.deepSleepAfter || previewing || endPending) return;
  Screen screen = model.screen;
  if (screen == Screen::Recording || screen == Screen::Transcribing || screen == Screen::Finding) return;
  // Without the phone there is nothing to wait for.
  uint32_t after = linkReady() ? settings.deepSleepAfter * 1000u : 15000u;
  if (millis() - lastActivity >= after) goToDeepSleep();
}

// MARK: Arduino

// A reset that lands mid-I2C (flashing, then the serial port's own reset)
// has left the PMIC silent, so M5Unified saw no board and set up no screen.
RTC_NOINIT_ATTR static uint32_t unknownBoardRetries;

void setup() {
  bool wokeByButton = esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0;
  wokeThisBoot = wokeByButton;
  noteWake(&WakeLog::setup);
  recordBoot();
  auto config = M5.config();
  // Unused, and slow to start: the BMI270 takes an 8 KB config upload.
  config.internal_imu = false;
  config.internal_rtc = false;
  // Woken from deep sleep the panel only needs waking, not a reset.
  config.clear_display = !wokeByButton;
  M5.begin(config);
  noteWake(&WakeLog::begun);
  Serial.begin(115200);
  Serial.printf("stick: board %d, retries %u\n", (int)M5.getBoard(), (unsigned)unknownBoardRetries);
  if (M5.getBoard() == m5::board_t::board_unknown || M5.Display.width() == 0) {
    if (unknownBoardRetries < 3) {
      unknownBoardRetries++;
      Serial.println("stick: no board found, restarting");
      delay(200);
      ESP.restart();
    }
  }
  unknownBoardRetries = 0;
  // 80 MHz is plenty for 16 kHz ADPCM and BLE; between BLE events the chip
  // light-sleeps (on USB power ESP-IDF keeps it awake for the serial port).
  esp_pm_config_t power = {};
  power.max_freq_mhz = 80;
  // The battery log's awake share assumes 80 MHz, so it reads low at 40.
  power.min_freq_mhz = 40;
  // No light sleep: with deep sleep between dictations the stick is only
  // awake for seconds, and light sleep cost more than it saved: the BLE link
  // kept dropping, the USB port stopped answering (no flashing, no logs),
  // and it left a timer wakeup armed for deep sleep.
  power.light_sleep_enable = false;
  esp_err_t powerResult = esp_pm_configure(&power);
  loadSettings();
  // Firmware before this counted minutes; 1–9 there means 15 s now.
  if (settings.deepSleepAfter > 0 && settings.deepSleepAfter < 10) settings.deepSleepAfter = 15;
  model.english = settings.language == 1;
  for (int16_t*& buffer : micBuffers) buffer = (int16_t*)ps_malloc(kMicBootChunk * sizeof(int16_t));
  // Flashing and opening the serial port both reset over USB.
  if (esp_reset_reason() == ESP_RST_USB) developingUntil = millis() + kDevelopingMs;
  M5.Speaker.end();
  pending = (int16_t*)ps_malloc(kPendingCapacity * sizeof(int16_t));
  if (wokeByButton) {
    // The press that woke it is a recording: start the mic before anything
    // that can wait.
    beginSession();
    queueMic(kMicBootChunk);
    queueMic(kMicBootChunk);
    noteWake(&WakeLog::recording);
  }
  // The PMIC's green LED; try keeping it off.
  M5.Power.M5pm1.setLedEnLevel(false);
  // Portrait, upright with the front button below the screen.
  M5.Display.setRotation(0);
  M5.Display.setBrightness(settings.brightness);
  canvas.setPsram(true);
  canvas.setColorDepth(16);
  canvas.createSprite(M5.Display.width(), M5.Display.height());
  loadFonts();
  // The press that woke it starts a recording, like a press when awake: still
  // held, it ends on release; let go already, it was a tap and the next press
  // sends it. The screen lights up on it right now, before BLE starts, so
  // "lit" means "speak".
  bool recordingOnWake = false;
  if (wokeByButton) {
    M5.update();
    if (!M5.BtnA.isPressed()) model.latched = settings.tapToLatch;
    recordingOnWake = M5.BtnA.isPressed() || model.latched;
    if (recordingOnWake) show(Screen::Recording);
    else finishRecording(false);
  }
  model.battery = batteryLevel();
  // On USB power, the first minute after any boot stays out of light sleep,
  // so a computer can flash it after a press. (Detecting the host by its
  // USB frames didn't work this early.) Deep sleep still follows as usual.
  if (M5.Power.getVBUSVoltage() > 4000 && !developing()) developingUntil = millis() + kHostSeenMs;
  stayAwakeOnUSB();
  startBLE();
  lastActivity = millis();
  if (wokeByButton) {
    if (recordingOnWake) setFastLink(true);
    Serial.printf("stick: woke by the button, recording %lu ms after reset\n", wakeLog.recording);
  }
  Serial.printf("stick: ready, battery %d, power management %s\n", model.battery, esp_err_to_name(powerResult));
}

void loop() {
  countAwakeCycles();
  M5.update();

  static bool wasConnected = false;
  bool isConnected = connected && subscribed;
  if (isConnected != wasConnected) {
    wasConnected = isConnected;
    Serial.printf("stick: %s, mtu %u\n", isConnected ? "connected" : "disconnected", peerMTU);
    previewing = false;
    fastLink = true;  // new links start fast; settle to idle below
    // A recording the phone already started can't be resumed; one it hasn't
    // seen yet keeps buffering for the next connection.
    if (!isConnected && model.screen == Screen::Recording && startSent) finishRecording(false);
    if (!isConnected) setFinding(false);
    bool busy = model.screen == Screen::Recording || endPending;
    if (isConnected) noteWake(&WakeLog::connected);
    if (isConnected && model.screen == Screen::Recording && !startSent) {
      sendStart();
      setFastLink(true);
    }
    if (isConnected && endPending) {
      setFastLink(true);
      deliverRecording();
    }
    if (!busy) show(isConnected ? Screen::Ready : Screen::Waiting, "", false);
  }
  if (endPending && millis() - endPendingSince > 20000) {
    endPending = false;
    pendingCount = 0;
    model.waitingForPhone = false;
    show(Screen::Failed, model.english ? "Can't reach the phone" : "連不上手機");
  }
  if (subscribedAgain && isConnected) {
    subscribedAgain = false;
    reportSettings();
  }

  PhoneMessage message;
  while (xQueueReceive(inbox, &message, 0) == pdTRUE) handle(message);

  if (M5.BtnA.wasPressed() && previewing) {
    previewing = false;
    show(isConnected ? Screen::Ready : Screen::Waiting);
  } else if (M5.BtnA.wasPressed()) {
    wake();
    Serial.println("stick: BtnA down");
    if (model.screen == Screen::Finding) {
      setFinding(false);
    } else if (model.screen == Screen::Recording && model.latched) {
      finishRecording(true);
    } else if (isConnected && model.screen != Screen::Recording) {
      startRecording();
    }
  }
  if (M5.BtnB.wasPressed()) Serial.println("stick: BtnB down");

  if (model.screen == Screen::Recording && !previewing) recordWhileHeld();

  chirpIfFinding();
  checkBattery();
  static uint32_t lastUSBCheck = 0;
  if (millis() - lastUSBCheck > 2000) {
    lastUSBCheck = millis();
    stayAwakeOnUSB();
  }
  dimWhenIdle();
  sleepWhenIdle();
  saveSettingsWhenSettled();
  readSerialCommand();
  pump();
  if (screenDirty) draw();
  // Every wake-up out of light sleep costs; at 15 ms the CPU was awake 21% of
  // an idle minute. Poll the button less often the less is going on.
  if (model.screen == Screen::Recording) return;
  if (model.screen == Screen::Finding) delay(5);
  else if (backlight == Backlight::On) delay(20);
  else delay(60);
}
