`default_nettype wire

module io (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [1:0]  clkdiv_ctl,
    input  logic [7:0]  clkdiv_data,

    ///////////////////////////
    //  I/O -> RTU Interface //
    ///////////////////////////

    render_if.src       render,   // render strobe and image dimensions, to RTU

    //////////////////////
    //  UART Interface  //
    //////////////////////

    input  logic        uart_rx,  // serial data from the host device
    output logic        uart_tx,  // serial data to the host device

    ////////////////////////////////////
    //  Accumulator -> I/O Interface  //
    ////////////////////////////////////

    colour_if.sink      pixel,    // pixel colour stream (W = COLOUR_DEPTH), from Accumulator

    ///////////////////////////
    // I/O -> SRAM Interface //
    ///////////////////////////

    sram_wr_if.client   sram
);


    localparam logic [7:0] RENDER_START = 8'h00; //basically it will recognize messages as render messages if they start with first byte of 0
    localparam logic [7:0] OBJ_START = 8'h01; //same for all these
    localparam logic [7:0] PIXEL_START = 8'h00;
    localparam logic [7:0] DLE = 8'h03; //basically every payload byte equal to 00, 01, or 03 will get a 03 added before it because it matches a starter

    localparam int DIM_W = tinytracer_pkg::DIM_WIDTH; //defined as 12
    localparam int COLOUR_W = tinytracer_pkg::COLOUR_DEPTH; //8
    localparam int ADDR_W = tinytracer_pkg::ADDR_WIDTH; //9
    localparam int DATA_W = tinytracer_pkg::DATA_WIDTH; //16




    /////////////////////////////
    //  UART <-> I/O Interface //
    /////////////////////////////

    stream_if #(.W(8)) rx_bytes ();  // receive byte stream, from UART
    stream_if #(.W(8)) tx_bytes ();  // transmit byte stream, to UART


    logic [7:0] b_reg;
    logic [7:0] c_reg;
    logic clkq;

    uart u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .clkq  (clkq),
        .rx    (rx_bytes),
        .tx    (tx_bytes),
        .TT_RX (uart_rx),
        .TT_TX (uart_tx)
    );

    clkdiv u_clkdiv (
        .clk(clk),
        .rst_n(rst_n),
        .b(b_reg),
        .c(c_reg),
        .q(clkq)
    );


    logic [1:0] clkdiv_ctl_meta;
    logic [1:0] clkdiv_ctl_sync; //clkdiv_ctl sets which divider setting to change
    logic [7:0] clkdiv_data_meta;
    logic [7:0] clkdiv_data_sync; //clkdiv_data sets what value to write

    //next part is reset part of clocked block, clears registers used to synchronize clock-divider control signals
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin //if reset is low, clear all registers to default values
            clkdiv_ctl_meta  <= 2'b00;
            clkdiv_ctl_sync  <= 2'b00;
            clkdiv_data_meta <= 8'h00;
            clkdiv_data_sync <= 8'h00;
            b_reg <= 8'd104; //found in the clkdiv module, this is the default value for the b register, which is used to set the baud rate of the UART
            c_reg <= 8'hEE;
        end else begin //if reset is high, synchronize the control signals and update the registers based on the control signals
            clkdiv_ctl_meta  <= clkdiv_ctl; 
            clkdiv_ctl_sync  <= clkdiv_ctl_meta;
            clkdiv_data_meta <= clkdiv_data;
            clkdiv_data_sync <= clkdiv_data_meta;

            case (clkdiv_ctl_sync) //looks at current value of clkdivctlsyn and sees what to do
                2'b10: b_reg <= clkdiv_data_sync; //if its binary 10, copy to b_reg
                2'b11: c_reg <= clkdiv_data_sync; //if itsb11, copy to c_reg
                2'b00: ; //if its 00, do nothing
                2'b01: ; //if its 01, do nothing
                default: ;
            endcase
        end
    end
    //uart recieve and parser
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_RENDER,
        RX_OBJECT
    } parser_state_t;
//basically parser_state_t can take one of 3 values of idle, render and obj and will handle it accordinly which it can recognize the types via the first byte of the message, as defined earlier
//parser is just something to determine whether something is an ovject or a render message, and then send the data to the appropriate interface, and it will also handle the escape character, which is 03, which is used to escape the start bytes of 00 and 01, so that they can be sent as data bytes instead of being recognized as start bytes
    parser_state_t rx_state;
    logic rx_escape; //used for the escape character, 03
    logic [1:0] rx_index; //seeing how many bytes received in current message, used to know when to switch states
    logic [7:0] dim_low; //used to store low bype of dimension, which is 12, so needs 2 bytes
    logic [7:0] object_data_low; //low byte of data, which is 16, so 2 bytes
    logic [7:0] object_addr_low; //low byte of address, which is 9, so 2 bytes
    //these are all registers used to remember the information the parser has recieved so far, and will just send to the appropriate render or sram interface when the message completes

    logic sram_pending; //shows that message is being sent to sram and is waiting for sram to receive so that the parser can continue to recieve more messages, because sram is not a stream interface, so the parser has to wait for the sram to finish before it can recieve more messages, and so this tells the parser to wait until the sram is done before it can continue to recieve more messages
    logic [ADDR_W-1:0] sram_addr_reg; //register to hold the address of the sram message being sent, so that the parser can continue to recieve more messages while the sram is processing the current message
    logic [DATA_W-1:0] sram_data_reg; //holds data for the same reason above
    
    wire rx_fire = rx_bytes.valid && rx_bytes.ready; //wire just declared to show when a byte has been recieved, so that the parser can know when to process the byte and update its state accordingly

    //accept another input byte unless the sram write buffer is full
    always_comb begin
       rx_bytes.ready = !sram_pending || sram.req_ready; //if sram is not pending or is ready to accept new req, then it will accept new bytes, otherwise it will not

    end

    assign sram.req_valid = sram_pending; // purpose is that if sram_pending is 1, then sram.req_valid will be 1, which means that the sram interface will know that there is a request pending and it should process it, and if sram_pending is 0, then sram.req_valid will be 0, which means that the sram interface will know that there is no request pending and it should not process anything
    assign sram.req_wen = 1'b1; //always writing to sram, so this is always 1
    assign sram.req_waddr = sram_addr_reg; // basically just the address of sram, note that w stands for write, so this is the address that the sram will write to
    assign sram.req_wdata = sram_data_reg; // basically just the data of the sram

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state        <= RX_IDLE;
            rx_escape       <= 1'b0;
            rx_index        <= 2'd0;
            dim_low         <= 8'h00;
            object_data_low <= 8'h00;
            object_addr_low <= 8'h00;

            sram_pending <= 1'b0;
            sram_addr_reg <= '0;
            sram_data_reg <= '0;

            render.render <= 1'b0;
            render.img_w  <= '0;
            render.img_h  <= '0;
            //basically when reset is active, all registers will be cleared to 0, and parser will be in idle state, sram wont be pending, render to 0

        end else begin
            render.render <= 1'b0;

            if (sram_pending && sram.req_ready)
                sram_pending <= 1'b0;

            if (rx_fire) begin
                if (rx_escape) begin
                    // The byte after DLE is payload, even if it is 00, 01, or 03.
                    rx_escape <= 1'b0;
                end else if (rx_bytes.data == DLE) begin
                    rx_escape <= 1'b1;
                end
            end
            //the above code handles the escape character by setting rx_escape to 1 when DLE (03) is recieved, and then the next byte will be treated as payload, even if it is 00, 01, or 03, and then rx_escape will be set back to 0 after that byte is processed
            if (rx_fire &&
                (rx_escape || rx_bytes.data != DLE) &&
                rx_state != RX_IDLE) begin

                case (rx_state)
                    RX_RENDER: begin
                        case (rx_index)
                            2'd0: begin
                                dim_low <= rx_bytes.data;
                                rx_index <= 2'd1;
                            end
                            //like goes throug hte first byte of the render message, which is the low byte of the width, and then goes to the next index to get the next byte, which is the high byte of the width

                            2'd1: begin
                                render.img_w <= {rx_bytes.data[3:0], dim_low};
                                rx_index <= 2'd2;
                            end
                            //width

                            2'd2: begin
                                dim_low <= rx_bytes.data;
                                rx_index <= 2'd3;
                            end
                            //height

                            2'd3: begin
                                render.img_h <= {rx_bytes.data[3:0], dim_low};
                                render.render <= 1'b1;
                                rx_state <= RX_IDLE;
                                rx_index <= 2'd0;
                            end
                            
                            default: begin
                                rx_state <= RX_IDLE;
                                rx_index <= 2'd0;
                            end
                        endcase
                    end
                    //essentially, the case aboce deals with the render message, which is 4 bytes long, and will store the width and height of the image that should be rendered, and then will set the render.render signal to 1 to tell the RTU that it should start rendering the image, and then will go back to idle state

                    RX_OBJECT: begin
                        case (rx_index)
                            2'd0: begin
                                object_data_low <= rx_bytes.data;
                                rx_index <= 2'd1;
                            end
                            //basically does the same thing with the object message, which is 4 bytes long, and will store the low byte of the data, and then will go to the next index to get the next byte, which is the high byte of the data

                            2'd1: begin
                                object_addr_low <= 8'h00;
                                // Temporarily keep the high data byte here;
                                // it is combined with object_data_low at the end.
                                sram_data_reg[15:8] <= rx_bytes.data;
                                rx_index <= 2'd2;
                            end
                            //here, the low byte of the address is set to 0, and the high byte of the data is stored in the sram_data_reg, and then goes to the next index to get the next byte, which is the low byte of the address

                            2'd2: begin
                                object_addr_low <= rx_bytes.data;
                                rx_index <= 2'd3;
                            end

                            2'd3: begin
                                sram_addr_reg <= {rx_bytes.data[0], object_addr_low};
                                sram_data_reg[7:0] <= object_data_low;
                                sram_pending <= 1'b1;
                                rx_state <= RX_IDLE;
                                rx_index <= 2'd0;
                            end
                            //here, the high byte of the address is stored in the sram_addr_reg, and the low byte of the data is stored in the sram_data_reg, and then sram_pending is set to 1 to tell the sram interface that there is a request pending, and then goes back to idle state

                            default: begin
                                rx_state <= RX_IDLE;
                                rx_index <= 2'd0;
                            end
                        endcase
                    end

                    default: begin
                        rx_state <= RX_IDLE;
                        rx_index <= 2'd0;
                    end
                endcase
            end
            //essentially this entire big if statement is the main parser logic, which configures the parser to specifically handle the render and object messages, and will store the data in the appropriate registers, and then will set the appropriate signals to tell the RTU or sram interface that there is a request pending, and then will go back to idle state
            if (rx_fire && !rx_escape && rx_bytes.data != DLE &&
                rx_state == RX_IDLE) begin
                    //saying that if the conditions of a byte being recieved, not being an escape character, and not being a DLE character, and the parser is in idle state, then it will check the first byte of the message to see if it is a render or object message, and then will set the appropriate state and index to start processing the message
                case (rx_bytes.data)
                    RENDER_START: begin
                        rx_state <= RX_RENDER;
                        rx_index <= 2'd0;
                    end
                    //if the first byte of the message is 00, then it will set the state to RX_RENDER and the index to 0, to start processing the render message

                    OBJ_START: begin
                        rx_state <= RX_OBJECT;
                        rx_index <= 2'd0;
                    end
                    //the same thing but for the object message

                    default: begin
                        rx_state <= RX_IDLE;
                        rx_index <= 2'd0;
                    end
                    //if neither of the above, will just stay idle
                endcase

            end
            //
        end
    end


endmodule
