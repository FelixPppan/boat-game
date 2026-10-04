// esp32_bmi270.ino — the oar's sensor. ESP32-WROOM-32 + BMI270.
//
// This replaces paddle_sensor.ino, which drove an ADXL345. That board is gone:
// the sensor on the oar is now a BMI270, and the ADXL345 sketch cannot talk to
// it at all (different chip, different bus protocol, different units).
//
// Why this file exists at all
// --------------------------
// The kit that came with the sensor ships a demo reading sketch, and its output
// is useless for measuring a stroke for three separate reasons:
//
//   1. It prints once per `delay(200)`, i.e. 5 Hz. The sensor is not the limit
//      -- the BMI270 will do 1600 Hz -- the delay is. 5 Hz cannot see a stroke:
//      the blade goes in and out in well under a second.
//   2. `delay()` stalls the whole loop, so nothing is sampled while it sleeps.
//      Even at a faster rate this misses precisely the peaks the analysis wants.
//   3. Six axes at exactly 0.000, forever, because the demo prints `imu.data.*`
//      fields that were never populated. It is silent about the only thing worth
//      knowing -- that it never talked to the chip. (Measuring wiring problems
//      is what Arduino/i2c_scan is for.)
//
// What this one does instead:
//   * Non-blocking micros() timing, like the ADXL345 sketch had, so no reading
//     is ever skipped because the loop was asleep.
//   * 100 Hz. Chosen to match the rate the rest of the pipeline is built around
//     (Scripts/sensor_input.gd, tools/direction_lab.py, and the sampling-error
//     analysis in the direction-measurement work all assume ~100 Hz), and
//     because the serial line below cannot carry much more.
//   * Prints the numeric init status when it fails. The firmware found on the
//     board on 2026-09-25 reported "Check wiring." with the status code dropped,
//     which cost real diagnostic time -- a number would have said which call
//     failed. Do not remove it.
//
// Bandwidth, since it decides the ceiling
// ---------------------------------------
// One line is about 80 bytes. At 115200 baud the line carries roughly 11520
// bytes/s, so ~100 Hz is close to the limit (~8000 B/s) and 200 Hz would not fit
// (~16000 B/s). Raising the rate needs BAUD raised too -- and Scripts/sensor_input.gd
// has to be told, since it opens the port at a fixed rate.
// 一行约 80 字节。115200 大约能载 11520 B/s,100 Hz 约 8000 B/s 已接近上限,
// 200 Hz(约 16000 B/s)载不动。要提高速率必须同时提高 BAUD,
// 并且 Scripts/sensor_input.gd 里那个固定的波特率也要跟着改。
//
// Wireless, added 2026-09-27
// -------------------------
// The radio is the ESP32's, not the sensor's: the BMI270 is a pure I2C slave and
// has no radio of any kind. The WROOM-32 module carries 2.4 GHz WiFi and
// dual-mode Bluetooth, and its antenna is the trace printed on the module, so
// untethering the oar needs no extra hardware at all -- only power, which is why
// this board now expects a USB power bank on the oar instead of a laptop.
//
// The board brings up its OWN access point rather than joining one, because
// there is no router out on the water. The host joins that network and sends one
// small hello packet to the board at 192.168.4.1; from then on the board sends to
// that address and to no other:
//
//   data         udp/4210   the "Accel(g): ..." lines, and nothing else
//   diagnostics  udp/4211   the "# ..." lines
//
// Unicast rather than broadcast, and that is a measurement rather than a taste.
// The first version of this broadcast to 192.168.4.255, and on 2026-09-28 the
// link measured 6.9% of samples never arriving -- and worse than the count, the
// timing: median gap between received packets 1.68 ms, gaps up to 190 ms, and
// runs of up to 11 consecutive samples missing. That is what 802.11 does to
// broadcast by design: no ACK, no retransmission, and the access point buffers
// broadcast frames and releases them after a DTIM beacon. Unicast is ACKed and
// retransmitted by the MAC and goes out immediately. The broadcast address is
// still the fallback for a host that has not said hello, so the link still works
// with nothing but a network join.
//
// Two ports rather than one, for a specific reason: on the host side the
// parse-failure counter is its only signal that a line was malformed, and a
// firmware diagnostic sharing the data socket would be counted as one -- so the
// two would be indistinguishable exactly when a corrupted line matters most.
//
// Serial is unchanged and still carries everything, so a tethered board stays
// exactly as debuggable as it was. The one asymmetry is that the wireless copy of
// each sample carries two fields the serial copy does not, a packet counter and
// the board's own micros(). UDP is the link that can lose and reorder whole
// samples, so it is the link that has to be able to prove it did not; serial
// cannot lose a line, so it does not pay for the metadata. It also could not
// afford to: see the bandwidth note above -- six axes at 100 Hz is already close
// to 90% of what 115200 carries.
// 无线的射频在 ESP32 上,不在传感器上:BMI270 是纯 I2C 从机,没有任何射频。
// 模组自带天线,所以「让桨脱线」不需要额外硬件 —— 只需要供电,于是桨上换成 USB 充电宝。
//
// 板子自己开热点(水上没有路由器)。主机连上来之后往 192.168.4.1 发一个小 hello 包,
// 此后板子只发给那一个地址。两个 UDP 口:4210 只走数据行,4211 走 "#" 诊断行。
//
// 用单播而不是广播,这是**量出来的**,不是偏好。第一版是广播到 192.168.4.255,
// 2026-09-28 实测:6.9% 的样本根本没到 —— 而比这个数字更糟的是时序:
// 收到的包之间中位间隔 1.68 ms、最差间隔 190 ms、最多连丢 11 个样本。
// 这就是 802.11 对广播的固有行为:没有 ACK、不重传,而且 AP 会把广播帧缓存到
// DTIM beacon 才一起放出来。单播由 MAC 层 ACK 并重传,而且是立刻发。
// 广播地址仍然是「主机还没打招呼」时的退路,所以只连个网也照样能跑。
//
// 分开的原因很具体:主机那边「解析失败计数」是判断乱码行的唯一信号,
// 固件诊断挤在数据口上会被算成一次解析失败 —— 恰恰在最需要分辨乱码的时候,两者分不开。
//
// 串口行为完全没变,所以插着线调试和以前一样。唯一的不对称是无线那份样本多了两个字段
// (包序号和板子自己的 micros()):会丢包、会乱序的是 UDP,所以需要能自证没丢的是它;
// 串口不会丢行,不必为这份元数据付代价 —— 它也付不起,见上面的带宽说明。
//
// The wire format is the one Scripts/sensor_input.gd already parses, so the
// Godot side needs no change: it keys on the literal "Accel(", takes the six
// numbers in order as accel x,y,z then gyro x,y,z, and sets has_gyro and
// accel_in_g from the fact that it matched.
// 输出格式就是 Scripts/sensor_input.gd 已经能解析的那种,所以 Godot 那边不用改。
//
// There is deliberately NO startup banner. The Godot parser counts every line
// that is not one of the two data formats as a parse failure, and shows that
// count, so a banner would make the readout claim a permanent error. The
// settings live in this file; if provenance needs to travel with a recording,
// the recorder is the right place to put it, not the sensor's byte stream.
// 故意没有开机横幅:Godot 那边的解析器会把「两种数据格式之外」的每一行都记成解析失败
// 并显示出来,横幅会让读数显示一个永久的错误计数。
//
// 这个文件取代 paddle_sensor.ino(ADXL345)。那块板子已经不在了,桨上现在是 BMI270,
// ADXL345 的 sketch 完全驱动不了它(芯片、总线协议、单位都不同)。

#include <Wire.h>
#include <stdarg.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <SparkFun_BMI270_Arduino_Library.h>

BMI270 imu;

// --------------------------------------------- Config / 配置调参 (中英对照) --
// Must match Scripts/sensor_input.gd's BAUD_RATE.
// 必须和 Scripts/sensor_input.gd 的 BAUD_RATE 一致。
constexpr long BAUD = 115200;

// ESP32-WROOM-32 default I2C pins, and what the kit's wiring table uses.
// ESP32-WROOM-32 的默认 I2C 引脚,也是操作包接线表用的引脚。
constexpr uint8_t SDA_PIN = 21;
constexpr uint8_t SCL_PIN = 22;

// 100 kHz, not 400 kHz. The bus is not the bottleneck (a sample is 12 bytes and
// we ask for 100 a second), and 100 kHz is far more forgiving of breadboard
// jumpers and hand-soldered headers -- which is exactly where this board's
// problems have been.
// 100 kHz 而不是 400 kHz。总线不是瓶颈(一个样本 12 字节、每秒 100 个),
// 而 100 kHz 对面包板跳线和手焊排针宽容得多 —— 这个板子的毛病正好出在这些地方。
constexpr uint32_t I2C_CLOCK_HZ = 100000;

// A bounded I2C timeout, set explicitly rather than trusted to the default.
//
// This is load-bearing for the watchdog below: if a stuck bus could make a Wire
// call block forever, loop() would never return to it and the one piece of code
// that could free the bus would never run. A stuck bus has to show up as a
// FAILED call, which the watchdog can see and act on, not as a hang.
// 明确设置一个有界的 I2C 超时,不依赖默认值。
//
// 这是下面那个看门狗的前提:如果总线卡住能让 Wire 调用无限阻塞,loop() 就永远回不到它,
// 而唯一能释放总线的代码也就永远不会执行。总线卡住必须是**调用失败**,看门狗才能看见并处理,
// 而不能是一次挂死。
constexpr uint16_t I2C_TIMEOUT_MS = 50;

// ADO/MISO tied to GND selects 0x68. If the scanner reports 0x69, ADO is tied
// high instead and this must change to match -- a mismatch here looks exactly
// like a dead sensor, and is the single most common way this board appears
// broken.
// ADO/MISO 接 GND 选中 0x68。若扫描报 0x69,说明 ADO 接高,这里必须改 ——
// 地址对不上看起来和传感器坏了一模一样,这是这块板子最常见的「坏掉」原因。
constexpr uint8_t SENSOR_ADDRESS = 0x68;

// Ranges. Resolution is NOT the reason to pick between these: even +/-16 g gives
// 2048 counts per g, which is 200x finer than the ~0.1 g differences the |a|/g
// analysis has to tell apart. So this is chosen for headroom. +/-8 g is 8 times
// gravity on a paddle -- well clear of any real stroke -- while the gyro is left
// at its widest (2000 deg/s) because a fast swing is the one motion that could
// clip, and clipping a rate the detector keys on would be worse than the coarser
// count.
// 量程。**不是**为了分辨率才在这几个里挑:即使 ±16g 也有 2048 格/g,
// 比 |a|/g 分析需要区分的约 0.1g 差别细 200 倍。所以这里按「留余量」选。
// ±8g 是 8 倍重力,远超任何真实划桨;陀螺仪则留在最宽的 2000 deg/s,
// 因为快速挥桨是唯一可能顶到上限的动作,而把检测所依赖的角速度削顶,比格子粗一点更糟。
constexpr uint8_t ACC_RANGE = BMI2_ACC_RANGE_8G;
constexpr uint8_t GYR_RANGE = BMI2_GYR_RANGE_2000;

// 100 Hz on both. See the bandwidth note at the top before raising these.
// 两个都是 100 Hz。要提高之前先看文件顶部的带宽说明。
constexpr uint8_t ACC_ODR = BMI2_ACC_ODR_100HZ;
constexpr uint8_t GYR_ODR = BMI2_GYR_ODR_100HZ;

// How often the loop looks at the sensor. Deliberately much FASTER than the
// 100 Hz ODR, so that the data-ready flag decides the rate rather than the loop
// does. Polling at exactly the ODR period was the first attempt and it measured
// 86 lines/s rather than 100: when the poll lands just before the chip's next
// sample is ready, that whole slot is skipped and the next one is 10 ms later,
// so slots are lost at roughly the beat frequency between the two clocks. 2 ms
// removes that -- the flag is still what gates the print, so polling faster
// cannot repeat a sample, because SparkFun's getSensorData() reads the data
// registers and that is what clears BMI2_DRDY_ACC.
// 循环看传感器的间隔。故意比 100 Hz 的 ODR **快得多**,让 data-ready 位而不是循环来决定速率。
// 一开始取的是正好等于 ODR 周期,实测只有 86 行/秒而不是 100:轮询恰好落在芯片下一个样本就绪之前时,
// 整个时隙被跳过,要再等 10ms,于是以两个时钟的拍频丢失时隙。2ms 消掉这个问题 ——
// 打印仍然由标志位门控,所以轮询再快也不会重复样本,因为 SparkFun 的 getSensorData()
// 读的就是数据寄存器,而清掉 BMI2_DRDY_ACC 的正是这个读操作。
//
// This is only safe because the flag really is cleared by the data read. If a
// future build ever shows a line rate near the poll rate (hundreds of Hz) instead
// of near 100, that assumption has broken and the gate is no longer gating --
// and since the wire cannot carry 500 lines/s, the rate must be brought back to
// the ODR period first and the flag investigated second.
// 这么做之所以安全,前提是标志位确实被那次读清掉。若将来某个版本的行速率接近轮询速率
// (几百 Hz)而不是接近 100,就说明这个前提破了、门控不再门控 ——
// 而线上载不动 500 行/秒,所以必须先把间隔改回 ODR 周期,再查标志位。
constexpr unsigned long POLL_INTERVAL_US = 2000UL;

unsigned long next_poll_us = 0;

// ---------------------------------------------------------------- Wireless --
// See the note at the top for why the radio lives here, and why there are two
// ports rather than one.
// 为什么射频在这里、为什么是两个口而不是一个,见文件顶部。
constexpr bool WIFI_ENABLED = true;
// The password must be at least 8 characters, or the ESP32 quietly brings the
// access point up OPEN instead of failing -- which looks like a working link
// right up until you notice anyone nearby can watch your oar.
// 密码必须至少 8 个字符,否则 ESP32 会**静默地**把热点开成无密码 ——
// 看起来一切正常,直到你意识到附近任何人都能收看你划桨。
constexpr char AP_SSID[] = "oar-sensor";
constexpr char AP_PASSWORD[] = "paddleoar";

constexpr uint16_t UDP_DATA_PORT = 4210;
constexpr uint16_t UDP_DIAG_PORT = 4211;

// The SoftAP's own subnet is 192.168.4.0/24 with the board at .1, so .255 is its
// broadcast address. Directed broadcast rather than 255.255.255.255, which some
// stacks drop for anything that is not a DHCP request.
//
// Since 2026-09-28 this is only the FALLBACK, for a host that has not sent its
// hello yet -- see udpSend(). Broadcast is what the link measured badly.
// 热点自己的网段是 192.168.4.0/24、板子在 .1,所以广播地址是 .255。
// 用定向广播而不是 255.255.255.255 —— 后者在有些协议栈上会被丢掉,只有 DHCP 例外。
//
// 从 2026-09-28 起这只是**退路**,给还没打过招呼的主机用 —— 见 udpSend()。
// 广播正是实测表现很差的那种发法。
const IPAddress UDP_BROADCAST(192, 168, 4, 255);

WiFiUDP udpData;
WiFiUDP udpDiag;

// The host's address, learned from the hello packet it sends us, and whether we
// have learned it yet.
//
// Deliberately not discovered from the DHCP server instead: esp_netif's client
// list is an internal header, and a single datagram from the host gives the same
// answer with none of that. The host re-sends the hello periodically, so a board
// restart or a host that rejoins the network on a new lease both recover on their
// own, with no handshake to get out of step.
// 主机的地址,从它发来的 hello 包里学到;以及有没有学到。
//
// 故意不从 DHCP 服务器那边查:esp_netif 的客户端列表是内部头文件,而主机发一个数据报
// 就能得到同样的答案,还不用碰那些。主机会周期性重发 hello,所以板子重启、
// 或者主机重新入网拿到新租约,两者都能自己恢复,没有会失步的握手状态。
IPAddress host_ip;
bool host_known = false;

// Whether the data socket is actually open. pollHostHello() runs in the hot loop,
// so it must never touch a socket that WiFiUDP::begin() refused -- on this core
// parsePacket() on an unopened socket is anywhere between useless and a null
// dereference, and a board that resets in a loop is a much worse outcome than a
// board that cannot hear the host.
// 数据 socket 到底开没开。pollHostHello() 跑在热循环里,所以它绝不能去碰一个
// begin() 拒绝开的 socket —— 在这个 core 上,对一个没开的 socket 调 parsePacket()
// 轻则没用重则空指针解引用,而「板子循环重启」比「板子听不见主机」糟糕得多。
bool data_socket_open = false;

// True only once softAP() has actually succeeded. A runtime flag rather than the
// constant above, because a radio that refuses to start must leave the board
// running on the serial link: losing the sensor because the WiFi did not come up
// would be a strictly worse outcome than having no wireless at all.
// 只有在 softAP() 真的成功之后才为 true。用运行期标志而不是上面那个常量,是因为
// 「射频起不来」必须让板子继续在老实的串口上工作:因为无线没起来而丢掉传感器,
// 比「干脆没有无线」糟糕得多。
bool wifi_started = false;

// Monotonically increasing packet counter, sent with every wireless sample so the
// host can see what the radio dropped. Serial has never needed one.
// 每发一个无线样本就加一的包序号,让主机看得见射频丢了多少。串口从来不需要这个。
unsigned long sample_seq = 0;

// Sends to the host once we know where the host is, and broadcasts until then.
//
// Unicast when we can, because broadcast is the version that measured badly: the
// MAC layer does not ACK it and never retransmits, and the access point defers it
// to the next DTIM beacon. Broadcasting is kept as the fallback so that a host
// which only joins the network -- the probe before it sends its hello, or any
// tool that never sends one -- still sees the stream.
// 知道主机在哪之后就发给主机,在那之前广播。
//
// 能单播就单播,因为广播是实测表现差的那种:MAC 层不 ACK、永不重传,
// 而且 AP 会把它推迟到下一个 DTIM beacon。保留广播作为退路,
// 是为了让「只连了网」的主机(还没发 hello 时的探针,或者任何从不发 hello 的工具)照样能看到流。
void udpSend(WiFiUDP &udp, const char *data, size_t len, uint16_t port) {
  udp.beginPacket(host_known ? host_ip : UDP_BROADCAST, port);
  udp.write((const uint8_t *)data, len);
  udp.endPacket();
}

// Whether anything is actually listening. Transmitting with no station connected
// spends airtime and battery to reach nobody, and this board is on a power bank.
// 到底有没有人在听。没有客户端连着还发,是拿电量和空口时间去打空气,而这块板子靠充电宝。
bool wirelessUp() {
  return wifi_started && WiFi.softAPgetStationNum() > 0;
}

// Learns where the host is from the hello packet it sends, and does nothing else.
//
// Called from loop() once per poll slot rather than from an interrupt: a hello is
// one datagram every second or two, so 500 chances a second to notice it is
// already absurdly generous, and doing it here keeps the socket's state owned by
// exactly one place.
// 从主机发来的 hello 包里学到主机在哪,别的什么都不做。
//
// 在 loop() 里每个轮询时隙调一次,而不是从中断里调:hello 是一两秒一个数据报,
// 每秒 500 次去发现它已经宽松得离谱,而放在这里能让这个 socket 的状态只有一个主人。
void pollHostHello() {
  if (!data_socket_open) { return; }
  if (udpData.parsePacket() <= 0) { return; }

  // Drained, not left sitting in the buffer: on this core parsePacket() parks the
  // datagram in an internal buffer, and an undrained one would keep reporting
  // itself as available forever, so the next hello could never get in.
  // 排空,而不是留在缓冲里:在这个 core 上 parsePacket() 会把数据报停进内部缓冲,
  // 不排空的话它会永远报告「有数据」,下一个 hello 就再也进不来。
  uint8_t scratch[32];
  while (udpData.available() > 0) {
    udpData.read(scratch, sizeof(scratch));
  }

  IPAddress from = udpData.remoteIP();
  if (host_known && from == host_ip) { return; }
  host_ip = from;
  host_known = true;
  diag("# wireless: host at %u.%u.%u.%u -- unicast from here",
       (unsigned)from[0], (unsigned)from[1], (unsigned)from[2], (unsigned)from[3]);
}

// Every diagnostic in this file, in one place, so that each of them reaches the
// host over BOTH links without the call sites having to know there are two.
// Calls with a literal and no arguments are fine.
//
// The trailing newline is added here rather than at each call site so that the
// serial stream and the UDP packets carry byte-identical text, and the host can
// split either of them on '\n' and get the same answer.
// 本文件所有的诊断都走这里,这样每条都会同时到达两个链路,而调用点不必知道有两个。
// 结尾的换行在这里加而不是每处加:串口流和 UDP 包里的文本就完全一致,
// 主机对两者按 '\n' 切分得到同样的结果。
void diag(const char *fmt, ...) {
  char buf[192];
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(buf, sizeof(buf) - 2, fmt, args);
  va_end(args);
  if (n < 0) { return; }
  buf[n++] = '\n';
  Serial.write((const uint8_t *)buf, n);
  if (wirelessUp()) { udpSend(udpDiag, buf, n, UDP_DIAG_PORT); }
}

void startWireless() {
  if (!WIFI_ENABLED) { return; }

  // persistent(false): the credentials are constants in this file, so letting the
  // stack re-save them to flash on every boot would only wear the flash out.
  // persistent(false):凭据就是这个文件里的常量,让协议栈每次开机都往 flash 里存一遍,
  // 只是白白磨损 flash。
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);
  // No modem sleep. It saves power by waking the radio periodically, which is
  // exactly the latency this link must not have; the board runs off a power bank,
  // not a coin cell, so there is nothing to trade away here.
  // 关掉 modem sleep。它靠周期性唤醒射频来省电,而那正是这条链路不能有的延迟;
  // 板子用的是充电宝不是纽扣电池,这里没有值得交换的东西。
  WiFi.setSleep(false);

  if (!WiFi.softAP(AP_SSID, AP_PASSWORD)) {
    diag("# wireless: softAP() refused -- running on the serial link only");
    return;
  }
  wifi_started = true;

  if (!udpData.begin(UDP_DATA_PORT)) {
    diag("# wireless: could not open udp/%u for data", (unsigned)UDP_DATA_PORT);
  } else {
    data_socket_open = true;
  }
  if (!udpDiag.begin(UDP_DIAG_PORT)) {
    diag("# wireless: could not open udp/%u for diagnostics", (unsigned)UDP_DIAG_PORT);
  }
}

// Resets the chip by hand before handing it to the library.
//
// This is not optional politeness. The SparkFun library reads the chip ID and
// compares it against 0x24 FIRST, and only calls the BMI270's soft reset inside
// the branch where that comparison passed -- so a chip that is not currently
// presenting 0x24 is a chip the library will never reset, and it reports
// BMI2_E_DEV_NOT_FOUND (-3) forever. That is not hypothetical: on 2026-09-25
// this exact module read 0x20 on 48 consecutive reads and the library refused it
// on every attempt, and the same chip answered 0x24 twelve times out of twelve
// after a reset. Doing the reset here removes that whole dead end.
// 这句不是可有可无的客套。SparkFun 库**先**读芯片 ID 跟 0x24 比较,**只有比较通过的那个分支里**
// 才调用 BMI270 的软复位 —— 所以一颗当前没在报 0x24 的芯片,库永远不会去复位它,
// 只会永远返回 BMI2_E_DEV_NOT_FOUND(-3)。这不是假设:2026-09-25 这个模块连续 48 次读出 0x20、
// 库每次都拒绝,而同一颗芯片在复位之后 12 次读出 12 次 0x24。在这里先复位,就把这条死路整个去掉了。
//
// The write is not fire-and-forget: the BMI270 NAKs while it boots (~90 ms), so
// the code waits for it to answer again rather than assuming it is ready.
// 写完不能不管:BMI270 启动期间会 NAK(约 90ms),所以这里等它重新应答,而不是假定它好了。
// These names are deliberately NOT the library's. SparkFun's bmi270.h already
// does `#define BMI270_CHIP_ID UINT8_C(0x24)`, and reusing that name here turns
// into "expected unqualified-id before numeric constant" at the point of the
// declaration -- a build error, which is at least loud. Worth knowing because
// it cost an upload cycle: arduino-cli's `upload` compiles first, and a failure
// there can leave the board still running the previous binary, which then looks
// like a code change that simply had no effect.
// 这些名字故意和库的不一样。SparkFun 的 bmi270.h 里已经有
// `#define BMI270_CHIP_ID UINT8_C(0x24)`,在这里复用这个名字会在声明处变成
// "expected unqualified-id before numeric constant"。这个错误本身是响亮的,
// 但值得记一笔,因为它花了整整一个烧录来回:arduino-cli 的 `upload` 会先编译,
// 而编译失败时板子上可能还跑着旧固件 —— 看起来就像「改了代码但毫无效果」。
constexpr uint8_t REG_CMD = 0x7E;
constexpr uint8_t CMD_SOFT_RESET = 0xB6;
constexpr uint8_t REG_CHIP_ID = 0x00;
constexpr uint8_t EXPECTED_CHIP_ID = 0x24;
constexpr unsigned long SOFT_RESET_TIMEOUT_MS = 500UL;

// Returns 0xFF when nothing answers, 0xFE when the device ACKed its address but
// sent no data -- which is what a chip mid-boot looks like, and is therefore the
// signal that the reset was accepted.
// 没应答返回 0xFF;ACK 了地址但没发数据返回 0xFE —— 正在启动的芯片就是这个样子,
// 所以这个值本身就是「复位被接受了」的信号。
uint8_t readChipId() {
  Wire.beginTransmission(SENSOR_ADDRESS);
  Wire.write(REG_CHIP_ID);
  if (Wire.endTransmission(false) != 0) { return 0xFF; }
  if (Wire.requestFrom((int)SENSOR_ADDRESS, 1) != 1) { return 0xFE; }
  return (uint8_t)Wire.read();
}

void softResetSensor() {
  // The write is retried, because the FIRST access after an ESP32 reset can be
  // NAKed even by a perfectly good sensor. Observed 2026-09-25: the very first
  // attempt after a reset failed while the immediately following beginI2C()
  // succeeded. The likely mechanism is that resetting the ESP32 can interrupt it
  // mid-transaction, leaving the sensor holding the bus until its own timeout
  // expires -- so one failure says nothing about whether the chip is there, and
  // treating it as "not on the bus" would be exactly the wrong conclusion.
  // 这次写会重试,因为 ESP32 复位后的**第一次**访问,即使传感器完全正常也可能被 NAK。
  // 2026-09-25 实测:复位后第一次尝试失败,而紧接着的 beginI2C() 就成功了。
  // 机制大概是:复位 ESP32 会打断一次进行中的传输,把从机留在持有总线的状态,
  // 直到它自己的超时结束 —— 所以一次失败根本说明不了芯片在不在,
  // 把它当成「不在总线上」正好是最错的结论。
  constexpr int RESET_WRITE_ATTEMPTS = 5;
  constexpr unsigned long RESET_WRITE_RETRY_MS = 20UL;

  bool acked = false;
  for (int attempt = 1; attempt <= RESET_WRITE_ATTEMPTS && !acked; attempt++) {
    Wire.beginTransmission(SENSOR_ADDRESS);
    Wire.write(REG_CMD);
    Wire.write(CMD_SOFT_RESET);
    acked = Wire.endTransmission() == 0;
    if (!acked) {
      delay(RESET_WRITE_RETRY_MS);
    }
  }

  if (!acked) {
    // Say why this is survivable rather than fatal: the reset is only needed
    // when the chip is not presenting 0x24, and the library is about to report
    // whatever it actually sees.
    // 说清楚为什么这件事是「能忍」而不是「致命」:只有在芯片没报 0x24 时才需要复位,
    // 而库马上就会把它实际看到的东西报出来。
    diag("# soft reset: no ACK in %d tries -- skipping; beginI2C below will say what it sees",
         RESET_WRITE_ATTEMPTS);
    return;
  }

  // Watch it come back. Reported rather than silent, so that "the chip needed a
  // reset to identify itself" is visible in the log instead of being a mystery
  // if this board ever behaves differently again.
  // 看着它回来。打印出来而不是默默过去,这样「芯片需要复位才认得出自己」在日志里看得见,
  // 万一以后这块板子又表现不同,不至于变成一个谜。
  unsigned long start = millis();
  while (millis() - start < SOFT_RESET_TIMEOUT_MS) {
    if (readChipId() == EXPECTED_CHIP_ID) {
      diag("# soft reset: chip back after %lu ms", millis() - start);
      return;
    }
    delay(5);
  }
  diag("# soft reset: no 0x24 within 500 ms -- continuing anyway, the"
       " library will report what it sees");
}

// One retry per second, and the status code is printed every time rather than
// once: this loop runs while the user is re-seating wires, and the numbers
// scrolling past are the progress indicator. Never a bare "failed".
// 每秒重试一次,而且每次都打印状态码、不是只打一次:这个循环是在用户重新插线的时候跑的,
// 滚过去的数字就是进度指示。绝不打印一个光秃秃的「failed」。
void waitForSensor() {
  int8_t status;
  while ((status = imu.beginI2C(SENSOR_ADDRESS)) != BMI2_OK) {
    diag("# BMI270 init failed. status=%d  (address 0x%02X) -- check ADO/CS wiring;"
         " run Arduino/i2c_scan to see the bus",
         (int)status, SENSOR_ADDRESS);
    delay(1000);
  }
}

// ------------------------------------------------- Silence, and getting it back --
// Why this exists
// ---------------
// Every failing path in loop() used to be a bare `return`. That made a stalled
// sensor indistinguishable from a working one at a glance: the wire went quiet,
// and the port stayed open, so the host had no way to tell "the board stopped
// sending" from "there is nothing to send". Observed symptom, 2026-09-26: the
// game reads fine for a while, then goes silent forever; restarting the game
// does not help, because the port opens fine and simply never delivers a byte.
// A reset of the ESP32 brought it straight back, so the board was alive the
// whole time and the sketch was running -- it had just stopped producing
// samples and had nothing to say about it.
//
// So there are two things here, and both are needed:
//   * the stall is REPORTED, with which branch stalled, so the fault is visible
//     on the wire instead of being a mystery;
//   * recovery is ATTEMPTED, so a transient bus fault heals itself instead of
//     requiring the user to unplug the oar mid-session.
// 这两件事都需要:卡住要**报出来**(并说明是哪条分支),故障才是看得见的;
// 同时要**尝试自救**,总线上的瞬时故障才能自己恢复,而不是让用户玩到一半去拔线。
//
// How long with no successfully-read sample before the watchdog looks. 100
// samples at the 100 Hz ODR, well clear of jitter.
//
// What this measures matters: a sample that was READ, not a line that went out.
// A chip that keeps answering and keeps handing samples over is never faulted
// here, whatever happens to the bytes afterwards, because reading a sample is
// what refreshes last_print_ms. What it catches is the chip no longer
// delivering -- the only thing resetting the chip can actually fix.
// 多久没有**成功读到**样本,看门狗才开始看。100 Hz 下 100 个样本,离抖动很远。
//
// 它量的是什么很关键:量的是**被读到的样本**,不是发出去的行。芯片只要一直在应答、
// 一直在交样本,就不会在这里被判故障,不管那些字节之后遭遇了什么 —— 因为刷新
// last_print_ms 的正是「读到了一个样本」这件事。它抓的是芯片不再交样本,
// 而那是复位芯片唯一真能治的东西。
constexpr unsigned long SILENCE_LIMIT_MS = 1000UL;

// How often to say so while still stalled, and how long to leave a recovery
// attempt alone before trying again -- `beginI2C` is not instant, and retrying
// it in a tight loop would flood the wire with its own failure messages.
// 还在卡着的时候多久报一次,以及一次自救之后隔多久再试 —— beginI2C 不是瞬时的,
// 紧循环重试会用它自己的失败信息把串口刷爆。
constexpr unsigned long STALL_REPORT_INTERVAL_MS = 1000UL;
constexpr unsigned long RECOVER_INTERVAL_MS = 3000UL;

unsigned long last_print_ms = 0;
unsigned long last_stall_report_ms = 0;
unsigned long last_recover_ms = 0;

// A `drdy_seen` latch used to live here and it was a trap. It was set whenever a
// poll saw DRDY and cleared ONLY after a sample was successfully printed, and it
// gated recovery: `if (!drdy_seen) recoverSensor();`.
//
// A failed read leaves DRDY SET in the chip -- the data registers were never
// clocked out -- so the state that set the latch re-created itself on the next
// poll, forever. And the only way to reach the watchdog with the latch set was
// exactly "the chip says a sample is ready and reading it keeps failing", i.e. a
// stalled chip: the one fault recovery exists for. The latch therefore reported
// "chip is fine, not resetting" and disabled recovery permanently. The oar went
// silent until the board was reset while the access point stayed up, which is
// how the user found it on 2026-09-29.
//
// Nothing needs to go back here. A healthy chip whose OUTPUT is blocked cannot
// reach the watchdog at all: it keeps reading samples successfully, and every
// successful read refreshes last_print_ms, which is the watchdog's own gate. So
// "no successful sample for SILENCE_LIMIT_MS" is the entire condition -- and a
// condition that is re-derived from scratch on every poll cannot latch.
//
// 这里原来有一个 `drdy_seen` 闩锁,它是个陷阱。看到 DRDY 就置位,**只有成功打印出一个
// 样本才清零**,而自救被它把关:`if (!drdy_seen) recoverSensor();`。
//
// **读失败会让 DRDY 留在芯片里置位** —— 数据寄存器根本没被读走 —— 所以置位它的那个状态
// 会在下一轮自己重建,永远如此。而唯一能带着它走到看门狗的状态,恰恰就是「芯片说有样本
// 好了、而读它一直在失败」,也就是卡住的芯片:自救存在的唯一理由。于是这个闩锁报出
// 「芯片没事,不复位」,并且永久关掉了自救。桨从此彻底沉默直到板子被复位,而热点一直立着
// —— 用户 2026-09-29 就是这么发现的。
//
// 这里不需要补任何东西。「输出被挡住但芯片健康」根本走不到看门狗:它一直在成功读样本,
// 而每次成功都会刷新 last_print_ms,那本身就是看门狗的门槛。所以「连续 SILENCE_LIMIT_MS
// 没有成功样本」就是全部条件 —— 而每轮都从零重新算出来的条件,闩不住。

// Which branch returned early without printing. Named rather than counted,
// because "no DRDY" and "getStatus failed" mean opposite things: the first is a
// chip that answers but never has data, the second is a bus that stopped
// answering at all.
// 是哪条分支没打印就返回了。记名字而不是记数,因为「没有 DRDY」和「getStatus 失败」
// 意思正相反:前者是芯片会应答但一直没数据,后者是总线干脆不应答了。
const char *stalled_at = "nothing yet";

// Counts polls whose I2C calls actually failed, which is a fact about the bus
// rather than about the output. Reported with the stall so that "the bus is
// failing constantly" cannot hide behind a watchdog message that only ever
// mentions DRDY.
// 统计 I2C 调用**真的失败**的轮询次数。这是关于总线的事实,不是关于输出的事实。
// 和卡住的信息一起报出来,免得「总线一直在失败」藏在一条只会提 DRDY 的看门狗信息后面。
unsigned long bus_error_count = 0;

// beginI2C() re-initialises the chip, which puts it back on its default ranges,
// so the configuration has to be re-applied every time it is called -- both at
// startup and after a recovery.
// beginI2C() 会重新初始化芯片,把它退回默认量程,所以每次调用之后都必须重新配置 ——
// 开机时和自救之后都一样。
void applyRanges() {
  // get-then-modify-then-set: setConfig() writes the whole struct, so building
  // one field by field would send garbage in the rest of it.
  // 先 get 再改再 set:setConfig() 写的是整个结构体,一个字段一个字段地凑会把其余字段写成垃圾。
  bmi2_sens_config config;

  config.type = BMI2_ACCEL;
  if (imu.getConfig(&config) != BMI2_OK) { return; }
  config.cfg.acc.odr = ACC_ODR;
  config.cfg.acc.range = ACC_RANGE;
  imu.setConfig(config);

  config.type = BMI2_GYRO;
  if (imu.getConfig(&config) != BMI2_OK) { return; }
  config.cfg.gyr.odr = GYR_ODR;
  config.cfg.gyr.range = GYR_RANGE;
  imu.setConfig(config);
}

// A slave interrupted mid-byte can hold SDA low, and the master cannot fix that
// by re-initialising its own peripheral -- the peripheral is fine, the BUS is
// stuck. It has to be clocked out: nine pulses to walk the slave through the
// rest of a byte it will never finish, then a STOP to put it back in a state
// where a start condition means something. Standard I2C escape, and the reason
// a bus that "needs a power cycle to recover" usually does not.
// 被中断在字节中间的从机会把 SDA 拉低,而主机重新初始化自己的外设根本解决不了 ——
// 外设没问题,是**总线**卡住了。必须把它「敲」出来:九个脉冲让从机走完那个它永远走不完的字节,
// 再补一个 STOP 让它回到「起始条件有意义」的状态。这是标准做法,也是「总线非得断电才能恢复」
// 其实往往不用断电的原因。
void freeBus() {
  pinMode(SDA_PIN, INPUT_PULLUP);
  pinMode(SCL_PIN, OUTPUT);
  digitalWrite(SCL_PIN, HIGH);
  for (int i = 0; i < 9; i++) {
    digitalWrite(SCL_PIN, LOW);
    delayMicroseconds(5);
    digitalWrite(SCL_PIN, HIGH);
    delayMicroseconds(5);
  }
  pinMode(SDA_PIN, OUTPUT);
  digitalWrite(SDA_PIN, LOW);
  delayMicroseconds(5);
  digitalWrite(SCL_PIN, HIGH);
  delayMicroseconds(5);
  digitalWrite(SDA_PIN, HIGH);        // STOP: SDA rises while SCL is high
  delayMicroseconds(5);
}

// Tear the bus and the chip down to a known state and bring them back. Reports
// every step it can fail at, for the same reason setup() does.
// 把总线和芯片推倒到已知状态再拉起来。每一步可能失败的地方都报出来,理由和 setup() 一样。
void recoverSensor() {
  diag("# recovery: sensor stalled, re-initialising bus and chip");
  freeBus();

  Wire.end();
  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(I2C_CLOCK_HZ);
  Wire.setTimeOut(I2C_TIMEOUT_MS);

  softResetSensor();

  int8_t status = imu.beginI2C(SENSOR_ADDRESS);
  diag("# recovery: beginI2C status=%d", (int)status);
  if (status == BMI2_OK) {
    applyRanges();
    // Pretend a sample just arrived, so the stall has to persist for another
    // full SILENCE_LIMIT_MS before this is called again -- otherwise a chip
    // that comes back but is genuinely dead would be reset every 3 s forever.
    // 当作刚刚收到过一个样本,这样必须再整整沉默 SILENCE_LIMIT_MS 才会再调一次 ——
    // 否则一颗「回来了但其实还是死的」芯片会被无限期地每 3 秒复位一次。
    last_print_ms = millis();
    stalled_at = "nothing yet";
  }
}

// The only thing that notices the loop has stopped producing lines. Called once
// per poll, before the branches that can return early.
// 唯一会发现「循环不再出数据」的地方。每次轮询调一次,在那些会提前返回的分支之前。
void watchSilence() {
  unsigned long now = millis();
  if (now - last_print_ms < SILENCE_LIMIT_MS) { return; }

  if (now - last_stall_report_ms >= STALL_REPORT_INTERVAL_MS) {
    last_stall_report_ms = now;
    // `stalled_at` names the branch, which is the whole diagnosis: "no DRDY" is
    // a chip that answers and has nothing to give, "getStatus" is a bus that
    // stopped answering, and "getSensorData" is a chip that says a sample is
    // ready while reading it fails -- a bus fault wearing a healthy chip's
    // status register. See where `drdy_seen` used to be for why there is only
    // one message here now.
    // `stalled_at` 指明了是哪条分支,诊断全在这里:「没有 DRDY」是芯片会应答但没东西给,
    // 「getStatus」是总线不再应答,而「getSensorData」是芯片说样本好了、读它却失败 ——
    // 一个披着健康芯片状态寄存器外衣的总线故障。这里现在为什么只剩一条信息,
    // 见 `drdy_seen` 原来的位置。
    diag("# no samples for %lu ms, stalled at %s, i2c failures=%lu",
         now - last_print_ms, stalled_at, bus_error_count);
  }

  // A full second with no successful sample is the entire condition, and it is
  // recomputed from scratch every poll, so it cannot latch. The latch that used
  // to gate this could only ever fire at the moment recovery was needed.
  // 整整一秒没有成功样本就是全部条件,而且每轮都从零重算,闩不住。原来把关的那个闩锁,
  // 只会在需要自救的那一刻把自救关掉。
  if (now - last_recover_ms >= RECOVER_INTERVAL_MS) {
    last_recover_ms = now;
    recoverSensor();
  }
}

void setup() {
  Serial.begin(BAUD);
  delay(1000);          // let the USB serial settle, or the first lines are lost

  // Before the sensor, deliberately: the radio is already running when the chip
  // is initialised, so the initialisation happens under the same interrupt load
  // as the steady state rather than in a quiet world it will never see again.
  // 故意放在传感器之前:初始化芯片时射频已经在跑了,于是它是在和稳定状态相同的
  // 中断负载下初始化的,而不是在一个之后再也见不到的安静世界里。
  startWireless();

  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(I2C_CLOCK_HZ);
  Wire.setTimeOut(I2C_TIMEOUT_MS);

  softResetSensor();
  waitForSensor();
  applyRanges();

  next_poll_us = micros();
  last_print_ms = millis();
}

void loop() {
  unsigned long now = micros();
  // The cast handles micros() wrapping, which it does about every 71 minutes.
  // 用 (long) 相减是为了正确处理 micros() 大约 71 分钟一次的溢出。
  if ((long)(now - next_poll_us) < 0) {
    return;
  }
  // Realign rather than catch up: if the loop fell behind, skip the missed slot
  // instead of sprinting to make it up.
  // 重新对齐而不补发:落后了就跳过错过的时隙,不要猛跑追回来。
  next_poll_us = now + POLL_INTERVAL_US;

  // Every slot, and before the sensor is so much as looked at, so that a stalled
  // chip cannot also stop us hearing the host.
  // 每个时隙都做,而且放在看传感器之前 —— 芯片卡住不该顺带让我们听不见主机。
  pollHostHello();

  watchSilence();

  uint8_t status = 0;
  if (imu.getStatus(&status) != BMI2_OK) {
    bus_error_count++;
    stalled_at = "getStatus (bus stopped answering)";
    return;
  }
  if ((status & BMI2_DRDY_ACC) == 0) {
    stalled_at = "no DRDY (chip answers but never has a sample)";
    return;             // no new sample yet; printing would repeat the last one
  }

  if (imu.getSensorData() != BMI2_OK) {
    // Getting here means the chip has just said a sample is ready and reading
    // it failed. That is a fault on the bus, not a chip with nothing to give --
    // name it, because the two send whoever is reading this looking in
    // completely different places.
    // 走到这里说明芯片刚说了样本好了、而读它失败了。那是总线上的故障,不是没东西可给的
    // 芯片 —— 要说清楚,因为这两者会让读这条信息的人去完全不同的地方找。
    stalled_at = "getSensorData (chip reports a sample ready, the read fails)";
    return;
  }

  last_print_ms = millis();
  stalled_at = "nothing yet";

  // The exact shape Scripts/sensor_input.gd parses. Six numbers, in the order
  // accelerometer x,y,z then gyro x,y,z -- the labels carry no digits, which is
  // what lets the Godot parser take them positionally. Anything appended after
  // the sixth number is ignored by it, which is what makes room for S and T.
  // 就是 Scripts/sensor_input.gd 解析的那种形状。六个数字,顺序是加速度 x,y,z 然后陀螺仪 x,y,z
  // —— 标签里没有数字,Godot 那边的解析器才能按位置取。第六个数之后追加的东西它不读,
  // S 和 T 就是靠这一点塞进去的。
  char line[224];
  int n = snprintf(line, sizeof(line),
                   "Accel(g): %.3f, %.3f, %.3f | Gyro(deg/s): %.3f, %.3f, %.3f",
                   imu.data.accelX, imu.data.accelY, imu.data.accelZ,
                   imu.data.gyroX, imu.data.gyroY, imu.data.gyroZ);

  // Serial gets those six numbers and nothing else: at ~80 bytes a line and
  // 100 Hz it is already near what 115200 carries (see the bandwidth note at the
  // top), and everything the host does with the wire depends on lines not being
  // lost to an overrun.
  // 串口只拿这六个数:一行约 80 字节、100 Hz,已经接近 115200 的运力(见顶部带宽说明),
  // 而主机依赖串口做的每一件事,都建立在「行不会因为发不出去而丢」上面。
  Serial.write((const uint8_t *)line, n);
  Serial.write('\n');

  if (wirelessUp()) {
    // One format string, with the wireless copy built by appending to the serial
    // copy in place. Two separate snprintf calls would be two places for the
    // field order to drift, and a drifted field order is exactly the bug the
    // host's positional parser cannot detect.
    //
    // T is micros() here, at the moment the line is built, not when the sample
    // was read: the difference is a fixed ~1 ms (the I2C transaction), so it
    // cancels exactly in the intervals the host measures the sample rate from.
    // 一个格式串,无线那份是在串口那份后面就地追加出来的。写两个 snprintf 就是两处
    // 可能让字段顺序跑偏的地方,而字段顺序跑偏恰恰是主机那个「按位置取数」的解析器
    // 检测不出来的 bug。
    //
    // T 取的是**构造这一行时**的 micros(),不是读样本时:两者差一个固定的一毫秒出头
    // (I2C 传输),而主机据以量采样率的那些**间隔**里它正好抵消。
    int m = snprintf(line + n, sizeof(line) - n, " | S: %lu, T: %lu\n",
                     ++sample_seq, micros());
    udpSend(udpData, line, n + m, UDP_DATA_PORT);
  }
}
