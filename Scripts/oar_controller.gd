class_name OarController
extends Node
## Single-oar control algorithm: turns the ADXL345's three axes into
## "oar pose + stroke effort", then into the thrust / lateral force / yaw
## torque applied to the boat.
##
## --- 1. Sensor mounting orientation (the measured calibration) -----------
##   blade straight down        x ~ -10   y ~   0   z ~   0
##   held flat out to the left  x ~   0   y ~ -10   z ~   0
##   held flat out to the right x ~   0   y ~ +10   z ~   0
##   held flat forward          x ~   0   y ~   0   z ~ -10
##   swept flat back            x ~   0   y ~   0   z ~ +10
##
## Full scale is +/-10 (gravity, ~9.8, sits in that range): whichever axis
## points down reads full scale, and the axis perpendicular to it reads 0.
##
## At rest the reading is gravity projected onto the three axes, so those five
## poses really say "which axis points down". Dividing by the vector length
## (normalising) gives three components whose squares always sum to 1:
##
##   s_vert = -x / |a|   how vertical the oar is    1 = fully vertical
##   s_left = -y / |a|   how far out to the left    +1 = fully flat left
##   s_back =  z / |a|   how far swept aft          +1 = flat back, -1 = forward
##
## Normalise by |a| rather than by a fixed 9.81, for three reasons:
##   1. only the oar's direction matters, not the absolute magnitude;
##   2. no need to guess this chip's absolute scale (full scale +/-10, with
##      gravity landing around 9.8);
##   3. normalised, the components satisfy s_vert^2 + s_left^2 + s_back^2 = 1,
##      so the pose is a point on the unit sphere and the two angles come out
##      clean.
##
## The RATE is the one thing in this file that is NOT normalised, and section 2
## says why: the player reads direction off the raw Z axis, so that is the axis
## that gets differentiated. Everything above applies to s_vert / s_left /
## s_back only.
##
## --- 2. The four phases of a real single-oar stroke ----------------------
##   catch  ->  drive  ->  release  ->  recovery
## Only the drive has the blade in the water pushing aft, so only the drive
## produces thrust; the recovery is the empty return trip.
##
## The criterion is therefore "the Z axis is rising" -- the blade is sweeping
## aft. The player stated the rule in exactly those terms, on their own oar: if Z
## is rising the blade is going aft, if Z is falling it is going forward. That is
## what this file reads. `_w_fa` is the filtered rate of the RAW filtered Z axis,
## in m/s^2 per second, positive exactly when the blade is sweeping aft; when it
## goes negative the oar is on its way back to the catch and produces nothing at
## all. Without that gate the recovery reads as reverse rowing and the boat
## twitches back and forth on the spot.
##
## The pose above is normalised and the rate is not, and that split is worth
## stating because it is the one thing here that is easy to get wrong. The pose
## wanted to be scale-free; the rate is what the player reads off the axis, so
## the division came out of it. The two carry the same SIGN -- s_back = _fz/|a|
## and |a| is near constant across a stroke, so d(s_back)/dt and d(_fz)/dt rise
## and fall together -- so nothing about the DIRECTION changed when the division
## was removed. What changed is the scale: raw units are ten times the
## normalised ones, because this chip reads 10 for gravity. Every rate constant
## in the file moved with it, and the note at FULL_DRIVE_RATE says how.
##
## Section 2b generalises this to both directions at once, and to a threshold on
## sweep speed rather than on the sign alone: every gate in this file, forward
## and astern, is one of its two comparisons.
##
## Thrust is continuous, not one impulse per stroke: the blade pushes for as
## long as it is moving through the water, so the force is proportional to how
## fast the oar is sweeping rather than fired off by a once-per-stroke trigger.
## Sweep slowly and the push is gentle but unbroken; sweep hard and it is a
## single strong shove.
##
## --- 2b. Two thresholds, one per direction --------------------------------
## The whole model is two lines long. One number says how fast the blade is
## sweeping toward the bow, negative for aft; its SIGN picks the direction the
## boat is pushed and its SIZE against a threshold decides whether the push
## counts at all. Each direction has its own threshold, because they do not want
## the same value and no single number can be both:
##
##   sweep <= -sweep_need_aft   thrust FORWARD, force = climb(-sweep)
##   sweep >= +sweep_need_fwd   thrust ASTERN, force = climb( sweep)
##   in between                 a RECOVERY, nothing happens
##
## `sweep` is `_w_fa`, the filtered rate of the raw Z axis, and the units are
## m/s^2 per second. The shipped pair is 40 (forward) and 55 (backstroke). Both
## bars are on the same scale and are read the same way -- a bar is a sweep speed
## the player can feel out, which is the whole reason the gate and the force are
## computed from the same number.
##
## `sweep_need_aft` is the FORWARD bar: it is read by a blade sweeping aft, which
## is a drive. `sweep_need_fwd` is the BACKSTROKE bar: it is read by a blade
## sweeping toward the bow. Both are live knobs, and there are two ways to move
## either one. [ ] walk the forward bar and , . walk the backstroke bar, one fine
## step each; holding Shift makes either pair take the coarse step; 0 puts both
## back to the shipped pair; and the panel in the top right corner is draggable
## -- grab the notch you mean, left of centre for the forward bar and right of
## centre for the backstroke bar. The overlay line and the panel both put each
## bar next to the live sweep rate, because the recordings cannot settle these
## numbers and the player can.
##
## --- Why there are two, and what the single one cost -----------------------
## Until 2026-09-20 there was one number asked to do both jobs, and that was the
## player's own instruction. What follows is the measurement they then went and
## contradicted with the oar in their hands, which is why it is now two.
##
## Sweeping aft past the forward bar is the drive. Sweeping toward the bow past
## the backstroke bar is the backstroke, and what that bar has to keep out is the
## return leg of ordinary rowing. So one bar would have to sit below every real
## backstroke push and above every real forward recovery -- and under the
## statistic this file used to read, those two requirements crossed. The band the
## backstroke bar needs is empty there:
##
##                                        the slowest     the fastest
##                                        genuine push    ordinary recovery
##   the old normalised rate d(s_back)/dt     3.83             5.16
##   the raw rate d(_fz)/dt                  79.23            46.02
##
## Each row is the same two quantities read the same way: the slowest of the four
## recorded backstroke pushes, and the fastest ordinary recovery over the eight
## paced copies of the forward capture (1x to 10x, the ladder this file reads; the
## recovery peaks at 46.02 at the top of it). Under the old statistic the first is
## below the second, 3.83 under 5.16, so no single number could be both -- and the
## player hit exactly that bind with the oar in their hands. Reading the raw Z axis
## instead pulls the same two quantities apart, because dividing by |a| was
## compressing the fast sweeps, which is what the division was for: the band is now
## 33.2 wide and 55 sits inside it, clearing the fastest recovery by 19.5% and
## sitting 30.6% under the slowest genuine push. The slowest take is not even the
## same one in the two rows -- rev3 under the old rate, rev4 under this one.
##
##   over the 40 arc x pace cells, per-cell peak sweep rate
##   the aft sweep, which drives forward     median 105.51   fastest 232.89
##   the bow sweep, which is the recovery    median  62.82   fastest 143.22
##   in all 40 cells the drive outruns that cell's own recovery, but the ladder's
##   fastest recovery, 143.22, is still above its slowest drive, 36.39 -- the two
##   ranges overlap, so on the widest model of rowing the band closes again.
##
## Here is what those two bars cost over the ladder:
##
##   the most forward thrust any gate could pass   39.67
##   forward bar 40, backstroke bar 55 (shipped)   23.30   leak 12.35   net +10.95
##   both bars zero -- nothing refused at all      39.67   leak 46.20   net  -6.53
##   forward bar 0, backstroke bar 55              39.67   leak 12.35   net +27.32
##
## Read the last row carefully, because it is the forward bar's whole bill: on
## forward rowing alone the backstroke bar does all of the work, and dropping the
## forward bar to zero would hand back 16.37 of thrust and leak not one frame
## more, since a recovery is a BOW sweep and cannot reach a bar read by an AFT
## sweep. What the forward bar governs is the other channel -- a backstroke's
## return is an aft sweep too, and the forward bar is what stops that return from
## being paid as a drive. The ladder is all forward rowing, so it can only show
## that bar's cost; the takes below are where its benefit is.
##
## At the pacing the player actually uses, the same pair reads:
##
##   the real capture, at n times its own demo pace, bars 40 / 55
##      n   the drive peaks   the recovery peaks   thrust kept   thrust leaked
##      1       36.39              29.25              0.000          0.000
##      2       53.07              35.57              0.088          0.000
##      3       62.08              40.00              0.132          0.000
##      4       65.57              42.19              0.201          0.000
##      5       67.79              41.95              0.264          0.000
##      6       67.54              41.56              0.335          0.000
##      8       68.61              44.80              0.335          0.000
##     10       75.69              46.02              0.359          0.000
##
## The leak column is zero at every pace, and that is the whole point of the
## backstroke bar sitting at 55. The fastest recovery anywhere in those eight
## copies is 46.02, at the 10x pace, and 55 is above it.
## The kept column is not a shortfall -- it is the forward bar behaving as the
## floor it is, so a slow sweep is paid less than a fast one. At the capture's own
## demo pace the drive peaks at 36.39, under the bar, and nothing fires; twice
## that pace clears it. That was true of the pair this replaces as well.
##
## A backstroke rows backwards, so its PUSH is a bow sweep: it is the bow column
## the backstroke bar reads and the aft column the forward bar reads. Get those
## two the wrong way round and every take looks like a forward stroke. The four
## recorded takes, at the gate alone:
##
##   take   push (bow sweep)   return (aft sweep)     nets astern?
##   rev1       136.65              240.69                +0.003
##   rev2        96.29              185.16                -0.124
##   rev3        80.87              152.40                -0.358
##   rev4        79.23               76.58                -0.210
##
## All four fire. Only one of the four nets astern here, and that is the honest
## cost of this statistic: under the old normalised rate three of the four did.
## The reason is in the return column -- rev1's return sweeps back at 240.69,
## nearly twice its own push, and paying that return as a drive is the same act as
## paying an honest stroke. Section 2c is what recovers it: through the whole
## shipped chain, with the 0.1 s silence in, rev1 comes back to +0.287 and rev3 to
## -0.011.
##
## Split, each bar is pinned only by its own direction:
##
##   the FORWARD bar lives between 0 and the drive peak, 75.69 at the fastest the
##     player has been recorded rowing. Higher and ordinary rowing stops firing;
##     lower and a backstroke's return is paid more generously as forward thrust.
##   the BACKSTROKE bar lives between the fastest ordinary recovery and the
##     slowest genuine push -- 46.02 to 79.23 as the recordings stand. Under
##     46.02 the return leg of ordinary rowing is paid as astern thrust; over
##     79.23 a backstroke as slow as rev4 never fires at all. That is a real band
##     rather than a crossing, and widening it is what a fresh backstroke
##     recording would buy. Both ends are read off the eight paced copies and the
##     four takes; the arc ladder's amplified strokes push the recovery up to
##     143.22 and close the band again there.
##
## The shipped pair is 40 / 55. 55 is set by the recovery, and there is nothing to
## negotiate about it; 40 sits just above a crawl, and the note at
## SWEEP_NEED_AFT_RESET says why that is where it is rather than lower. At the gate
## alone rev3 stays forward net at every usable setting, because its return is an
## aft sweep at 152.40 -- faster than its own push is a bow sweep -- and refusing
## that return would take a forward bar above 152.40, which is higher than the
## median drive of the entire ladder (105.51). No pair of bars reaches it; section
## 2c is, somehow, the only thing in this file that does.
##
## --- Why the gate reads the same number the force does --------------------
## The gate and the force are both computed from `_w_fa`, the filtered rate of the
## raw Z axis, so they can never disagree about what the blade is doing. That is
## not a stylistic choice. An earlier version decided WHETHER from a 0.25 s window
## of net travel and HOW MUCH from the filtered rate, and the two disagreed on a
## large share of every stroke: a sweep with real speed in it gets refused because
## its window average has not caught up yet, and a sweep that has already turned
## gets paid because the average has not turned either.
##
## The window average of an axis is a duller number than the instant filter, so at
## the same bar the two designs are not the same gate -- which is where the old
## version of this comparison went wrong, because it read each design at its own
## pair and the two pairs were not comparable. Here is the mismatch measured
## directly: same rows, same force law, same bars, only the gate's statistic
## differs, so every frame they differ on would have been paid differently by the
## same force.
##
##   arc x pace      thrust paid     thrust paid    refused    invented
##                   on the rate    on a window    by window  by window
##   1.00 x  2x          0.088          0.000         0.088      0.000
##   1.00 x  4x          0.201          0.000         0.201      0.000
##   1.00 x  8x          0.335          0.000         0.335      0.000
##   1.00 x 10x          0.359          0.000         0.359      0.000
##   1.50 x  1x          0.155          0.013         0.155      0.013
##   2.00 x  1x          0.393          0.213         0.217      0.037
##   3.00 x  1x          0.706          0.267         0.476      0.037
##
## At the same bar the window refuses essentially all of the drive, so its bar
## would have to come down to about 15 where this one is 40 before it passed the
## same amount -- and a bar that means 15 in window units is not a sweep speed
## anywhere else, which is the point. It stops being a number the player can feel
## out with the oar in their hands.
##
## At that matched drive the window is not even the better gate, and it is worth
## showing why rather than asserting it. Same forward thrust, 23.31 either way:
##
##   the ladder, gate alone        forward   astern   the four takes, net
##   both sides on the rate         23.303   12.351   +0.003 -0.124 -0.358 -0.210
##   gate on a window, bar 15       23.306    3.664   -0.452 -0.476 -0.361 -0.226
##
## The window leaks far less over the ladder and it is bought by not paying the
## backstrokes at all: all four takes go net FORWARD, because 55 in window units
## is a much stricter bar than 55 in rate units and the real pushes stop clearing
## it. A cleaner ladder and no backstroke channel is not a trade worth making.
##
## --- The one thing this model cannot do, stated plainly -------------------
## A backstroke's return and an ordinary forward drive are the same motion to an
## accelerometer with no water to touch. Two bars separate the two PLACES a bar
## can sit; they do not separate the two motions, and no pair of them makes rev3
## net astern on its own. rev3's return is a faster aft sweep than its push is a
## bow sweep -- 152.40 against 80.87 -- so its return IS a forward drive as far as
## this rig can tell, and paying it forward is the same act as paying an honest
## stroke. Refusing that return would take a forward bar above 152.40, which is
## higher than the median drive of the whole ladder (105.51): the bar that catches
## rev3's return catches ordinary rowing with it. At the gate alone rev3 nets
## forward at every setting a stroke could use.
##
## What does reach it is not a statistic but a time. The return's forward
## mispayment begins a few frames after the push closes -- rev3's runs from frame
## 30, with the close at 26 -- so the silence of section 2c lands on it while the
## astern burst, which arrives BEFORE the close, is untouched by any length of it.
## rev3's forward payment falls 0.536, 0.189, 0.037, 0.000 as the silence goes
## 0.00, 0.10, 0.15, 0.20 while its astern payment stays at 0.179 throughout, and
## that is the whole of why rev3 nets +0.142 astern at 0.15 s -- the first version
## of this file in which it has ever netted astern at all.
##
## What the split does buy is that the trade is no longer one-for-one. A single
## bar forced both directions onto the same position, so protecting forward rowing
## and letting a slow backstroke fire were the same decision. Two bars make them
## two decisions, and the measurements above say which one each bar is really
## making.
##
## --- 2c. The silence after a stroke ----------------------------------------
## The player's diagnosis, and it is the right one: the leak is not spread evenly
## through the recovery. It comes in short bursts, and a burst is the oar's own
## momentum reversing for an instant at the end of a stroke.
##
## Every table in this section is read at the shipped pair, fwd bar 40 / back bar
## 55, because the back bar is what decides how much of the leak exists at all.
##
##   40 forward-rowing cells, fwd bar 40 / back bar 55
##   12.351 astern in 119 bursts
##   burst length   under 0.05 s   29.7% of the impulse
##                  0.05 .. 0.10   49.4%
##                  0.10 .. 0.15   18.3%
##                  0.15 .. 0.20    2.5%
##                  over  0.20 s    0.0%
##
## Every frame of the leak belongs to a burst under a fifth of a second, and four
## fifths of it to bursts under a tenth. So STROKE_COOLDOWN stops paying for the
## oar for a fixed time after a stroke closes: the gate still runs and the panel
## still shows the verdict, and the verdict is simply not honoured.
##
## The player's second instruction was that a close is a threshold crossing in
## EITHER direction. That is what the code now does: the bookkeeping reads
## push_power, the thrust actually being paid, rather than drive_power, which is
## only the forward half of it. Reading the forward half alone made the silence
## one-sided: only a forward push could close a stroke, so a backstroke could
## never arm a silence of its own. Over the whole 40-cell ladder the one-sided rule
## closes 116 strokes and the two-sided rule 186; over the four real takes, 6
## against 12. Every one of the extra closes is a backstroke's. Any excursion past
## the bar now ends the same way, and a backstroke opens and closes a stroke on
## exactly the terms a forward push does.
##
## Whether that costs anything depends on whether a direction's own return can
## reach a bar at all -- and which bar. A forward stroke's return is a BOW sweep,
## so the bar it could reach is the backstroke one, 55; on the player's own capture
## the fastest bow sweep anywhere in it is 46.02, at the 10x pace, 8.98 under the
## bar. So on every recording the player has actually rowed the two-sided rule is
## not merely cheap, it is free -- the eight paced copies of the capture come out
## bit-identical either way:
##
##   the eight paced copies of the real capture      fwd only      either
##     forward thrust                                   1.699       1.699
##     astern leak                                      0.000       0.000
##   the four real takes, net        -0.242 -0.079 -0.358 -0.181
##                                   +0.287 -0.289 -0.011 -0.015
##   the 40-cell arc ladder
##     forward thrust                                  21.894      20.128
##     astern leak                                      7.827       6.901
##     net                                            +14.066     +13.227
##
## It costs where the capture cannot reach: the ladder's amplified arcs push a
## recovery past 55, and there the silence it arms mutes forward frames -- 8% of
## the ladder's forward thrust. It BUYS on the real backstrokes, and that is the
## whole point of the rule: a backstroke's push is a bow sweep past 55, so reading
## the paid power lets that push close its own stroke and run the silence that
## stops its return being paid forward. At the shipped 0.10 s, the one-sided rule
## leaves all four takes netting forward (-0.242, -0.079, -0.358, -0.181); the
## two-sided rule takes rev1 properly astern (+0.287) and pulls rev3 and rev4 back
## to -0.011 and -0.015, near enough flat, at the cost of rev2, which deepens from
## -0.079 to -0.289. Three takes improve and one gets worse. The 8% is paid on a
## ladder built out of stretched copies of a recording; the four takes are the
## player's own backstrokes.
##
## How long after a stroke closes each leaking frame falls, weighted by the impulse
## it pays and measured against the closes the GATE ALONE makes -- that is the
## material a silence has to work with. A silence of length L reaches the rows
## below L:
##
##   0.00 .. 0.05 s   11.4%      0.15 .. 0.20 s   12.9%
##   0.05 .. 0.10 s   33.8%      0.20 .. 0.30 s    8.6%
##   0.10 .. 0.15 s   27.6%      over 0.30 s       5.7%
##
## 45% of the leak sits within a tenth of a second of a close and 73% within
## 0.15 s. The shipped 0.10 s can therefore reach a little under half of it
## directly, and takes back 44.1% -- the small shortfall and the tail running past
## the window are the same thing, and are also why the table below is not a
## straight line down to zero: the last 6% is more than 0.30 s from any close and
## no length of silence reaches it at all.
##
## Those are the ladder's numbers. The four real takes behave differently, and it
## is worth knowing which half of a take the silence is actually working on. On
## every one of them the astern burst arrives BEFORE the stroke closes, so no
## silence armed by a close can reach it -- rev3's astern payment is 0.179 at every
## length from 0.00 to 0.20 s, unmoved. What the silence reaches is the take's
## RETURN, whose forward mispayment starts a few frames after the close, and that
## is where all of the take's improvement comes from: rev3's forward payment falls
## 0.536, 0.189, 0.037, 0.000 as the silence lengthens, and that alone is what
## turns its -0.358 into +0.142.
##
##   cooldown  forward  astern   net      removed   rev1     rev2     rev3     rev4
##   0.00      23.303   12.351  +10.952    --      +0.003   -0.124   -0.358   -0.210
##   0.05      22.382   10.473  +11.908   15.2%    +0.091   -0.159   -0.305   -0.147
##   0.10      20.128    6.901  +13.227   44.1%    +0.287   -0.289   -0.011   -0.015
##   0.15      20.242    5.016  +15.226   59.4%    +0.312   -0.375   +0.142   +0.096
##   0.20      20.275    3.442  +16.833   72.1%    +0.543   -0.350   +0.179   +0.079
##   0.25      19.003    3.271  +15.732   73.5%    -0.601   -0.054   +0.179   +0.080
##   0.30      17.802    2.917  +14.885   76.4%    -0.355   +0.460   +0.179   +0.112
##
## The last four columns are each backstroke take's NET -- its astern thrust minus
## the forward thrust it also pays. Positive means the boat really went backwards.
## rev3 is the take the old statistic could not pay at all, and it is the clearest
## single thing the re-derivation bought. Its push is a bow sweep of 80.87 and the
## 55 bar fires on it -- where under the normalised rate that same push peaked at
## 3.83 against a bar of 4.0 and never fired once, so rev3 netted forward at every
## setting of the old file. It still ends up forward at the gate alone (-0.358)
## because its return is a faster aft sweep than its push is a bow sweep, 152.40
## against the ladder's median drive of 105.51, so the forward payment it collects
## is large. What stops that is the silence rather than the bar: at 0.15 s rev3
## nets +0.142 astern for the first time in any version of this file. (All four
## takes' pushes clear 55 now -- 136.65, 96.29, 80.87, 79.23 -- so the bar is not
## what separates them. Nothing about the bar does.)
##
## The shipped 0.1 s gives up 13.6% of the ladder's drive and takes back 44.1% of
## the leak, a net gain of +2.275 -- 20.8% on top of the +10.952 the gate was
## getting on its own.
##
## What the table does NOT show is the shipped value being the best row, and that
## is worth stating rather than leaving for whoever reads the file next. Between
## 0.10 and 0.20 the ladder's forward thrust is flat -- 20.128, 20.242, 20.275 --
## while the leak falls 6.901 to 5.016 to 3.442, and three of the four takes net
## astern at 0.15 against one at 0.10. The forward cost is essentially all paid by
## 0.10 and does not grow again until 0.25, where the drive finally steps down and
## rev1, the take that nets astern best at 0.15, flips negative. So the usable
## stretch is 0.10 to 0.20 and 0.10 sits at its conservative end. Where on that
## line to sit is the player's call, which is why the readout shows COOLDOWN and
## the seconds still on it while it runs.
##
## Why not refuse short bursts instead, which would take 79% of the leak against
## this 44%? Because a real backstroke pays in bursts the same length as the false
## ones -- the table above says so directly, and so does the fact that the drive
## arrives in the same short runs. A rule "a burst shorter than 0.10 s pays
## nothing" removes 79.2% of the leak and costs 42.6% of the ladder's drive, where
## the 0.10 s silence removes 44.1% for 13.6%; at 0.15 s the burst rule removes
## 97.5% and costs 81.0%. Duration does not separate the two; only the stroke's own
## phase does, and the cooldown is that phase.
##
## --- 2b. 两个门槛,一个方向一个 ------------------------------------------
## 整个模型只有两行。一个数表示桨正以多快的速度向船头方向扫(向后为负);它的「符号」
## 决定船被推向哪边,它的「大小」和一个门槛比较,决定这一下算不算数。两个方向各有一个
## 门槛,因为它们想要的值不一样,而一个数不可能同时是两个值:
##
##   扫速 <= -sweep_need_aft   船向前,力度 = climb(-扫速)
##   扫速 >= +sweep_need_fwd   船向后,力度 = climb( 扫速)
##   两者之间                  回桨,什么也不发生
##
## `sweep` 就是 `_w_fa`,原始 Z 轴的滤波速率,单位是 m/s^2 每秒。出厂这一对是 40(前划)
## 和 55(后滑)。两个门槛同一量纲、同一种读法 —— 一个门槛就是一个玩家能用桨「摸出来」的
## 扫速,这正是门槛和力度必须从同一个数算出来的原因。
##
## `sweep_need_aft` 是「前划门槛」:读它的是向后扫的桨,那是动力段。`sweep_need_fwd`
## 是「后滑门槛」:读它的是向船头扫的桨。两个都是活的,各有两种调法:[ ] 走前划门槛,
## , . 走后滑门槛,一下一个细步;按住 Shift 任一对都走粗步;0 把两个都放回出厂值;
## 右上角的面板可以直接用鼠标拖 —— 抓你想改的那个缺口,中点左边是前划门槛、右边是后滑
## 门槛。角标和面板都把两个门槛摆在实时扫速旁边,因为录像决定不了这两个数,玩家能。
##
## --- 为什么会有两个,以及当初那一个的代价 ---------------------------------
## 在 2026-09-20 之前只有一个数干这两件事,那是玩家自己的要求。下面这些测量,就是他们
## 随后握着桨推翻掉的东西 —— 也是现在有两个的原因。
##
## 向后扫过门槛就是前划。向船头扫过门槛就是后划,它要挡住的是普通划水的回桨。所以后滑
## 门槛得低于每一次真实后划的动力段、又高于每一次真实前划的回桨段 —— 而在旧的统计量下,
## 这两个要求是交叉的,后滑门槛需要的区间在那里是空的:
##
##                                         最慢的一次    最快的一次
##                                         真实后划推力  普通回桨
##   旧的归一化速率 d(s_back)/dt               3.83          5.16
##   原始速率       d(_fz)/dt                 79.23         46.02
##
## 两行读的是同一对量、用同一套读法:四次实录里最慢的一记后划推力,和前划录像八份节奏副本
## (1 倍到 10 倍,本文件读的这条阶梯;回桨峰值在顶端是 46.02)里最快的一次回桨。在旧的
## 统计量下前者低于后者 —— 3.83 在 5.16 下面 —— 所以没有任何一个数能同时是两个,玩家
## 握着桨撞上的就是这个死结。改成直接读原始 Z 轴之后,同样这一对量被拉开了,因为「除以 |a|」
## 本来就在压缩快扫(那正是那次除法的用途):现在这条带子宽 33.2,55 落在里面,比最快的一次
## 回桨高 19.5%,比最慢的一次真实推力低 30.6%。两行里最慢的那一记甚至不是同一次 ——
## 旧速率下是 rev3,这里换成 rev4。
##
##   40 个「弧长 x 节奏」组合,每格的最大扫速
##   向后扫 = 动力段   中位 105.51   最快 232.89
##   向前扫 = 回桨段   中位  62.82   最快 143.22
##   40 格里每一格的动力段都比它自己的回桨快;但 40 格里最快的回桨(143.22)仍然高过
##   最慢的动力段(36.39)—— 两段互相穿插,所以在最宽的压力模型上这条带子又合上了。
##
## 这两个门槛在阶梯上的代价是:
##
##   任何门都放得过的前向冲量上限        39.67
##   前划门槛 40,后滑门槛 55(出厂)      23.30   漏 12.35   净 +10.95
##   两个门槛都是 0 —— 什么都不拦        39.67   漏 46.20   净  -6.53
##   前划门槛 0,后滑门槛 55             39.67   漏 12.35   净 +27.32
##
## 最后一行要看仔细,那是前划门槛的全部账单:只在前划这件事上,活儿全是后滑门槛干的,把
## 前划门槛降到 0 会还回来 16.37 的前向推力,而且一帧都不会多漏 —— 因为回桨是向船头扫的,
## 碰不到一个由向后扫来读的门槛。前划门槛管的是另一条通道:一次后划的归位也是向后扫,而
## 前划门槛正是用来拦住「这次归位被当前划付出去」的。阶梯全是前划,所以它只能显出这个门槛
## 的成本;它的收益在下面四次实录里。
##
## 在玩家真正用的节奏上,同一对门槛读出来是:
##
##   真实录像,按它自己的示范速度的 n 倍,门槛 40 / 55
##      n   动力段峰值   回桨段峰值   留下的推力   漏掉的倒退
##      1       36.39        29.25        0.000        0.000
##      2       53.07        35.57        0.088        0.000
##      3       62.08        40.00        0.132        0.000
##      4       65.57        42.19        0.201        0.000
##      5       67.79        41.95        0.264        0.000
##      6       67.54        41.56        0.335        0.000
##      8       68.61        44.80        0.335        0.000
##     10       75.69        46.02        0.359        0.000
##
## 漏掉那一列在每个节奏上都是零,这正是后滑门槛落在 55 的意义。这八份副本里最快的回桨
## 是 46.02(十倍节奏处),而 55 在它上面。「留下的推力」那一列不是缺口 —— 那是前划
## 门槛在当它该当的「地板」:扫得慢就付得少。在录像自己的示范节奏上动力段峰值 36.39,在
## 门槛下面,什么也不触发;两倍节奏就过去了。这一点在它替换掉的那一对门槛上也一样。
##
## 后划是倒着划的,所以它的「动力段」是向船头扫:后滑门槛读的是向前那一列,前划门槛读的
## 是向后那一列。这两个搞反,每一次后划看起来都会像一次前划。四次实录,只看门槛:
##
##   实录   动力段(向船头扫)   归位段(向后扫)   净向后?
##   rev1        136.65              240.69        +0.003
##   rev2         96.29              185.16        -0.124
##   rev3         80.87              152.40        -0.358
##   rev4         79.23               76.58        -0.210
##
## 四次全部触发。这里四次里只有一次净向后,而这是这个统计量要付的诚实代价:在旧的归一化
## 速率下四次里有三次净向后。原因在归位那一列 —— rev1 的归位向后扫到 240.69,差不多是它
## 自己动力段的两倍,而把这次归位当前划付出去,和付一次老老实实的划水是同一个动作。2c 那
## 一节把它捞回来一部分:跑完整条出厂链路、把 0.1 秒的静默算进去,rev1 回到 +0.287、
## rev3 回到 -0.011。
##
## 拆开之后,每个门槛只被自己那一边顶住:
##
##   前划门槛活动在 0 到动力段峰值之间(玩家有记录的最快一次是 75.69)。再高,普通前划就
##   触发不到了;再低,一次后划的归位会被更慷慨地当前向推力付出去。
##   后滑门槛活动在最快的普通回桨和最慢的一次真实推力之间 —— 按现有录像就是 46.02 到
##   79.23。低于 46.02,普通划水的回桨会被当成后退推力付出去;高于 79.23,像 rev4 这么慢
##   的后划永远不触发。这是一条真实的带子而不是一个交叉点,能把它撑宽的是一份新的后划录像。
##   这两个端点分别读自八份节奏副本和四次实录;阶梯里那些放大过的弧长会把回桨顶到 143.22,
##   带子在那里又合上。
##
## 出厂这一对是 40 / 55。55 由回桨决定,没什么可商量的;40 比爬行稍高一点,为什么在那儿而
## 不更低,SWEEP_NEED_AFT_RESET 那一段写了。只看门槛,rev3 在任何能用的设置上都净向前,因为
## 它的归位向后扫到 152.40 —— 比它自己的动力段(向船头扫 80.87)还快 —— 而要拦住这次归位,
## 前划门槛得高过 152.40,那比整条阶梯动力段的中位数(105.51)还高。没有任何一对门槛够得着
## 它;能把这件事办成的,整个文件里只有 2c。
##
## --- 为什么门槛和力度读同一个数 ------------------------------------------
## 门槛和力度都从 `_w_fa`(原始 Z 轴的滤波速率)算出来,所以两者永远不会对「桨在干什么」
## 有分歧。这不是风格选择。早先的版本用 0.25 秒窗口内的净位移做门槛、却用滤波速率算力度,
## 而每一桨的头尾两者都在打架:明明有速度的一扫会因为窗口均值还没跟上而被拒,已经掉头的一扫
## 会因为均值也还没掉头而被付出去。
##
## 一根轴的窗口均值比瞬时滤波钝得多,所以同一个门槛数值在两版里根本不是同一个门 —— 早先
## 那版比较就错在这里,它让两版各按各自的门槛读,而那两对数字根本不可比。下面是直接量出来的
## 分歧:同样的行、同样的力度公式、同样的门槛,只有门槛用的统计量不同,所以两者不一致的
## 每一帧,同一个力度都会付出不同的值。
##
##   弧长 x 节奏     按速率付    按窗口付    窗口拒绝的    窗口凭空付的
##   1.00 x  2x       0.088       0.000       0.088         0.000
##   1.00 x  4x       0.201       0.000       0.201         0.000
##   1.00 x  8x       0.335       0.000       0.335         0.000
##   1.00 x 10x       0.359       0.000       0.359         0.000
##   1.50 x  1x       0.155       0.013       0.155         0.013
##   2.00 x  1x       0.393       0.213       0.217         0.037
##   3.00 x  1x       0.706       0.267       0.476         0.037
##
## 同一个门槛下,窗口几乎把动力段全拒了,所以要让窗口放行同样多的推力,它的门槛得降到 15
## 左右,而这里用的是 40 —— 而一个「窗口单位下的 15」在别处不代表任何扫速,这正是问题所在:
## 它不再是玩家能用桨摸出来的那个数了。
##
## 就算把力度对齐了,窗口也不是更好的门,这一点值得摆出来而不是嘴上说说。同样是 23.31 的
## 前向推力:
##
##   阶梯,只看门槛            前向      倒退     四次实录的净值
##   两侧都用速率             23.303   12.351   +0.003 -0.124 -0.358 -0.210
##   门槛用窗口,阈值 15       23.306    3.664   -0.452 -0.476 -0.361 -0.226
##
## 窗口在阶梯上漏得少得多,换来的是四次实录全部净向前 —— 因为在窗口的单位下 55 比在速率的
## 单位下严得多,真实的动力段够不到它了。把阶梯擦干净、代价是把后划通道整条关掉,这笔交易
## 不值得做。
##
## --- 这个模型做不到的一件事,明说 ----------------------------------------
## 在没有水的加速度计眼里,后划的归位和普通前划的动力段是同一个动作。两个门槛分开的是
## 「门槛能待的位置」,不是「这两个动作」,也没有任何一对门槛能让 rev3 靠自己就净向后。
## rev3 的归位比它自己的动力段扫得还快 —— 152.40 对 80.87 —— 所以它的归位在这套判定眼里
## 就是一次前向动力,把它当前划付出去和付一次老老实实的划水是同一个动作。要拦住这次归位,
## 前划门槛得高过 152.40,那比整条阶梯动力段的中位数(105.51)还高:能接住 rev3 归位的门槛
## 同时也接住了普通前划。只看门槛,rev3 在任何能用的设置上都净向前。
##
## 真正够得着它的不是某个统计量,而是一个「时间」。这次归位被当前划付出去的那一段,是从动力
## 段收桨之后几帧才开始的 —— rev3 收桨在第 26 帧、误付从第 30 帧起 —— 所以 2c 那段静默正好
## 盖在它上面;而它那一小簇真正的倒退发生在收桨之前,任何长度的静默都碰不到。rev3 的前向付出
## 随静默长度是 0.536、0.189、0.037、0.000,而它的倒退付出全程都是 0.179,这就是为什么 rev3
## 在 0.15 秒上净向后 +0.142 —— 这个文件有史以来第一次。
##
## 拆开真正买到的是:这个取舍不再是「一换一」。一个门槛把两个方向钉在同一个位置上,于是
## 「护住前划」和「让慢后划能触发」是同一个决定。两个门槛把它们变成两个决定,而上面的
## 实测说清楚了每个门槛真正在做的是哪个决定。
##
## --- 2c. 一桨结束之后的静默 ----------------------------------------------
## 玩家的判断是对的,而且切中要害:漏出去的推力并不是均匀铺在回桨里的,它是一簇一簇的,
## 每一簇就是收桨瞬间桨自身的动量反了一下。
##
## 本节所有表格都按出厂那一对读取:前划门槛 40 / 后滑门槛 55 —— 漏出去多少,本来就是由
## 后滑门槛决定的。
##
##   40 个前划格,前划门槛 40 / 后滑门槛 55
##   共 12.351 的倒退冲量,分成 119 簇
##   簇的长度   不足 0.05 秒   占冲量 29.7%
##              0.05 ~ 0.10    49.4%
##              0.10 ~ 0.15    18.3%
##              0.15 ~ 0.20     2.5%
##              超过 0.20 秒     0.0%
##
## 漏出去的每一帧都属于一个短于五分之一秒的簇,其中五分之四属于短于十分之一秒的簇。
## 于是 STROKE_COOLDOWN:一桨结束之后的一段时间里不再为桨的运动付力。判定照跑,面板照
## 显示结论,只是结论不兑现。
##
## 玩家的第二条要求是:收桨就是「越过门槛」这个事件本身,方向不分正反。这也是现在代码的
## 行为:记账读的是 push_power —— 此刻真正在出的那份力,而不是只占一半的 drive_power。只读
## 前向那一半,静默就是单边的:只有前向的力能收桨,后划永远开不出属于自己的那段静默。整个
## 40 格阶梯上,单边规则收桨 116 次,双边收 186 次;四次实录是 6 次对 12 次。多出来的每一次
## 都来自后划。现在任何一次越过门槛的行程都以同样的方式结束,后划和前划一样会开一桨、收一桨。
##
## 这件事的代价,取决于某个方向自己的回桨快不快到能碰到门槛 —— 还要看是哪一个门槛。前划的
## 回桨是向船头扫,所以它够得到的那个门槛是后滑门槛 55;而在玩家自己的录像里,从头到尾最快的
## 向船头扫只有 46.02(十倍节奏处),比门槛低 8.98。所以玩家真正划过的每一份录像上,双边规则
## 不只是便宜,是白送的 —— 八份节奏副本两种规则下逐位相同:
##
##   实录的八份节奏副本             只按前向计   两个方向都计
##     前向冲量                        1.699        1.699
##     漏掉的倒退                      0.000        0.000
##   四次实录的净值                   -0.242 -0.079 -0.358 -0.181
##                                    +0.287 -0.289 -0.011 -0.015
##   40 格弧长阶梯
##     前向推力                       21.894       20.128
##     漏掉的倒退                      7.827        6.901
##     净值                          +14.066      +13.227
##
## 要花钱的地方是录像够不到的地方:阶梯的放大弧长把回桨顶过了 55,它开出的静默就会吃掉前向
## 的帧 —— 阶梯 8% 的前向推力。但它在真实后划上是赚的,而这正是这条规则的意义:一次后划的
## 动力段是向船头扫过 55,于是读「真正在出的力」就允许那次动力段自己收起这一桨,并开出那段
## 不让归位被当前划付出去的静默。出厂的 0.10 秒下,单边规则让四次实录全部净向前(-0.242、
## -0.079、-0.358、-0.181);双边规则把 rev1 真正推到净向后(+0.287),把 rev3、rev4 拉回到
## -0.011 和 -0.015(基本持平),代价是 rev2 从 -0.079 加深到 -0.289。三次变好,一次变差。
## 那 8% 是花在一份「把录像拉伸复制出来的阶梯」上的;四次实录是玩家自己的后划。
##
## 这些帧分别落在收桨之后的多久 —— 按它本来要付的冲量加权,量的是「只看门槛」时收桨的时刻,
## 因为那才是一段静默要处理的原料。长度为 L 的静默够得到 L 以下的那些行:
##
##   0.00 ~ 0.05 秒   11.4%      0.15 ~ 0.20 秒   12.9%
##   0.05 ~ 0.10 秒   33.8%      0.20 ~ 0.30 秒    8.6%
##   0.10 ~ 0.15 秒   27.6%      超过 0.30 秒       5.7%
##
## 45% 的漏落在收桨之后十分之一秒以内,73% 落在 0.15 秒以内。所以出厂的 0.10 秒能直接够到
## 略少于一半,实际消掉 44.1% —— 那一小截出入和拖出窗口的尾巴是同一件事,也是下面那张表
## 不是一条直线归零的原因:最后那 6% 离任何一次收桨都超过 0.30 秒,没有任何长度的静默够得到它。
##
## 上面这些是阶梯的数。四次实录的行为不一样,而且值得知道静默到底在四次实录的哪一半上干活。
## 四次里那一小簇倒退全都发生在收桨之前,所以任何长度的静默都碰不到它 —— rev3 的倒退付出从
## 0.00 到 0.20 秒全程是 0.179,纹丝不动。静默够得到的是实录的「归位」,它的误付从收桨之后
## 几帧才开始,实录的全部改善都来自这里:rev3 的前向付出随静默长度是 0.536、0.189、0.037、
## 0.000,而把它从 -0.358 变成 +0.142 的就是这一件事。
##
##   冷却    前向推力  漏掉的倒退   净值     消掉     rev1     rev2     rev3     rev4
##   0.00    23.303   12.351   +10.952   --      +0.003   -0.124   -0.358   -0.210
##   0.05    22.382   10.473   +11.908   15.2%   +0.091   -0.159   -0.305   -0.147
##   0.10    20.128    6.901   +13.227   44.1%   +0.287   -0.289   -0.011   -0.015
##   0.15    20.242    5.016   +15.226   59.4%   +0.312   -0.375   +0.142   +0.096
##   0.20    20.275    3.442   +16.833   72.1%   +0.543   -0.350   +0.179   +0.079
##   0.25    19.003    3.271   +15.732   73.5%   -0.601   -0.054   +0.179   +0.080
##   0.30    17.802    2.917   +14.885   76.4%   -0.355   +0.460   +0.179   +0.112
##
## 右边四列是每次真实后划的净值 —— 它付出的倒退推力减去它同时付出的前向推力,为正说明船真的
## 往后走了。rev3 是旧统计量下一点也付不出来的那一次,也是这次重定单位买到的、最清楚的一件事:
## 它的动力段是向船头扫的 80.87,55 这个门槛在它上面会触发 —— 而在旧的归一化速率下,同一个
## 动力段峰值只有 3.83,对着 4.0 的门槛一次都没触发过,所以 rev3 在旧文件的任何设置上都净向前。
## 只看门槛时 rev3 仍然净向前(-0.358),因为它的归位比它的动力段扫得还快 —— 152.40,对着整条
## 阶梯动力段中位数 105.51 —— 所以它收上来的前向付出很大。拦住这件事的是静默而不是门槛:
## 0.15 秒时 rev3 净向后 +0.142,这是这个文件有史以来第一次。(现在四次实录的动力段全都越过
## 55 —— 136.65、96.29、80.87、79.23 —— 所以门槛根本不是把它们分开的那个东西。)
##
## 出厂的 0.1 秒:让出阶梯上 13.6% 的动力,换回 44.1% 的漏,净赚 +2.275 —— 在单靠门槛那
## +10.952 之上再多 20.8%。
##
## 这张表没有显示出来的是「出厂这个值不是最好的一行」,而这值得写下来,而不是留给下一个读
## 这个文件的人去发现。0.10 到 0.20 之间,阶梯的前向推力是平的 —— 20.128、20.242、20.275 ——
## 而漏从 6.901 一路降到 5.016、3.442,同时 0.15 秒上四次实录有三次净向后,0.10 秒上只有一次。
## 前向的代价基本上在 0.10 秒就付完了,直到 0.25 秒才再往下掉一档 —— 而那里 rev1(0.15 秒上
## 净向后最好的那一次)翻成了负的。所以能用的一段是 0.10 到 0.20,而 0.10 在这一段的保守那一
## 端。停在这条线的哪里由玩家决定,所以角标在冷却期间会显示 COOLDOWN 和剩余秒数。
##
## 那为什么不改成「太短的簇直接不给力」—— 那样能消掉 79%,是这个 44% 的近两倍?因为真实后划
## 的倒退和误触发的倒退一样长,上面那组数据直接说明了这一点,而动力段本身也是以同样的短簇形式
## 到来的。「短于 0.10 秒的簇不给力」能消掉 79.2% 的漏,代价是阶梯上 42.6% 的动力,而 0.10 秒
## 的静默只付 13.6%;到 0.15 秒,这条规则能消 97.5%,代价是 81.0%。时长分不开这两者,能分开
## 的只有它处在划桨周期的哪个相位 —— 冷却就是这个相位。
##
## --- 3. Splitting the force ----------------------------------------------
##   forward: sweep rate x how vertical the oar is (the more upright the oar,
##            the more of the force points straight ahead)
##   lateral: rate of sideways sweep (sweeping the blade left pushes the
##            boat right)
##   yaw:     a left-side stroke pushes at the blade, which sits left of the
##            centreline, so the bow swings right (physically correct)
##
## Every tunable lives in the "Tuning" block below.

# ------------------------------------------- Tuning / 调参 (中英对照) ------
## Low-pass time constant for the readings, in seconds. Larger = smoother but
## more sluggish.
## 读数低通滤波时间常数(秒)。越大越平稳、越迟钝。
const FILTER_TAU := 0.025
## Time constant for the rates. Differentiation amplifies noise, so this one
## is deliberately duller than the filter above.
## 变化率(角速度)的滤波时间常数。微分会放大噪声,所以这里压得更钝。
const RATE_TAU := 0.04
## Sweep rate, per second, that counts as a full-power stroke. The response is
## linear up to here rather than clipped at it, so a slow sweep gets a
## proportionally gentle push instead of being cut off.
## 每秒扫过多少算「满力」。到这之前是线性的、不是硬削顶的,
## 所以慢扫桨得到的是成比例的轻推,不会被一刀切掉。
## The unit is m/s^2 per second -- see the note on the rate below. The chip's own
## gravity reads 10 (the calibration sits at x ~ -10 with the blade down), so
## this is the old 2.6 /s of NORMALISED sweep multiplied by that 10, and the feel
## is meant to be unchanged from the version that shipped before 2026-09-20.
## 单位是 m/s²/秒,见下面关于速率那一段。芯片自己的重力读数就是 10
## (标定里桨叶朝下时 x ≈ -10),所以这个 26 等于旧版归一化扫速的 2.6/s 乘 10,
## 手感跟 2026-09-20 之前那版保持一致。
## 想让划水更灵敏就调小;想更难划满力就调大。
const FULL_DRIVE_RATE := 26.0
## Dead band on the sweep rate, per second. Anything smaller is treated as hand
## tremor and dropped, so an idle oar never nudges the boat. It has to stay
## well below a deliberate slow stroke, or slow rowing stops moving the boat.
## 扫速死区(每秒)。低于它的一律当手抖丢掉,桨放着不动时船不会自己跑。
## 必须明显小于「故意慢划」的速度,否则慢划就推不动船了。
## 0.15 是实测手感正常的那一版用的值;调小会让桨一有动静就出力。
## Rescaled with everything else: 1.5 m/s^2 per second.
## 跟其他速率常数一起按同样的比例放大到 1.5。
const DRIVE_DEADBAND := 1.5
## The oar lies nearly flat at both ends of the sweep (x -> 0 in the measured
## calibration), which would otherwise pinch the push down to nothing exactly
## where the stroke starts and ends. Clamping the verticality factor to this
## floor keeps the force smooth across the whole sweep instead of bulging in
## the middle.
## 扫到两端时桨几乎是平躺的(实测标定里 x → 0),不兜底的话正好在
## 一桨的头尾把推力掐到接近零、中间鼓起来。给个下限,全程就平顺了。
## 0.15 是实测手感正常的那一版用的值。
const MIN_VERTICAL := 0.15
## How far one tap of a tuning key moves a bar. Two sizes, because a bar is a
## speed the player feels out while rowing and no single step suits both jobs:
## 1.0 to feel out a value in play, 5.0 to cross the range without holding a key
## down for a minute. Both bars take the same two steps.
## 调门槛的按键一次动多少。两档,因为门槛是玩家边划边试出来的速度,没有哪个步长同时对
## 「试手感」和「走完范围」都合适:1 用来边划边试,5 用来不用按住键一分钟就能走完。
## 两个门槛用同一对步长。
const SWEEP_FINE_STEP := 1.0
const SWEEP_COARSE_STEP := 5.0
## The range either bar can be moved over. Zero is "every sweep of that direction
## counts", which is a legitimate thing to want and is also the setting the
## measurement above says pushes the boat net backwards -- reachable, not default.
##
## The top is a deliberately specific number. 200 is past every rate in the
## recordings by a wide margin -- the fastest aft sweep anywhere is the hard air
## swing at 268, the fastest bow sweep is its own return at 321 -- so a bar at the
## top of the range lets nothing through and the channel is simply off. What the
## range is really sized for is the two shipped bars, 40 and 55, sitting in the
## middle of it with room either side to feel out a value in play.
## 两个门槛可以走的范围。0 是「这个方向的每一扫都算」,这是合理需求,也是上面实测里
## 净向后的一档 —— 够得着,但不是默认。
##
## 上限是个特意选的数:200 远远超过实录里所有的速率 —— 全场最快的向后扫是空中猛挥的
## 268,最快的向前扫是它自己的回程 321 —— 所以门槛拉到顶就是把这个通道关掉。这个范围主要
## 是为出厂的两个门槛(40 和 55)留的:它们落在中段,两边都还有地方边划边试。
const SWEEP_NEED_MIN := 0.0
const SWEEP_NEED_MAX := 200.0
## Where "reset" puts the two bars back to. Both vars below are initialised from
## these, so the shipped tuning is written down exactly once -- otherwise the
## reset key and the defaults drift apart the first time one of them is edited.
## 「重置」把两个门槛放回的值。下面两个 var 就用它们初始化,出厂调参只写一遍 ——
## 否则重置键和默认值会在第一次改动其中一个的时候悄悄对不上。
##
## FORWARD, 40. It sits just above a crawl: the player's own recorded forward
## stroke peaks at 36.4 at its own pace, 53.1 at twice that, 65.6 at four times --
## so 40 asks for about a real stroke and no more. Its job is not to keep anything
## out, because the recovery is a BOW sweep and cannot reach a bar read by an AFT
## sweep at all. Its job is to be low enough that ordinary rowing fires.
##
## 前划门槛 40。它就卡在「蠕动」之上:玩家自己那段实录按原速峰值 36.4,两倍速 53.1,
## 四倍速 65.6 —— 所以 40 大约就是要一记真划,不再多要。它不负责挡住什么,因为回桨是
## 向船头扫,根本够不到这个读「向后扫」的门槛;它的职责是低到让普通划水能触发。
const SWEEP_NEED_AFT_RESET := 40.0
## BACKSTROKE, 55, and this band is wide now. The player's own recovery peaks at
## 42.2 four times the recorded pace, 44.8 at eight, 46.0 at ten -- and it never
## reaches 55 at ANY decimation of the capture: over every pace from 1x to 37x the
## highest is 52.5, at 17x. The slowest of the four recorded backstroke pushes is
## 79.2, which clears 55 by 44%. Over the whole real capture the astern leak is
## exactly 0.000 at every pace the file's own ladder reads, and all four takes
## still fire. Under the old normalised statistic these two requirements crossed
## and no bar could serve both; reading the raw rate puts them 33.2 apart.
##
## 后滑门槛 55,而且这条带子现在是宽的。玩家自己的回桨在四倍速下峰值 42.2、八倍速 44.8、
## 十倍速 46.0 —— 而且把录像按任何倍率抽稀都够不到 55:从 1 倍到 37 倍里最高的一次是
## 17 倍速的 52.5。四次实录后划里最慢的那一记推力是 79.2,超出门槛 44%。整段真实前划录在
## 本文件这条阶梯读的每一个节奏上,漏过去的向后推力**恰好是 0.000**,同时四次后划全都还能
## 触发。在旧的归一化统计量下这两个要求是交叉的、没有门槛能同时满足;换成原始速率之后,
## 它们之间隔了 33.2。
const SWEEP_NEED_FWD_RESET := 55.0
## Sweep rate that counts as a stroke, one bar per direction. Past the forward
## bar, an aft sweep drives the boat FORWARD; past the backstroke bar, a sweep
## toward the bow drives it ASTERN; anything slower is a recovery and pays
## nothing. Both are live: the keys and the draggable panel, listed at _input.
##
## Two numbers, and the whole argument for that is at the top of the file. The
## short version: the forward bar is pinned from below by the pace of ordinary
## rowing, and the backstroke bar from above by the return leg of a forward
## stroke, and a single bar forced both directions onto one of them.
##
## 多快才算「划了一桨」的门槛速率,一个方向一个。越过前划门槛,向后扫推船向前;越过
## 后滑门槛,向船头扫推船向后;慢于门槛算回桨,什么都不给。两个都是活的:按键和可拖动的
## 面板,都在 _input 那里列着。
##
## 为什么是两个数,完整的论证在文件开头。短版本:前划门槛被普通划水的节奏从下面顶住,
## 后滑门槛被一次前划的回桨段从上面顶住,而单个门槛等于强行让两个方向共用其中一个。
var sweep_need_aft := SWEEP_NEED_AFT_RESET
var sweep_need_fwd := SWEEP_NEED_FWD_RESET
## Dead band on the lateral rate, and it is a much bigger number than it used to
## be for the same reason every other rate here is: it is the old 0.15 on
## normalised sweep multiplied by the chip's 10. In raw units 1.5 m/s^2 per
## second is a slow drift sideways, which is what it was always meant to be.
## 侧向速率的死区。它比过去大得多,原因和这里其他每个速率常数一样:它就是旧的归一化速率
## 上的 0.15 乘以芯片的 10。换成原始单位之后,1.5 m/s²/秒 就是一次很慢的横向漂移,
## 这正是它一开始想表达的意思。
const LATERAL_DEADBAND := 1.5
## Lateral force gain. A sideways sweep was never going to shove the boat
## hard, so this stays small. Scaled with the rates: the old 0.55 divided by the
## same 10, so the sideways push a given gesture produces is unchanged.
## 侧向力增益。横向扫桨对船的推力本来就不大,给个小系数。它跟着速率一起缩放:旧的 0.55
## 除以同一个 10,所以同一个动作产生的侧向推力跟以前完全一样。
const LATERAL_GAIN := 0.055
## How fore/aft a sweep has to be before its sideways component counts at full
## strength. The weight is the fore/aft share of the oar's motion, ramped 0..1
## and saturating here. Below it the sweep is mostly a sideways reposition --
## swapping the paddle from one hand to the other is almost pure lateral motion
## -- so the sideways push is scaled down in proportion; at or above it the
## sweep is an ordinary stroke and steering is untouched.
## 一次扫桨要有多「前后向」,它的侧向分量才算满力。权重 = 前后扫占整体运动的
## 比例,从 0 线性升到 1、到这里饱和。低于它说明这次主要是横向挪桨(换手),
## 侧向力按比例缩小;达到它就是正常划水,转向完全不受影响。
## 实测:正常划水的前后占比中位 0.71、5% 分位 0.39;换手动作最高只有 0.20 左右,
## 两边分得开,所以 0.6 这个门槛压得住换手、又几乎不动正常划水。
const LATERAL_FWD_SHARE := 0.6
## Lateral offset of the blade from the boat's centreline, in metres. Sets how
## much yaw torque a given amount of thrust produces.
## 桨叶到船中线的侧向距离(米)。决定同样大的推力能产生多大的转向力矩,
## 也就是船头转得多快。想转向更利落就调大。
const OARLOCK_OFFSET := 0.6
## Hysteresis threshold for deciding the side. The side only flips once
## |s_left| exceeds this, otherwise s_left would cross zero for an instant as
## the oar sweeps through vertical and the bow would twitch left and right.
## 左右判定的滞回阈值。|s_left| 超过它才改判左右,免得桨扫过竖直方向时
## s_left 瞬时过零、左右来回跳、船头乱抖。
##
## 0.08 was too small for that job. Measured on the recordings, a backstroke
## swings s_left 0.129 past the centreline at the instant the thrust fires, so
## the side flipped mid-take and the yaw torque flipped with it -- rev1 came out
## 4.8 degrees the wrong way. 0.20 clears the deepest crossing with 50% margin.
## Forward rowing never crosses at all (0.000 at every recorded pace), so this
## is a no-op there: all nine paces come out bit-identical.
## 0.08 对这个活儿来说太小了。实测:一次后划在推力触发的那一刻把 s_left 甩过中线
## 0.129,于是左右在划程中途翻转、转向力矩跟着翻,rev1 的结果差了 4.8 度、方向正好
## 相反。0.20 能带着 50% 余量熬过最深的那次穿越。向前划水根本不会穿到另一侧
## (各个录制速度下都是 0.000),所以这里对它是空操作:九个速度的结果逐位相同。
const SIDE_HYSTERESIS := 0.20
## Start / end thresholds for counting a stroke. Power rising past ON opens
## the stroke; falling back below OFF closes it.
## 记一桨的起止阈值(滞回):力度升过 ON 开始计数,跌回 OFF 以下算这一桨结束。
## 它们不改变任何一帧的推力,但 OFF 那一侧决定 STROKE_COOLDOWN 什么时候开始,
## 而冷却确实不给力——所以这两个数现在间接影响手感,不再只是显示用的。
const STROKE_ON := 0.28
const STROKE_OFF := 0.12

## Forced silence after a stroke closes. The player's diagnosis: at the end of a
## stroke the hand decelerates and the oar's own momentum carries it the other way
## for an instant; that reversal crosses the bar and pays astern thrust, which is
## what eats the coast the stroke just bought. For this long afterwards the gate
## still runs and still shows its verdict, but the verdict is not paid for -- no
## forward, no astern, no steering, in any direction. Zero disables it.
## 一桨结束后的强制静默。玩家的判断:收桨时手在减速,桨自身的动量会把它往反方向
## 带一瞬间;那次反向越过门槛就会付出倒退推力,把这一桨刚换来的滑行吃掉。在这段
## 时间之内,判定照常跑、照常显示结论,但结论不兑现——不前进、不后退、不转向,
## 任何方向都不给力。设为 0 就是关掉它。
const STROKE_COOLDOWN := 0.1

# ------------------------------------------------------------------ State --
## Whether usable sensor data is coming in. While false, boat.gd falls back
## to the keyboard. Not named "ready" to avoid clashing with Node's signal.
var sensor_ready := false
## Normalised pose components; the squares always sum to 1.
var s_vert := 1.0
var s_left := 0.0
var s_back := 0.0
## Lateral and fore/aft angles in degrees. Lateral + is left, fore/aft + is aft.
var ang_lat := 0.0
var ang_fa := 0.0
## Which side the oar is on: +1 left, -1 right, 0 not yet decided.
var side := 0.0
## Drive effort at this instant: 0 = coasting, 1 = full power.
var drive_power := 0.0
## The split components (forward is >= 0, lateral carries its sign).
var forward_power := 0.0
var side_power := 0.0
## Astern thrust from a backstroke; 0 unless the blade is sweeping toward the bow
## past sweep_need_fwd. Never negative, so it cannot be confused with forward
## thrust. The two forces can never both be positive: one needs the rate past
## +sweep_need_fwd, the other past -sweep_need_aft, and a single rate cannot be
## both unless BOTH bars are zero -- and then both forces are still zero, because
## the dead band zeroes them.
var reverse_power := 0.0
## Thrust actually being paid this frame, in whichever direction is paying it.
## forward_power and reverse_power can never both be positive, so this is just the
## one that is on. It is what the stroke bookkeeping reads, which is why a
## backstroke opens and closes a stroke exactly like a forward one does.
var push_power := 0.0
## How fast the blade is sweeping toward the bow right now, in m/s^2 per second.
## Positive means toward the bow. This one number is the whole model -- its SIGN
## picks the direction and its SIZE against that direction's bar picks stroke or
## recovery -- so it is shown live in the overlay and on the panel, and the rule
## is visible to the player while they aim at it. It is the filtered rate of the
## raw Z axis, negated, which is also what the two force laws read, so the gates
## and the forces can never disagree about what a sweep is doing.
var reverse_rate := 0.0
## Updated once per completed stroke:
var stroke_count := 0
##   peak effort of the previous stroke (0..1+)
var last_stroke_power := 0.0
##   which side the previous stroke was on (+1 left / -1 right)
var last_stroke_side := 0.0

## Deliberately untyped. SensorInput is an autoload singleton whose script
## declares no class_name, so `var _src: Node` makes the static analyser fail
## with "no member port_open / x / y / z on Node" and the whole script stops
## compiling. Leaving it as a Variant resolves those lookups dynamically.
var _src = null
var _fx := 0.0
var _fy := 0.0
var _fz := 0.0
var _w_lat := 0.0
var _w_fa := 0.0
var _prev_y := 0.0
var _prev_z := 0.0
var _primed := false
var _in_stroke := false
var _stroke_peak := 0.0
var _stroke_side := 0.0
## Seconds left on STROKE_COOLDOWN's silence; 0 when nothing is muted. Public
## because the overlay reports it, the way it reports every other reason a motion
## is being ignored.
var stroke_cool := 0.0

var _overlay: CanvasLayer
var _label: Label
var _overlay_visible := true
## Seconds left on the "the bar just moved" marker. Tuning a knob with no feedback
## is indistinguishable from a key that does not work, so for a moment after any
## change both the readout line and the panel mark the value that moved.
## 「门槛刚被动过」标记的剩余秒数。调旋钮却没有反馈,和按键失效是分不出来的,
## 所以改动之后的一小段时间里,读数行和面板都会把动过的那个数标出来。
const TUNED_FLASH := 0.8
var _tuned := 0.0
## Which bar that marker belongs to: TUNED_NONE, TUNED_AFT (the forward bar) or
## TUNED_FWD (the backstroke bar). With one bar "something moved" was enough to
## say which knob was live; with two it is not, so the marker names one.
## 那个标记属于哪个门槛:TUNED_NONE、TUNED_AFT(前划门槛)或 TUNED_FWD(后滑门槛)。
## 只有一个门槛时「有东西动了」就足以说明是哪个旋钮;有两个就不够,所以这个标记要点名。
const TUNED_NONE := 0
const TUNED_AFT := 1
const TUNED_FWD := 2
var _tuned_bar := TUNED_NONE

## The panel: a title, one big number per bar, a draggable meter, and the live
## sweep rate. Every piece is a member because _layout_meter() repositions them on
## every physics frame, and a get_node per frame would be silly.
## 面板:标题、两个门槛各一个大号数值、可拖动的轨道、以及实时扫速。每一块都存成成员
## 变量,因为 _layout_meter() 每帧都要重新摆放它们,每帧 get_node 太浪费。
## The two numbers sit at the ends of the top row, each coloured like the band it
## governs, so "which of these two is the one I just moved" needs no label.
## 两个数值分列顶端两角,各自用它所管的色带的颜色,所以「我刚动的是哪一个」不需要标签。
var _panel: Panel
var _title: Label
var _value_aft: Label
var _value_fwd: Label
var _live: Label
var _reset: Button
var _meter: Control
var _track: ColorRect
var _zone_fwd: ColorRect
var _zone_ast: ColorRect
var _mark_aft: ColorRect
var _mark_fwd: ColorRect
var _needle: ColorRect
## True between mouse-down and mouse-up on the meter. Held as a flag rather than
## inferred from Input, so a button released outside the panel still ends the drag.
## 在轨道上按下到松开之间为 true。用标志位而不是每帧读 Input,这样在面板外面松手
## 也能正常结束拖动。
var _dragging := false
## Which bar the current drag grabbed: true for the forward bar (the left notch),
## false for the backstroke bar (the right one). Decided once, on mouse-down, from
## the side of the centre the press landed on -- held for the whole drag, so a
## pointer that wanders across the middle does not hand the drag to the other bar
## halfway through.
## 本次拖动抓的是哪个门槛:true 是前划门槛(左边的缺口),false 是后滑门槛(右边那个)。
## 在按下那一刻按落点在中点哪一侧定下来,整段拖动保持不变 —— 否则指针划过中线就会把这次
## 拖动中途交给另一个门槛。
var _drag_aft := true


func _ready() -> void:
	# Looked up by path rather than spelled as SensorInput, so a missing
	# autoload degrades gracefully instead of crashing.
	_src = get_node_or_null("/root/SensorInput")
	if _src == null:
		push_warning("[OarController] SensorInput autoload missing; keyboard only.")
	_build_overlay()
	# Draw once up front, so the panel shows the shipped bar for the frames before
	# the first update() rather than an empty box.
	_refresh_overlay()


## Live threshold tuning, in game and at any moment. Two ways in, because the two
## are good at different things: keys for a nudge while both hands are on the oar
## handle, the panel for finding a value in the first place.
##
##   [  ]          the FORWARD bar, one fine step (1)
##   ,  .          the BACKSTROKE bar, one fine step (1)
##   Shift + any of those four     the same move, one coarse step (5)
##   -  =          the FORWARD bar, one coarse step (5) -- the older alias
##   0             both bars back to the shipped pair
##   F2            show / hide the readout and the panel
##   drag the meter in the panel   grab a notch; the bar follows the distance from
##                                 the centre, left notch = forward bar
##
## There is one key pair per direction so that neither bar can be nudged by
## accident while the player is aiming at the other, which is the whole reason
## there are two of them. Shift is read as a STEP SIZE rather than as a second set
## of bindings, so there are four keys to learn and not six.
##
## The numbers themselves are handed to the player because the recordings cannot
## settle them (section 2b), and the readout redraws even with no sensor attached,
## so they can be set before the oar is ever plugged in. Holding a key
## auto-repeats, so the value walks.
##
## Every key is matched on the CHARACTER it produces (keycode) first, and the
## bracket and comma pairs additionally on the POSITION (physical_keycode). The
## two readings disagree on a non-US layout: "[" is AltGr+8 in several European
## layouts while the key sitting where the US "[" sits produces a letter, and
## Shift turns "," and "." into ";" and ":" in the same places. A tuning key that
## silently does nothing on the player's own keyboard is the worst outcome, so
## those four accept the position too.
##
## The other three keys are matched on the character ONLY, on purpose. Position
## is a safe fallback for a key whose character is awkward to type, but it is not
## safe in general: on a US layout Shift+0 is the physical "0" key, so a position
## match would let it fire the reset.
##
## 游戏里随时可以调门槛。两种入口,因为它们各自擅长不同的事:两只手都在桨把上时用按键挪
## 一下,要找一个值的时候用面板。
##
##   [  ]          前划门槛,一个细步(0.1)
##   ,  .          后滑门槛,一个细步(0.1)
##   Shift + 上面任意一个          同样的移动,一个粗步(0.5)
##   -  =          前划门槛,一个粗步(0.5) —— 旧的别名
##   0             两个门槛都放回出厂值
##   F2            显示 / 隐藏读数与面板
##   拖面板上的轨道   抓一个缺口;门槛跟着落点到中点的距离走,左边缺口是前划门槛
##
## 两对按键一个方向一对,这样玩家瞄准其中一个的时候不会顺手动了另一个 —— 这正是有两个
## 门槛的全部理由。Shift 被当作「步长」而不是第二套按键,所以要记的是四个键不是六个。
##
## 数值交给玩家,因为录像决定不了它们(见 2b);读数在没接传感器时也照常重绘,所以桨还没
## 插上就能调好。按住键会自动重复,数值是一格格走的。
##
## 每个键先按它产生的「字符」(keycode)匹配,括号对和逗号对额外再按「位置」
## (physical_keycode)匹配一次。非美式键盘上这两种读法会分家:好几种欧洲布局里 "[" 是
## AltGr+8,而美式 "[" 那个物理键位打出来是字母;同样是这些布局里 Shift+"," 和 Shift+"."
## 出的是 ";" 和 ":"。一个在玩家自己的键盘上悄悄失灵的调参键是最糟的结果,所以那四个键
## 也接受位置匹配。
##
## 另外三个键故意只按字符匹配。对于一个「字符难打」的键,位置是安全的兜底;但一般情况下
## 不安全:美式布局里 Shift+0 就是物理上的 "0" 键,位置匹配会让它触发重置。
func _input(event: InputEvent) -> void:
	# Read through a typed local rather than off `event` directly. `event` is an
	# InputEvent, and a property of a base class is not something the analyzer can
	# infer a type from, so `var code := event.keycode` is an error here: the `is`
	# test above does not narrow the parameter for the lines that follow it. The
	# cast both narrows it and makes the rest of the function ordinary typed code.
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var code := key.keycode
	if code == KEY_F2:
		if key.echo:
			return
		_overlay_visible = not _overlay_visible
		if _overlay != null:
			_overlay.visible = _overlay_visible
		return
	var echo := key.echo
	var step := SWEEP_COARSE_STEP if key.shift_pressed else SWEEP_FINE_STEP
	if key_is(key, code, KEY_BRACKETLEFT):
		_tune_aft(sweep_need_aft - step, echo)
	elif key_is(key, code, KEY_BRACKETRIGHT):
		_tune_aft(sweep_need_aft + step, echo)
	elif key_is(key, code, KEY_COMMA) or key_is(key, code, KEY_SEMICOLON):
		_tune_fwd(sweep_need_fwd - step, echo)
	elif key_is(key, code, KEY_PERIOD) or key_is(key, code, KEY_COLON):
		_tune_fwd(sweep_need_fwd + step, echo)
	elif code == KEY_MINUS:
		_tune_aft(sweep_need_aft - SWEEP_COARSE_STEP, echo)
	elif code == KEY_EQUAL:
		_tune_aft(sweep_need_aft + SWEEP_COARSE_STEP, echo)
	elif code == KEY_0:
		_reset_bars(echo)


## True when the event is this key, read either as the character it produced or
## as the position it was pressed in.
func key_is(key: InputEventKey, code: int, want: int) -> bool:
	return code == want or key.physical_keycode == want


## Set the FORWARD bar -- the one an aft-sweeping blade reads -- flag it as
## just-changed and redraw. The console line is there for the same reason as the
## marker: so there is something to check the key against, even if the readout has
## been hidden with F2. A held key or a drag passes quiet = true, because a line
## per repeat would bury the output.
func _tune_aft(v: float, quiet: bool) -> void:
	var was := sweep_need_aft
	sweep_need_aft = clampf(v, SWEEP_NEED_MIN, SWEEP_NEED_MAX)
	_tuned = TUNED_FLASH
	_tuned_bar = TUNED_AFT
	if not quiet and not is_equal_approx(was, sweep_need_aft):
		print("[OarController] forward bar -> %.0f  (an aft sweep past it drives FORWARD)"
				% sweep_need_aft)
	_refresh_overlay()


## Set the BACKSTROKE bar -- the one a bow-ward sweep reads. Same contract as
## _tune_aft, and deliberately the same shape: these two setters are the only
## writers either bar has, and neither can touch the other's.
## 设置后滑门槛 —— 向船头扫的桨读的那个。契约和上面的 _tune_aft 一样,而且是故意写成
## 同一个形状:这两个 setter 是两个门槛仅有的写入者,谁都碰不到对方那一个。
func _tune_fwd(v: float, quiet: bool) -> void:
	var was := sweep_need_fwd
	sweep_need_fwd = clampf(v, SWEEP_NEED_MIN, SWEEP_NEED_MAX)
	_tuned = TUNED_FLASH
	_tuned_bar = TUNED_FWD
	if not quiet and not is_equal_approx(was, sweep_need_fwd):
		print("[OarController] backstroke bar -> %.0f  (a bow-ward sweep past it drives ASTERN)"
				% sweep_need_fwd)
	_refresh_overlay()


## Both bars back to the shipped pair. Routed through the two setters rather than
## assigning the vars directly, so the flash and the console line happen once per
## bar that actually moved and there is no third copy of the clamp to keep in step.
## 两个门槛都放回出厂值。走上面两个 setter,而不是直接给变量赋值 —— 这样闪烁和控制台
## 输出只在真正动过的那个门槛上各发生一次,也不会多出第三份 clamp 要对齐。
func _reset_bars(quiet: bool) -> void:
	_tune_aft(SWEEP_NEED_AFT_RESET, quiet)
	_tune_fwd(SWEEP_NEED_FWD_RESET, quiet)


# -------------------------------------------------------------- Main loop --
## Called once per physics frame. delta is the physics delta; it has nothing
## to do with the sensor's sample rate.
func update(delta: float) -> void:
	# Run the tuning marker down before anything else, and before any of the
	# early returns below: every one of them already redraws the overlay, so
	# doing it here means the marker fades even with no oar attached.
	if _tuned > 0.0:
		_tuned = maxf(0.0, _tuned - delta)

	if _src == null or not _src.port_open or delta <= 0.0:
		sensor_ready = false
		drive_power = 0.0
		forward_power = 0.0
		side_power = 0.0
		reverse_power = 0.0
		reverse_rate = 0.0
		_refresh_overlay()
		return

	# --- 1. Low-pass filter: sensor noise and impact spikes --------------
	var a := 1.0 - exp(-delta / FILTER_TAU)
	_fx = lerp(_fx, _src.x, a)
	_fy = lerp(_fy, _src.y, a)
	_fz = lerp(_fz, _src.z, a)

	var mag := sqrt(_fx * _fx + _fy * _fy + _fz * _fz)
	if mag < 1.0:
		# A tiny resultant means we are not in a gravity field at all
		# (free fall, or simply garbage) -- nothing here can be trusted.
		sensor_ready = false
		drive_power = 0.0
		forward_power = 0.0
		side_power = 0.0
		reverse_power = 0.0
		reverse_rate = 0.0
		_refresh_overlay()
		return
	sensor_ready = true

	# --- 2. Pose decomposition -------------------------------------------
	s_vert = clampf(-_fx / mag, -1.0, 1.0)
	s_left = clampf(-_fy / mag, -1.0, 1.0)
	s_back = clampf(_fz / mag, -1.0, 1.0)
	ang_lat = rad_to_deg(asin(s_left))
	ang_fa = rad_to_deg(asin(s_back))

	# Hysteresis on the side, so the oar sweeping through vertical does not
	# make it flip back and forth.
	if absf(s_left) > SIDE_HYSTERESIS:
		side = signf(s_left)

	# --- 3. Rates (difference, then filter) ------------------------------
	# The rate is taken on the RAW filtered axes, not on the normalised pose
	# above. Section 2's s_back is still what the overlay and the lateral share
	# read, but the direction rule the player stated is literally "if Z is
	# rising the blade is going aft", and Z is the raw axis -- so that is what
	# gets differentiated. Because s_back = _fz / mag and mag is near constant
	# over a stroke, d(s_back)/dt and d(_fz)/dt carry the SAME sign, so _w_fa
	# keeps its meaning exactly: positive means the blade is sweeping aft. What
	# changes is the scale (m/s^2 per second instead of 1/s, ten times bigger
	# since the chip reads 10 for gravity) and the fact that the division no
	# longer eats part of the rate -- see the note at FULL_DRIVE_RATE.
	# 速率取的是「滤波后的原始轴」,不是上面的归一化姿态。第 2 节的 s_back 仍然是
	# 覆盖层和侧向占比读的东西,但玩家给的判断规则字面上就是「Z 在涨 = 桨在向后
	# 扫」,而 Z 是原始轴,所以被微分的就应该是它。因为 s_back = _fz / mag 而一次
	# 划水过程中 mag 近似不变,所以 d(s_back)/dt 和 d(_fz)/dt 同号,_w_fa 的含义
	# 一点没变:为正就是桨在向后扫。变的是量纲(m/s²/秒 而不是 1/秒,由于芯片重力
	# 读数就是 10,数值大十倍),以及除法不再吃掉一部分速率 —— 见 FULL_DRIVE_RATE
	# 那里的说明。
	var raw_w_lat := (_fy - _prev_y) / delta
	var raw_w_fa := (_fz - _prev_z) / delta
	_prev_y = _fy
	_prev_z = _fz
	if not _primed:
		# The first frame has no predecessor to difference against, which
		# would blow up into a bogus spike. Throw it away.
		_primed = true
		raw_w_lat = 0.0
		raw_w_fa = 0.0
	var b := 1.0 - exp(-delta / RATE_TAU)
	_w_lat = lerp(_w_lat, raw_w_lat, b)
	_w_fa = lerp(_w_fa, raw_w_fa, b)

	# --- 4. Which way the blade is sweeping, and how fast -------------------
	# One number, and it is the same one the force is computed from. _w_fa is
	# the filtered rate of _fz, so it is positive exactly when the blade is
	# sweeping aft; negating it gives a rate that is positive toward the bow,
	# which is the direction the overlay reads in.
	reverse_rate = -_w_fa
	var sweep := reverse_rate
	var vert := maxf(absf(s_vert), MIN_VERTICAL)

	# --- 5. One direction each, one threshold each ---------------------------
	# The rule, in full. Two bars: a sweep toward the bow past the backstroke bar
	# is a backstroke and drives the boat astern, a sweep aft past the forward bar
	# is a forward stroke and drives it forward, and anything slower is a recovery
	# and pays nothing. Each bar is read by exactly the direction it names, and
	# neither is read by the other -- that separation is the point of splitting
	# them, and section 2b is what the split costs forward rowing.
	var aft_is_stroke := -sweep >= sweep_need_aft
	var fwd_is_stroke := sweep >= sweep_need_fwd

	# --- 6. The force ------------------------------------------------------
	# One law, both ways: clamped at zero, the dead band subtracted, then
	# proportional to sweep speed with no saturation, so a slow stroke is a long
	# gentle push and a fast one a short hard shove. The more upright the oar, the
	# more of that force points straight ahead. Forward reads the aft half of the
	# number, astern the forward half, and no single value can be both -- so the
	# two can never be positive together even with both bars at zero, which is
	# what stops the gate from pushing the boat both ways at once.
	forward_power = 0.0
	if aft_is_stroke:
		forward_power = maxf(0.0, -sweep - DRIVE_DEADBAND) / FULL_DRIVE_RATE * vert
	reverse_power = 0.0
	if fwd_is_stroke:
		reverse_power = maxf(0.0, sweep - DRIVE_DEADBAND) / FULL_DRIVE_RATE * vert
	drive_power = forward_power

	# Lateral: sweeping left pushes the boat right, hence +. s_left is MINUS _fy
	# divided by mag, so a rising s_left is a FALLING _fy -- the raw-axis rate
	# _w_lat now points the other way, and the negation below is what puts it
	# back. Drop that minus sign and the boat steers away from every stroke.
	# 侧向:向左扫把船推向右边,所以是 +。s_left 等于「负的 _fy」除以 mag,所以
	# s_left 上涨就是 _fy 下跌 —— 换成原始轴之后 _w_lat 的方向是反的,下面那个负号
	# 就是把它掰回来的。去掉它,船会朝每一次划桨的反方向漂。
	var lat_rate := -_w_lat
	if absf(lat_rate) < LATERAL_DEADBAND:
		lat_rate = 0.0
	else:
		lat_rate -= signf(lat_rate) * LATERAL_DEADBAND

	# Weight the sideways push by how much of the sweep is fore/aft. Swapping the
	# paddle from one side of the body to the other swings the oar a long way
	# sideways with no fore/aft sweep to go with it, and that must not shove the
	# boat sideways. The share is deliberately scale-invariant: it does not matter
	# how fast or how wide the swap is, only that it has no fore/aft component. A
	# real stroke is fore/aft-dominated, so the weight sits at 1 and steering is
	# unaffected. (This is also why the rescale does not disturb it: both rates
	# grew by the same factor, so their ratio is what it was.)
	# 侧向推力按「这次扫桨有多前后向」加权。把桨从身体一侧换到另一侧,桨横向走很远
	# 却没有前后分量,这不能把船横推出去。这个占比刻意做成尺度无关:换手多快、多宽都
	# 不重要,只要它没有前后分量。真划水是前后主导的,权重落在 1,转向不受影响。
	#(这也正是这次改单位没影响到它的原因:两个速率按同一个倍数变大,比值不变。)
	var total_rate := absf(_w_fa) + absf(lat_rate)
	var fwd_share := 0.0
	if total_rate > 0.0:
		fwd_share = absf(_w_fa) / total_rate
	side_power = lat_rate * LATERAL_GAIN * clampf(
		fwd_share / LATERAL_FWD_SHARE, 0.0, 1.0)

	# --- 7. The silence after a stroke ---------------------------------------
	# A stroke closed on an earlier frame, so until this timer runs out nothing
	# the oar does is paid for, in either direction and sideways too. Sections 5
	# and 6 have already run and reverse_rate above is still live, which is the
	# point: the gate keeps reading the bar and the panel keeps showing the sweep,
	# so the player watches the rule fire and watches it not be paid. Muting the
	# readout instead would make the cooldown look like a broken sensor.
	if stroke_cool > 0.0:
		stroke_cool = maxf(0.0, stroke_cool - delta)
		forward_power = 0.0
		reverse_power = 0.0
		side_power = 0.0
		drive_power = 0.0

	# Computed from what is left after section 7, so while the silence runs this is
	# zero and the bookkeeping below cannot close a stroke it has not opened. That
	# ordering is what stops the silence from being re-armed by its own muting.
	push_power = maxf(forward_power, reverse_power)

	_update_stroke_stats()

	_refresh_overlay()


## Per-stroke bookkeeping: power rising past ON opens a stroke, falling back
## below OFF closes it, records that stroke's peak and side, and starts the
## post-stroke silence. It reads push_power, so it counts a threshold crossing in
## EITHER direction -- a backstroke opens and closes a stroke here on exactly the
## same terms as a forward push, and arms the same 0.1 s of silence when its own
## sweep comes back through zero. It used to read drive_power, which is the
## forward half only, and that is the whole reason the silence was one-sided:
## forward rowing got its reversal muted and a backstroke did not.
func _update_stroke_stats() -> void:
	if not _in_stroke:
		if push_power > STROKE_ON:
			_in_stroke = true
			_stroke_peak = push_power
			_stroke_side = side
		return

	if push_power > _stroke_peak:
		_stroke_peak = push_power
	if push_power < STROKE_OFF:
		_in_stroke = false
		stroke_count += 1
		last_stroke_power = _stroke_peak
		last_stroke_side = _stroke_side
		# This is where the stroke ends, so this is where the silence starts. The
		# timer takes effect on the next frame, not this one: the power for this
		# frame has already been handed to the boat. One frame of lag, 16.7 ms at
		# 60 Hz, and the reversal it is aimed at is a tenth of a second long.
		stroke_cool = STROKE_COOLDOWN


# --------------------------------------------------------- Boat interface --
## Thrust in the boat's own frame: x = right, z = back.
## Note Godot points the bow along -Z, so forward thrust is negative z and a
## backstroke is positive z. The two can never be positive together: one needs the
## sweep rate negative past the forward bar, the other positive past the
## backstroke bar, and no single rate can be both.
func thrust_local() -> Vector3:
	return Vector3(side_power, 0.0, reverse_power - forward_power)


## Yaw torque coefficient about Y: positive turns the bow left, negative right.
## A left-side stroke (side > 0) pushes left of the centreline, giving a
## negative torque and a bow that swings right, exactly like a real boat.
## A backstroke pushes the blade the other way, so the same blade position
## gives the opposite torque -- hence the sign flip on reverse_power.
## Both terms are already zero on the recovery, so the return never swings the
## bow back and undoes the turn.
func yaw_torque() -> float:
	return (reverse_power - forward_power) * OARLOCK_OFFSET * side


# ---------------------------------------------------------------- Overlay --
## Panel geometry, in pixels. The base viewport is 1152 wide, so PANEL_W plus both
## margins has to stay inside that or the panel hangs off the screen. Written down
## once: _build_panel and _layout_meter both need it, and if they disagreed the
## needle would sit somewhere the drag does not expect.
## 面板的尺寸(像素)。基础视口宽 1152,所以 PANEL_W 加两侧边距必须留在里面,否则面板
## 会跑出屏幕。只写这一处:_build_panel 和 _layout_meter 都要用,两者一旦对不上,
## 指针就会出现在拖动所预期之外的位置。
const PANEL_W := 560.0
const PANEL_H := 190.0
const PANEL_MARGIN := 16.0
const PANEL_PAD := 14.0
## The meter: where it sits in the panel, how wide it is, and how many pixels one
## unit of sweep rate takes up. The scale is fixed to the full tunable range rather
## than to the current value, so the notches and the needle move by the same rule
## and a notch always lands under the pointer that grabbed it.
## 轨道:它在面板里的位置、宽度,以及一个单位的扫速占多少像素。刻度是按整个可调范围
## 固定的,不是跟着当前值走 —— 这样缺口和指针用同一套换算,抓哪个缺口就停在哪个位置。
const METER_Y := 50.0
const METER_W := PANEL_W - 2.0 * PANEL_PAD
const METER_H := 56.0
const METER_SCALE := METER_W * 0.5 / SWEEP_NEED_MAX
## The bars drawn inside the meter: the full-width track, the two notches that mark
## where the bar is, and the needle that is the live sweep rate.
## 轨道里画的三样东西:贯穿全宽的底槽、标出门槛位置的两个缺口、以及代表实时扫速的指针。
const TRACK_H := 22.0
const NOTCH_W := 4.0
const NOTCH_H := 34.0
const NEEDLE_W := 3.0
const NEEDLE_H := 52.0
## How far a drag is allowed to land from a whole step, so a drag reaches exactly
## the values the arrow keys produce instead of stopping beside them. It is half a
## step: fine enough that every arrow value is reachable, coarse enough that the
## last digit of the readout is not noise while dragging.
## 拖动允许落在一个整步长之外多远 —— 这样拖出来的值能和方向键调出来的值对齐。它是
## 半个步长:细到方向键走过的每个值都够得着,又粗到拖动时读数最后一位不会乱跳。
const DRAG_SNAP := 0.5


func _side_text(v: float) -> String:
	if v > 0.0:
		return "L"
	if v < 0.0:
		return "R"
	return "-"


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 99   # below SensorInput's 100, so both readouts stay put
	add_child(_overlay)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	_build_label(root)
	_build_panel(root)


## The text readout, pinned to the bottom-left corner. Bottom-aligned inside its
## box, so extra room is spent upward and the readout always hugs the bottom edge.
## The width stops short of the base viewport: the label is left-anchored and does
## not clip, so a line wider than the box would run off the right-hand edge.
func _build_label(root: Control) -> void:
	_label = Label.new()
	_label.anchor_left = 0.0
	_label.anchor_top = 1.0
	_label.anchor_right = 0.0
	_label.anchor_bottom = 1.0
	_label.offset_left = 16.0
	_label.offset_top = -178.0
	_label.offset_right = 1130.0
	_label.offset_bottom = -16.0
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.08, 0.10, 0.12))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	root.add_child(_label)


## The threshold panel, pinned to the top-right corner -- the bottom-left one is
## already the readout's, and the two must not collide.
##
## It exists because a rule made of numbers is not something a player can act on
## while rowing. The meter is a bipolar track: the centre is a sweep rate of zero,
## the two lit bands are the two directions, and the two dark notches are the two
## bars -- one on each side, moving INDEPENDENTLY, with the gap between them no
## longer centred. That off-centre gap is the whole point of the picture: it is
## the split made visible. The white needle is the live sweep rate, so "have I
## cleared it" is a glance rather than a comparison.
##
## Nothing here is a Container or a Slider. Containers place their children a frame
## after being built, and a Slider would have to be forced back into agreement with
## its bar every frame with a guard against the signal that setting it emits.
## Plain Controls moved by hand have neither problem.
##
## 门槛面板,钉在右上角 —— 左下角已经是读数文本的位置,两者不能重叠。
##
## 它的理由:一条由数字组成的规则,玩家划起来是没法照着操作的。轨道是双极的:中间是
## 扫速为零,两条亮色带是两个方向,两个深色缺口就是两个门槛 —— 左右各一个、各自独立
## 移动,两个缺口之间的空档不再居中。这个不居中的空档正是整张图要说的东西:门槛的拆分
## 被画了出来。白色指针是实时扫速,所以「过了没有」是看一眼、不是做比较。
##
## 这里没有用任何 Container 或 Slider:Container 要等一帧才摆好子节点,而 Slider 得
## 每帧再把它同步回它那个门槛,还要防着「设置它」本身会发出的信号。手工摆放没这些问题。
func _build_panel(root: Control) -> void:
	_panel = Panel.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	box.set_corner_radius_all(10)
	box.set_border_width_all(1)
	box.border_color = Color(1.0, 1.0, 1.0, 0.18)
	_panel.add_theme_stylebox_override("panel", box)
	# Both anchors on the right edge and both offsets negative, so the panel keeps
	# its size and stays in the corner whatever the window does.
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -(PANEL_W + PANEL_MARGIN)
	_panel.offset_right = -PANEL_MARGIN
	_panel.offset_top = PANEL_MARGIN
	_panel.offset_bottom = PANEL_MARGIN + PANEL_H
	# The panel must not eat the mouse: everything in it except the meter is
	# decoration, and a click on it should reach the game. Setting a parent to
	# IGNORE does not stop its children being tested, which is why the meter can
	# still be STOP inside it.
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)

	_title = _panel_label("SWEEP THRESHOLDS", PANEL_PAD, 0.0, 260.0, 18.0, 12)
	_title.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	_panel.add_child(_title)

	var right := PANEL_W - PANEL_PAD - 200.0
	# One number per bar, at the two ends of the row above the meter and each
	# coloured like the band it governs. Two labels rather than one "40 / 55"
	# string on purpose: a single string flashes as a whole, which would leave the
	# player unable to tell which of the four tuning keys actually did something --
	# the one failure this entire readout exists to prevent.
	# 两个门槛各一个大号数值,分列轨道上方那一行的两端,各自用它所管色带的颜色。故意用
	# 两个 Label 而不是拼一个「40 / 55」:拼成一串的话闪烁是整串一起闪,玩家就看不出
	# 刚按的四个调参键里到底哪个起了作用 —— 而那是这整套读数存在的唯一理由。
	_value_aft = _panel_label("", PANEL_PAD, 18.0, 200.0, 32.0, 24)
	_value_aft.add_theme_color_override("font_color", Color(0.35, 0.82, 1.0))
	_panel.add_child(_value_aft)
	_value_fwd = _panel_label("", right, 18.0, 200.0, 32.0, 24)
	_value_fwd.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_value_fwd.add_theme_color_override("font_color", Color(1.0, 0.72, 0.30))
	_panel.add_child(_value_fwd)

	_build_meter()

	_zone_label("FORWARD", PANEL_PAD, Color(0.35, 0.82, 1.0))
	_zone_label("ASTERN", right, Color(1.0, 0.72, 0.30))

	_reset = Button.new()
	_reset.text = "Reset  (0)"
	_reset.focus_mode = Control.FOCUS_NONE
	_reset.mouse_filter = Control.MOUSE_FILTER_STOP
	_reset.anchor_right = 0.0
	_reset.anchor_bottom = 0.0
	_reset.offset_left = PANEL_PAD
	_reset.offset_top = PANEL_H - 44.0
	_reset.offset_right = PANEL_PAD + 130.0
	_reset.offset_bottom = PANEL_H - 12.0
	_reset.pressed.connect(_on_reset_pressed)
	_panel.add_child(_reset)

	_live = _panel_label("", right, PANEL_H - 44.0, 200.0, 32.0, 18)
	_live.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_live.add_theme_color_override("font_color", Color(0.86, 0.90, 0.95))
	_panel.add_child(_live)


## A Label placed by hand inside the panel: anchors all at the top-left and the
## rectangle given by offsets, so nothing waits on a parent's size being resolved.
func _panel_label(text: String, x: float, y: float, w: float, h: float,
		size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.offset_left = x
	l.offset_top = y
	l.offset_right = x + w
	l.offset_bottom = y + h
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("outline_size", 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## One of the two direction captions under the meter, coloured to match the band
## it names.
func _zone_label(text: String, x: float, colour: Color) -> void:
	var l := _panel_label(text, x, METER_Y + METER_H + 6.0, 200.0, 24.0, 14)
	l.add_theme_color_override("font_color", colour)
	l.horizontal_alignment = (
		HORIZONTAL_ALIGNMENT_LEFT if x < PANEL_W * 0.5
		else HORIZONTAL_ALIGNMENT_RIGHT)
	_panel.add_child(l)


## The meter itself: the drag target, and the bars drawn inside it. Child order is
## the draw order, so the notches and the needle go on last.
func _build_meter() -> void:
	_meter = Control.new()
	_meter.anchor_right = 0.0
	_meter.anchor_bottom = 0.0
	_meter.offset_left = PANEL_PAD
	_meter.offset_top = METER_Y
	_meter.offset_right = PANEL_PAD + METER_W
	_meter.offset_bottom = METER_Y + METER_H
	_meter.mouse_filter = Control.MOUSE_FILTER_STOP
	_meter.gui_input.connect(_on_meter_input)
	_panel.add_child(_meter)

	_track = _meter_rect(Color(0.26, 0.29, 0.34))
	_zone_fwd = _meter_rect(Color(0.20, 0.72, 0.92, 0.85))
	_zone_ast = _meter_rect(Color(0.95, 0.62, 0.18, 0.85))
	_mark_aft = _meter_rect(Color(0.05, 0.06, 0.08))
	_mark_fwd = _meter_rect(Color(0.05, 0.06, 0.08))
	_needle = _meter_rect(Color(1, 1, 1))


## A bar inside the meter. Every one of them is transparent to the mouse, so the
## meter underneath is the single thing a click or a drag lands on.
func _meter_rect(colour: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = colour
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(r)
	return r


## Where a sweep rate sits on the meter, in meter-local pixels.
##
## The right-hand half is a rate toward the BOW, which is a sweep that drives the
## boat ASTERN -- the same sign the overlay's number uses, so the two readouts
## cannot disagree about which way the blade is going.
func meter_x(v: float) -> float:
	return METER_W * 0.5 + clampf(v, -SWEEP_NEED_MAX, SWEEP_NEED_MAX) * METER_SCALE


## Lay the meter's bars out for the two thresholds and reverse_rate. Called on
## every redraw; the values are all it needs, so it cannot go stale.
##
## Watch the names, because they read backwards at a glance: the LEFT notch sits
## at a NEGATIVE rate, a sweep aft, so it is the FORWARD bar; the RIGHT notch is
## the backstroke bar. With one bar the two were mirror images and the picture was
## symmetric. It is not any more, and the asymmetry in the picture is exactly the
## asymmetry in the numbers -- 40 against 55, and whatever the player makes them.
## 摆放轨道里的东西。每次重绘都跑,需要的只有那几个值,所以不会走样。
##
## 注意哪个缺口是哪个,因为名字乍看是反的:左边缺口落在负速率上,也就是向后扫,那个是
## 前划门槛;右边缺口才是后滑门槛。只有一个门槛时两边是镜像、图是对称的;现在不是了,
## 图上的不对称就是数值上的不对称 —— 40 对 55,以及玩家之后把它们调成的任何样子。
func _layout_meter() -> void:
	if _meter == null:
		return
	var mid_track := (METER_H - TRACK_H) * 0.5
	var fwd_edge := meter_x(-sweep_need_aft)
	var ast_edge := meter_x(sweep_need_fwd)
	# The track spans the lot; the two zones cover it from each end inwards, so what
	# is left showing between them is the recovery band -- it grows as either bar is
	# raised, which is the cost of the bars made visible.
	_place(_track, 0.0, mid_track, METER_W, TRACK_H)
	_place(_zone_fwd, 0.0, mid_track, fwd_edge, TRACK_H)
	_place(_zone_ast, ast_edge, mid_track, METER_W - ast_edge, TRACK_H)
	_place(_mark_aft, fwd_edge - NOTCH_W * 0.5, (METER_H - NOTCH_H) * 0.5,
			NOTCH_W, NOTCH_H)
	_place(_mark_fwd, ast_edge - NOTCH_W * 0.5, (METER_H - NOTCH_H) * 0.5,
			NOTCH_W, NOTCH_H)
	_place(_needle, meter_x(reverse_rate) - NEEDLE_W * 0.5,
			(METER_H - NEEDLE_H) * 0.5, NEEDLE_W, NEEDLE_H)


## Put one meter bar at a rectangle. Widths are floored at zero: with both bars at
## 0 the two zones meet in the middle, and with either bar at 0 its own zone
## reaches the centre, which a rounding error could otherwise ask for a negative
## width.
func _place(r: ColorRect, x: float, y: float, w: float, h: float) -> void:
	r.offset_left = x
	r.offset_top = y
	r.offset_right = x + maxf(0.0, w)
	r.offset_bottom = y + h


## Mouse on the meter. A press picks a bar by the side of the centre it landed on
## -- left of centre the forward bar, right of centre the backstroke bar -- and
## the rest of the drag moves that one by its distance from the centre.
##
## Which bar a drag owns is decided once, at the press, and does not change while
## the pointer travels. With one bar there was nothing to decide; with two, a drag
## that reassigned itself mid-motion would pick one bar up and drop the other the
## moment the pointer crossed the middle, and the player would have no way to see
## why. The press also sets the value immediately, so a click on the meter jumps
## the grabbed notch to the pointer rather than waiting for a movement.
##
## The subclass members are reached through an explicit cast rather than by relying
## on the `is` test to narrow the type: button_index and position live on the
## subclasses, and a member lookup on the base InputEvent does not compile.
##
## 轨道上的鼠标。按下时按落点在中点哪一侧选定一个门槛 —— 左边是前划门槛,右边是后滑
## 门槛 —— 之后整段拖动都在动那一个,幅度是落点到中点的距离。
##
## 一次拖动归谁管只在按下那一刻决定,指针移动过程中不变。只有一个门槛时没有什么要决定;
## 有两个时,一个会在中途改主自己指派的拖动,会在指针越过中线的一瞬间把一个门槛拿起来、
## 把另一个丢下,而玩家没有任何线索能看出这是为什么。按下同时也立刻定值,所以在轨道上
## 点一下,被抓的缺口就直接跳到指针处,不用等移动。
##
## 子类的成员一律用显式转换去取,不指望 `is` 测试帮忙收窄类型:button_index 和
## position 都在子类上,在基类 InputEvent 上查成员是编译不过的。
func _on_meter_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_dragging = true
			_drag_aft = button.position.x < METER_W * 0.5
			_set_from_meter_x(button.position.x)
		elif _dragging:
			# One line at the end of a drag rather than one per pixel, so there is
			# a record of where it landed without burying the output.
			_dragging = false
			print("[OarController] %s bar -> %.0f" % [
				"forward" if _drag_aft else "backstroke",
				sweep_need_aft if _drag_aft else sweep_need_fwd])
	elif event is InputEventMouseMotion and _dragging:
		_set_from_meter_x((event as InputEventMouseMotion).position.x)


## Turn a point on the meter into a value for the bar this drag owns, through the
## same scale meter_x uses in the other direction, and snapped so a drag can land
## on the values the keys produce instead of stopping beside them.
##
## Distance from the centre is what sets the value, so the notch follows the
## pointer and a drag to the far right drives its bar to the top of the range
## wherever the notch started. A drag can therefore push one bar past the other,
## which is allowed: the two are independent knobs and nothing says the forward
## bar has to stay the higher of them. If it happens the picture says so plainly.
## 把一个轨道上的点换算成本次拖动所属那个门槛的值,用的是 meter_x 的反函数,并且做了
## 吸附,让拖出来的值能落在按键走出的那些十分位上、而不是停在它们旁边。
##
## 定值的是到中点的距离,所以缺口跟着指针走,往最右一拖就是把它的门槛推到范围顶端,不管
## 缺口原先在哪。因此一次拖动可以把一个门槛推到另一个的另一边 —— 这是允许的:两个是独立
## 的旋钮,没有哪条规则说前划门槛必须一直更高。真发生了,图上看得一清二楚。
func _set_from_meter_x(px: float) -> void:
	var frac := clampf((px - METER_W * 0.5) / (METER_W * 0.5), -1.0, 1.0)
	var v := roundf(absf(frac) * SWEEP_NEED_MAX / DRAG_SNAP) * DRAG_SNAP
	if _drag_aft:
		_tune_aft(v, true)
	else:
		_tune_fwd(v, true)


func _on_reset_pressed() -> void:
	_reset_bars(false)


func _refresh_overlay() -> void:
	if _label == null:
		return
	# The last two lines are the whole rule: the live sweep rate, the two bars it
	# is compared against, the keys that move them, and what clearing them does.
	# Two lines rather than one because there are now two bars to name and one line
	# would run off the right-hand edge of the readout. Drawn whether or not there
	# is a sensor, because this is the part the player tunes and it must not vanish
	# exactly when they are setting up. The live number is the same _w_fa the
	# forces are computed from, so what the player watches while turning a knob is
	# what the boat is reading.
	var rule := (
		"sweep %s      fwd bar %.0f%s      back bar %.0f%s\n" % [
			_f1(reverse_rate), sweep_need_aft, _bar_flash(TUNED_AFT),
			sweep_need_fwd, _bar_flash(TUNED_FWD)]
		+ "[ ] fwd   , . back   Shift coarse   drag panel      %s" % [
			_verdict_text(reverse_rate)]
	)
	_refresh_panel()
	if not sensor_ready:
		_label.text = (
			"○  Oar: no sensor data (hold WASD to test)\n\n" + rule)
		return

	var phase := "RECOVER"
	if stroke_cool > 0.0:
		# Tested first, because the cooldown has already zeroed every power and
		# this would otherwise read as an ordinary recovery. The rule line below
		# still shows the live verdict, so the player gets to see the sweep clear
		# the bar on one line and be told on another that it is not being paid for
		# yet -- which is the entire point of the feature, and the only way they
		# can tell it apart from a dead sensor. The seconds are in there because
		# the length is the one thing about it worth tuning.
		phase = "COOLDOWN %.2fs" % stroke_cool
	elif reverse_power > 0.0:
		phase = "BACK"
	elif forward_power > 0.0:
		phase = "DRIVE"
	_label.text = (
		"●  Oar %s      lateral %s°      fore/aft %s°\n" % [
			_side_text(side), _f1(ang_lat), _f1(ang_fa)]
		+ "%s    power %.2f      fwd %s / lat %s / back %s\n" % [
			phase, drive_power, _f2(forward_power), _f2(side_power),
			_f2(reverse_power)]
		+ "strokes %d      last %.2f (%s)\n" % [
			stroke_count, last_stroke_power, _side_text(last_stroke_side)]
		+ rule
	)


## The panel's numbers and bars, brought up to date with the two thresholds and
## the live rate. Rebuilt on every redraw rather than on the tuning events, so it
## is right the first time it is drawn and after a sensor comes and goes.
func _refresh_panel() -> void:
	if _panel == null:
		return
	_value_aft.text = "%.0f" % sweep_need_aft
	_value_fwd.text = "%.0f" % sweep_need_fwd
	# Flash the number that moved, and only that one, matching the << on the readout
	# line: a knob that gives no sign of having moved is indistinguishable from a
	# key that is dead. With two knobs "something moved" is not enough, because the
	# player's next question is always which.
	_value_aft.modulate = (
		Color(1.0, 0.86, 0.32)
		if _tuned > 0.0 and _tuned_bar == TUNED_AFT else Color(1, 1, 1))
	_value_fwd.modulate = (
		Color(1.0, 0.86, 0.32)
		if _tuned > 0.0 and _tuned_bar == TUNED_FWD else Color(1, 1, 1))
	_live.text = "sweep %s" % _f1(reverse_rate)
	_layout_meter()


## A marker for one bar on the readout line, for a moment after that bar moves. A
## knob with no feedback is indistinguishable from a key that does nothing, which
## is the one failure this whole readout exists to prevent -- and now that two
## numbers move independently, the marker has to say WHICH one.
func _bar_flash(bar: int) -> String:
	return " <<" if _tuned > 0.0 and _tuned_bar == bar else ""


## What the live sweep rate is worth right now, said back to the player. Dashes
## when it has cleared neither bar, so the line reads as a live comparison -- the
## arrow appears as the player's own sweep carries the rate past the bar for that
## direction.
##
## Deliberately the GATES, not the forces: between a bar and the dead band the gate
## is open and the push is still zero, and this line exists to show the player the
## rule they are tuning, which is the gates. Each direction is tested against its
## own bar, so the verdict is the same comparison the gate in section 5 makes.
func _verdict_text(sweep: float) -> String:
	if sweep <= -sweep_need_aft:
		return "-> FORWARD"
	if sweep >= sweep_need_fwd:
		return "-> ASTERN"
	return "-> ---"


## One or two decimals with an explicit sign. The "+" format flag is avoided:
## whether Godot's sprintf implements it is not something to bet the whole
## string on, since an unsupported flag blanks the entire result.
func _f1(v: float) -> String:
	return "%s%.1f" % ["+" if v >= 0.0 else "-", absf(v)]


func _f2(v: float) -> String:
	return "%s%.2f" % ["+" if v >= 0.0 else "-", absf(v)]
