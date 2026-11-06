#include <Arduino.h>
#include <esp32-hal-rgb-led.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <USBHost.h>
#include <USBHostHIDGamepad.h>

#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error This sketch targets an ESP32-S3 board.
#endif

// Protocol v1: UTF-8 commands and responses. No controller writes are implemented.
static constexpr char kServiceUuid[] = "a8c70001-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kStatusUuid[] = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kCommandUuid[] = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kResponseUuid[] = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001";

static BLEServer *server = nullptr;
static BLECharacteristic *status = nullptr;
static BLECharacteristic *response = nullptr;
static volatile bool connected = false;
static volatile bool restartAdvertising = false;
static USBHostHIDGamepad gamepad;
static bool usbHostStarted = false;
static bool lastMounted = false;
// AITRIP's DevKitC-1 style N16R8 board uses the original GPIO48 RGB LED.
// Official DevKitC-1 v1.1 boards use GPIO38 instead.
static constexpr uint8_t kRgbLedPin = 48;
static uint8_t lastLedState = 255;

static void updateStatusLed() {
  // Blue: advertising; green: phone connected; cyan: USB gamepad detected.
  // Purple indicates that USB host initialization failed.
  uint8_t ledState = !usbHostStarted ? 0 : gamepad.mounted() ? 3
                                         : connected ? 2 : 1;
  if (ledState == lastLedState) return;
  lastLedState = ledState;
  switch (ledState) {
    case 0: rgbLedWrite(kRgbLedPin, 10, 0, 10); break;
    case 1: rgbLedWrite(kRgbLedPin, 0, 0, 14); break;
    case 2: rgbLedWrite(kRgbLedPin, 0, 14, 0); break;
    case 3: rgbLedWrite(kRgbLedPin, 0, 10, 10); break;
  }
}

static String currentStatus() {
  const char *usbState = !usbHostStarted ? "HOST_ERROR"
                         : gamepad.mounted() ? "HID_GAMEPAD_CONNECTED"
                                             : "HOST_READY_NO_GAMEPAD";
  return String("READY v2; USB=") + usbState +
         "; STICK_WRITES=DISABLED";
}

class BridgeServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    connected = true;
    Serial.println("iPhone connected");
  }

  void onDisconnect(BLEServer *server) override {
    connected = false;
    Serial.println("iPhone disconnected; advertising again");
    restartAdvertising = true;
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String command = characteristic->getValue();
    command.trim();
    String reply;
    if (command == "PING") {
      reply = "PONG v1";
    } else if (command == "STATUS") {
      reply = currentStatus();
    } else {
      reply = "ERR UNKNOWN_COMMAND";
    }
    Serial.printf("Command: %s -> %s\n", command.c_str(), reply.c_str());
    response->setValue(reply.c_str());
    if (connected) response->notify();
  }
};

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("ArcadeMacro Bridge v2 starting");

  gamepad.registerWithHost();
  gamepad.setNotifyOnChangeOnly(true);
  usbHostStarted = USBHost.begin();
  Serial.println(usbHostStarted ? "USB host started" : "USB host start failed");

  BLEDevice::init("ArcadeMacro Bridge");
  server = BLEDevice::createServer();
  server->setCallbacks(new BridgeServerCallbacks());
  BLEService *service = server->createService(kServiceUuid);

  status = service->createCharacteristic(
      kStatusUuid, BLECharacteristic::PROPERTY_READ |
                       BLECharacteristic::PROPERTY_NOTIFY);
  status->setValue(currentStatus().c_str());

  BLECharacteristic *command = service->createCharacteristic(
      kCommandUuid, BLECharacteristic::PROPERTY_WRITE);
  command->setCallbacks(new CommandCallbacks());

  response = service->createCharacteristic(
      kResponseUuid, BLECharacteristic::PROPERTY_READ |
                         BLECharacteristic::PROPERTY_NOTIFY);
  response->setValue(currentStatus().c_str());

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
    bool mounted = gamepad.mounted();
    if (mounted != lastMounted) {
      lastMounted = mounted;
      String value = currentStatus();
      status->setValue(value.c_str());
      Serial.println(value);
      if (connected) status->notify();
    }
    if (gamepad.available()) {
      uint8_t report[USBHostHIDGamepad::REPORT_CAP];
      uint16_t n = gamepad.getReport(report, sizeof(report));
      Serial.printf("USB HID report %u bytes:", (unsigned)n);
      for (uint16_t i = 0; i < n && i < 16; ++i) {
        Serial.printf(" %02X", report[i]);
      }
      Serial.println();
      gamepad.clear();
    }
  }
  if (restartAdvertising) {
    restartAdvertising = false;
    server->startAdvertising();
  }
  updateStatusLed();
  delay(2);
}
