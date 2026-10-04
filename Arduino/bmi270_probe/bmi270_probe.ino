// bmi270_probe.ino — is that chip ID real, or a misread?
//
// Why this exists
// ---------------
// On 2026-09-25 the I²C scanner found a device at 0x68 whose register 0x00 -- the
// BMI270's CHIP_ID -- read 0x20 on 48 consecutive reads. The BMI270's ID is 0x24
// and the SparkFun library refuses to proceed unless it matches (bmi2.c compares
// the read value against bmi270.c's BMI270_CHIP_ID = 0x24 and returns
// BMI2_E_DEV_NOT_FOUND if it differs), which is exactly why the firmware on the
// board kept printing "init failed" even after the headers were soldered.
//
// 0x24 is 0b00100100 and 0x20 is 0b00100000: ONE bit apart. So there are three
// very different explanations and they need different fixes:
//
//   1. the chip really is not a BMI270 and reports 0x20  -> the library cannot
//      ever work; the answer is a different driver or a different module.
//   2. the wire dropped bit 2 on every read              -> a contact problem.
//      This one is now weak: 48 out of 48 identical is not what a marginal
//      contact does, and a real chip ID is constant by construction.
//   3. the chip only reports its ID correctly AFTER a soft reset -> the chip is
//      fine and the LIBRARY's order of operations is what fails us, permanently.
//
// Number 3 is why this file has a second phase. bmi2.c reads the chip ID and
// compares it FIRST, and calls bmi2_soft_reset() only inside the branch where the
// comparison succeeded. So a chip that needs a reset before its ID reads right is
// a chip the library can never get far enough to reset -- it looks exactly like
// this. Nothing in the library will ever test that, so the test has to live here.
//
// Phase 1: read the ID many times. A real 0x20 is 0x20 every time; a marginal
// contact scatters -- 0x24 sometimes, 0x20 sometimes.
// Phase 2: write the soft-reset command (0xB6 to 0x7E), then watch the ID
// closely for the next half second. A BMI270 runs a boot sequence after reset
// during which it NAKs, so a device that accepted the command will go quiet
// briefly and then answer. A device that ignored the write answers 0x20 through
// the whole window, unchanged, which is itself the answer: not a BMI270.
//
// ---------------------------------------------------------------------------
// 存在的理由
// ----------
// 2026-09-25,I²C 扫描在 0x68 找到一个设备,它的寄存器 0x00(BMI270 的 CHIP_ID)
// 连续 48 次读出 0x20。BMI270 的 ID 是 0x24,而 SparkFun 库在两者不等时直接拒绝
// (bmi2.c 把读到的值跟 bmi270.c 里的 BMI270_CHIP_ID = 0x24 比较,不等就返回
// BMI2_E_DEV_NOT_FOUND)—— 这正是排针焊好之后板上固件仍然一直打印 "init failed" 的原因。
//
// 0x24 是 0b00100100,0x20 是 0b00100000,**只差一位**。所以有三种截然不同的解释,
// 修法也各不相同:
//
//   1. 芯片真不是 BMI270、本来就报 0x20 -> 这个库永远不可能工作,要换驱动或换模块。
//   2. 每次读都**掉了 bit 2** -> 接触问题。但这条现在很弱:48/48 完全一致不是接触不良
//      的表现,而且真的芯片 ID 按设计就是恒定值。
//   3. 芯片**必须先软复位、ID 才读得对** -> 芯片是好的,是**库的操作顺序**害了我们,
//      而且是永久性的。
//
// 第 3 条就是这个文件有第二阶段的原因。bmi2.c **先读 ID 并比较**,只有在比较通过的
// 那个分支里才调用 bmi2_soft_reset()。所以「必须先复位、ID 才读得对」的芯片,
// 库永远走不到复位那一步 —— 表现和现在一模一样。库自己永远不会去测这件事,
// 所以这个测试只能放在这里。
//
// 阶段 1:多次读 ID。真的 0x20 会每次都读出 0x20;接触不良则散开 —— 有时 0x24、有时 0x20。
// 阶段 2:写软复位命令(把 0xB6 写进 0x7E),然后在接下来半秒内紧盯着 ID。
// BMI270 复位后会跑一段启动序列,期间会 NAK,所以**接受了命令**的设备会短暂沉默、
// 然后恢复应答。而**忽略了这次写**的设备,整个窗口里都是不变的 0x20 ——
// 这本身就是答案:它不是 BMI270。

#include <Wire.h>
#include <SparkFun_BMI270_Arduino_Library.h>

BMI270 imu;

constexpr uint8_t SENSOR_ADDRESS = 0x68;
constexpr uint8_t CHIP_ID_REG = 0x00;
constexpr uint8_t BMI270_CHIP_ID_EXPECTED = 0x24;

// Bosch command interface. Writing the command byte here is how the datasheet
// asks for a soft reset; no other register is involved.
// Bosch 的命令接口。按数据手册,软复位就是把命令字节写到这里,不涉及别的寄存器。
constexpr uint8_t CMD_REG = 0x7E;
constexpr uint8_t SOFT_RESET_CMD = 0xB6;

// How many times to re-read the ID before asking the library. Enough that a
// flaky bit shows up as a mix, and few enough to stay readable.
// 问库之前重读多少次 ID。够多,让不稳定的位表现为混合;也够少,保持可读。
constexpr int ID_READS = 12;

// After the reset command: sample the ID every 10 ms for 600 ms. The BMI270's
// boot sequence is tens of milliseconds, so a boot window that exists at all
// falls inside this, and 600 ms is short enough to stay readable.
// 发完复位命令后:每 10ms 读一次 ID,持续 600ms。BMI270 的启动序列是几十毫秒,
// 只要存在启动窗口就一定落在这里面;600ms 也够短,输出还读得下去。
constexpr int RESET_POLLS = 60;
constexpr unsigned long RESET_POLL_INTERVAL_MS = 10UL;

constexpr unsigned long REPORT_INTERVAL_MS = 3000UL;

// Reads one register. 0xFF = no answer at all (the address NAKed); 0xFE = the
// device answered its address but then sent no data. Those are distinct faults
// -- 0xFE is what a chip mid-reboot or mid-init looks like, 0xFF is what a chip
// that is not there at all looks like, and the reset test below reads the
// difference as evidence.
// 读一个寄存器。0xFF = 完全没应答(地址就被 NAK);0xFE = 应答了地址但没发数据。
// 这是两种不同的故障 —— 0xFE 是芯片正在重启/初始化时的样子,0xFF 是芯片根本不在了的样子,
// 下面的复位测试正是把两者的区别当证据来读的。
uint8_t readReg(uint8_t addr, uint8_t reg) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return 0xFF;            // no answer
  }
  if (Wire.requestFrom((int)addr, 1) != 1) {
    return 0xFE;            // answered the address, then said nothing
  }
  return (uint8_t)Wire.read();
}

// Writes one register. Returns true when the device ACKed the address and the
// register byte -- i.e. the write was at least received, whatever the chip then
// does with it.
// 写一个寄存器。返回 true 表示设备 ACK 了地址和寄存器字节 —— 也就是这次写至少被收到了,
// 至于芯片随后拿它做什么是另一回事。
bool writeReg(uint8_t addr, uint8_t reg, uint8_t value) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

void printHex(uint8_t v) {
  Serial.print("0x");
  if (v < 0x10) {
    Serial.print('0');
  }
  Serial.print(v, HEX);
}

// The phase-1 question: is the ID stable at 0x20, or does it scatter?
// 阶段 1 的问题:ID 是稳定在 0x20,还是会散开?
void reportIdTally(int n_expected, int n_20, int n_other, int n_silent) {
  if (n_expected > 0 && n_20 + n_other > 0) {
    Serial.println("# -> the value MOVES. That is a contact/electrical fault, not a"
                   " wrong chip: a real chip ID is constant.");
  } else if (n_expected == 0 && n_20 == ID_READS) {
    Serial.println("# -> a stable 0x20. Either this is not a BMI270, or it only"
                   " reports its ID after a reset -- phase 2 below tells them apart.");
  } else if (n_silent == ID_READS) {
    Serial.println("# -> the device stopped answering entirely.");
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Wire.begin(21, 22);       // SDA, SCL -- ESP32-WROOM-32 defaults
  Wire.setClock(100000);
}

void loop() {
  // ------------------------------------------------ Phase 1: is 0x20 stable? --
  Serial.println();
  Serial.println("# === phase 1: CHIP_ID (reg 0x00), 12 reads ===");

  int n_expected = 0, n_20 = 0, n_other = 0, n_silent = 0;
  for (int i = 0; i < ID_READS; i++) {
    uint8_t id = readReg(SENSOR_ADDRESS, CHIP_ID_REG);
    Serial.printf("#   %2d: 0x%02X%s\n", i, id,
                  id == BMI270_CHIP_ID_EXPECTED ? "   <- expected" : "");
    if (id == BMI270_CHIP_ID_EXPECTED)  n_expected++;
    else if (id == 0x20)                n_20++;
    else if (id == 0xFF)                n_silent++;
    else                                n_other++;
  }
  Serial.printf("# tally: 0x24 x%d,   0x20 x%d,   other x%d,   no-answer x%d\n",
                n_expected, n_20, n_other, n_silent);
  reportIdTally(n_expected, n_20, n_other, n_silent);

  // ------------------------------------- Phase 2: does a soft reset change it? --
  // This is the whole point of this revision of the file. The library can never
  // reach its own soft reset when the ID is wrong, so if the ID is only wrong
  // *because* no reset has happened, this is the only place it can be discovered.
  // 这一版文件的重点就是这一段。ID 不对时,库永远走不到它自己的软复位;
  // 所以如果 ID 之所以不对,仅仅是因为还没复位过,那这里是唯一能发现它的地方。
  Serial.println();
  Serial.println("# === phase 2: soft reset (0xB6 -> reg 0x7E), then watch the ID ===");

  bool acked = writeReg(SENSOR_ADDRESS, CMD_REG, SOFT_RESET_CMD);
  Serial.printf("# write 0xB6 to 0x7E: %s\n",
                acked ? "address ACKed, command sent" : "NOT ACKed -- write rejected");

  // Poll fast enough to catch the boot window. A device that rebooted goes
  // 0xFE/0xFF for a moment; a device that ignored the write does not move.
  // 以足够快的节奏轮询,以便捕捉启动窗口。真重启的设备会有一瞬间读出 0xFE/0xFF;
  // 忽略这次写的设备不会有任何变化。
  int seen_expected = 0, seen_silent = 0;
  uint8_t first = 0, last = 0;
  Serial.print("# ID every 10 ms:");
  for (int i = 0; i < RESET_POLLS; i++) {
    uint8_t id = readReg(SENSOR_ADDRESS, CHIP_ID_REG);
    if (i == 0)                     first = id;
    last                                = id;
    if (id == BMI270_CHIP_ID_EXPECTED) seen_expected++;
    if (id == 0xFF || id == 0xFE)      seen_silent++;
    // One character per sample keeps 60 samples on one readable line, which is
    // what makes a boot window (a run of '.') visible at a glance.
    // 每个样本一个字符,60 个样本压在一行里还能读 —— 启动窗口(一长串 '.')才能一眼看出来。
    if (i % 10 == 0) {
      Serial.printf(" %d:", i);
    }
    Serial.print(id == BMI270_CHIP_ID_EXPECTED ? 'Y'
                 : (id == 0xFF ? '!' : (id == 0xFE ? '?' : '.')));
  }
  Serial.println();
  Serial.printf("# first=0x%02X last=0x%02X   0x24 x%d, no-answer x%d of %d\n",
                first, last, seen_expected, seen_silent, RESET_POLLS);

  if (seen_expected > 0 && n_expected == 0) {
    Serial.println("# -> !!! the ID BECOMES 0x24 only after a reset. The chip IS a"
                   " BMI270; the library just never gets to reset it. Fix is to"
                   " soft-reset by hand before beginI2C().");
  } else if (seen_silent > 0) {
    Serial.println("# -> the device went quiet during the window, so the command was"
                   " received and it DID something -- but the ID never became 0x24.");
  } else if (last == 0x20 && first == 0x20) {
    Serial.println("# -> unchanged 0x20 right through the reset window. The device"
                   " ignored the write: a BMI270 would have rebooted. Not a BMI270.");
  }

  // And now the same question asked of the library itself, so the status code
  // makes the mechanism explicit rather than inferred.
  // 再把同一个问题交给库本身,让状态码把机制讲清楚,而不是靠推断。
  int8_t status = imu.beginI2C(SENSOR_ADDRESS);
  Serial.printf("# beginI2C(0x%02X) -> %d   (0=OK, -2=comms failed, -3=device not found)\n",
                SENSOR_ADDRESS, status);

  if (status == BMI2_OK) {
    if (imu.getSensorData() == BMI2_OK) {
      Serial.printf("Accel(g): %.3f, %.3f, %.3f | Gyro(deg/s): %.3f, %.3f, %.3f\n",
                    imu.data.accelX, imu.data.accelY, imu.data.accelZ,
                    imu.data.gyroX, imu.data.gyroY, imu.data.gyroZ);
    }
  }
  delay(REPORT_INTERVAL_MS);
}
