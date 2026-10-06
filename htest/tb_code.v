// 8b/10b 编码与译码的穷举核对，判据都来自码本身的性质，不照抄实现里的表：
//   每个码字 4、5 或 6 个 1；6 个 1 的只出现在游程差为负时并把它翻正，4 个 1 的反之，5 个 1 的不动游程差；
//   译码回到原来的字节与 K 标记；不同的符号不共用码字；
//   数据流里任何位置的连续相同位不超过 5 个，逗号 0011111 与 1100000 不在数据流里出现。
`timescale 1ns/1ps
module tb_code;
  reg  [7:0] d;
  reg        k;
  reg        rd;
  wire [9:0] code;
  wire       rdn, bad_k;
  serdes_enc8b10b enc (.d(d), .k(k), .rd(rd), .code(code), .rd_next(rdn), .bad_k(bad_k));

  wire [7:0] dd;
  wire       dk, dbad;
  serdes_dec8b10b dec (.code(code), .d(dd), .k(dk), .bad(dbad));

  reg [9:0]  owner [0:1023];     // 最高位：这个码字有主了；其余是 {k, d}
  integer    errors, i, r, ones, n, run, valid_codes;
  reg        last;
  reg [6:0]  tail;
  reg        cur;

  function is_k (input [7:0] v);
    is_k = v[4:0] == 5'd28 || v == 8'hf7 || v == 8'hfb || v == 8'hfd || v == 8'hfe;
  endfunction

  task check_symbol;
    begin
      #1;
      ones = code[0] + code[1] + code[2] + code[3] + code[4] + code[5] + code[6] + code[7] + code[8] + code[9];
      if (ones < 4 || ones > 6) begin
        errors = errors + 1;
        $display("FAIL %s%0d.%0d rd=%b: %b has %0d ones", k ? "K" : "D", d[4:0], d[7:5], rd, code, ones);
      end
      if ((ones == 6 && !(rd == 1'b0 && rdn == 1'b1)) || (ones == 4 && !(rd == 1'b1 && rdn == 1'b0))
          || (ones == 5 && rdn != rd)) begin
        errors = errors + 1;
        $display("FAIL %s%0d.%0d rd=%b: %b moves the disparity to %b", k ? "K" : "D", d[4:0], d[7:5], rd, code, rdn);
      end
      if (dbad || dd !== d || dk !== k) begin
        errors = errors + 1;
        $display("FAIL %s%0d.%0d rd=%b: %b decodes to %s%0d.%0d bad=%b", k ? "K" : "D", d[4:0], d[7:5], rd, code,
                 dk ? "K" : "D", dd[4:0], dd[7:5], dbad);
      end
      if (owner[code][9] && owner[code][8:0] !== {k, d}) begin
        errors = errors + 1;
        $display("FAIL code %b belongs to two symbols", code);
      end
      if (!owner[code][9]) valid_codes = valid_codes + 1;
      owner[code] = {1'b1, k, d};
    end
  endtask

  initial begin
    errors = 0;
    valid_codes = 0;
    for (i = 0; i < 1024; i = i + 1) owner[i] = 10'd0;

    for (r = 0; r < 2; r = r + 1) begin
      rd = r[0];
      for (i = 0; i < 256; i = i + 1) begin
        d = i[7:0];
        k = 1'b0;
        check_symbol;
        k = 1'b1;
        #1;
        if (bad_k !== !is_k(d)) begin
          errors = errors + 1;
          $display("FAIL bad_k is %b for K code %h", bad_k, d);
        end
        if (is_k(d)) check_symbol;
      end
    end
    // 256 个数据字加 12 个控制字，各有一种或两种写法
    $display("%0d distinct code words", valid_codes);

    // 随机数据流：连续相同位不超过 5，逗号不出现
    rd = 1'b0;
    k = 1'b0;
    run = 0;
    last = 1'b0;
    tail = 7'b0101010;
    for (n = 0; n < 200000; n = n + 1) begin
      d = $random;
      #1;
      for (i = 9; i >= 0; i = i - 1) begin
        cur = code[i];
        run = cur == last ? run + 1 : 1;
        last = cur;
        tail = {tail[5:0], cur};
        if (run > 5) begin
          errors = errors + 1;
          $display("FAIL a run of %0d at symbol %0d", run, n);
        end
        if (tail == 7'b0011111 || tail == 7'b1100000) begin
          errors = errors + 1;
          $display("FAIL a comma inside the data stream at symbol %0d", n);
        end
      end
      rd = rdn;
    end

    if (errors == 0) $display("PASS tb_code");
    else $display("FAILED tb_code: %0d errors", errors);
    $finish;
  end
endmodule
