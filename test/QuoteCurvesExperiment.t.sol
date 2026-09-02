// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// ─────────────────────────────────────────────────────────────────────────
// THROWAWAY — Phase 0 experiment for the onchain multileg design spike.
// Sweeps quote sizes across every whitelisted venue on a mainnet fork to
// map price-vs-size curves and capacity cliffs. Not meant to be committed.
// Run: RPC_URL=<mainnet rpc> forge test --match-contract QuoteCurvesExperiment -vv
// ─────────────────────────────────────────────────────────────────────────

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";

contract QuoteCurvesExperiment is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant ROUTER = 0x4DdF368080CD7946db5b459aD591c350158175e1;
    uint256 constant USDC_BALANCES_SLOT = 9;

    IPropAMMRouter constant router = IPropAMMRouter(ROUTER);

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        // Fund the router itself: simulation-based quotes (Kipseli) pull
        // tokenIn from the router's balance while quoting.
        bytes32 slot = keccak256(abi.encode(ROUTER, USDC_BALANCES_SLOT));
        vm.store(USDC, slot, bytes32(uint256(50_000_000 * 1e6))); // 50M USDC
        assertEq(IERC20(USDC).balanceOf(ROUTER), 50_000_000 * 1e6, "USDC fund failed");
        deal(WETH, ROUTER, 20_000 ether);
    }

    function _name(address v) internal pure returns (string memory) {
        if (v == 0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76) return "Bebop";
        if (v == 0x5979458912F80B96d30D4220af8E2e4925A33320) return "Fermi";
        if (v == 0x71e790dd841c8A9061487cb3E78C288E75cE0B3d) return "Kipseli";
        if (v == 0x00000003f1ec2379e79F58E12EC6C4F51Ee92149) return "Tempest";
        if (v == 0x217d58931A8549ca539426AA8152E33dAfc3d95A) return "TaurusFi";
        if (v == 0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB) return "Metric";
        if (v == UNISWAP_ROUTER_02) return "UniswapV3";
        return "unknown";
    }

    function test_quoteCurves() public {
        console2.log(string.concat("BLOCK;", vm.toString(block.number), ";", vm.toString(block.timestamp)));

        address[] memory venues = _venues();
        for (uint256 v = 0; v < venues.length; v++) {
            console2.log(string.concat("VENUE;", _name(venues[v]), ";", vm.toString(venues[v])));
        }

        uint256[14] memory usdcSizes = [
            uint256(100e6),
            500e6,
            1_000e6,
            5_000e6,
            10_000e6,
            25_000e6,
            50_000e6,
            100_000e6,
            250_000e6,
            500_000e6,
            1_000_000e6,
            2_500_000e6,
            5_000_000e6,
            10_000_000e6
        ];
        uint256[14] memory wethSizes = [
            uint256(0.05 ether),
            0.25 ether,
            0.5 ether,
            1 ether,
            2.5 ether,
            5 ether,
            10 ether,
            25 ether,
            50 ether,
            100 ether,
            250 ether,
            500 ether,
            1000 ether,
            2500 ether
        ];

        for (uint256 v = 0; v < venues.length; v++) {
            for (uint256 i = 0; i < usdcSizes.length; i++) {
                _quoteOne(venues[v], USDC, WETH, usdcSizes[i]);
            }
            for (uint256 i = 0; i < wethSizes.length; i++) {
                _quoteOne(venues[v], WETH, USDC, wethSizes[i]);
            }
        }
    }

    /// @dev The live whitelist plus the Uniswap fallback as the last entry.
    function _venues() internal view returns (address[] memory out) {
        (bool ok, bytes memory ret) = ROUTER.staticcall(abi.encodeWithSignature("getWhitelistedVenues()"));
        require(ok, "getWhitelistedVenues failed");
        address[] memory listed = abi.decode(ret, (address[]));
        out = new address[](listed.length + 1);
        for (uint256 i = 0; i < listed.length; i++) {
            out[i] = listed[i];
        }
        out[listed.length] = UNISWAP_ROUTER_02;
    }

    function _quoteOne(address venue, address tokenIn, address tokenOut, uint256 amountIn) internal {
        string memory tin = tokenIn == USDC ? "USDC" : "WETH";
        string memory tout = tokenOut == USDC ? "USDC" : "WETH";
        uint256 g0 = gasleft();
        try router.quoteVenueV1(venue, tokenIn, tokenOut, amountIn) returns (uint256 amountOut, address) {
            uint256 used = g0 - gasleft();
            console2.log(
                string.concat(
                    "CSV;",
                    _name(venue),
                    ";",
                    tin,
                    ";",
                    tout,
                    ";",
                    vm.toString(amountIn),
                    ";",
                    vm.toString(amountOut),
                    ";ok;",
                    vm.toString(used)
                )
            );
        } catch (bytes memory err) {
            uint256 used = g0 - gasleft();
            bytes memory sel = new bytes(err.length >= 4 ? 4 : err.length);
            for (uint256 i = 0; i < sel.length; i++) {
                sel[i] = err[i];
            }
            console2.log(
                string.concat(
                    "CSV;",
                    _name(venue),
                    ";",
                    tin,
                    ";",
                    tout,
                    ";",
                    vm.toString(amountIn),
                    ";0;revert:",
                    vm.toString(sel),
                    ";",
                    vm.toString(used)
                )
            );
        }
    }
}
