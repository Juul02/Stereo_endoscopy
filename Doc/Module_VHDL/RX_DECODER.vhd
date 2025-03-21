--------------------------------------------------------------------------------
-- AWAIBA GmbH
--------------------------------------------------------------------------------
-- MODUL NAME:  RX_DECODER
-- FILENAME:    rx_decoder.vhd
-- AUTHOR:      Michael Heil - Ing. B锟絩o f锟絩 FPGA-Logic-Design
--              email:  michael.heil@fpga-logic-design.de
--
-- CREATED:     11.11.2009
--------------------------------------------------------------------------------
-- DESCRIPTION: decodes manchester-coded rx-stream
--
--
--------------------------------------------------------------------------------
--
--------------------------------------------------------------------------------
-- REVISIONS:
-- DATE         VERSION    AUTHOR      DESCRIPTION
-- 12.11.2009   01         M. Heil     Initial version
-- 02.03.2010   02         M. Heil     Debug outputs + INPUT_SYNC + CLEAR added
-- 01.01.2011   03         M. Heil     sampling at higher speed (ddr),
--                                     thresholds are dynamically adjusted
-- 02.01.2011   04         M. Heil     modification for spartan-3E (iddr),
--                                     inverter for input data removed
-- 30.10.2011   05         M. Heil     comparators for half/full bit decisions
--                                     work without fixed thresholds
-- 04.11.2011   06         M. Heil     Modifications for NanEye3A
-- 18.01.2012   07         M. Heil     FSM switches from CAL_DONE to CAL_FIND_FS
--                                     instead to CAL_IDLE, corrections and
--                                     simplifications
-- 05.03.2012   08         M. Heil     BIT_PERIOD output added
-- 03.11.2013   09         M. Heil     BIT_PERIOD output removed, generic
--                                     G_CLOCK_PERIOD_PS added, timing improved,
--                                     local clock inversion for sampling clock,
--                                     histogram used for determining min/max
--                                     pulse periods
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.STD_LOGIC_ARITH.all;
use IEEE.STD_LOGIC_UNSIGNED.all;
--use UNISIM.VCOMPONENTS.all;

LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;


entity RX_DECODER is
  generic (
    G_CLOCK_PERIOD_PS:          integer:= 5555);                                -- CLOCK period in ps
  port (
    RESET:                      in  std_logic;                                  -- async. Reset
    CLOCK:                      in  std_logic;                                  -- sampling clock
    ENABLE:                     in  std_logic;                                  -- module activation
    RSYNC:                      in  std_logic;                                  -- resynchronize decoder
    INPUT:                      in  STD_LOGIC_VECTOR (0 DOWNTO 0);--std_logic;                                  -- manchester coded input
    CONFIG_DONE:                in  std_logic;                                  -- end of config phase (async)
    CONFIG_EN:                  out std_logic;                                  -- start of config phase
    SYNC_START:                 out std_logic;                                  -- start of synchronisation phase
    FRAME_START:                out std_logic;                                  -- start of frame
    OUTPUT:                     out std_logic;                                  -- decoded data
    OUTPUT_EN:                  out std_logic;                                  -- output data valid
    NANEYE3A_NANEYE2B_N:        out std_logic;                                  -- '0'=NANEYE2B, '1'=NANEYE3A
    ERROR_OUT:                  out std_logic;                                  -- decoder error
    DEBUG_OUT:                  out std_logic_vector(31 downto 0));             -- debug outputs
end entity RX_DECODER;



architecture RTL of RX_DECODER is

constant C_BIT_LEN_W:           integer:=5;
constant C_HISTOGRAM_ENTRIES:   integer:=2**C_BIT_LEN_W;
constant C_HISTOGRAM_ENTRY_W:   integer:=12;
constant C_CAL_CNT_W:           integer:=14;
constant C_HB_PERIOD_CNT_W:     integer:=14;
constant C_CAL_CNT_FR_END:      std_logic_vector(C_CAL_CNT_W-1 downto 0):=conv_std_logic_vector(850000/G_CLOCK_PERIOD_PS,C_CAL_CNT_W);                -- 0.85 锟絪
constant C_CAL_CNT_SYNC:        std_logic_vector(C_CAL_CNT_W-1 downto 0):=conv_std_logic_vector(32,C_CAL_CNT_W);
constant C_RSYNC_PER_CNT_END:   std_logic_vector(C_HB_PERIOD_CNT_W-1 downto 0):=(others => '1');
constant C_RSYNC_PP_THR:        std_logic_vector(C_HB_PERIOD_CNT_W-1 downto 0):=conv_std_logic_vector(2*350*12,C_HB_PERIOD_CNT_W);

type   T_CAL_STATES is (CAL_IDLE,CAL_FIND_FS,CAL_FIND_SYNC,WAIT_FOR_SENSOR_CFG,CAL_SYNC_FOUND,CAL_MEASURE,CAL_SEARCH_MIN,
                        CAL_FOUND_MIN,CAL_SEARCH_MAX,CAL_FOUND_MAX,CAL_DONE);
type   T_DEC_STATES is (DEC_IDLE,DEC_START,DEC_SYNC,DEC_HALF_BIT,DEC_ERROR);
type   T_HISTOGRAM  is array (0 to C_HISTOGRAM_ENTRIES-1) of std_logic_vector(C_HISTOGRAM_ENTRY_W-1 downto 0);

signal I_CLOCK_N:               std_logic;
signal I_IDDR_Q0:               STD_LOGIC_VECTOR (0 DOWNTO 0);--std_logic;
signal I_IDDR_Q1:               STD_LOGIC_VECTOR (0 DOWNTO 0);--std_logic;
signal I_IDDR_Q:                std_logic_vector(1 downto 0);
signal I_LAST_IDDR_Q:           std_logic_vector(1 downto 0);
signal I_ADD:                   std_logic_vector(C_BIT_LEN_W-1 downto 0);
signal I_BIT_LEN:               std_logic_vector(C_BIT_LEN_W-1 downto 0);
signal I_HISTOGRAM:             T_HISTOGRAM;
signal I_HISTOGRAM_ENTRY:       std_logic_vector(C_HISTOGRAM_ENTRY_W-1 downto 0);
signal I_HISTOGRAM_CNT_EN:      std_logic_vector(C_HISTOGRAM_ENTRIES-1 downto 0);
signal I_HISTOGRAM_ENTRY_MAX:   std_logic_vector(C_HISTOGRAM_ENTRIES-1 downto 0);
signal I_HISTOGRAM_INDEX:       std_logic_vector(C_BIT_LEN_W-1 downto 0);
signal I_BIT_LEN_MAX:           std_logic_vector(C_BIT_LEN_W-1 downto 0);
signal I_BIT_LEN_MIN:           std_logic_vector(C_BIT_LEN_W-1 downto 0);
signal I_BIT_LEN_DIFF2MIN:      std_logic_vector(C_BIT_LEN_W downto 0);
signal I_BIT_LEN_DIFF2MAX:      std_logic_vector(C_BIT_LEN_W downto 0);
signal I_BIT_LEN_DIFF2MIN_ABS:  std_logic_vector(C_BIT_LEN_W downto 0);
signal I_BIT_LEN_DIFF2MAX_ABS:  std_logic_vector(C_BIT_LEN_W downto 0);
signal I_BIT_TRANS:             std_logic;
signal I_BIT_TRANS_1:           std_logic;
signal I_BIT_TRANS_2:           std_logic;
signal I_COMP_EN:               std_logic;
signal I_CHECK_EN:              std_logic;
signal I_HB_PERIOD:             std_logic;
signal I_FB_PERIOD:             std_logic;
signal I_BIT_PERIOD_ERR:        std_logic;
signal I_CAL_CNT:               std_logic_vector(C_CAL_CNT_W-1 downto 0);
signal I_CONFIG_DONE_1:         std_logic;
signal I_CONFIG_DONE_2:         std_logic;
signal I_CAL_PS:                T_CAL_STATES;
signal I_CAL_LS:                T_CAL_STATES;
signal I_CAL_DONE:              std_logic;
signal I_DEC_PS:                T_DEC_STATES;
signal I_OUTPUT:                std_logic;
signal I_OUTPUT_EN:             std_logic;
signal I_HB_PERIOD_CNT_EN:      std_logic;
signal I_HB_PERIOD_CNT:         std_logic_vector(C_HB_PERIOD_CNT_W-1 downto 0);
signal I_NANEYE3A_NANEYE2B_N:   std_logic;



component IDDO
	PORT
	(
		aclr		: IN STD_LOGIC ;
		datain		: IN STD_LOGIC_VECTOR (0 DOWNTO 0);
		inclock		: IN STD_LOGIC ;
		dataout_h		: OUT STD_LOGIC_VECTOR (0 DOWNTO 0);
		dataout_l		: OUT STD_LOGIC_VECTOR (0 DOWNTO 0)
	);
END component;


begin
--------------------------------------------------------------------------------
-- IDDR register for sampling the input data
--------------------------------------------------------------------------------


king_inst : IDDO 
PORT MAP (
		aclr	 => RESET,
		datain	 => INPUT,
		inclock	 => CLOCK,
		dataout_h	 => I_IDDR_Q0,
		dataout_l	 => I_IDDR_Q1
	);
	
	


--I_CLOCK_N <= not CLOCK;
--
--I_IDDR2: IDDR2
--  generic map (
--    DDR_ALIGNMENT               => "NONE",                                      -- Sets output alignment to "NONE", "C0", "C1"
--    INIT_Q0                     => '0',                                         -- Sets initial state of the Q0 output to '0' or '1'
--    INIT_Q1                     => '0',                                         -- Sets initial state of the Q1 output to '0' or '1'
--    SRTYPE                      => "ASYNC")                                     -- Specifies "SYNC" or "ASYNC" set/reset
--  port map (
--    Q0                          => I_IDDR_Q0,                                   -- 1-bit output captured with C0 clock
--    Q1                          => I_IDDR_Q1,                                   -- 1-bit output captured with C1 clock
--    C0                          => CLOCK,                                       -- 1-bit clock input
--    C1                          => I_CLOCK_N,                                   -- 1-bit clock input
--    CE                          => '1',                                         -- 1-bit clock enable input
--    D                           => INPUT,                                       -- 1-bit data input
--    R                           => RESET,                                       -- 1-bit reset input
--    S                           => '0');                                        -- 1-bit set input


--------------------------------------------------------------------------------
-- 2 bit pipeline register for the input data
--------------------------------------------------------------------------------
IDDR_Q_REG: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_IDDR_Q <= (others => '0');
    I_LAST_IDDR_Q <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    I_IDDR_Q(0) <= I_IDDR_Q1(0);
    I_IDDR_Q(1) <= I_IDDR_Q0(0);
    I_LAST_IDDR_Q <= I_IDDR_Q;
  end if;
end process IDDR_Q_REG;


--------------------------------------------------------------------------------
-- adder for measuring the duration of a bit
--------------------------------------------------------------------------------
ADDER: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_ADD <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    case I_IDDR_Q is
      when "00" =>
        if (I_LAST_IDDR_Q(0) = '1') then
          I_ADD <= conv_std_logic_vector(2,C_BIT_LEN_W);
        else
          I_ADD <= I_ADD + "10";
        end if;
      when "01" =>
        I_ADD <= conv_std_logic_vector(1,C_BIT_LEN_W);
      when "10" =>
        I_ADD <= conv_std_logic_vector(1,C_BIT_LEN_W);
      when "11" =>
        if (I_LAST_IDDR_Q(0) = '0') then
          I_ADD <= conv_std_logic_vector(2,C_BIT_LEN_W);
        else
          I_ADD <= I_ADD + "10";
        end if;
      when others =>
        I_ADD <= (others => '0');
    end case;
  end if;
end process ADDER;


--------------------------------------------------------------------------------
-- register for storing the duration of a bit
--------------------------------------------------------------------------------
BIT_LEN_REG: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_LEN <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    case I_IDDR_Q is
      when "00" =>
        if (I_LAST_IDDR_Q(0) = '1') then
          I_BIT_LEN <= I_ADD;
        else
          I_BIT_LEN <= I_BIT_LEN;
        end if;
      when "01" =>
        I_BIT_LEN <= I_ADD + "01";
      when "10" =>
        I_BIT_LEN <= I_ADD + "01";
      when "11" =>
        if (I_LAST_IDDR_Q(0) = '0') then
          I_BIT_LEN <= I_ADD;
        else
          I_BIT_LEN <= I_BIT_LEN;
        end if;
      when others =>
        I_BIT_LEN <= I_BIT_LEN;
    end case;
  end if;
end process BIT_LEN_REG;


--------------------------------------------------------------------------------
-- I_BIT_TRANS is activated every time a transition in the bit stream occurs
--------------------------------------------------------------------------------
BIT_TRANS_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_TRANS <= '0';
  elsif (rising_edge(CLOCK)) then
    case I_IDDR_Q is
      when "00" =>
        if (I_LAST_IDDR_Q(0) = '1') then
          I_BIT_TRANS <= '1';
        else
          I_BIT_TRANS <= '0';
        end if;
      when "01" =>
        I_BIT_TRANS <= '1';
      when "10" =>
        I_BIT_TRANS <= '1';
      when "11" =>
        if (I_LAST_IDDR_Q(0) = '0') then
          I_BIT_TRANS <= '1';
        else
          I_BIT_TRANS <= '0';
        end if;
      when others =>
        I_BIT_TRANS <= '0';
    end case;
  end if;
end process BIT_TRANS_EVAL;


--------------------------------------------------------------------------------
-- generate histogram
--------------------------------------------------------------------------------
HISTOGRAM_EVAL:  process(RESET,CLOCK)
begin
  if (RESET = '1') then
    for i in 0 to C_HISTOGRAM_ENTRIES-1 loop
      I_HISTOGRAM(i) <= (others => '0');
    end loop;
    I_HISTOGRAM_ENTRY_MAX <= (others => '0');
    I_BIT_TRANS_1   <= '0';
    I_BIT_TRANS_2   <= '0';
    I_HISTOGRAM_CNT_EN <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    I_BIT_TRANS_1 <= I_BIT_TRANS;
    I_BIT_TRANS_2 <= I_BIT_TRANS_1;
    if (I_CAL_PS = CAL_SYNC_FOUND) then
      for i in 0 to C_HISTOGRAM_ENTRIES-1 loop
        I_HISTOGRAM(i) <= (others => '0');
      end loop;
      I_HISTOGRAM_ENTRY_MAX <= (others => '0');
      I_HISTOGRAM_CNT_EN <= (others => '0');
    elsif (I_CAL_PS = CAL_MEASURE) then
      I_HISTOGRAM_CNT_EN <= (others => '0');
      if (I_BIT_TRANS = '1') then
        for i in 0 to C_HISTOGRAM_ENTRIES-1 loop
          if (conv_std_logic_vector(i,C_BIT_LEN_W) = I_BIT_LEN) then
            I_HISTOGRAM_CNT_EN(i) <= '1';
          end if;
        end loop;
      end if;
      if (I_BIT_TRANS_1 = '1') then
        for i in 0 to C_HISTOGRAM_ENTRIES-1 loop
          if (I_HISTOGRAM_CNT_EN(i) = '1') then
            I_HISTOGRAM(i) <= I_HISTOGRAM(i) + "01";
          end if;
        end loop;
      end if;
      if (I_BIT_TRANS_2 = '1') then
        for i in 0 to C_HISTOGRAM_ENTRIES-1 loop
          if (I_HISTOGRAM(i)(C_HISTOGRAM_ENTRY_W-1) = '1') then
            I_HISTOGRAM_ENTRY_MAX(i) <= '1';
          end if;
        end loop;
      end if;
    end if;
  end if;
end process HISTOGRAM_EVAL;


--------------------------------------------------------------------------------
-- index counter for reading out the histogram to determine the min/max bit
-- periods
--------------------------------------------------------------------------------
HISTOGRAM_INDEX_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_HISTOGRAM_INDEX <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    case I_CAL_PS is
      when CAL_MEASURE    => I_HISTOGRAM_INDEX <= (others => '0');
      when CAL_SEARCH_MIN => I_HISTOGRAM_INDEX <= I_HISTOGRAM_INDEX + "01";
      when CAL_FOUND_MIN  => I_HISTOGRAM_INDEX <= (others => '1');
      when CAL_SEARCH_MAX => I_HISTOGRAM_INDEX <= I_HISTOGRAM_INDEX - "01";
      when others         => I_HISTOGRAM_INDEX <= I_HISTOGRAM_INDEX;
    end case;
  end if;
end process HISTOGRAM_INDEX_EVAL;


--------------------------------------------------------------------------------
-- store longest bit period
--------------------------------------------------------------------------------
BIT_LEN_MAX_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_LEN_MAX <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    if (I_CAL_PS = CAL_FOUND_MAX) then
      I_BIT_LEN_MAX <= I_HISTOGRAM_INDEX;
    end if;
  end if;
end process BIT_LEN_MAX_EVAL;


--------------------------------------------------------------------------------
-- calculate difference between current bit period and longest bit period
--------------------------------------------------------------------------------
BIT_LEN_DIFF2MAX_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_LEN_DIFF2MAX_ABS <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    if (I_CAL_DONE = '1') then
      if (I_BIT_TRANS = '1') then
        I_BIT_LEN_DIFF2MAX_ABS <= abs(signed('0'&I_BIT_LEN - I_BIT_LEN_MAX));
      else
        I_BIT_LEN_DIFF2MAX_ABS <= I_BIT_LEN_DIFF2MAX_ABS;
      end if;
    else
      I_BIT_LEN_DIFF2MAX_ABS <= (others => '0');
    end if;
  end if;
end process BIT_LEN_DIFF2MAX_EVAL;


--------------------------------------------------------------------------------
-- store shortest bit period
--------------------------------------------------------------------------------
BIT_LEN_MIN_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_LEN_MIN <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    if (I_CAL_PS = CAL_FOUND_MIN) then
      I_BIT_LEN_MIN <= I_HISTOGRAM_INDEX;
    end if;
  end if;
end process BIT_LEN_MIN_EVAL;


--------------------------------------------------------------------------------
-- calculate difference between current bit period and shortest bit period
--------------------------------------------------------------------------------
BIT_LEN_DIFF2MIN_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_LEN_DIFF2MIN_ABS <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    if (I_CAL_DONE = '1') then
      if (I_BIT_TRANS = '1') then
        I_BIT_LEN_DIFF2MIN_ABS <= abs(signed('0'&I_BIT_LEN - I_BIT_LEN_MIN));
      else
        I_BIT_LEN_DIFF2MIN_ABS <= I_BIT_LEN_DIFF2MIN_ABS;
      end if;
    else
      I_BIT_LEN_DIFF2MIN_ABS <= (others => '0');
    end if;
  end if;
end process BIT_LEN_DIFF2MIN_EVAL;


--------------------------------------------------------------------------------
-- synchronize config done pulse to CLOCK
--------------------------------------------------------------------------------
SYNC_CFG_DONE: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_CONFIG_DONE_1 <= '0';
    I_CONFIG_DONE_2 <= '0';
  elsif (rising_edge(CLOCK)) then
    I_CONFIG_DONE_1 <= CONFIG_DONE;
    I_CONFIG_DONE_2 <= I_CONFIG_DONE_1;
  end if;
end process SYNC_CFG_DONE;


--------------------------------------------------------------------------------
-- fsm for measuring the minimum duration of a half-bit and the maximum duration
-- of a full-bit
--------------------------------------------------------------------------------
CAL_FSM: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_CAL_PS <= CAL_IDLE;
    I_CAL_LS <= CAL_IDLE;
  elsif (rising_edge(CLOCK)) then
    I_CAL_LS <= I_CAL_PS;
    if (ENABLE = '0') then
      I_CAL_PS <= CAL_IDLE;
    else
      case I_CAL_PS is
--------------------------------------------------------------------------------
-- IDLE-State: waiting for the first transition in the data stream
--------------------------------------------------------------------------------
        when CAL_IDLE =>
          if (I_BIT_TRANS = '1') then
            I_CAL_PS <= CAL_FIND_FS;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_FIND_FS: waiting for frame start
--------------------------------------------------------------------------------
        when CAL_FIND_FS =>
          if (I_CAL_CNT = C_CAL_CNT_FR_END) then
            I_CAL_PS <= WAIT_FOR_SENSOR_CFG;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- WAIT_FOR_SENSOR_CFG: when there are configuration data to be transmitted to
-- the sensor => wait for the end of the transmission phase
--------------------------------------------------------------------------------
        when WAIT_FOR_SENSOR_CFG =>
          if (I_CONFIG_DONE_2 = '1') then
            I_CAL_PS <= CAL_FIND_SYNC;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_FIND_SYNC: waiting for the first bits of the sync phase
--------------------------------------------------------------------------------
        when CAL_FIND_SYNC =>
          if (I_CAL_CNT = C_CAL_CNT_SYNC) then
            I_CAL_PS <= CAL_SYNC_FOUND;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_SYNC_FOUND: C_CAL_CNT_SYNC transitions found, clear I_CAL_CNT
--------------------------------------------------------------------------------
        when CAL_SYNC_FOUND =>
          I_CAL_PS <= CAL_MEASURE;
--------------------------------------------------------------------------------
-- CAL_MEASURE: measure duration of shortest half bit and longest full bit
--------------------------------------------------------------------------------
        when CAL_MEASURE =>
          if (I_CAL_CNT = C_CAL_CNT_FR_END) then
            I_CAL_PS <= CAL_SEARCH_MIN;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_SEARCH_MIN: search shortest bit period in histogram
--------------------------------------------------------------------------------
        when CAL_SEARCH_MIN =>
          if (I_HISTOGRAM_ENTRY_MAX(conv_integer(I_HISTOGRAM_INDEX)) = '1') then
            I_CAL_PS <= CAL_FOUND_MIN;
          elsif (I_HISTOGRAM_INDEX = (I_HISTOGRAM_INDEX'range => '1')) then
            I_CAL_PS <= CAL_DONE;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_FOUND_MIN: shortest bit period in histogram found
--------------------------------------------------------------------------------
        when CAL_FOUND_MIN =>
          I_CAL_PS <= CAL_SEARCH_MAX;
--------------------------------------------------------------------------------
-- CAL_SEARCH_MAX: search longest bit period in histogram
--------------------------------------------------------------------------------
        when CAL_SEARCH_MAX =>
          if (I_HISTOGRAM_ENTRY_MAX(conv_integer(I_HISTOGRAM_INDEX)) = '1') then
            I_CAL_PS <= CAL_FOUND_MAX;
          elsif (I_HISTOGRAM_INDEX = (I_HISTOGRAM_INDEX'range => '0')) then
            I_CAL_PS <= CAL_DONE;
          else
            I_CAL_PS <= I_CAL_PS;
          end if;
--------------------------------------------------------------------------------
-- CAL_FOUND_MAX: shortest bit period in histogram found
--------------------------------------------------------------------------------
        when CAL_FOUND_MAX =>
          I_CAL_PS <= CAL_DONE;
--------------------------------------------------------------------------------
-- CAL_DONE: measurement finished, switch to IDLE-state
--------------------------------------------------------------------------------
        when CAL_DONE =>
          I_CAL_PS <= CAL_FIND_FS;
      end case;
    end if;
  end if;
end process CAL_FSM;


--------------------------------------------------------------------------------
-- counter used for calibration timing
--------------------------------------------------------------------------------
CAL_CNT_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_CAL_CNT <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    case I_CAL_PS is
      when CAL_MEASURE | CAL_FIND_FS =>
        if (I_BIT_TRANS = '1') then
          I_CAL_CNT <= (others => '0');
        else
          I_CAL_CNT <= I_CAL_CNT + "01";
        end if;
      when CAL_FIND_SYNC =>
        if (I_BIT_TRANS = '1') then
          I_CAL_CNT <= I_CAL_CNT + "01";
        end if;
      when others =>
        I_CAL_CNT <= (others => '0');
    end case;
  end if;
end process CAL_CNT_EVAL;


--------------------------------------------------------------------------------
-- I_CAL_DONE is activated after finishing the initial calibration
--------------------------------------------------------------------------------
CAL_DONE_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_CAL_DONE <= '0';
  elsif (rising_edge(CLOCK)) then
    if (ENABLE = '0') then
      I_CAL_DONE <= '0';
    elsif (I_CAL_PS = CAL_DONE) then
      I_CAL_DONE <= '1';
    else
      I_CAL_DONE <= I_CAL_DONE;
    end if;
  end if;
end process CAL_DONE_EVAL;


--------------------------------------------------------------------------------
-- I_COMP_EN = I_BIT_TRANS delayed by one clock cycle
-- I_CHECK_EN = I_COMP_EN delayed by one clock cycle
--------------------------------------------------------------------------------
COMP_CHECK_EN_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_COMP_EN  <= '0';
    I_CHECK_EN <= '0';
  elsif (rising_edge(CLOCK)) then
    I_CHECK_EN <= I_COMP_EN;
    if (I_CAL_DONE = '1') then
      I_COMP_EN <= I_BIT_TRANS;
    else
      I_COMP_EN <= '0';
    end if;
  end if;
end process COMP_CHECK_EN_EVAL;



--------------------------------------------------------------------------------
-- comparator which decides, whether a "half"-bit period was received
--------------------------------------------------------------------------------
HB_PERIOD_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_HB_PERIOD <= '0';
  elsif (rising_edge(CLOCK)) then
    if (I_COMP_EN = '1') then
      if (I_BIT_LEN_DIFF2MIN_ABS < I_BIT_LEN_DIFF2MAX_ABS) then
        I_HB_PERIOD <= '1';
      else
        I_HB_PERIOD <= '0';
      end if;
    else
      I_HB_PERIOD <= '0';
    end if;
  end if;
end process HB_PERIOD_EVAL;


--------------------------------------------------------------------------------
-- comparator which decides, whether a "full"-bit period was received
--------------------------------------------------------------------------------
FB_PERIOD_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_FB_PERIOD <= '0';
  elsif (rising_edge(CLOCK)) then
    if (I_COMP_EN = '1') then
      if (I_BIT_LEN_DIFF2MAX_ABS < I_BIT_LEN_DIFF2MIN_ABS) then
        I_FB_PERIOD <= '1';
      else
        I_FB_PERIOD <= '0';
      end if;
    else
      I_FB_PERIOD <= '0';
    end if;
  end if;
end process FB_PERIOD_EVAL;


--------------------------------------------------------------------------------
-- comparator which decides, whether there was a bit period error
--------------------------------------------------------------------------------
BIT_PERIOD_ERR_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_BIT_PERIOD_ERR <= '0';
  elsif (rising_edge(CLOCK)) then
    if (I_CHECK_EN = '1') then
      if ((I_HB_PERIOD = '0') and (I_FB_PERIOD = '0')) then
        I_BIT_PERIOD_ERR <= '1';
      else
        I_BIT_PERIOD_ERR <= '0';
      end if;
    else
      I_BIT_PERIOD_ERR <= I_BIT_PERIOD_ERR;
    end if;
  end if;
end process BIT_PERIOD_ERR_EVAL;


--------------------------------------------------------------------------------
-- fsm for decoding
--------------------------------------------------------------------------------
DECODE_FSM: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_DEC_PS <= DEC_IDLE;
  elsif (rising_edge(CLOCK)) then
    if ((ENABLE = '0') or (I_CAL_PS = CAL_FIND_SYNC)) then
      I_DEC_PS <= DEC_IDLE;
    else
      case I_DEC_PS is
--------------------------------------------------------------------------------
-- IDLE-State: waiting for the end of the configuration phase
--------------------------------------------------------------------------------
        when DEC_IDLE =>
          if (I_CAL_PS = CAL_SYNC_FOUND) then
            I_DEC_PS <= DEC_START;
          else
            I_DEC_PS <= I_DEC_PS;
          end if;
--------------------------------------------------------------------------------
-- START-State: waiting for the first "full"-bit to synchronize
--------------------------------------------------------------------------------
        when DEC_START =>
          if (RSYNC = '1') then
            I_DEC_PS <= DEC_START;
          elsif (I_FB_PERIOD = '1') then
            I_DEC_PS <= DEC_SYNC;
          else
            I_DEC_PS <= I_DEC_PS;
          end if;
--------------------------------------------------------------------------------
-- SYNC-State: synchronisized to bit stream, waiting for full-/half-bit
-- pulses generated by the comparator
--------------------------------------------------------------------------------
        when DEC_SYNC =>
          if (RSYNC = '1') then
            I_DEC_PS <= DEC_START;
          elsif (I_FB_PERIOD = '1') then
            I_DEC_PS <= I_DEC_PS;
          elsif (I_HB_PERIOD = '1') then
            I_DEC_PS <= DEC_HALF_BIT;
          else
            I_DEC_PS <= I_DEC_PS;
          end if;
--------------------------------------------------------------------------------
-- HALF_BIT-State: first half-bit received, waiting for the second half-bit
--------------------------------------------------------------------------------
        when DEC_HALF_BIT =>
          if (RSYNC = '1') then
            I_DEC_PS <= DEC_START;
          elsif (I_FB_PERIOD = '1') then
            I_DEC_PS <= DEC_ERROR;
          elsif (I_HB_PERIOD = '1') then
            I_DEC_PS <= DEC_SYNC;
          else
            I_DEC_PS <= I_DEC_PS;
          end if;
--------------------------------------------------------------------------------
-- ERROR-State: generate an pulse on ERROR => resynchronize
--------------------------------------------------------------------------------
        when DEC_ERROR =>
          I_DEC_PS <= DEC_START;
      end case;
    end if;
  end if;
end process DECODE_FSM;


--------------------------------------------------------------------------------
-- generating the OUTPUT signal
--------------------------------------------------------------------------------
OUTPUT_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_OUTPUT <= '0';
  elsif (rising_edge(CLOCK)) then
    if (I_DEC_PS = DEC_START) then
      if (I_FB_PERIOD = '1') then
        I_OUTPUT <= '1';
      else
        I_OUTPUT <= '0';
      end if;
    elsif (I_FB_PERIOD = '1') then
      I_OUTPUT <= not I_OUTPUT;
    else
      I_OUTPUT <= I_OUTPUT;
    end if;
  end if;
end process OUTPUT_EVAL;


--------------------------------------------------------------------------------
-- Generating OUTPUT_EN
--------------------------------------------------------------------------------
OUTPUT_EN_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_OUTPUT_EN <= '0';
  elsif (rising_edge(CLOCK)) then
    if ((ENABLE = '0') or (RSYNC = '1')) then
      I_OUTPUT_EN <= '0';
    elsif (((I_DEC_PS = DEC_START) and (I_FB_PERIOD = '1')) or
        ((I_DEC_PS = DEC_SYNC) and (I_FB_PERIOD = '1')) or
        ((I_DEC_PS = DEC_HALF_BIT) and (I_HB_PERIOD = '1'))) then
      I_OUTPUT_EN <= '1';
    else
      I_OUTPUT_EN <= '0';
    end if;
  end if;
end process OUTPUT_EN_EVAL;


--------------------------------------------------------------------------------
-- determine whether a NANEYE3A or NANEYE2B is connected by counting the
-- number of half bit period pulses before the first full bit period is received
--------------------------------------------------------------------------------
HB_PERIOD_CNT_EN_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_HB_PERIOD_CNT_EN <= '0';
  elsif (rising_edge(CLOCK)) then
    if ((I_CAL_LS = CAL_FIND_SYNC) and (I_CAL_PS = CAL_MEASURE)) then        -- frame start
      I_HB_PERIOD_CNT_EN <= '1';
    elsif ((I_CAL_DONE = '1') and (I_DEC_PS = DEC_START) and (I_FB_PERIOD = '1')) then
      I_HB_PERIOD_CNT_EN <= '0';
    else
      I_HB_PERIOD_CNT_EN <= I_HB_PERIOD_CNT_EN;
    end if;
  end if;
end process HB_PERIOD_CNT_EN_EVAL;


HB_PERIOD_CNT_EVAL: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_HB_PERIOD_CNT <= (others => '0');
  elsif (rising_edge(CLOCK)) then
    if ((I_CAL_DONE = '1') and (I_DEC_PS = DEC_START) and (I_HB_PERIOD_CNT_EN = '1')) then
      if (I_HB_PERIOD = '1') then
        if (I_HB_PERIOD_CNT = C_RSYNC_PER_CNT_END) then
          I_HB_PERIOD_CNT <= I_HB_PERIOD_CNT;
        else
          I_HB_PERIOD_CNT <= I_HB_PERIOD_CNT + "01";
        end if;
      else
        I_HB_PERIOD_CNT <= I_HB_PERIOD_CNT;
      end if;
    else
      I_HB_PERIOD_CNT <= (others => '0');
    end if;
  end if;
end process HB_PERIOD_CNT_EVAL;


--------------------------------------------------------------------------------
-- The duration of the resynchronisation phase (after the serial configuration)
-- is used to determine whether a NANEYE3A or NANEYE2B is connected.
-- The duration of the NANEYE2B's resynchronisation phase is 250 pixel periods
-- The duration of the NANEYE3A's resynchronisation phase is > 508 pixel periods
--------------------------------------------------------------------------------
NANEYE3A_OR_NANEYE2B: process(RESET,CLOCK)
begin
  if (RESET = '1') then
    I_NANEYE3A_NANEYE2B_N <= '0';
  elsif (rising_edge(CLOCK)) then
    if ((I_CAL_DONE = '1') and (I_DEC_PS = DEC_START) and (I_FB_PERIOD = '1') and (I_HB_PERIOD_CNT_EN = '1')) then
      if (I_HB_PERIOD_CNT > C_RSYNC_PP_THR) then
        I_NANEYE3A_NANEYE2B_N <= '1';     -- NANEYE3A
      else
        I_NANEYE3A_NANEYE2B_N <= '0';     -- NANEYE2B
      end if;
    else
      I_NANEYE3A_NANEYE2B_N <= I_NANEYE3A_NANEYE2B_N;
    end if;
  end if;
end process NANEYE3A_OR_NANEYE2B;


SYNC_START  <= '1' when (I_CAL_PS = CAL_SYNC_FOUND) else '0';
CONFIG_EN   <= '1' when (I_CAL_PS = WAIT_FOR_SENSOR_CFG) else '0';
FRAME_START <= '1' when (I_CAL_PS = CAL_SYNC_FOUND) else '0';
OUTPUT      <= I_OUTPUT;
OUTPUT_EN   <= I_OUTPUT_EN;

NANEYE3A_NANEYE2B_N <= I_NANEYE3A_NANEYE2B_N;

ERROR_OUT   <= '1' when (I_DEC_PS = DEC_ERROR) else '0';

DEBUG_OUT   <= (others => '0');

end RTL;
