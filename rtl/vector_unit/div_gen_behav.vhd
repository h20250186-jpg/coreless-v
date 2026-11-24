library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Behavioral replacement for Xilinx div_gen IP (AXI-Stream divider).
-- Matches the port interface of div_gen_0 / div_gen_1.
-- Configurable signed vs unsigned via generic.
-- Latency: result appears after LATENCY clock cycles (default 36,
-- matching the Xilinx IP default for 32-bit operands).

entity div_gen_behav is
  generic (
    IS_SIGNED : boolean := true;
    LATENCY   : integer := 36
  );
  port (
    aclk                    : in  std_logic;
    aclken                  : in  std_logic;
    s_axis_divisor_tvalid   : in  std_logic;
    s_axis_divisor_tdata    : in  std_logic_vector(31 downto 0);
    s_axis_dividend_tvalid  : in  std_logic;
    s_axis_dividend_tdata   : in  std_logic_vector(31 downto 0);
    m_axis_dout_tvalid      : out std_logic;
    m_axis_dout_tuser       : out std_logic_vector(0 downto 0);
    m_axis_dout_tdata       : out std_logic_vector(63 downto 0)
  );
end entity div_gen_behav;

architecture behavioral of div_gen_behav is
  signal shift_valid : std_logic_vector(LATENCY-1 downto 0) := (others => '0');
  type data_pipe_t is array (0 to LATENCY-1) of std_logic_vector(63 downto 0);
  signal shift_data  : data_pipe_t := (others => (others => '0'));
  type user_pipe_t is array (0 to LATENCY-1) of std_logic_vector(0 downto 0);
  signal shift_user  : user_pipe_t := (others => (others => '0'));
begin

  process(aclk)
    variable dividend_s : signed(31 downto 0);
    variable divisor_s  : signed(31 downto 0);
    variable dividend_u : unsigned(31 downto 0);
    variable divisor_u  : unsigned(31 downto 0);
    variable quotient   : std_logic_vector(31 downto 0);
    variable remainder  : std_logic_vector(31 downto 0);
    variable dbz        : std_logic;
  begin
    if rising_edge(aclk) then
      if aclken = '1' then
        -- Compute result at input stage
        if s_axis_divisor_tvalid = '1' and s_axis_dividend_tvalid = '1' then
          if s_axis_divisor_tdata = x"00000000" then
            -- Divide by zero
            quotient  := (others => '0');
            remainder := s_axis_dividend_tdata;
            dbz       := '1';
          else
            if IS_SIGNED then
              dividend_s := signed(s_axis_dividend_tdata);
              divisor_s  := signed(s_axis_divisor_tdata);
              quotient   := std_logic_vector(dividend_s / divisor_s);
              remainder  := std_logic_vector(dividend_s rem divisor_s);
            else
              dividend_u := unsigned(s_axis_dividend_tdata);
              divisor_u  := unsigned(s_axis_divisor_tdata);
              quotient   := std_logic_vector(dividend_u / divisor_u);
              remainder  := std_logic_vector(dividend_u rem divisor_u);
            end if;
            dbz := '0';
          end if;
          -- Stage 0: latch input
          shift_valid(0) <= '1';
          shift_data(0)  <= quotient & remainder;  -- [63:32]=quotient, [31:0]=remainder
          shift_user(0)  <= (0 => dbz);
        else
          shift_valid(0) <= '0';
          shift_data(0)  <= (others => '0');
          shift_user(0)  <= (others => '0');
        end if;

        -- Shift pipeline
        for i in 1 to LATENCY-1 loop
          shift_valid(i) <= shift_valid(i-1);
          shift_data(i)  <= shift_data(i-1);
          shift_user(i)  <= shift_user(i-1);
        end loop;
      end if;  -- aclken
    end if;  -- rising_edge
  end process;

  -- Output from last pipeline stage
  m_axis_dout_tvalid <= shift_valid(LATENCY-1);
  m_axis_dout_tdata  <= shift_data(LATENCY-1);
  m_axis_dout_tuser  <= shift_user(LATENCY-1);

end architecture behavioral;
