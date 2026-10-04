// i2c_scan.ino — find out whether the IMU is answering at all.
//
// Why this exists
// ---------------
// As of 2026-09-25 the board on the oar prints, about five times a second:
//
//     Accel(g): 0.000, 0.000, 0.000 | Gyro(deg/s): 0.000, 0.000, 0.000
//
// Note two things about that. First, it is NOT our sketch: paddle_sensor.ino
// prints three bare numbers, so whatever is on the board now is something else
// someone flashed. Second, six axes at exactly zero forever is not a sensor
// reporting "perfectly still" -- a still accelerometer still reads gravity,
// about 1.0 in g. A stream of zeros means the program never got a reading and
// prints zeros regardless.
//
// That leaves exactly two possibilities, and telling them apart decides whether
// the fix is code or soldering:
//
//   * The chip answers at some address -> it is powered and wired, so the fault
//     is in the CODE. By far the most common cause: MPU6050-family parts come
//     out of reset ASLEEP, and every data register reads zero until the sleep
//     bit in PWR_MGMT_1 (0x6B) is cleared. A sketch that skips that step prints
//     zeros forever and looks exactly like a dead sensor.
//   * Nothing answers -> the fault is WIRING or POWER, and no amount of code
//     will help: check SDA/SCL not swapped, VCC and GND, and whether the board
//     wants 3.3 V rather than 5 V.
//
// It also reads the WHO_AM_I register of anything it finds, because the address
// alone does NOT identify the chip -- 0x68 is an MPU6050, an MPU9250 and an
// ICM-20602 among others, and they need different libraries. Knowing the chip is
// what makes it possible to write the real sketch at all.
//
// Flash this, open Serial Monitor at 115200, and read the list.
// ---------------------------------------------------------------------------
// 这个文件要回答的问题:IMU 到底有没有应答。
//
// 现在板子每秒约 5 次打印六个精确的 0.000。这不是「传感器读到静止」——
// 静止时加速度计仍然读到重力,单位 g 时约 1.0。一串零意味着程序从来没拿到读数,
// 只是照样打印零。
//
// 于是只剩两种可能,而分清它们决定了要改的是代码还是接线:
//
//   * 某个地址上有应答 -> 芯片有电、接线是通的,问题在**代码**。最常见的原因:
//     MPU6050 系列上电后处于 **sleep**,在清掉 PWR_MGMT_1(0x6B)的 sleep 位之前,
//     所有数据寄存器都读成 0。漏掉这一步的 sketch 会永远打印零,和传感器坏了一模一样。
//   * 一个都不应答 -> 问题在**接线或供电**,写多少代码都没用:检查 SDA/SCL 有没有接反、
//     VCC/GND、以及板子要 3.3V 还是 5V。
//
// 它还会读 WHO_AM_I,因为**光看地址认不出芯片** —— 0x68 可能是 MPU6050、MPU9250、
// ICM-20602 等等,而它们要不同的库。知道是哪一颗,才谈得上写真正的 sketch。
//
// 烧进去,串口监视器 115200,看列表。

#include <Wire.h>

// --------------------------------------------- Config / 配置调参 (中英对照) --
// Must match the Serial Monitor's setting, which is a separate dial and does not
// follow the sketch.
// 必须和串口监视器的设置一致 —— 那是另一个独立的旋钮,不会跟着 sketch 变。
const long BAUD = 115200;

// How long to wait between scans, so the list can be watched while re-plugging
// wires. Long enough to read, short enough to feel responsive.
// 两次扫描之间等多久,方便一边插拔线一边看列表。
const unsigned long RESCAN_INTERVAL_MS = 2000UL;

// Registers worth reading on whatever turns up. Different vendors put their
// chip-ID at different registers, so all of the usual ones are read and the raw
// value is printed -- the point is to be able to identify the chip from the
// output alone, without guessing which register it uses.
//
//   0x75 -> InvenSense/TDK MPU and ICM parts:  0x68 MPU6050, 0x70 MPU6500,
//           0x71 / 0x73 MPU9250, 0x12 ICM-20602, 0xEA ICM-20948
//   0x00 -> Bosch BMI160: 0xD1 (BMI270 would be 0x24).
//           Also the ADXL345, if the old sensor is plugged back in: 0xE5.
//   0x0F -> ST LSM6DS3: 0x69 (LSM6DSL / LSM6DS3TR-C are 0x6A, LSM6DSO 0x6C,
//           ISM330DHCX 0x6B)
//
// 不同厂商把芯片 ID 放在不同寄存器,所以常见的几个都读一遍、把原始值打出来 ——
// 目的是光看输出就能认芯片,不用猜它用的是哪个寄存器。
const uint8_t ID_REGS[] = {0x75, 0x00, 0x0F};
const uint8_t ID_REG_COUNT = sizeof(ID_REGS) / sizeof(ID_REGS[0]);

// The range worth scanning: 0x00-0x07 and 0x78-0x7F are reserved by the I2C
// spec, and cannot hold a device.
// 值得扫的范围:0x00-0x07 和 0x78-0x7F 被 I2C 规范保留,不可能有设备。
const uint8_t ADDR_FIRST = 0x08;
const uint8_t ADDR_LAST = 0x77;


// Reads one register, returning 0xFF when the device does not answer -- a value
// no real chip-ID register uses, so it reads as "no answer" rather than as a
// plausible ID.
// 读一个寄存器,设备不应答时返回 0xFF —— 没有哪个真的芯片 ID 寄存器会用这个值,
// 所以它读起来是「没应答」,而不是一个看着像真的 ID。
uint8_t readReg(uint8_t addr, uint8_t reg) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return 0xFF;
  }
  if (Wire.requestFrom((int)addr, 1) != 1) {
    return 0xFF;
  }
  return (uint8_t)Wire.read();
}

void printHex(uint8_t v) {
  Serial.print("0x");
  if (v < 0x10) {
    Serial.print('0');
  }
  Serial.print(v, HEX);
}

// Scans the bus once and prints everything found.
// 扫一遍总线,把找到的都打出来。
void scanOnce() {
  // A device can read as present on one pass and missing on the next if a wire
  // is loose, so the count is printed rather than just the list: "found nothing"
  // and "found two of these a second ago" are very different answers.
  // 线松的时候,同一个设备可能这一遍在、下一遍不在,所以除了列表还打印「找到了几个」:
  // 「一个都没有」和「刚才还有两个」是完全不同的答案。
  uint8_t found = 0;

  for (uint8_t addr = ADDR_FIRST; addr <= ADDR_LAST; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() != 0) {
      continue;                       // no device at this address
    }

    found++;
    Serial.print("  found ");
    printHex(addr);
    Serial.print("   ID:");

    for (uint8_t i = 0; i < ID_REG_COUNT; i++) {
      Serial.print("  reg");
      printHex(ID_REGS[i]);
      Serial.print("=");
      printHex(readReg(addr, ID_REGS[i]));
    }
    Serial.println();
  }

  if (found == 0) {
    // Said at length, because this is the answer that means "stop editing code":
    // every IMU shares the same two pins, so if the chip were alive and wired it
    // would show up here. Nothing showing up points at power, at a swapped
    // SDA/SCL pair, or at a module that is not actually on this bus.
    // 说得详细一点,因为这个答案的含义是「别再改代码了」:所有 IMU 都用同样两根线,
    // 只要芯片有电、线是通的,就一定会出现在这里。一个都没有,说明问题在供电、
    // 在 SDA/SCL 接反,或者这个模块根本不在总线上。
    Serial.println("  nothing found.");
    Serial.println("  -> the wiring or the power is the problem, not the code.");
    Serial.println("     check, in this order:");
    Serial.println("       1. SDA/SCL not swapped (a swap gives exactly this: silence)");
    Serial.println("       2. VCC and GND actually seated, breadboard rows not split");
    Serial.println("       3. 3.3V vs 5V -- many of these modules are 3.3V-only");
    Serial.println("     -> 接线或供电的问题,不是代码。依次查:SDA/SCL 是否接反、");
    Serial.println("        VCC/GND 是否真的通、模块要 3.3V 还是 5V。");
  }

  Serial.print("  scan done, ");
  Serial.print(found);
  Serial.print(" device(s).");
  if (found > 0) {
    Serial.print("  A real chip-ID is not 0xFF -- that value means no answer.");
    Serial.print("  Six zeros on the data meanwhile usually means the sleep bit");
    Serial.print("  in PWR_MGMT_1 (0x6B) was never cleared.");
  }
  Serial.println();
  Serial.println();
}


void setup() {
  Serial.begin(BAUD);

  // No arguments: the default pins for the board (A4/A5 on an Uno or Nano).
  // Passing pins explicitly would be wrong for any other board, and this sketch
  // has no way to know which one it is running on.
  // 不传参数 = 用板子的默认引脚(Uno/Nano 上是 A4/A5)。
  // 写死引脚换一块板子就错了,而这个 sketch 无从知道自己在哪块板上跑。
  Wire.begin();
  // Some modules need a moment after power-up before they answer at all.
  // 有些模块上电后要等一会儿才会应答。
  delay(300);

  Serial.println();
  Serial.println("=== I2C scan / I2C 扫描 ===");
  Serial.println("(rescanning every 2 s; open at 115200)");
}

void loop() {
  scanOnce();
  delay(RESCAN_INTERVAL_MS);
}
