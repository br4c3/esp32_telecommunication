#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>

#define SERVICE_UUID      "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_CHARACTERISTIC "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_CHARACTERISTIC "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ESP32-C3 ADC1 채널에 연결된 5개 FSR 센서입니다.
const int SENSOR_COUNT = 5;
const int PRESSURE_PINS[SENSOR_COUNT] = {0, 1, 2, 3, 4};

const int ADC_AVERAGES = 32;
const unsigned long CALIBRATION_TIME_MS = 5000;
const unsigned long SAMPLE_INTERVAL_MS = 50;  // 약 20 Hz
// ESP32-C3의 보정된 ADC 상단값은 실제 3.3 V보다 낮게 보고될 수 있습니다.
const float MIN_UNLOADED_MV = 2500.0f;
const float MIN_REFERENCE_DELTA = 25.0f;
const float MIN_SENSOR_GAIN = 0.5f;
const float MAX_SENSOR_GAIN = 2.0f;

const int MEDIAN_SIZE = 5;  // 반드시 홀수
const float PROCESS_NOISE = 0.5f;
const float MEASUREMENT_NOISE = 4.0f;

int medianBuffers[SENSOR_COUNT][MEDIAN_SIZE];
int medianIndexes[SENSOR_COUNT] = {0};
float kalmanEstimates[SENSOR_COUNT] = {0};
float kalmanErrors[SENSOR_COUNT] = {0};
float baselines[SENSOR_COUNT] = {0};
float sensorGains[SENSOR_COUNT] = {1, 1, 1, 1, 1};

BLEServer* bleServer = nullptr;
BLECharacteristic* txCharacteristic = nullptr;
Preferences preferences;
bool deviceConnected = false;
bool previousConnection = false;
bool balanceCalibrated = false;
volatile bool zeroCalibrationRequested = false;
volatile bool balanceCalibrationRequested = false;
volatile bool calibrationStatusRequested = false;
unsigned long lastSampleTime = 0;
unsigned long lastSerialPrintTime = 0;
String deviceCode;
String deviceName;

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
    value.trim();
    if (value.length() > 0) {
      Serial.print("BLE 수신: ");
      Serial.println(value);
      if (value.equalsIgnoreCase("CALIBRATE") ||
          value.equalsIgnoreCase("CALIBRATE_ZERO")) {
        zeroCalibrationRequested = true;
      } else if (value.equalsIgnoreCase("CALIBRATE_BALANCE")) {
        balanceCalibrationRequested = true;
      } else if (value.equalsIgnoreCase("GET_CALIBRATION_STATUS")) {
        calibrationStatusRequested = true;
      }
    }
  }
};

void sendStatus(const char* status) {
  if (!deviceConnected || txCharacteristic == nullptr) return;
  txCharacteristic->setValue(status);
  txCharacteristic->notify();
}

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

float readMilliVolts(int pin) {
  float sum = 0;
  for (int i = 0; i < ADC_AVERAGES; i++) {
    sum += analogReadMilliVolts(pin);
  }
  return sum / ADC_AVERAGES;
}

void loadBalanceCalibration() {
  preferences.begin("pressure", false);
  balanceCalibrated =
      preferences.getUChar("count", 0) == SENSOR_COUNT &&
      preferences.getBool("balanced", false);
  for (int i = 0; i < SENSOR_COUNT; i++) {
    char key[4];
    snprintf(key, sizeof(key), "g%d", i);
    sensorGains[i] = preferences.getFloat(key, 1.0f);
    if (!isfinite(sensorGains[i]) || sensorGains[i] < MIN_SENSOR_GAIN ||
        sensorGains[i] > MAX_SENSOR_GAIN) {
      sensorGains[i] = 1.0f;
      balanceCalibrated = false;
    }
  }
}

void saveBalanceCalibration() {
  for (int i = 0; i < SENSOR_COUNT; i++) {
    char key[4];
    snprintf(key, sizeof(key), "g%d", i);
    preferences.putFloat(key, sensorGains[i]);
  }
  preferences.putUChar("count", SENSOR_COUNT);
  preferences.putBool("balanced", true);
  balanceCalibrated = true;
}

void calibrateZero() {
  sendStatus("S:ZERO_CALIBRATING");
  Serial.println("5초 동안 센서에 압력을 가하지 마세요.");
  float sums[SENSOR_COUNT] = {0};
  unsigned long sampleCount = 0;
  const unsigned long startedAt = millis();

  while (millis() - startedAt < CALIBRATION_TIME_MS) {
    for (int i = 0; i < SENSOR_COUNT; i++) {
      sums[i] += readMilliVolts(PRESSURE_PINS[i]);
    }
    sampleCount++;
    delay(10);
  }

  bool zeroValid = true;
  for (int i = 0; i < SENSOR_COUNT; i++) {
    baselines[i] = sums[i] / (float)sampleCount;
    kalmanEstimates[i] = baselines[i];
    kalmanErrors[i] = 1.0f;
    for (int j = 0; j < MEDIAN_SIZE; j++) {
      medianBuffers[i][j] = (int)baselines[i];
    }
    Serial.printf("센서 %d 무부하 기준값: %.1f mV\n", i + 1, baselines[i]);
    if (baselines[i] < MIN_UNLOADED_MV) {
      Serial.printf("센서 %d 무부하 전압 확인 필요\n", i + 1);
      zeroValid = false;
    }
  }
  Serial.print("BASE_MV:");
  for (int i = 0; i < SENSOR_COUNT; i++) {
    if (i > 0) Serial.print(',');
    Serial.print(baselines[i], 1);
  }
  Serial.println();
  if (!zeroValid) {
    sendStatus("S:ZERO_FAILED");
    return;
  }

  sendStatus(balanceCalibrated ? "S:READY" : "S:BALANCE_REQUIRED");
  Serial.println("센서 영점 보정 완료");
}

void calibrateBalance() {
  sendStatus("S:BALANCE_CALIBRATING");
  Serial.println("평평한 판과 균일한 기준 하중으로 센서 균형을 측정합니다.");
  float sums[SENSOR_COUNT] = {0};
  unsigned long sampleCount = 0;
  const unsigned long startedAt = millis();

  while (millis() - startedAt < CALIBRATION_TIME_MS) {
    for (int i = 0; i < SENSOR_COUNT; i++) {
      sums[i] += readMilliVolts(PRESSURE_PINS[i]);
    }
    sampleCount++;
    delay(10);
  }

  float responses[SENSOR_COUNT];
  float sortedResponses[SENSOR_COUNT];
  for (int i = 0; i < SENSOR_COUNT; i++) {
    // 이 회로는 압력이 커질수록 탭 전압이 낮아집니다.
    responses[i] = baselines[i] - sums[i] / (float)sampleCount;
    if (responses[i] < MIN_REFERENCE_DELTA) {
      Serial.printf("센서 %d 기준 하중 부족: %.1f\n", i + 1, responses[i]);
      sendStatus("S:CALIBRATION_FAILED");
      return;
    }
    sortedResponses[i] = responses[i];
  }

  for (int i = 0; i < SENSOR_COUNT - 1; i++) {
    for (int j = i + 1; j < SENSOR_COUNT; j++) {
      if (sortedResponses[i] > sortedResponses[j]) {
        const float temp = sortedResponses[i];
        sortedResponses[i] = sortedResponses[j];
        sortedResponses[j] = temp;
      }
    }
  }
  const float target = SENSOR_COUNT % 2 == 0
      ? (sortedResponses[SENSOR_COUNT / 2 - 1] +
         sortedResponses[SENSOR_COUNT / 2]) / 2.0f
      : sortedResponses[SENSOR_COUNT / 2];

  for (int i = 0; i < SENSOR_COUNT; i++) {
    sensorGains[i] = constrain(target / responses[i],
                               MIN_SENSOR_GAIN, MAX_SENSOR_GAIN);
    Serial.printf("센서 %d 보정계수: %.3f\n", i + 1, sensorGains[i]);
  }
  saveBalanceCalibration();
  sendStatus("S:READY");
  Serial.println("최초 센서 균형 보정 완료 및 저장");
}

void setupBle() {
  const uint64_t chipId = ESP.getEfuseMac();
  char codeBuffer[7];
  snprintf(codeBuffer, sizeof(codeBuffer), "%06X", (uint32_t)(chipId & 0xFFFFFF));
  deviceCode = String(codeBuffer);
  deviceName = "ESP32-P-" + deviceCode;

  BLEDevice::init(deviceName.c_str());
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
  Serial.println("BLE 광고 시작 완료: " + deviceName);
  Serial.println("기기 바코드 값: ESP32:" + deviceCode);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  analogReadResolution(12);
  for (int i = 0; i < SENSOR_COUNT; i++) {
    analogSetPinAttenuation(PRESSURE_PINS[i], ADC_11db);
  }

  loadBalanceCalibration();
  calibrateZero();
  setupBle();
}

void loop() {
  if (calibrationStatusRequested) {
    calibrationStatusRequested = false;
    sendStatus(balanceCalibrated ? "S:ZERO_REQUIRED" : "S:SETUP_REQUIRED");
  }
  if (zeroCalibrationRequested) {
    zeroCalibrationRequested = false;
    calibrateZero();
    lastSampleTime = millis();
    return;
  }
  if (balanceCalibrationRequested) {
    balanceCalibrationRequested = false;
    calibrateBalance();
    lastSampleTime = millis();
    return;
  }

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
    const int raw = (int)roundf(readMilliVolts(PRESSURE_PINS[i]));
    const float filtered = kalmanFilter(i, medianFilter(i, raw));
    float pressure = (baselines[i] - filtered) * sensorGains[i];
    if (pressure < 0) pressure = 0;

    // 앱 표시와 BLE 패킷 크기를 일정하게 유지하기 위해 정수로 보냅니다.
    const int pressureValue = (int)roundf(pressure);
    if (i > 0) packet += ',';
    packet += String(pressureValue);
  }

  if (now - lastSerialPrintTime >= 300) {
    lastSerialPrintTime = now;
    Serial.println(packet);
  }
  if (deviceConnected) {
    txCharacteristic->setValue(packet.c_str());
    txCharacteristic->notify();
  }
}
