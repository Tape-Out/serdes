# serdes

An all-digital serial link over two single-ended pins: 8b/10b coding, a receiver that oversamples the line and recovers timing from the data, comma alignment, and a PRBS15 generator and checker.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20OR%20MulanPSL--2.0-blue)

Part of the [Tape-Out](https://github.com/Tape-Out) IP library. It is plain Verilog with no cell or macro of any process, so it hardens on a standard-cell flow as it is. The process this library targets has no SerDes macro and no differential pad; this is the part of a serial link that needs neither.

## What it does

A lane sends and receives 10-bit symbols, most significant code bit first. Each bit lasts four cycles of `clk`, so the line rate is a quarter of the clock and a symbol takes 40 cycles.

- **Transmit.** A byte and its K flag are taken on `tx_ready`, encoded with the running disparity, and shifted out. With nothing to send the lane sends K28.5, so the line always has transitions and the far end can realign at any time.
- **Receive.** The line carries no clock. The local clock samples it four times a bit, and a 2-bit phase counter marks where the first sample after a transition should fall. Every transition checks the counter: one cycle late and the phase waits a cycle, one early and it skips one, half a bit off and it still moves only one. The frequency offset between the two ends is followed a cycle at a time, and a glitch moves the phase by one cycle rather than slipping a bit. The bit is the majority of three samples.
- **Alignment.** While not locked, a K28.5 in the 10-bit window sets the symbol boundary and the disparity. Fifteen good symbols in a row lock the receiver; three bad symbols close together unlock it and the hunt starts again. Once locked the boundary is not moved, so an error that looks like a comma cannot drag it away.
- **Checking.** A received symbol is decoded by table, encoded again for both disparities and compared with what arrived. That one comparison gives both the code error and the disparity error, with no second rule set to keep in step with the encoder.
- **PRBS.** `prbs_tx` sends PRBS15 bytes with a K28.5 every 64 symbols. `prbs_rx` checks received data bytes against a self-synchronising predictor, so the two ends need no common seed; one line error counts three times.

## Ports of `serdes_lane`

| Port | Dir | Meaning |
|:--:|:--:|:--:|
| `clk`, `rst_n` | in | line clock, four cycles a bit; reset is active low and asynchronous |
| `tx`, `rx` | out, in | the line |
| `tx_data[7:0]`, `tx_k`, `tx_valid`, `tx_ready` | in, in, in, out | a symbol is taken in the cycle `tx_ready` is high; idle is sent if `tx_valid` is low |
| `rx_data[7:0]`, `rx_k`, `rx_err`, `rx_valid` | out | one symbol per cycle of `rx_valid`; idle K28.5 is dropped; `rx_err` marks a code or disparity error |
| `loopback` | in | the receiver listens to its own transmitter |
| `prbs_tx`, `prbs_rx` | in | send and check PRBS15 |
| `inject`, `clear` | in | pulses: flip one bit on the line; zero the counters |
| `aligned`, `locked` | out | a comma has set the boundary; fifteen good symbols have followed |
| `n_sym[31:0]`, `n_code[15:0]`, `n_disp[15:0]`, `n_realign[7:0]` | out | symbols received, code errors, disparity errors, realignments; all saturate |
| `n_prbs_byte[31:0]`, `n_prbs_err[31:0]` | out | PRBS bytes checked and bits that did not match |

Everything is in the one clock domain. `serdes_afifo` is a Gray-pointer FIFO for the bytes when the logic above the lane runs on another clock.

K28.5 is reserved for idle. K28.7 followed by some symbols forms a false comma across the boundary and should not be sent either. The other K codes (K28.0 to K28.4, K28.6, K23.7, K27.7, K29.7, K30.7) are free for framing.

## Testing

```console
$ ran test serdes
```

`htest/tb_code.v` goes through every data byte and control code in both disparities. It checks properties of the code rather than the tables: each code word has four, five or six ones and moves the disparity accordingly; the decoder returns the byte; no two symbols share a code word; and in 200,000 random data bytes no run is longer than five and no comma appears.

`htest/tb_rx.v` feeds the receiver code words bit by bit and checks what it reports for each symbol. The first comma has the positive-disparity form, so a receiver that did not take its disparity from the comma would accuse the first symbol. Then come a code word that is in the table but belongs to the other disparity, and one that is in no table: the two errors must be told apart, and reception must carry on after each.

`htest/tb_lane.v` joins two lanes whose clocks differ by 600 ppm, through lines that add up to 6 ns of random jitter to every edge against a 10 ns sampling interval. It sends 3,000 random symbols each way with gaps and compares them one by one, runs PRBS both ways with no error, flips a line bit eight times at different places in a symbol and expects each one counted without losing lock, cuts the line and expects the receiver to unlock and then relock on a comma, and runs both lanes in loopback.

Twelve single-line mutations of the design each fail one of the benches.

## License

任选其一：

- [MIT](LICENSE-MIT)
- [Apache 2.0](LICENSE-APACHE)
- [木兰宽松许可证 第2版](LICENSE-MULAN)

`SPDX-License-Identifier: MIT OR Apache-2.0 OR MulanPSL-2.0`

除非另行说明，你提交的贡献按上述三者同时授权，不附加其他条件。
