#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID      "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_CHARACTERISTIC "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_CHARACTERISTIC "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// BLE 사용 중에도 읽을 수 있는 ESP32 ADC1 핀만 사용합니다.
const int SENSOR_COUNT = 6;
const int PRESSURE_PINS[SENSOR_COUNT] = {32, 33, 34, 35, 36, 39};
const int LED_PIN = 2;

const float DISPLAY_GAIN = 5.0f;
const unsigned long CALIBRATION_TIME_MS = 5000;
const unsigned long SAMPLE_INTERVAL_MS = 20;  // 약 50 Hz

const int MEDIAN_SIZE = 5;  // 반드시 홀수
const float PROCESS_NOISE = 0.5f;
const float MEASUREMENT_NOISE = 4.0f;

int medianBuffers[SENSOR_COUNT][MEDIAN_SIZE];
int medianIndexes[SENSOR_COUNT] = {0};
float kalmanEstimates[SENSOR_COUNT] = {0};
float kalmanErrors[SENSOR_COUNT] = {0};
float baselines[SENSOR_COUNT] = {0};

BLEServer* bleServer = nullptr;
BLECharacteristic* txCharacteristic = nullptr;
bool deviceConnected = false;
bool previousConnection = false;
unsigned long lastSampleTime = 0;

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

float medianFilter(int sensor, int newValue) {
  medianBuffers[sensor][medianIndexes[sensor]] = newValue;
  medianIndexes[sensor] = (medianIndexes[sensor] + 1) % MEDIAN_SIZE;

  int sorted[MEDIAN_SIZE];
  for (int i = 0; i < MEDIAN_SIZE; i++) {
    sorted[i] = medianBuffers[sensor][i];
  }
  for (int i = 0; i < MEDIAN_SIZE - 1; i++) {
    for (int j = i + 1; j < MEDIAN_SIZE; j++) {
      if (sorted[i] > sorted[j]) {
        int temp = sorted[i];
        sorted[i] = sorted[j];
        sorted[j] = temp;
      }
    }
  }
  return sorted[MEDIAN_SIZE / 2];
}

float kalmanFilter(int sensor, float measurement) {
  kalmanErrors[sensor] += PROCESS_NOISE;
  const float gain = kalmanErrors[sensor] /
                     (kalmanErrors[sensor] + MEASUREMENT_NOISE);
  kalmanEstimates[sensor] += gain * (measurement - kalmanEstimates[sensor]);
  kalmanErrors[sensor] *= (1.0f - gain);
  return kalmanEstimates[sensor];
}

void calibrateSensors() {
  Serial.println("5초 동안 센서에 압력을 가하지 마세요.");
  unsigned long sums[SENSOR_COUNT] = {0};
  unsigned long sampleCount = 0;
  const unsigned long startedAt = millis();

  while (millis() - startedAt < CALIBRATION_TIME_MS) {
    for (int i = 0; i < SENSOR_COUNT; i++) {
      sums[i] += analogRead(PRESSURE_PINS[i]);
    }
    sampleCount++;
    delay(10);
  }

  for (int i = 0; i < SENSOR_COUNT; i++) {
    baselines[i] = sums[i] / (float)sampleCount;
    kalmanEstimates[i] = baselines[i];
    kalmanErrors[i] = 1.0f;
    for (int j = 0; j < MEDIAN_SIZE; j++) {
      medianBuffers[i][j] = (int)baselines[i];
    }
    Serial.printf("센서 %d 기준값: %.1f\n", i + 1, baselines[i]);
  }

  for (int i = 0; i < 3; i++) {
    digitalWrite(LED_PIN, HIGH);
    delay(200);
    digitalWrite(LED_PIN, LOW);
    delay(200);
  }
}

void setupBle() {
  BLEDevice::init("ESP32-Pressure-6");
  BLEDevice::setMTU(64);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);
  txCharacteristic = service->createCharacteristic(
    TX_CHARACTERISTIC, BLECharacteristic::PROPERTY_NOTIFY
  );
  txCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic* rxCharacteristic = service->createCharacteristic(
    RX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  rxCharacteristic->setCallbacks(new RxCallbacks());

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.println("BLE 광고 시작 완료: ESP32-Pressure-6");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  analogReadResolution(12);
  for (int i = 0; i < SENSOR_COUNT; i++) {
    analogSetPinAttenuation(PRESSURE_PINS[i], ADC_11db);
  }

  calibrateSensors();
  setupBle();
}

void loop() {
  if (!deviceConnected && previousConnection) {
    delay(500);
    bleServer->startAdvertising();
    previousConnection = false;
    Serial.println("BLE 광고 다시 시작");
  }
  if (deviceConnected && !previousConnection) {
    previousConnection = true;
  }

  const unsigned long now = millis();
  if (now - lastSampleTime < SAMPLE_INTERVAL_MS) {
    delay(1);
    return;
  }
  lastSampleTime = now;

  String packet = "P:";
  for (int i = 0; i < SENSOR_COUNT; i++) {
    const int raw = analogRead(PRESSURE_PINS[i]);
    const float filtered = kalmanFilter(i, medianFilter(i, raw));
    float pressure = (filtered - baselines[i]) * DISPLAY_GAIN;
    if (pressure < 0) pressure = 0;

    // 앱 표시와 BLE 패킷 크기를 일정하게 유지하기 위해 정수로 보냅니다.
    const int pressureValue = (int)roundf(pressure);
    if (i > 0) packet += ',';
    packet += String(pressureValue);
  }

  Serial.println(packet);
  if (deviceConnected) {
    txCharacteristic->setValue(packet.c_str());
    txCharacteristic->notify();
  }
}
