// paddle_sensor.ino — sensor side of the paddle game.
//
// ADXL345 three-axis accelerometer -> prints "x,y,z\n" over serial.
//
// What changed from the very first version:
//   1. Sample rate 20 Hz -> 100 Hz. delay(50) was removed in favour of
//      non-blocking micros() timing. delay() stalls the whole loop, so no
//      reading is taken while it sleeps and the peaks are missed.
//   2. Baud 9600 -> 115200. At 100 Hz this is roughly 2000 bytes per second,
//      which 9600 baud (~960 B/s) cannot carry; the transmit buffer fills and
//      Serial.print blocks, which drags the sample rate back down.
//      [IMPORTANT] The Godot side must use 115200 too, or the data arrives
//      garbled.
//   3. The ADXL345's internal data rate is now set to 100 Hz explicitly, so
//      it produces new readings in step with how often we read them.
//
// Note: once this sketch is uploaded, close the Arduino IDE's Serial Monitor.
// It holds the port exclusively, and on macOS Godot then cannot open it.

#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_ADXL345_U.h>

Adafruit_ADXL345_Unified accel = Adafruit_ADXL345_Unified(12345);

// --------------------------------------------- Config / 配置调参 (中英对照) --
// Must match the Godot side.
// 必须和 Godot 端一致。
const long BAUD = 115200;
// 10000us = 10ms = 100Hz.
// 10000us = 10ms = 100Hz(采样间隔)。想提高采样率就改小,
// 但记得波特率要跟着一起提,否则发不完。
const unsigned long SAMPLE_INTERVAL_US = 10000UL;

unsigned long next_sample_us = 0;

void setup() {
  Serial.begin(BAUD);

  if (!accel.begin()) {
    Serial.println("ADXL345 not found - check the wiring!");
    while (1);
  }

  // Range: +/-16G all but guarantees nothing clips, at a cost of 31.2 mg per
  // count. If the goal were measuring gentle tilts, ADXL345_RANGE_4_G would be
  // four times finer (7.8 mg) -- but the blade hitting the water can slam into
  // the ceiling. Catching force peaks matters more right now, so 16G stays.
  // 量程:±16G 几乎不会削顶,代价是每格 31.2mg。
  //      若主要做轻微倾斜测量,改成 ADXL345_RANGE_4_G 精度细 4 倍(7.8mg),
  //      但桨叶拍水的冲击可能顶到上限。现在以「抓力度峰值」为主,先留 16G。
  accel.setRange(ADXL345_RANGE_16_G);

  // Have the chip itself produce a new reading at 100 Hz.
  // 让芯片内部也按 100Hz 产出新读数。
  accel.setDataRate(ADXL345_DATARATE_100_HZ);

  next_sample_us = micros();
}

void loop() {
  unsigned long now = micros();

  // Not time for the next sample yet, so return immediately without blocking.
  // The (long) cast on the subtraction handles micros() wrapping around,
  // which it does roughly every 71 minutes.
  // 还没到下一个采样点就立刻返回,不阻塞。
  // 用 (long) 相减是为了正确处理 micros() 大约 71 分钟一次的溢出。
  if ((long)(now - next_sample_us) < 0) {
    return;
  }
  // Re-align rather than catching up: if we fell behind, skip the missed slots.
  // 重新对齐,落后时不补发。
  next_sample_us = now + SAMPLE_INTERVAL_US;

  sensors_event_t event;
  accel.getEvent(&event);

  Serial.print(event.acceleration.x);
  Serial.print(",");
  Serial.print(event.acceleration.y);
  Serial.print(",");
  Serial.println(event.acceleration.z);
}
