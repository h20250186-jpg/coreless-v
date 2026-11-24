library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity dmem_bram is
  generic (
    ADDR_WIDTH : integer := 14;
    DATA_WIDTH : integer := 32
  );
  port (
    clka  : in  std_logic;
    wea   : in  std_logic_vector(0 downto 0);
    addra : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    dina  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    douta : out std_logic_vector(DATA_WIDTH-1 downto 0)
  );
end entity dmem_bram;

architecture behavioral of dmem_bram is
  type ram_type is array (0 to 2**ADDR_WIDTH - 1) of std_logic_vector(DATA_WIDTH-1 downto 0);
  signal ram : ram_type := (others => (others => '0'));
begin
  process(clka)
  begin
    if rising_edge(clka) then
      if wea(0) = '1' then
        ram(to_integer(unsigned(addra))) <= dina;
      end if;
      douta <= ram(to_integer(unsigned(addra)));  -- read-first mode
    end if;
  end process;
end architecture behavioral;
