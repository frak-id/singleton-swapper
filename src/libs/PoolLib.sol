// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {SwapLib} from "./SwapLib.sol";

struct Pool {
    uint256 totalLiquidity;
    mapping(address => uint256) positions;
    uint128 reserves0;
    uint128 reserves1;
}

using PoolLib for Pool global;

/// @title PoolLib
/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
/// @notice This contract manage all the pool actions
library PoolLib {
    using SafeCastLib for uint256;

    error InsufficientLiquidity();

    /**
     * @dev Swap tokens in the pool
     * @param self The pool
     * @param zeroForOne Whether to swap token0 for token1 or token1 for token0
     * @param amount The amount of token0 or token1 to swap
     * @param fee The fee to charge for the liquidity providers
     * @return delta0 The amount of token0 swapped
     * @return delta1 The amount of token1 swapped
     */
    function swap(Pool storage self, bool zeroForOne, uint256 amount, uint256 fee)
        internal
        returns (int256 delta0, int256 delta1)
    {
        uint256 newReserves0;
        uint256 newReserves1;
        (newReserves0, newReserves1, delta0, delta1) =
            SwapLib.swap(self.reserves0, self.reserves1, zeroForOne, amount, fee);

        // Update the reserve of the pool
        self.reserves0 = newReserves0.toUint128();
        self.reserves1 = newReserves1.toUint128();
    }

    /**
     * @dev Swap tokens in the pool
     * @param self The pool
     * @param zeroForOne Whether to swap token0 for token1 or token1 for token0
     * @param amount The amount of token0 or token1 to swap
     * @param fee The fee to charge for the liquidity providers
     * @param protocolFee The fee to charge for the protocol
     * @return delta0 The amount of token0 swapped
     * @return delta1 The amount of token1 swapped
     */
    function swap(Pool storage self, bool zeroForOne, uint256 amount, uint256 fee, uint256 protocolFee)
        internal
        returns (int256 delta0, int256 delta1, uint256 protocolFeeToken0, uint256 protocolFeeToken1)
    {
        uint256 newReserves0;
        uint256 newReserves1;

        (newReserves0, newReserves1, delta0, delta1, protocolFeeToken0, protocolFeeToken1) =
            SwapLib.swap(self.reserves0, self.reserves1, zeroForOne, amount, fee, protocolFee);

        // Update the reserve of the pool
        self.reserves0 = newReserves0.toUint128();
        self.reserves1 = newReserves1.toUint128();
    }

    /**
     * @dev Add liquidity to the pool
     * @param self The pool
     * @param to The address of the liquidity provider
     * @param maxAmount0 The maximum amount of token0 to add
     * @param maxAmount1 The maximum amount of token1 to add
     * @return newLiquidity The amount of liquidity added
     * @return delta0 The amount of token0 added
     * @return delta1 The amount of token1 added
     */
    function addLiquidity(Pool storage self, address to, uint256 maxAmount0, uint256 maxAmount1)
        internal
        returns (uint256 newLiquidity, int256 delta0, int256 delta1)
    {
        uint256 total = self.totalLiquidity;

        uint256 amount0;
        uint256 amount1;

        if (total == 0) {
            newLiquidity = Math.sqrt(maxAmount0 * maxAmount1);
            amount0 = maxAmount0;
            amount1 = maxAmount1;

            self.totalLiquidity = newLiquidity;
            self.positions[to] = newLiquidity;
            self.reserves0 = amount0.toUint128();
            self.reserves1 = amount1.toUint128();
        } else {
            uint256 reserves0 = self.reserves0;
            uint256 reserves1 = self.reserves1;
            uint256 liq0 = total * maxAmount0 / reserves0;
            uint256 liq1 = total * maxAmount1 / reserves1;

            if (liq0 > liq1) {
                newLiquidity = liq1;
                amount0 = reserves0 * amount1 / reserves1;
                amount1 = maxAmount1;
            } else {
                // liq0 <= liq1
                newLiquidity = liq0;
                amount0 = maxAmount0;
                amount1 = reserves1 * amount0 / reserves0;
            }
            self.totalLiquidity = total + newLiquidity;
            self.positions[to] += newLiquidity;
            self.reserves0 = (reserves0 + amount0).toUint128();
            self.reserves1 = (reserves1 + amount1).toUint128();
        }

        delta0 = amount0.toInt256();
        delta1 = amount1.toInt256();
    }

    /**
     * @dev Remove liquidity from the pool
     * @param from The address of the user
     * @param liquidity The amount of liquidity to remove
     * @return delta0 The amount of token0 that should be transfered to the user
     * @return delta1 The amount of token1 that should be transfered to the user
     */
    function removeLiquidity(Pool storage self, address from, uint256 liquidity)
        internal
        returns (int256 delta0, int256 delta1)
    {
        // Ensure the user has enough liquidity
        uint256 position = self.positions[from];
        if (liquidity > position) revert InsufficientLiquidity();
        uint256 total = self.totalLiquidity;

        uint256 reserves0 = self.reserves0;
        uint256 reserves1 = self.reserves1;

        // Compute the amount that should be transfered
        uint256 amount0 = reserves0 * liquidity / total;
        uint256 amount1 = reserves1 * liquidity / total;

        // Decrease user position
        self.positions[from] = position - liquidity;

        // Decrease reserves and total liquidity
        self.reserves0 = (reserves0 - amount0).toUint128();
        self.reserves1 = (reserves1 - amount1).toUint128();
        self.totalLiquidity -= liquidity;

        // Compute the delta for the user
        delta0 = -amount0.toInt256();
        delta1 = -amount1.toInt256();
    }
}
