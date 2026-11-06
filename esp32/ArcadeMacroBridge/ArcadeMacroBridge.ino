#include <Arduino.h>
#include <esp32-hal-rgb-led.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <USBHost.h>
#include <USBHostHID.h>
#include "tusb.h"

#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error This sketch targets an ESP32-S3 board.
#endif

// Bridge v3: live input plus macro-only settings writes for the 8BitDo Arcade
// Stick 80FE. Packet formats were verified byte-for-byte against a USB capture
// of the official 8BitDo Ultimate Software (see esp32/model-80FE-notes.md).
//
// Safety rules enforced here, not in the phone app:
//  - The firmware-update ("boot") command is never sent; only the version and
//    config-mode commands exist in this file.
//  - WRITE requires a READ in the same session, and is rejected unless every
//    byte outside the two macro sections matches what was read. Button
//    mappings, profile names and flags outside the macro sections can't change.
//  - Every write is read back and compared.

static constexpr char kServiceUuid[] = "a8c70001-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kStatusUuid[] = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kCommandUuid[] = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kResponseUuid[] = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kInputUuid[] = "a8c70005-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kDataUuid[] = "a8c70006-7d2b-4f4e-a5e9-8b7b5f66e001";

// ---------------------------------------------------------------------------
// Settings block layout (ultimate_info_record_t_ArcadeStick, 564 bytes)
//   0  u16 crc (CRC-16, reflected poly 0x1021, init 0xFFFF, over bytes 2..563)
//   2  u8  struct_ver
//   3  u8  platform (0 = Switch/S slot, 1 = Windows/X slot)
//   4  slot[2], 280 bytes each:
//        +0   u32 flag (0x20191212)
//        +4   u8  file_name[32] (UTF-16LE)
//        +36  macro_fun (168 bytes): u32 flag, u8 total_cnt, pad, 2 x 80-byte macro
//        +204 map_key (76 bytes): u32 flag, u32 key[18]
static constexpr uint16_t kBlockSize = 564;
static constexpr uint16_t kChunk = 45;
static constexpr uint16_t kSlotBase = 4, kSlotSize = 280;
static constexpr uint16_t kMacroOffset = 36, kMacroSize = 168;
static constexpr uint16_t kBleChunk = 16;

static bool inMacroRegion(uint16_t i) {
  if (i < kSlotBase) return false;
  uint16_t rel = (i - kSlotBase) % kSlotSize;
  return rel >= kMacroOffset && rel < kMacroOffset + kMacroSize;
}

static uint16_t blockCrc(const uint8_t *b) {
  uint16_t c = 0xFFFF;
  for (uint16_t i = 2; i < kBlockSize; ++i) {
    c ^= b[i];
    for (int k = 0; k < 8; ++k) c = (c & 1) ? (c >> 1) ^ 0x8408 : (c >> 1);
  }
  return c;
}

// ---------------------------------------------------------------------------
// USB HID handler for the stick, in either of its two identities:
//   057E:2009  Switch (S) mode - normal play
//   2DC8:901A  8BitDo config mode - settings read/write
static constexpr uint16_t kVidNintendo = 0x057E, kPidSwitchPro = 0x2009;
static constexpr uint16_t kVid8BitDo = 0x2DC8;

class StickLink : public USBHostHIDDevice {
public:
  bool claim(uint8_t dev_addr, uint8_t idx, uint8_t, const uint8_t *, uint16_t) override {
    uint16_t vid = 0, pid = 0;
    tuh_vid_pid_get(dev_addr, &vid, &pid);
    bool ours = (vid == kVidNintendo && pid == kPidSwitchPro) || vid == kVid8BitDo;
    if (!ours || !bindHidInterface(dev_addr, idx)) return false;
    portENTER_CRITICAL(&mux_);
    vid_ = vid; outPending_ = false; respHead_ = respTail_ = 0; inputReady_ = false;
    portEXIT_CRITICAL(&mux_);
    return true;
  }
  void onUnmount(uint8_t dev_addr, uint8_t idx) override {
    if (!matches(dev_addr, idx)) return;
    clearHidInterfaceBinding();
    portENTER_CRITICAL(&mux_);
    vid_ = 0; outPending_ = false;
    portEXIT_CRITICAL(&mux_);
  }
  void onReport(uint8_t, uint8_t, const uint8_t *r, uint16_t len) override {
    uint16_t n = len > 64 ? 64 : len;
    bool isResponse = n >= 2 && ((r[0] == 0x81 && r[1] == 0x66) ||  // Switch-mode reply
                                 (r[0] == 0x02 && r[1] == 0x04));   // config-mode reply
    portENTER_CRITICAL(&mux_);
    if (isResponse) {
      // Small FIFO so a late or repeated reply can't overwrite the one we want.
      uint8_t next = (respHead_ + 1) % kRespSlots;
      if (next == respTail_) respTail_ = (respTail_ + 1) % kRespSlots;  // drop oldest
      memset(resp_[respHead_], 0, 64);
      memcpy(resp_[respHead_], r, n);
      respHead_ = next;
    }
    else { memset(input_, 0, 64); memcpy(input_, r, n); inputLen_ = n; inputReady_ = true; }
    portEXIT_CRITICAL(&mux_);
  }
  void serviceFromHostTask() override {
    if (!outPending_ || !_mounted) return;
    if (!tuh_hid_send_ready(_dev_addr, _idx)) return;
    uint8_t pkt[64];
    portENTER_CRITICAL(&mux_);
    memcpy(pkt, out_, 64);
    portEXIT_CRITICAL(&mux_);
    if (tuh_hid_send_report(_dev_addr, _idx, 0, pkt, 64)) outPending_ = false;
  }

  bool isConfigMode() const { return mounted() && vid_ == kVid8BitDo; }
  bool isSwitchMode() const { return mounted() && vid_ == kVidNintendo; }

  void queue(const uint8_t *pkt) {
    portENTER_CRITICAL(&mux_);
    memcpy(out_, pkt, 64); respHead_ = respTail_ = 0; outPending_ = true;
    portEXIT_CRITICAL(&mux_);
  }
  bool takeResponse(uint8_t *dst) {
    bool ok = false;
    portENTER_CRITICAL(&mux_);
    if (respTail_ != respHead_) { memcpy(dst, resp_[respTail_], 64); respTail_ = (respTail_ + 1) % kRespSlots; ok = true; }
    portEXIT_CRITICAL(&mux_);
    return ok;
  }
  uint16_t takeInput(uint8_t *dst) {
    uint16_t n = 0;
    portENTER_CRITICAL(&mux_);
    if (inputReady_) { memcpy(dst, input_, 64); n = inputLen_; inputReady_ = false; }
    portEXIT_CRITICAL(&mux_);
    return n;
  }

private:
  portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
  volatile uint16_t vid_ = 0;
  static constexpr uint8_t kRespSlots = 8;
  uint8_t out_[64] = {}, resp_[kRespSlots][64] = {}, input_[64] = {};
  volatile uint8_t respHead_ = 0, respTail_ = 0;
  uint16_t inputLen_ = 0;
  volatile bool outPending_ = false, inputReady_ = false;
};

static StickLink stick;

// ---------------------------------------------------------------------------
static BLEServer *server = nullptr;
static BLECharacteristic *status = nullptr;
static BLECharacteristic *response = nullptr;
static BLECharacteristic *input = nullptr;
static BLECharacteristic *dataChar = nullptr;
static volatile bool connected = false;
static volatile bool restartAdvertising = false;
static bool usbHostStarted = false;
static constexpr uint8_t kRgbLedPin = 48;  // AITRIP DevKitC-1 style N16R8 board
static uint8_t lastLedState = 255;
static uint8_t lastInput[12] = {};
static bool haveLastInput = false;
static int lastMode = -1;

static uint8_t baseline[kBlockSize];   // last block read from the stick
static bool haveBaseline = false;
static uint8_t staged[kBlockSize];     // block uploaded by the phone
static bool stagedSeen[(kBlockSize + kBleChunk - 1) / kBleChunk];

enum class Pending : uint8_t { None, Read, Write };
static volatile Pending pending = Pending::None;
static volatile bool busy = false;

static int stickMode() { return stick.isConfigMode() ? 2 : stick.isSwitchMode() ? 1 : 0; }

static String currentStatus() {
  const char *usbState = !usbHostStarted ? "HOST_ERROR"
                         : stick.mounted() ? "HID_GAMEPAD_CONNECTED"
                                           : "HOST_READY_NO_GAMEPAD";
  const char *mode = stickMode() == 2 ? "CONFIG" : stickMode() == 1 ? "SWITCH" : "NONE";
  return String("READY v3.1; USB=") + usbState + "; MODE=" + mode +
         "; STICK_WRITES=MACROS_ONLY";
}

static void reply(const String &text) {
  Serial.printf("-> %s\n", text.c_str());
  response->setValue(text.c_str());
  if (connected) response->notify();
}

static void updateStatusLed() {
  // Blue: advertising; green: phone connected; cyan: stick; yellow: busy.
  uint8_t s = !usbHostStarted ? 0 : busy ? 4 : stick.mounted() ? 3 : connected ? 2 : 1;
  if (s == lastLedState) return;
  lastLedState = s;
  switch (s) {
    case 0: rgbLedWrite(kRgbLedPin, 10, 0, 10); break;
    case 1: rgbLedWrite(kRgbLedPin, 0, 0, 14); break;
    case 2: rgbLedWrite(kRgbLedPin, 0, 14, 0); break;
    case 3: rgbLedWrite(kRgbLedPin, 0, 10, 10); break;
    case 4: rgbLedWrite(kRgbLedPin, 14, 10, 0); break;
  }
}

// Send a packet, then pump USB until a reply that `matches` arrives or the
// timeout passes. Replies that don't match (late or repeated answers to an
// earlier packet) are skipped instead of failing the request.
typedef bool (*ReplyMatch)(const uint8_t *resp, uint8_t cmd, uint8_t n, uint16_t off);
static bool transact(const uint8_t *pkt, uint8_t *resp, uint32_t timeoutMs, ReplyMatch matches,
                     uint8_t cmd = 0, uint8_t n = 0, uint16_t off = 0) {
  stick.queue(pkt);
  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    USBHost.task();
    while (stick.takeResponse(resp)) {
      if (matches(resp, cmd, n, off)) return true;
    }
    delay(1);
  }
  return false;
}

static bool versionReply(const uint8_t *r, uint8_t, uint8_t, uint16_t) {
  return r[0] == 0x81 && r[1] == 0x66 && ((r[3] << 8) | r[4]) == 0x901A;
}
static bool readReply(const uint8_t *r, uint8_t, uint8_t n, uint16_t off) {
  return r[0] == 0x02 && r[6] == 0x0C && r[10] == n && (r[14] | (r[15] << 8)) == off;
}
static bool writeReply(const uint8_t *r, uint8_t, uint8_t, uint16_t off) {
  return r[0] == 0x02 && r[6] == 0x0B && (r[14] | (r[15] << 8)) == off;
}
static bool saveReply(const uint8_t *r, uint8_t, uint8_t, uint16_t) {
  return r[0] == 0x02 && r[6] == 0x06;
}

static bool waitForConfigMode(uint32_t timeoutMs) {
  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    USBHost.task();
    if (stick.isConfigMode()) return true;
    delay(5);
  }
  return false;
}

// Switch-mode commands from the official software (Advance.Hid.Switch).
static bool enterConfigMode(String &err) {
  if (stick.isConfigMode()) return true;
  if (!stick.isSwitchMode()) { err = "NO_STICK"; return false; }
  uint8_t pkt[64] = {0x01, 0x66, 0xAA, 0x00, 0x21, 0x01};  // version_CMD
  uint8_t resp[64];
  bool ok = false;
  for (int attempt = 0; attempt < 5 && !ok; ++attempt) {
    if (transact(pkt, resp, 300, versionReply)) ok = true;
  }
  if (!ok) { err = "VERSION_NO_REPLY"; return false; }
  uint8_t change[64] = {0x01, 0x66, 0xAA, 0x00, 0x51, 0x01};  // changeDinput_CMD
  stick.queue(change);
  if (!waitForConfigMode(6000)) { err = "NO_CONFIG_MODE"; return false; }
  uint32_t settle = millis();
  while (millis() - settle < 300) { USBHost.task(); delay(5); }
  return true;
}

static void buildHeader(uint8_t *p, uint8_t cmd, uint8_t n, uint16_t off) {
  memset(p, 0, 64);
  p[0] = 0x81; p[1] = 17 + n; p[2] = 0x04; p[3] = cmd;
  memset(p + 4, 0xCC, 7);
  p[11] = n; p[12] = 0xCC; p[13] = kBlockSize & 0xFF; p[14] = kBlockSize >> 8;
  p[15] = off & 0xFF; p[16] = off >> 8; p[17] = 0xCC; p[18] = 0xCC;
}

static bool readBlock(uint8_t *dst, String &err) {
  for (uint16_t off = 0; off < kBlockSize; off += kChunk) {
    uint8_t n = min<uint16_t>(kChunk, kBlockSize - off);
    uint8_t pkt[64], resp[64];
    buildHeader(pkt, 0x0C, n, off);
    memset(pkt + 19, 0xCC, n);
    bool ok = false;
    for (int attempt = 0; attempt < 4 && !ok; ++attempt) {
      ok = transact(pkt, resp, 700, readReply, 0x0C, n, off);
    }
    if (!ok) { err = String("READ_CHUNK_") + off; return false; }
    memcpy(dst + off, resp + 18, n);
  }
  if (blockCrc(dst) != (dst[0] | (dst[1] << 8))) { err = "CRC_MISMATCH"; return false; }
  return true;
}

static bool writeBlock(const uint8_t *src, String &err) {
  for (uint16_t off = 0; off < kBlockSize; off += kChunk) {
    uint8_t n = min<uint16_t>(kChunk, kBlockSize - off);
    uint8_t pkt[64], resp[64];
    buildHeader(pkt, 0x0B, n, off);
    memcpy(pkt + 19, src + off, n);
    bool ok = false;
    for (int attempt = 0; attempt < 2 && !ok; ++attempt) {
      ok = transact(pkt, resp, 900, writeReply, 0x0B, n, off);
    }
    if (!ok) {
      err = String("WRITE_CHUNK_") + off;
      return false;
    }
  }
  uint8_t save[64] = {0x81, 0x11, 0x04, 0x06, 0x00, 0x00, 0x00, 0x15};
  uint8_t resp[64];
  if (!transact(save, resp, 2500, saveReply)) { err = "SAVE_NO_ACK"; return false; }
  return true;
}

static void sendBlockToPhone(const uint8_t *b) {
  for (uint16_t off = 0; off < kBlockSize; off += kBleChunk) {
    uint8_t n = min<uint16_t>(kBleChunk, kBlockSize - off);
    uint8_t msg[2 + kBleChunk] = {(uint8_t)(off & 0xFF), (uint8_t)(off >> 8)};
    memcpy(msg + 2, b + off, n);
    dataChar->setValue(msg, 2 + n);
    if (connected) dataChar->notify();
    delay(15);
  }
}

static void doRead() {
  String err;
  if (!enterConfigMode(err) || !readBlock(baseline, err)) { reply("READ ERR " + err); return; }
  haveBaseline = true;
  memcpy(staged, baseline, kBlockSize);
  memset(stagedSeen, 0, sizeof(stagedSeen));
  sendBlockToPhone(baseline);
  reply(String("READ OK ") + kBlockSize);
}

static void doWrite() {
  String err;
  if (!haveBaseline) { reply("WRITE ERR READ_FIRST"); return; }
  for (bool seen : stagedSeen) if (!seen) { reply("WRITE ERR INCOMPLETE_UPLOAD"); return; }
  for (uint16_t i = 2; i < kBlockSize; ++i) {
    if (!inMacroRegion(i) && staged[i] != baseline[i]) {
      reply(String("WRITE ERR NON_MACRO_BYTE_") + i);
      return;
    }
  }
  for (int s = 0; s < 2; ++s) {
    const uint8_t *m = staged + kSlotBase + s * kSlotSize + kMacroOffset;
    if (m[4] > 2) { reply("WRITE ERR MACRO_COUNT"); return; }
    for (int k = 0; k < 2; ++k) if (m[8 + k * 80 + 76] > 18) { reply("WRITE ERR STEP_COUNT"); return; }
  }
  uint16_t crc = blockCrc(staged);
  staged[0] = crc & 0xFF; staged[1] = crc >> 8;
  if (memcmp(staged + 2, baseline + 2, kBlockSize - 2) == 0) { reply("WRITE OK UNCHANGED"); return; }
  if (!enterConfigMode(err) || !writeBlock(staged, err)) { reply("WRITE ERR " + err); return; }
  uint8_t check[kBlockSize];
  if (!readBlock(check, err)) { reply("WRITE ERR VERIFY_" + err); return; }
  if (memcmp(check + 2, staged + 2, kBlockSize - 2) != 0) { reply("WRITE ERR VERIFY_MISMATCH"); return; }
  memcpy(baseline, check, kBlockSize);
  memset(stagedSeen, 0, sizeof(stagedSeen));
  reply("WRITE OK");
}

class BridgeServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { connected = true; Serial.println("iPhone connected"); }
  void onDisconnect(BLEServer *) override {
    connected = false;
    Serial.println("iPhone disconnected; advertising again");
    restartAdvertising = true;
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String command = characteristic->getValue();
    command.trim();
    Serial.printf("Command: %s\n", command.c_str());
    if (command == "PING") reply("PONG v1");
    else if (command == "STATUS") reply(currentStatus());
    else if (busy || pending != Pending::None) reply("ERR BUSY");
    else if (command == "READ") pending = Pending::Read;
    else if (command == "WRITE") pending = Pending::Write;
    else reply("ERR UNKNOWN_COMMAND");
  }
};

// Phone upload: [offset lo, offset hi, up to 16 bytes]. Offsets must be chunk-aligned.
class DataCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String v = characteristic->getValue();
    const uint8_t *p = (const uint8_t *)v.c_str();
    size_t len = v.length();
    if (busy || len < 3) return;
    uint16_t off = p[0] | (p[1] << 8);
    size_t n = len - 2;
    if (off % kBleChunk || off >= kBlockSize || n > kBleChunk || off + n > kBlockSize) return;
    memcpy(staged + off, p + 2, n);
    stagedSeen[off / kBleChunk] = true;
  }
};

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("ArcadeMacro Bridge v3.1 starting");

  USBHostHID.addDevice(&stick);
  usbHostStarted = USBHost.begin();
  Serial.println(usbHostStarted ? "USB host started" : "USB host start failed");

  BLEDevice::init("ArcadeMacro Bridge");
  server = BLEDevice::createServer();
  server->setCallbacks(new BridgeServerCallbacks());
  BLEService *service = server->createService(BLEUUID(kServiceUuid), 30);

  status = service->createCharacteristic(
      kStatusUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  status->setValue(currentStatus().c_str());

  BLECharacteristic *command = service->createCharacteristic(
      kCommandUuid, BLECharacteristic::PROPERTY_WRITE);
  command->setCallbacks(new CommandCallbacks());

  response = service->createCharacteristic(
      kResponseUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  response->setValue(currentStatus().c_str());

  input = service->createCharacteristic(
      kInputUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  uint8_t emptyInput[12] = {};
  input->setValue(emptyInput, sizeof(emptyInput));

  dataChar = service->createCharacteristic(
      kDataUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE |
                     BLECharacteristic::PROPERTY_NOTIFY);
  dataChar->setCallbacks(new DataCallbacks());

  service->start();
  BLEAdvertising *advertising = server->getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->start();
  Serial.println("BLE advertising as ArcadeMacro Bridge");
  updateStatusLed();
}

void loop() {
  if (usbHostStarted) {
    USBHost.task();

    Pending job = pending;
    if (job != Pending::None) {
      busy = true;
      updateStatusLed();
      if (job == Pending::Read) doRead(); else doWrite();
      pending = Pending::None;
      busy = false;
    }

    int mode = stickMode();
    if (mode != lastMode) {
      lastMode = mode;
      String value = currentStatus();
      status->setValue(value.c_str());
      Serial.println(value);
      if (connected) status->notify();
    }

    uint8_t report[64];
    uint16_t n = stick.takeInput(report);
    if (n >= sizeof(lastInput)) {
      // Bytes 1-2 are a changing packet counter in Switch mode.
      bool changed = !haveLastInput || report[0] != lastInput[0] ||
                     memcmp(report + 3, lastInput + 3, sizeof(lastInput) - 3);
      if (changed) {
        memcpy(lastInput, report, sizeof(lastInput));
        haveLastInput = true;
        input->setValue(lastInput, sizeof(lastInput));
        if (connected) input->notify();
      }
    }
  }
  if (restartAdvertising) {
    restartAdvertising = false;
    server->startAdvertising();
  }
  updateStatusLed();
  delay(2);
}
