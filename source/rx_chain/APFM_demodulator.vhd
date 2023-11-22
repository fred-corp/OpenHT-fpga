-------------------------------------------------------------
-- Complex frequency demodulator
--
-- Takes in a 32bit IQ signal stream (16bis I, 16bit Q) and outputs
-- the demodulated signal (AM, PM or FM) as a 16bit stream.
--
--
-- Frédéric Druppel, ON4PFD, fredcorp.cc
-- Sebastien, ON4SEB
-- M17 Project
-- November 2023
--
-- TODO : Implement I/IQ mode for AM
-- TODO : Normalise phase angle from -pi to pi
--
-------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.axi_stream_pkg.all;
use work.cordic_pkg.all;
use work.apb_pkg.all;

entity FM_demodulator is
  generic  (
    PSEL_ID : natural
  );
  port (
    clk_i    : in std_logic;            -- Clock, from upstream
    nrst_i   : in std_logic;            -- Reset, from upstream

    s_apb_o  : out apb_out_t;           -- slave apb interface out, to upstream
    s_apb_i  : in apb_in_t;             -- slave apb interface in, from upstream

    s_axis_o : out axis_out_iq_t;       -- slave out, to upstream entity (ready)                      -- This entity's ready to receive flag (tready)
    s_axis_i : in axis_in_iq_t;         -- slave in, from upstream entity (data and valid)            -- IQ signal (tdata), valid (tvalid)
    m_axis_o : out axis_in_iq_t;        -- master out, to downstream entity (data and valid)          -- Demodulated signal (tdata), valid (tvalid)
    m_axis_i : in axis_out_iq_t         -- master input, from downstream entity (ready)               -- From next entity's ready to receive flag (tready)
  );
end entity;

architecture magic of FM_demodulator is
  signal magnitude    : signed(20 downto 0) := (others => '0');
  signal phase        : signed(20 downto 0) := (others => '0');
  signal phase_1      : signed(20 downto 0) := (others => '0');
  signal iq_vld       : std_logic := '0';

  signal ready        : std_logic := '0';
  signal output_valid : std_logic := '0';
  signal cordic_busy  : std_logic;

  type demod_mode_t is (BYPASS, AM, PM, FM);
  signal demod_mode   : demod_mode_t := FM;

  type sig_state_t is (IDLE, COMPUTE, DONE);
  signal sig_state    : sig_state_t := IDLE;

begin
  -- Find the phase of the IQ signal with the CORDIC's arctan function
  -- Ø = arctan(Q/I)

  -- CORDIC
  arctan : entity work.cordic_sincos generic map( -- Same as cordic_sincos
    SIZE => 21,
    ITERATIONS => 21,
    TRUNC_SIZE => 16,
    RESET_ACTIVE_LEVEL => '0'
    )
  port map(
    Clock => clk_i,
    Reset => nrst_i,

    Data_valid => iq_vld,
    Busy       => cordic_busy,
    Result_valid => output_valid,
    Mode => cordic_vector,

    X => to_signed(s_axis_i.tdata(31 downto 16), 21), -- I
    Y => abs(to_signed(s_axis_i.tdata(15 downto 0), 21)), -- Q
    Z => 21x"000000", -- not used

    std_logic_vector(X_Result) => magnitude,
    std_logic_vector(Z_Result) => phase
  );

  -- APB
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_apb_o.pready <= '0';
      s_apb_o.prdata <= (others => '0');

      if s_apb_i.PSEL(PSEL_ID) then
        if s_apb_i.PENABLE and s_apb_i.PWRITE then
          case s_apb_i.PADDR(2 downto 1) is
            when "00" => -- Mode
              demod_mode <= demod_mode_t(to_integer(unsigned(s_apb_i.PWDATA(1 downto 0))));
            when others =>
              null;
          end case;
        end if;

        if not s_apb_i.PENABLE then
          s_apb_o.pready <= '1';
          case s_apb_i.PADDR(2 downto 1) is
            when "00" => -- Mode
              s_apb_o.prdata <= std_logic_vector(to_unsigned(to_integer(demod_mode), 2));
            when others =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process;

  -- FSM
  process(clk_i)
  begin
    if nrst_i = '0' then
      phase <= (others => '0');
      iq_vld <= '0';
    
    elsif rising_edge(clk_i) then
      ready <= '0';
      case demod_mode is
        when BYPASS =>
        -- Output the RAW signal
          m_axis_o.tdata <= s_axis_i.tdata;
          m_axis_o.tvalid <= s_axis_i.tvalid;
          m_axis_o.tstrb <= s_axis_i.tstrb;
          s_axis_o.tready <= m_axis_i.tready;

        when others =>
          case sig_state is
            when COMPUTE =>
              iq_vld <= '0';
              if output_valid then
                sig_state <= DONE;
                m_axis_o.tvalid <= '1';
                case demod_mode is
                  when AM =>
                    -- Output the magniutde
                    m_axis_o.tdata <= std_logic_vector(magnitude);  -- TODO : Convert to 16bit
                    m_axis_o.tstrb <= 16#C#;
                  when PM =>
                    -- Output the phase
                    m_axis_o.tdata <= std_logic_vector(phase);  -- TODO : Convert to 16bit
                    m_axis_o.tstrb <= 16#C#;
                  when FM =>
                    -- Compute the phase difference between the current and previous sample
                    phase_1 <= phase;
                    phase <=  phase_1-phase;
                    -- Output the phase difference
                    m_axis_o.tdata <= std_logic_vector(phase);  -- TODO : Convert to 16bit
                    m_axis_o.tstrb <= 16#C#;
                end case;
              end if;

            when DONE =>
              if m_axis_i.tready and m_axis_o.tvalid then
                sig_state <= IDLE;
                m_axis_o.tvalid <= '0';
              end if;

            when others =>
              m_axis_o.tvalid <= '0';
              ready <= '1';
              if s_axis_i.tvalid and not cordic_busy then
                ready <= '0';
                iq_vld <= '1';
                sig_state <= COMPUTE;
              end if;

          end case;
          -- AXI Stream
          s_axis_o.tready <= ready;

      end case;
    end if;
  end process;
end architecture;