library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.apb_pkg.all;

entity tx_apb_regs is
    generic (
        PSEL_ID : natural
    );
    port (
        clk   : in std_logic;
        s_apb_in : in apb_in_t;
        s_apb_out : out apb_out_t;

        mode : out std_logic_vector(2 downto 0)
    );
end entity tx_apb_regs;

architecture rtl of tx_apb_regs is

begin
    process (clk)
    begin
        if rising_edge(clk) then
            s_apb_out.pready <= '0';
            s_apb_out.prdata <= (others => '0');

            if s_apb_in.PSEL(PSEL_ID) then
                if s_apb_in.PENABLE and s_apb_in.PWRITE then
                    mode <= s_apb_in.PWDATA(2 downto 0);
                end if;

                if not s_apb_in.PENABLE then
                    s_apb_out.pready <= '1';
                    s_apb_out.prdata(2 downto 0) <= mode;
                end if;

            end if;

        end if;
    end process;
    

end architecture;