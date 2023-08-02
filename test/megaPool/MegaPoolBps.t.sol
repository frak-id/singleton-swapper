// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MegaPool} from "src/MegaPool.sol";
import {BaseEncoderLib} from "src/encoder/BaseEncoderLib.sol";
import {MegaOpEncoderLib} from "src/encoder/MegaOpEncoderLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {MockGiver} from "../mock/MockGiver.sol";

/// @title MegaPoolTest
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Test contract for MegaPool with a BPS value
contract MegaPoolBpsTest is Test {
    using SafeTransferLib for address;
    using BaseEncoderLib for bytes;
    using MegaOpEncoderLib for bytes;

    MegaPool private pool;

    // 0.5e3 = 0.5%
    uint256 private bps = 1e3;

    function setUp() public {
        pool = new MegaPool(bps);
    }

    /**
     * @notice Test swap with single operation
     */
    function testMain() public {
        MockERC20 token0 = _newToken("token_0");
        MockERC20 token1 = _newToken("token_1");

        if (token0 >= token1) (token0, token1) = (token1, token0);

        address liquidityProvider = address(_newGiver("liquidityProvider"));
        address swapUser = address(_newGiver("swapUser"));

        uint256 initialDepositToken0 = 10e18;
        uint256 initialDepositToken1 = 10e18;

        token0.mint(liquidityProvider, initialDepositToken0);
        token1.mint(liquidityProvider, initialDepositToken1);

        // 64 map size
        // | execute                            | 13914           | 31572 | 22205  | 139656 | 14      |
        // 32 map size
        // | execute                            | 13585           | 31202 | 21835  | 139327 | 14      |
        // 16 map size
        // | execute                            | 13425           | 31022 | 21655  | 139167 | 14      |
        // 2 map size
        // | execute                            | 13288           | 30868 | 21501  | 139030 | 14      |
        // 4 map size (seems enough for single swap OP)
        // | execute                            | 13308           | 30889 | 21523  | 139049 | 14      |

        // Append initial liquidity to the pool
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendAddLiquidity(address(token0), address(token1), liquidityProvider, initialDepositToken0, initialDepositToken1)
            .appendReceive(address(token0), initialDepositToken0).appendReceive(address(token1), initialDepositToken1)
            .done();

        vm.prank(liquidityProvider);
        pool.execute(program);

        console.log("= Post add liquidity =");
        _postSwapReserveLog(address(token0), address(token1));
        console.log("");

        // Perform a few swap
        token0.mint(swapUser, 0.1e18);
        _swap0to1(address(token0), address(token1), swapUser, token0.balanceOf(swapUser));
        _swap1to0(address(token0), address(token1), swapUser, token1.balanceOf(swapUser));
        _swap0to1(address(token0), address(token1), swapUser, token0.balanceOf(swapUser));
        _swap1to0(address(token0), address(token1), swapUser, token1.balanceOf(swapUser));

        // Perform a few unilateral swap
        token1.mint(swapUser, 20e18);
        _swap1to0(address(token0), address(token1), swapUser, 5e18);
        _swap1to0(address(token0), address(token1), swapUser, 5e18);
        _swap1to0(address(token0), address(token1), swapUser, 5e18);
        _swap1to0(address(token0), address(token1), swapUser, 5e18);

        // Perform a few other unilateral swap
        token0.mint(swapUser, 20e18);
        _swap0to1(address(token0), address(token1), swapUser, 5e18);
        _swap0to1(address(token0), address(token1), swapUser, 5e18);
        _swap0to1(address(token0), address(token1), swapUser, 5e18);
        _swap0to1(address(token0), address(token1), swapUser, 5e18);

        // Tell the liquidityProvider to withdraw of all his founds
        // forgefmt: disable-next-item
        program = BaseEncoderLib.init(4)
            .appendRemoveLiquidity(address(token0), address(token1), 10e18)
            .appendSendAll(address(token0), liquidityProvider)
            .appendSendAll(address(token1), liquidityProvider)
            .done();

        vm.prank(liquidityProvider);
        pool.execute(program);

        // Log the final state
        console.log("= Post remove liquidity =");
        _postSwapReserveLog(address(token0), address(token1));
        console.log("");

        // Ensure that the liquidity provider has all his founds
        uint256 newBalanceToken0 = token0.balanceOf(liquidityProvider);
        uint256 newBalanceToken1 = token1.balanceOf(liquidityProvider);
        console.log("liquidity provider new global balance: %s", newBalanceToken0 + newBalanceToken1);
        console.log(
            "liquidity provider profit: %s",
            (newBalanceToken0 + newBalanceToken1) - (initialDepositToken0 + initialDepositToken1)
        );
        assertGt(newBalanceToken0 + newBalanceToken1, initialDepositToken0 + initialDepositToken1);
    }

    function _swap0to1(address token0, address token1, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves1 - (reserves0 * reserves1) / (reserves0 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        // forgefmt: disable-next-item
        bytes memory operations = BaseEncoderLib.init(4)
            .appendSwap(token0, token1, true, inAmount)
            .appendReceive(token0, inAmount)
            .appendSend(token1, user, outAmount)
            .done();

        // Send it
        vm.prank(user);
        pool.execute(operations);

        (reserves0, reserves1, totalLiquidity) = pool.getPool(token0, token1);
        console.log("= Post 0->1 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token0, token1, user);
        _postSwapReserveLog(token0, token1);
        console.log("");
    }

    function _swap1to0(address token0, address token1, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves0 - (reserves0 * reserves1) / (reserves1 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        // forgefmt: disable-next-item
        bytes memory operations = BaseEncoderLib.init(4)
            .appendSwap(token0, token1, false, inAmount)
            .appendReceive(token1, inAmount)
            .appendSend(token0, user, outAmount)
            .done();

        vm.prank(user);
        pool.execute(operations);

        (reserves0, reserves1, totalLiquidity) = pool.getPool(token0, token1);
        console.log("= Post 1->0 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token0, token1, user);
        _postSwapReserveLog(token0, token1);
        console.log("");
    }

    function _postSwapAmountLog(uint256 inAmount, uint256 outAmount) internal view {
        console.log("=== Swap ===");
        console.log(" inAmount: %s", inAmount);
        console.log("outAmount: %s", outAmount);
    }

    function _postSwapReserveLog(address token0, address token1) internal view {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);
        console.log("=== Pool ===");
        console.log("reserves0: %s", reserves0);
        console.log("reserves1: %s", reserves1);
        console.log("totalLiquidity: %s", totalLiquidity);
    }

    function _postSwapBalanceLog(address token0, address token1, address user) internal view {
        console.log("=== User Balances ===");
        console.log("token0: %s", ERC20(token0).balanceOf(user));
        console.log("token1: %s", ERC20(token1).balanceOf(user));
    }

    function _newToken(string memory label) internal returns (MockERC20 newToken) {
        newToken = new MockERC20();
        vm.label(address(newToken), label);
    }

    function _newGiver(string memory label) internal returns (MockGiver newGiver) {
        newGiver = new MockGiver();
        vm.label(address(newGiver), label);
    }
}
