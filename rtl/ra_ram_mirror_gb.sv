// RetroAchievements RAM Mirror for Game Boy / Game Boy Color — Option C + RTQuery (Tier 1)
//
// Each VBlank, reads a list of specific rcheevos addresses from DDRAM
// (written by ARM), fetches byte values from WRAM BRAM, ZPRAM BRAM, or
// Cart RAM in SDRAM, and writes them back to DDRAM for the ARM to read.
//
// Memory routing (rcheevos address → source):
//   $A000-$BFFF   → Cart RAM bank 0  (SDRAM ch2)
//   $C000-$CFFF   → WRAM bank 0      (BRAM port B)
//   $D000-$DFFF   → WRAM bank 1      (BRAM port B)
//   $E000-$FDFF   → Echo RAM         (mirrors $C000-$DDFF)
//   $FF80-$FFFE   → HRAM / ZPRAM     (BRAM port B)
//   $10000-$15FFF → WRAM banks 2-7   (BRAM port B, GBC only)
//   $16000-$33FFF → Cart RAM banks 1-15 (SDRAM ch2)
//   All other     → return 0x00
//
// DDRAM Layout (at ddram_base_addr, ARM phys 0x3D000000):
//   [0x00000] Header:   magic(32) + 0(8) + flags(8) + 0(16)
//   [0x00008] Frame:    frame_counter(32) + 0(32)
//   [0x00010] Debug:    {ver(8), 0(8), 0(16), timeout_cnt(16), ok_cnt(16)}
//   [0x00018] Debug2:   {0(16), wram_cnt(16), cram_cnt(16), hram_cnt(16)}
//
//   [0x40000] AddrReq:  addr_count(32) + request_id(32)       (ARM → FPGA)
//   [0x40008] Addrs:    addr[0](32) + addr[1](32), ...        (2 per 64-bit word)
//
//   [0x48000] ValResp:  response_id(32) + response_frame(32)  (FPGA → ARM)
//   [0x48008] Values:   val[0..7](8b each), val[8..15], ...   (8 per 64-bit word)

module ra_ram_mirror_gb #(
	parameter [27:1] DDRAM_BASE = 27'h6800000  // ARM phys 0x3D000000
)(
	input             clk,           // clk_sys
	input             reset,
	input             vblank,

	// WRAM BRAM read interface (active when ra_wram_req=1)
	output reg [14:0] wram_addr,
	output reg        wram_req,      // mux select: 1=RA drives port B
	input       [7:0] wram_dout,

	// ZPRAM (HRAM) BRAM read interface
	output reg  [6:0] zpram_addr,
	output reg        zpram_req,
	input       [7:0] zpram_dout,

	// Cart RAM via SDRAM ch2 (8-bit, directly connected)
	output reg [24:0] sdram_addr,
	output reg        sdram_rd,
	input       [7:0] sdram_dout,
	input             sdram_busy,

	// DDRAM ch2 interface (req pulse / ready pulse protocol)
	output reg [27:1] ddram_addr,
	output reg [63:0] ddram_din,
	output reg        ddram_req,
	output reg        ddram_rnw,     // 1=read, 0=write
	output reg  [7:0] ddram_be,
	input      [63:0] ddram_dout,
	input             ddram_ready,

	// Status
	output reg        active,
	output reg [31:0] dbg_frame_counter
);

// ======================================================================
// Constants (byte offsets converted to [27:1] half-word offsets)
// ======================================================================
localparam [27:1] ADDRLIST_BASE = DDRAM_BASE + 27'h20000;  // byte 0x40000 / 2
localparam [27:1] VALCACHE_BASE = DDRAM_BASE + 27'h24000;  // byte 0x48000 / 2
localparam [12:0] MAX_ADDRS     = 13'd4096;

// Realtime query mailbox (Tier 1 smart cache) - [27:1] byte addressing
localparam [27:1] QUERY_CTRL_ADDR = DDRAM_BASE + 27'h28000;  // byte offset 0x50000 / 2
localparam [27:1] QUERY_REQ_BASE  = DDRAM_BASE + 27'h28004;  // byte offset 0x50008 / 2
localparam [27:1] QUERY_RESP_BASE = DDRAM_BASE + 27'h28044;  // byte offset 0x50088 / 2
localparam [27:1] ARM_CFG_ADDR    = DDRAM_BASE + 27'd32;        // byte offset 0x40 / 2: ARM-written config
localparam [3:0]  MAX_RT_QUERIES  = 4'd16;

// Cart RAM SDRAM base address: {2'b01, 6'd0, offset[16:0]}
localparam [24:0] CARTRAM_SDRAM_BASE = {2'b01, 6'd0, 17'd0};

// ======================================================================
// VBlank edge detection
// ======================================================================
reg vblank_prev;
wire vblank_rising = vblank & ~vblank_prev;
always @(posedge clk) vblank_prev <= vblank;

// Sticky vblank flag
reg vblank_pending;
always @(posedge clk) begin
	if (reset)
		vblank_pending <= 1'b0;
	else if (vblank_rising)
		vblank_pending <= 1'b1;
	else if (state == S_IDLE && vblank_pending)
		vblank_pending <= 1'b0;
end

// SDRAM busy edge detection
reg sdram_busy_prev;
wire sdram_data_valid = sdram_busy_prev & ~sdram_busy;
always @(posedge clk) sdram_busy_prev <= sdram_busy;

// ======================================================================
// State machine
// ======================================================================
localparam S_IDLE         = 5'd0;
localparam S_WR_BUSY_HDR  = 5'd1;   // Write header with busy=1
localparam S_WAIT_DDR_WR  = 5'd2;   // Wait DDRAM write ready
localparam S_WAIT_DDR_RD  = 5'd3;   // Wait DDRAM read ready
localparam S_READ_HDR     = 5'd4;   // Issue DDRAM read: addr list header
localparam S_PARSE_HDR    = 5'd5;   // Parse addr_count + request_id
localparam S_READ_PAIR    = 5'd6;   // Issue DDRAM read: address pair
localparam S_PARSE_ADDR   = 5'd7;   // Extract address from word
localparam S_DISPATCH     = 5'd8;   // Route to memory source
localparam S_FETCH_WRAM   = 5'd9;   // Set WRAM BRAM address
localparam S_WRAM_WAIT    = 5'd10;  // Wait for BRAM address register latch
localparam S_FETCH_ZPRAM  = 5'd11;  // Set ZPRAM BRAM address
localparam S_ZPRAM_WAIT   = 5'd12;  // Wait for BRAM address register latch
localparam S_FETCH_CRAM   = 5'd13;  // Issue SDRAM ch2 read
localparam S_CRAM_WAIT    = 5'd14;  // Wait SDRAM
localparam S_STORE_VAL    = 5'd15;  // Store byte in collect buffer
localparam S_FLUSH_BUF    = 5'd16;  // Write collect buffer to DDRAM
localparam S_WRITE_RESP   = 5'd17;  // Write response header
localparam S_WR_HDR0      = 5'd18;  // Write main header (busy=0)
localparam S_WR_HDR1      = 5'd19;  // Write frame counter
localparam S_WR_DBG       = 5'd20;  // Write debug word 1
localparam S_WR_DBG2      = 5'd21;  // Write debug word 2
localparam S_WRAM_READ    = 5'd22;  // Capture WRAM data (after BRAM latency)
localparam S_ZPRAM_READ   = 5'd23;  // Capture ZPRAM data (after BRAM latency)
// Realtime query states
localparam S_QRY_PARSE    = 5'd24;
localparam S_QRY_RD_REQ   = 5'd25;
localparam S_QRY_FETCH    = 5'd26;
localparam S_QRY_WRAM_W   = 5'd27;  // WRAM wait
localparam S_QRY_WRAM_R   = 5'd28;  // WRAM read
localparam S_QRY_ZPRAM_W  = 5'd29;  // ZPRAM wait
localparam S_QRY_ZPRAM_R  = 5'd30;  // ZPRAM read
localparam S_QRY_WR_RESP  = 5'd31;

// Need 6 bits for remaining query states
localparam S_QRY_CRAM     = 6'd32;  // Cart RAM SDRAM read
localparam S_QRY_CRAM_W   = 6'd33;  // Cart RAM wait
localparam S_QRY_WR_CTRL  = 6'd34;
localparam S_RD_ARMCFG    = 6'd35;  // initiate read of ARM config word
localparam S_PARSE_ARMCFG = 6'd36;  // latch rtquery_armed from rd_data[0]
localparam S_QRY_DISPATCH = 6'd37;  // route one query byte by qry_addr (multi-byte loop)

reg [5:0] state;
reg [5:0] return_state;

reg [31:0] frame_counter;
always @(posedge clk) dbg_frame_counter <= frame_counter;

reg [63:0] rd_data;         // Captured DDRAM read data
reg [31:0] req_count;       // Number of addresses in request
reg [31:0] req_id;          // Request ID from ARM
reg [12:0] addr_idx;        // Current address index
reg [63:0] addr_word;       // Cached DDRAM word (2 addresses)
reg [31:0] cur_addr;        // Current rcheevos address
reg [63:0] collect_buf;
reg  [3:0] collect_cnt;     // 0-8 bytes in buffer
reg [12:0] val_word_idx;    // DDRAM word index for value writes
reg  [7:0] fetch_byte;

reg [15:0] sdram_timeout;

// Debug counters (per frame)
reg [15:0] dbg_ok_cnt;
reg [15:0] dbg_timeout_cnt;
reg [15:0] dbg_wram_cnt;
reg [15:0] dbg_cram_cnt;
reg [15:0] dbg_hram_cnt;

// Realtime query registers
reg  [7:0] qry_request_seq;
reg  [7:0] qry_last_seen_seq;
reg  [7:0] qry_num;
reg  [3:0] qry_idx;
reg [31:0] qry_addr;
reg  [7:0] qry_num_bytes;
reg [31:0] qry_value;
reg  [2:0] qry_byte_idx;
reg  [10:0] qry_poll_timer;
reg        rtquery_armed = 1'b0;  // set by ARM via RA_ARM_CFG_RTQUERY bit

// ======================================================================
// Address translation helpers
// ======================================================================
// Translate rcheevos address to WRAM BRAM [14:0] address
// Returns valid=1 if address maps to WRAM
reg [14:0] wram_translated;
reg        wram_valid;

always @(*) begin
	wram_valid = 1'b0;
	wram_translated = 15'd0;

	if (cur_addr >= 32'hC000 && cur_addr <= 32'hCFFF) begin
		// WRAM bank 0: $C000-$CFFF
		wram_translated = {3'd0, cur_addr[11:0]};
		wram_valid = 1'b1;
	end
	else if (cur_addr >= 32'hD000 && cur_addr <= 32'hDFFF) begin
		// WRAM bank 1: $D000-$DFFF
		wram_translated = {3'd1, cur_addr[11:0]};
		wram_valid = 1'b1;
	end
	else if (cur_addr >= 32'hE000 && cur_addr <= 32'hFDFF) begin
		// Echo RAM: mirrors $C000-$DDFF
		if (cur_addr[12])
			wram_translated = {3'd1, cur_addr[11:0]};
		else
			wram_translated = {3'd0, cur_addr[11:0]};
		wram_valid = 1'b1;
	end
	else if (cur_addr >= 32'h10000 && cur_addr <= 32'h15FFF) begin
		// GBC WRAM banks 2-7: $10000-$15FFF
		// Bank = (addr - $10000) / $1000 + 2
		wram_translated = {cur_addr[14:12] + 3'd2, cur_addr[11:0]};
		wram_valid = 1'b1;
	end
end

// Translate rcheevos address to Cart RAM SDRAM address [24:0]
// Returns valid=1 if address maps to Cart RAM
reg [24:0] cram_translated;
reg        cram_valid;

always @(*) begin
	cram_valid = 1'b0;
	cram_translated = 25'd0;

	if (cur_addr >= 32'hA000 && cur_addr <= 32'hBFFF) begin
		// Cart RAM bank 0: $A000-$BFFF → offset 0-8191
		cram_translated = CARTRAM_SDRAM_BASE + {12'd0, cur_addr[12:0]};
		cram_valid = 1'b1;
	end
	else if (cur_addr >= 32'h16000 && cur_addr <= 32'h33FFF) begin
		// Cart RAM banks 1-15: $16000-$33FFF → offset 8192+
		cram_translated = CARTRAM_SDRAM_BASE + {7'd0, cur_addr[17:0]} - 25'h16000 + 25'h2000;
		cram_valid = 1'b1;
	end
end

// Translate rcheevos address to ZPRAM (HRAM) address [6:0]
reg  [6:0] zpram_translated;
reg        zpram_valid;

always @(*) begin
	zpram_valid = 1'b0;
	zpram_translated = 7'd0;

	if (cur_addr >= 32'hFF80 && cur_addr <= 32'hFFFE) begin
		zpram_translated = cur_addr[6:0];
		zpram_valid = 1'b1;
	end
end

// ======================================================================
// Main state machine
// ======================================================================
always @(posedge clk) begin
	// Defaults: deassert single-cycle signals
	ddram_req <= 1'b0;
	sdram_rd  <= 1'b0;

	if (reset) begin
		state         <= S_IDLE;
		active        <= 1'b0;
		frame_counter <= 32'd0;
		wram_req      <= 1'b0;
		zpram_req     <= 1'b0;
		qry_last_seen_seq <= 8'd0;
		qry_poll_timer <= 11'd0;
	end
	else begin
		case (state)

		// =============================================================
		// IDLE: Wait for VBlank rising edge
		// =============================================================
		S_IDLE: begin
			active   <= 1'b0;
			wram_req <= 1'b0;
			zpram_req <= 1'b0;
			if (vblank_pending) begin
				active <= 1'b1;
				qry_poll_timer  <= 10'd0;
				dbg_ok_cnt      <= 16'd0;
				dbg_timeout_cnt <= 16'd0;
				dbg_wram_cnt    <= 16'd0;
				dbg_cram_cnt    <= 16'd0;
				dbg_hram_cnt    <= 16'd0;
				state           <= S_WR_BUSY_HDR;
			end
			else if (qry_poll_timer < 11'd2000) begin
				qry_poll_timer <= qry_poll_timer + 11'd1;
			end
			else if (rtquery_armed) begin
				qry_poll_timer <= 11'd0;
				ddram_addr   <= QUERY_CTRL_ADDR;
				ddram_rnw    <= 1'b1;
				ddram_be     <= 8'hFF;
				ddram_req    <= 1'b1;
				return_state <= S_QRY_PARSE;
				state        <= S_WAIT_DDR_RD;
			end
			else begin
				qry_poll_timer <= 11'd0;  // no rtquery active, skip poll
			end
		end

		// =============================================================
		// Write header with busy=1
		// =============================================================
		S_WR_BUSY_HDR: begin
			ddram_addr   <= DDRAM_BASE;
			ddram_din    <= {16'd0, 8'h01, 8'd0, 32'h52414348}; // "RACH", busy=1
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_READ_HDR;
			state        <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Wait DDRAM write ready
		// =============================================================
		S_WAIT_DDR_WR: begin
			if (ddram_ready)
				state <= return_state;
		end

		// =============================================================
		// Wait DDRAM read ready — capture data
		// =============================================================
		S_WAIT_DDR_RD: begin
			if (ddram_ready) begin
				rd_data <= ddram_dout;
				state   <= return_state;
			end
		end

		// =============================================================
		// Read address list header from DDRAM
		// =============================================================
		S_READ_HDR: begin
			ddram_addr   <= ADDRLIST_BASE;
			ddram_rnw    <= 1'b1;
			ddram_be     <= 8'hFF;
			ddram_req    <= 1'b1;
			return_state <= S_PARSE_HDR;
			state        <= S_WAIT_DDR_RD;
		end

		// =============================================================
		// Parse header: addr_count and request_id
		// =============================================================
		S_PARSE_HDR: begin
			req_id <= rd_data[63:32];
			if (rd_data[31:0] == 32'd0) begin
				req_count <= 32'd0;
				state     <= S_WRITE_RESP;
			end else begin
				req_count    <= (rd_data[31:0] > {19'd0, MAX_ADDRS}) ?
				                {19'd0, MAX_ADDRS} : rd_data[31:0];
				addr_idx     <= 13'd0;
				collect_cnt  <= 4'd0;
				collect_buf  <= 64'd0;
				val_word_idx <= 13'd0;
				state        <= S_READ_PAIR;
			end
		end

		// =============================================================
		// Read address pair from DDRAM (2 addrs per 64-bit word)
		// =============================================================
		S_READ_PAIR: begin
			// Word at: ADDRLIST_BASE + 4 (header offset) + addr_idx/2 * 4
			ddram_addr   <= ADDRLIST_BASE + 27'd4 + {14'd0, addr_idx[12:1], 2'b00};
			ddram_rnw    <= 1'b1;
			ddram_be     <= 8'hFF;
			ddram_req    <= 1'b1;
			return_state <= S_PARSE_ADDR;
			state        <= S_WAIT_DDR_RD;
		end

		// =============================================================
		// Extract current address from cached word
		// =============================================================
		S_PARSE_ADDR: begin
			if (!addr_idx[0]) begin
				addr_word <= rd_data;
				cur_addr  <= rd_data[31:0];
			end else begin
				cur_addr <= addr_word[63:32];
			end
			state <= S_DISPATCH;
		end

		// =============================================================
		// Route to WRAM, ZPRAM, or Cart RAM
		// =============================================================
		S_DISPATCH: begin
			if (wram_valid) begin
				dbg_wram_cnt <= dbg_wram_cnt + 16'd1;
				state <= S_FETCH_WRAM;
			end
			else if (cram_valid) begin
				dbg_cram_cnt <= dbg_cram_cnt + 16'd1;
				state <= S_FETCH_CRAM;
			end
			else if (zpram_valid) begin
				dbg_hram_cnt <= dbg_hram_cnt + 16'd1;
				state <= S_FETCH_ZPRAM;
			end
			else begin
				// Unmapped address: return 0
				fetch_byte <= 8'd0;
				state      <= S_STORE_VAL;
			end
		end

		// =============================================================
		// WRAM: set BRAM address, wait for registered addr + unregistered output
		// Cycle N:   S_FETCH_WRAM — set wram_addr, wram_req
		// Cycle N+1: S_WRAM_WAIT  — BRAM address register latches
		// Cycle N+2: S_WRAM_READ  — q_b valid (unregistered output)
		// =============================================================
		S_FETCH_WRAM: begin
			wram_addr <= wram_translated;
			wram_req  <= 1'b1;
			state     <= S_WRAM_WAIT;
		end

		S_WRAM_WAIT: begin
			// BRAM address register latches this cycle; output not yet valid
			state <= S_WRAM_READ;
		end

		S_WRAM_READ: begin
			// BRAM unregistered output now valid
			fetch_byte <= wram_dout;
			wram_req   <= 1'b0;
			dbg_ok_cnt <= dbg_ok_cnt + 16'd1;
			state      <= S_STORE_VAL;
		end

		// =============================================================
		// ZPRAM (HRAM): same 2-cycle latency as WRAM
		// =============================================================
		S_FETCH_ZPRAM: begin
			zpram_addr <= zpram_translated;
			zpram_req  <= 1'b1;
			state      <= S_ZPRAM_WAIT;
		end

		S_ZPRAM_WAIT: begin
			state <= S_ZPRAM_READ;
		end

		S_ZPRAM_READ: begin
			fetch_byte <= zpram_dout;
			zpram_req  <= 1'b0;
			dbg_ok_cnt <= dbg_ok_cnt + 16'd1;
			state      <= S_STORE_VAL;
		end

		// =============================================================
		// Cart RAM: SDRAM ch2 read (8-bit, busy/data_valid protocol)
		// =============================================================
		S_FETCH_CRAM: begin
			sdram_addr    <= cram_translated;
			sdram_rd      <= 1'b1;
			sdram_timeout <= 16'd0;
			state         <= S_CRAM_WAIT;
		end

		S_CRAM_WAIT: begin
			sdram_timeout <= sdram_timeout + 16'd1;

			// Re-pulse sdram_rd every 16 cycles if not yet accepted
			if (~sdram_busy && ~sdram_busy_prev && sdram_timeout != 16'd0 && sdram_timeout[3:0] == 4'd0)
				sdram_rd <= 1'b1;

			// Timeout safety (~3ms)
			if (sdram_timeout >= 16'hFFFF) begin
				fetch_byte      <= 8'd0;
				dbg_timeout_cnt <= dbg_timeout_cnt + 16'd1;
				state           <= S_STORE_VAL;
			end
			else if (sdram_data_valid) begin
				fetch_byte <= sdram_dout;
				dbg_ok_cnt <= dbg_ok_cnt + 16'd1;
				state      <= S_STORE_VAL;
			end
		end

		// =============================================================
		// Store byte in collect buffer
		// =============================================================
		S_STORE_VAL: begin
			case (collect_cnt[2:0])
				3'd0: collect_buf[ 7: 0] <= fetch_byte;
				3'd1: collect_buf[15: 8] <= fetch_byte;
				3'd2: collect_buf[23:16] <= fetch_byte;
				3'd3: collect_buf[31:24] <= fetch_byte;
				3'd4: collect_buf[39:32] <= fetch_byte;
				3'd5: collect_buf[47:40] <= fetch_byte;
				3'd6: collect_buf[55:48] <= fetch_byte;
				3'd7: collect_buf[63:56] <= fetch_byte;
			endcase
			collect_cnt <= collect_cnt + 4'd1;
			addr_idx    <= addr_idx + 13'd1;

			if (collect_cnt == 4'd7 || (addr_idx + 13'd1 >= req_count[12:0])) begin
				state <= S_FLUSH_BUF;
			end
			else if (addr_idx[0]) begin
				// Was odd → next is even → need new pair from DDRAM
				state <= S_READ_PAIR;
			end else begin
				// Was even → next is odd → use cached high half
				state <= S_PARSE_ADDR;
			end
		end

		// =============================================================
		// Flush collect buffer to DDRAM value cache
		// =============================================================
		S_FLUSH_BUF: begin
			// Value data at: VALCACHE_BASE + 4 (resp header) + val_word_idx * 4
			ddram_addr <= VALCACHE_BASE + 27'd4 + {14'd0, val_word_idx[12:0], 2'b00};
			ddram_din  <= collect_buf;
			ddram_be   <= (collect_cnt == 4'd8) ? 8'hFF
			             : ((8'd1 << collect_cnt[2:0]) - 8'd1);
			ddram_rnw  <= 1'b0;
			ddram_req  <= 1'b1;
			val_word_idx <= val_word_idx + 13'd1;
			collect_cnt  <= 4'd0;
			collect_buf  <= 64'd0;

			if (addr_idx >= req_count[12:0])
				return_state <= S_WRITE_RESP;
			else if (!addr_idx[0])
				return_state <= S_READ_PAIR;
			else
				return_state <= S_PARSE_ADDR;

			state <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Write response header: {response_frame, response_id}
		// =============================================================
		S_WRITE_RESP: begin
			ddram_addr   <= VALCACHE_BASE;
			ddram_din    <= {frame_counter + 32'd1, req_id};
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_WR_HDR0;
			state        <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Write main header (busy=0)
		// =============================================================
		S_WR_HDR0: begin
			ddram_addr   <= DDRAM_BASE;
			ddram_din    <= {16'd0, 8'h00, 8'd0, 32'h52414348}; // busy=0
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_WR_HDR1;
			state        <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Write frame counter (word 1)
		// =============================================================
		S_WR_HDR1: begin
			ddram_addr    <= DDRAM_BASE + 27'd4;
			ddram_din     <= {32'd0, frame_counter + 32'd1};
			ddram_be      <= 8'hFF;
			ddram_rnw     <= 1'b0;
			ddram_req     <= 1'b1;
			frame_counter <= frame_counter + 32'd1;
			return_state  <= S_WR_DBG;
			state         <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Write debug word 1
		// =============================================================
		S_WR_DBG: begin
			ddram_addr   <= DDRAM_BASE + 27'd8;
			ddram_din    <= {8'h02, 8'd0, 16'd0, dbg_timeout_cnt, dbg_ok_cnt};
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_WR_DBG2;
			state        <= S_WAIT_DDR_WR;
		end

		// =============================================================
		// Write debug word 2
		// =============================================================
		S_WR_DBG2: begin
			ddram_addr   <= DDRAM_BASE + 27'd12;
			ddram_din    <= {16'd0, dbg_wram_cnt, dbg_cram_cnt, dbg_hram_cnt};
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_RD_ARMCFG;  // read ARM config before returning to idle
			state        <= S_WAIT_DDR_WR;
		end

		// Read ARM-written config byte once per VBlank.
		// ARM sets RA_ARM_CFG_RTQUERY (bit 0) when rtquery is active.
		// FPGA latches it to gate inter-VBlank query mailbox polling.
		S_RD_ARMCFG: begin
			ddram_addr   <= ARM_CFG_ADDR;
			ddram_rnw    <= 1'b1;
			ddram_be     <= 8'hFF;
			ddram_req    <= 1'b1;
			return_state <= S_PARSE_ARMCFG;
			state        <= S_WAIT_DDR_RD;
		end

		S_PARSE_ARMCFG: begin
			rtquery_armed <= rd_data[0];
			state <= S_IDLE;
		end

		// =============================================================
		// Realtime Query States
		// =============================================================
		S_QRY_PARSE: begin
			if (rd_data[7:0] != qry_last_seen_seq && rd_data[15:8] != 8'd0) begin
				qry_request_seq <= rd_data[7:0];
				qry_num         <= (rd_data[15:8] > {4'd0, MAX_RT_QUERIES}) ?
				                   {4'd0, MAX_RT_QUERIES} : rd_data[15:8];
				qry_idx         <= 4'd0;
				state           <= S_QRY_RD_REQ;
			end else begin
				state <= S_IDLE;
			end
		end

		S_QRY_RD_REQ: begin
			ddram_addr   <= QUERY_REQ_BASE + {23'd0, qry_idx[3:0], 2'b00};
			ddram_rnw    <= 1'b1;
			ddram_be     <= 8'hFF;
			ddram_req    <= 1'b1;
			return_state <= S_QRY_FETCH;
			state        <= S_WAIT_DDR_RD;
		end

		S_QRY_FETCH: begin
			qry_addr      <= rd_data[31:0];
			qry_num_bytes <= (rd_data[39:32] == 8'd0) ? 8'd1 : rd_data[39:32];
			qry_value     <= 32'd0;
			qry_byte_idx  <= 3'd0;
			state         <= S_QRY_DISPATCH;
		end

		// Route ONE query byte based on qry_addr. Multi-byte reads (2/4,
		// issued by the ARM smart-cache miss path) loop back here with
		// qry_addr+1 so each byte is translated independently — the old
		// code routed only from rd_data and returned just byte 0
		// ("single byte per query"), truncating 16/32-bit rtquery values.
		S_QRY_DISPATCH: begin
			cur_addr <= qry_addr;
			if (qry_addr >= 32'hC000 && qry_addr <= 32'hDFFF) begin
				// WRAM bank 0 or 1
				if (qry_addr >= 32'hD000)
					wram_addr <= {3'd1, qry_addr[11:0]};
				else
					wram_addr <= {3'd0, qry_addr[11:0]};
				wram_req <= 1'b1;
				state    <= S_QRY_WRAM_W;
			end
			else if (qry_addr >= 32'hE000 && qry_addr <= 32'hFDFF) begin
				// Echo RAM
				if (qry_addr[12])
					wram_addr <= {3'd1, qry_addr[11:0]};
				else
					wram_addr <= {3'd0, qry_addr[11:0]};
				wram_req <= 1'b1;
				state    <= S_QRY_WRAM_W;
			end
			else if (qry_addr >= 32'h10000 && qry_addr <= 32'h15FFF) begin
				// GBC WRAM banks 2-7
				wram_addr <= {qry_addr[14:12] + 3'd2, qry_addr[11:0]};
				wram_req  <= 1'b1;
				state     <= S_QRY_WRAM_W;
			end
			else if (qry_addr >= 32'hFF80 && qry_addr <= 32'hFFFE) begin
				// ZPRAM (HRAM)
				zpram_addr <= qry_addr[6:0];
				zpram_req  <= 1'b1;
				state      <= S_QRY_ZPRAM_W;
			end
			else if ((qry_addr >= 32'hA000 && qry_addr <= 32'hBFFF) ||
			         (qry_addr >= 32'h16000 && qry_addr <= 32'h33FFF)) begin
				// Cart RAM (SDRAM)
				state <= S_QRY_CRAM;
			end
			else begin
				// Unmapped: this byte contributes 0
				qry_byte_idx <= qry_byte_idx + 3'd1;
				if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
					state <= S_QRY_WR_RESP;
				end else begin
					qry_addr <= qry_addr + 32'd1;  // next byte, stay in dispatch
				end
			end
		end

		S_QRY_WRAM_W: begin
			// BRAM address latched
			state <= S_QRY_WRAM_R;
		end

		S_QRY_WRAM_R: begin
			qry_value    <= qry_value | ({24'd0, wram_dout} << (qry_byte_idx * 8));
			wram_req     <= 1'b0;
			qry_byte_idx <= qry_byte_idx + 3'd1;
			if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
				state <= S_QRY_WR_RESP;
			end else begin
				qry_addr <= qry_addr + 32'd1;
				state    <= S_QRY_DISPATCH;
			end
		end

		S_QRY_ZPRAM_W: begin
			state <= S_QRY_ZPRAM_R;
		end

		S_QRY_ZPRAM_R: begin
			qry_value    <= qry_value | ({24'd0, zpram_dout} << (qry_byte_idx * 8));
			zpram_req    <= 1'b0;
			qry_byte_idx <= qry_byte_idx + 3'd1;
			if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
				state <= S_QRY_WR_RESP;
			end else begin
				qry_addr <= qry_addr + 32'd1;
				state    <= S_QRY_DISPATCH;
			end
		end

		S_QRY_CRAM: begin
			// Translate address to SDRAM offset
			if (qry_addr >= 32'hA000 && qry_addr <= 32'hBFFF)
				sdram_addr <= CARTRAM_SDRAM_BASE + {12'd0, qry_addr[12:0]};
			else
				sdram_addr <= CARTRAM_SDRAM_BASE + {7'd0, qry_addr[17:0]} - 25'h16000 + 25'h2000;
			sdram_rd      <= 1'b1;
			sdram_timeout <= 16'd0;
			state         <= S_QRY_CRAM_W;
		end

		S_QRY_CRAM_W: begin
			sdram_timeout <= sdram_timeout + 16'd1;
			if (sdram_timeout >= 16'hFFFF) begin
				// SDRAM channel dead: bail out with what we have
				state <= S_QRY_WR_RESP;
			end
			else if (sdram_data_valid) begin
				qry_value    <= qry_value | ({24'd0, sdram_dout} << (qry_byte_idx * 8));
				qry_byte_idx <= qry_byte_idx + 3'd1;
				if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
					state <= S_QRY_WR_RESP;
				end else begin
					qry_addr <= qry_addr + 32'd1;
					state    <= S_QRY_DISPATCH;
				end
			end
		end

		S_QRY_WR_RESP: begin
			ddram_addr   <= QUERY_RESP_BASE + {23'd0, qry_idx[3:0], 2'b00};
			ddram_din    <= {32'd0, qry_value};
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			qry_idx      <= qry_idx + 4'd1;
			if (qry_idx + 4'd1 >= qry_num[3:0])
				return_state <= S_QRY_WR_CTRL;
			else
				return_state <= S_QRY_RD_REQ;
			state <= S_WAIT_DDR_WR;
		end

		S_QRY_WR_CTRL: begin
			qry_last_seen_seq <= qry_request_seq;
			ddram_addr   <= QUERY_CTRL_ADDR;
			ddram_din    <= {24'd0, qry_request_seq, 16'd0, qry_num[7:0], qry_request_seq};
			ddram_be     <= 8'hFF;
			ddram_rnw    <= 1'b0;
			ddram_req    <= 1'b1;
			return_state <= S_IDLE;
			state        <= S_WAIT_DDR_WR;
		end

		default: state <= S_IDLE;
		endcase
	end
end

endmodule
