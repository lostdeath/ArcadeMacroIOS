#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error This sketch targets an ESP32-S3 board.
#endif

// Protocol v1: UTF-8 commands and responses. No controller writes are implemented.
static constexpr char kServiceUuid[] = "a8c70001-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kStatusUuid[] = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kCommandUuid[] = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001";
static constexpr char kResponseUuid[] = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001";

static BLEServer *server = nullptr;
static BLECharacteristic *response = nullptr;
static volatile bool connected = false;
static volatile bool restartAdvertising = false;

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
      reply = "READY v1; USB=NOT_CONNECTED; STICK_WRITES=DISABLED";
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
  Serial.println("ArcadeMacro Bridge v1 starting");

  BLEDevice::init("ArcadeMacro Bridge");
  server = BLEDevice::createServer();
  server->setCallbacks(new BridgeServerCallbacks());
  BLEService *service = server->createService(kServiceUuid);

  BLECharacteristic *status = service->createCharacteristic(
      kStatusUuid, BLECharacteristic::PROPERTY_READ);
  status->setValue("READY v1; USB=NOT_CONNECTED; STICK_WRITES=DISABLED");

  BLECharacteristic *command = service->createCharacteristic(
      kCommandUuid, BLECharacteristic::PROPERTY_WRITE);
  command->setCallbacks(new CommandCallbacks());

  response = service->createCharacteristic(
      kResponseUuid, BLECharacteristic::PROPERTY_READ |
                         BLECharacteristic::PROPERTY_NOTIFY);
  response->setValue("READY v1");

  service->start();
  BLEAdvertising *advertising = server->getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->start();
  Serial.println("BLE advertising as ArcadeMacro Bridge");
}

void loop() {
  if (restartAdvertising) {
    restartAdvertising = false;
    server->startAdvertising();
  }
  delay(100);
}
