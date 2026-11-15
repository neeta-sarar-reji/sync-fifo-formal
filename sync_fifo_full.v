module sync_fifo_full #(parameter DEPTH = 8, DWIDTH = 16) (
  input                    clk,
  input                    rstn,
  input                    wr_en,
  input                    rd_en,
  input      [DWIDTH-1:0]  din,
  output reg [DWIDTH-1:0]  dout,
  output                   empty,
  output                   full,
  output [$clog2(DEPTH):0] count
);

  localparam AW = $clog2(DEPTH);

  generate
    if (DEPTH < 2 || (DEPTH & (DEPTH-1)) != 0) begin : g_bad_depth
      $error("DEPTH must be a power of two and >= 2");
    end
  endgenerate

  reg [DWIDTH-1:0] fifo [0:DEPTH-1];
  reg [AW:0]       wptr, rptr;

  wire do_wr = wr_en & !full;
  wire do_rd = rd_en & !empty;

  always @(posedge clk) begin
    if (!rstn) wptr <= 0;
    else if (do_wr) begin
      fifo[wptr[AW-1:0]] <= din;
      wptr <= wptr + 1'b1;
    end
  end

  always @(posedge clk) begin
    if (!rstn) begin
      rptr <= 0;
      dout <= 0;
    end else if (do_rd) begin
      dout <= fifo[rptr[AW-1:0]];
      rptr <= rptr + 1'b1;
    end
  end

  assign empty = (wptr == rptr);
  assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
  assign count = wptr - rptr;

`ifdef FORMAL
  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1;

  always @(*) if (!f_past_valid) assume(!rstn);

  always @(posedge clk) if (rstn) begin
    assert(count <= DEPTH);
    assert(empty == (count == 0));
    assert(full  == (count == DEPTH));
    assert(!(full && empty));
  end

  always @(posedge clk)
    if (f_past_valid && $past(!rstn)) begin
      assert(wptr == 0);
      assert(rptr == 0);
      assert(dout == 0);
    end

  always @(posedge clk)
    if (f_past_valid && $past(rstn) && rstn) begin
      case ({$past(do_wr), $past(do_rd)})
        2'b10:   assert(count == $past(count) + 1'b1);
        2'b01:   assert(count == $past(count) - 1'b1);
        default: assert(count == $past(count));
      endcase
    end

  always @(posedge clk)
    if (f_past_valid && $past(rstn)) begin
      if (!$past(do_wr)) assert(wptr == $past(wptr));
      if (!$past(do_rd)) assert(rptr == $past(rptr));
    end

  (* anyconst *) wire [AW:0]       f_idx;
  (* anyconst *) wire [DWIDTH-1:0] f_data;

  reg f_tracked = 0;
  reg f_rd_chk  = 0;

  wire [AW:0] f_off = f_idx - rptr;

  always @(posedge clk) begin
    f_rd_chk <= 0;
    if (!rstn) f_tracked <= 0;
    else begin
      if (do_wr && wptr == f_idx) begin
        assume(din == f_data);
        f_tracked <= 1;
      end
      if (do_rd && rptr == f_idx) begin
        f_tracked <= 0;
        f_rd_chk  <= 1;
      end
    end
  end

  always @(posedge clk)
    if (f_past_valid && f_rd_chk) assert(dout == f_data);

  always @(posedge clk) if (rstn) begin
    assert(f_tracked == (f_off < count));
    if (f_tracked)
      assert(fifo[f_idx[AW-1:0]] == f_data);
  end

  always @(posedge clk) if (f_past_valid) begin
    cover(rstn && full);
    cover(rstn && empty && $past(full));
    cover(rstn && count == DEPTH/2);
    cover(rstn && f_rd_chk);
    cover(rstn && wptr[AW] && rptr[AW]);
  end
`endif

endmodule
