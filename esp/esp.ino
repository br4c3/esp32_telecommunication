#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_CHARACTERISTIC   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_CHARACTERISTIC   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer* bleServer = nullptr;
BLECharacteristic* txCharacteristic = nullptr;

bool deviceConnected = false;
bool previousConnection = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    deviceConnected = true;
    Serial.println("BLE 장치 연결됨");
  }

  void onDisconnect(BLEServer* server) override {
    deviceConnected = false;
    Serial.println("BLE 연결 해제됨");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String value = characteristic->getValue();

    if (value.length() > 0) {
      Serial.print("BLE 수신: ");
      Serial.println(value);
    }
  }
};

void setup() {
  Serial.begin(115200);
  delay(1500);

  Serial.println();
  Serial.println("============================");
  Serial.println("ESP32 BLE 시작");
  Serial.println("============================");

  BLEDevice::init("ESP32-ADS1115");

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);

  txCharacteristic = service->createCharacteristic(
    TX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  txCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic* rxCharacteristic =
    service->createCharacteristic(
      RX_CHARACTERISTIC,
      BLECharacteristic::PROPERTY_WRITE |
      BLECharacteristic::PROPERTY_WRITE_NR
    );

  rxCharacteristic->setCallbacks(new RxCallbacks());

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);

  BLEDevice::startAdvertising();

  Serial.println("BLE 광고 시작 완료: ESP32-ADS1115");
}

void loop() {
  if (deviceConnected) {
    String message = "ESP32 동작 시간: ";
    message += String(millis());
    message += " ms";

    txCharacteristic->setValue(message.c_str());
    txCharacteristic->notify();

    Serial.println(message);
    delay(1000);
  }

  if (!deviceConnected && previousConnection) {
    delay(500);
    bleServer->startAdvertising();
    Serial.println("BLE 광고 다시 시작");
    previousConnection = false;
  }

  if (deviceConnected && !previousConnection) {
    previousConnection = true;
  }

  delay(10);
}