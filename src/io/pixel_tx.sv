`default_nettype wire

// Sends each pixel from the Accumulator to the host as a PIXEL message:
// PIXEL_START, R, G, B, with DLE in front of any colour byte that is 0x00 or
// 0x03. See docs/encoding/uart_frame.md.
module pixel_tx (
    input  logic       clk,
    input  logic       rst_n,

    colour_if.sink     pixel,   // pixel colour {r, g, b}, from Accumulator
    stream_if.src      tx       // byte stream, to UART
);

    // The pixel is copied on accept so the Accumulator is free for the next
    // one while these bytes go out. The current colour byte is always the top
    // 8 bits; the register shifts left by 8 after each colour byte.
    logic [3*tinytracer_pkg::COLOUR_DEPTH-1:0] colour_reg;
    logic [1:0] byte_idx;   // 0 = PIXEL_START, 1 = R, 2 = G, 3 = B
    logic       esc_sent;   // DLE for the current colour byte already sent
    logic       busy;       // a pixel is held and being sent

    // Take a new pixel only when the last one is fully sent.
    assign pixel.ready = !busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            colour_reg <= '0;
            byte_idx   <= 2'd0;
            esc_sent   <= 1'b0;
            busy       <= 1'b0;
        end else if (pixel.valid && pixel.ready) begin
            colour_reg <= pixel.colour;
            byte_idx   <= 2'd0;
            esc_sent   <= 1'b0;
            busy       <= 1'b1;
        end
    end

endmodule
