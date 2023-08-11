// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {Pool} from "./libs/PoolLib.sol";
import {Accounter} from "./libs/AccounterLib.sol";
import {BPS} from "./libs/SwapLib.sol";
import {Ops} from "./Ops.sol";

import {IWrappedNativeToken} from "./interfaces/IWrappedNativeToken.sol";
import {IGiver} from "./interfaces/IGiver.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {OpDecoderLib} from "./encoder/OpDecoderLib.sol";

/// @title MonoTokenPool
/// @author philogy <https://github.com/philogy>
/// @notice Same as the original MegaTokenPool, but with a single ERC_20 base token (useful for project that want a pool for their internal swap)
/// @dev baseToken as 0 and 1 as target pool token
/// @dev Every delta, reserves and liquidity follow this rule
contract MonoTokenPool is ReentrancyGuard {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using OpDecoderLib for uint256;

    /// @dev The max swap fee (5%)
    uint256 private constant MAX_SWAP_FEE = 50;

    /* -------------------------------------------------------------------------- */
    /*                                   Storage                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev The fee that will be taken from each swaps
    uint256 public immutable FEE_BPS;

    /// @dev The base token we will use for all the pools
    address private immutable baseToken;

    /// @dev The fee that will be taken from each swaps
    uint16 private swapFeePerThousands;

    /// @dev The receiver for the swap fees
    address private feeReceiver;

    /// @dev The mapping of all the pools per target token
    mapping(address token => Pool pool) internal pools;

    /// @dev The mapping of our reserves per tokens
    mapping(address token => uint256 totalReserve) public totalReservesOf;

    /* -------------------------------------------------------------------------- */
    /*                               Custom error's                               */
    /* -------------------------------------------------------------------------- */

    error InvalidOp(uint256 op);
    error LeftoverDelta();
    error InvalidGive();
    error NegativeAmount();
    error NegativeReceive();
    error AmountOutsideBounds();
    error NotCurrentFeeReceiver();

    constructor(address token, uint256 feeBps, address _feeReceiver, uint16 _swapFeePerThousands) {
        require(feeBps < BPS);
        require(token != address(0));
        require(_feeReceiver != address(0));
        require(_swapFeePerThousands <= MAX_SWAP_FEE);
        FEE_BPS = feeBps;
        baseToken = token;
        feeReceiver = _feeReceiver;
        swapFeePerThousands = _swapFeePerThousands;
    }

    /**
     * @notice In memory state to handle the accounting for the execution of a program.
     */
    struct State {
        Accounter tokenDeltas;
        address lastToken;
    }

    /* -------------------------------------------------------------------------- */
    /*                           External write method's                          */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Update the fee receiver and the fee amount
     * @param _feeReceiver The new fee receiver
     * @param _swapFeePerThousands The new fee amount per thousand
     * @dev Only the current fee receiver can update the fee receiver and the amount
     */
    function updateFeeReceiver(address _feeReceiver, uint16 _swapFeePerThousands) external {
        if (feeReceiver != msg.sender) revert NotCurrentFeeReceiver();

        require(_swapFeePerThousands <= MAX_SWAP_FEE);

        if (_feeReceiver == address(0)) {
            require(_swapFeePerThousands == 0);
        }

        feeReceiver = _feeReceiver;
        swapFeePerThousands = _swapFeePerThousands;
    }

    /**
     * @notice Execute a program of operations on pools. The `program` is a serialized list of operations, encoded in a specific format.
     * @dev This function uses a non-ABI encoding to ensure a custom set of operations, each taking on a different amount of data while keeping calldata size minimal. It is not reentrant.
     * @param program Serialized list of operations, with each operation consisting of an 8-bit operation specifier and parameters. The structure is as follows:
     *  2 bytes: accounting hash map size (in tokens) e.g. 0x0040 => up to 64 key, value pairs in the accounting map
     *  For every operation:
     *    1 byte:  8-bit operation (4-bits operation id and 4-bits flags)
     *    n bytes: opcode data
     * Refer to the function documentation for details on individual operations.
     */
    function execute(bytes calldata program) external payable nonReentrant {
        (uint256 ptr, uint256 endPtr) = _getPc(program);

        State memory state;
        {
            uint256 hashMapSize;
            (ptr, hashMapSize) = ptr.readUint(2);
            state.tokenDeltas.init(hashMapSize);
        }

        uint256 op;
        while (ptr < endPtr) {
            unchecked {
                (ptr, op) = ptr.readUint(1);

                ptr = _interpretOp(state, ptr, op);
            }
        }

        if (state.tokenDeltas.totalNonZero != 0) revert LeftoverDelta();
    }

    /* -------------------------------------------------------------------------- */
    /*                           Internal write method's                          */
    /* -------------------------------------------------------------------------- */

    function _interpretOp(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        uint256 mop = op & Ops.MASK_OP;
        // TODO: Should be sorted by more common op to less common one
        if (mop == Ops.SWAP) {
            ptr = _swap(state, ptr, op);
        } else if (mop == Ops.RECEIVE) {
            ptr = _receive(state, ptr, op);
        } else if (mop == Ops.SEND_ALL) {
            ptr = _sendAll(state, ptr, op);
        } else if (mop == Ops.SEND_ALL_AND_UNWRAP) {
            ptr = _sendAllAndUnwrap(state, ptr, op);
        } else if (mop == Ops.PULL_ALL) {
            ptr = _pullAll(state, ptr, op);
        } else if (mop == Ops.PERMIT_VIA_SIG) {
            ptr = _permitViaSig(ptr);
        } else if (mop == Ops.SEND) {
            ptr = _send(state, ptr);
        } else if (mop == Ops.RECEIVE_ALL) {
            ptr = _receiveAll(state, ptr, op);
        } else if (mop == Ops.ADD_LIQ) {
            ptr = _addLiquidity(state, ptr);
        } else if (mop == Ops.RM_LIQ) {
            ptr = _removeLiquidity(state, ptr);
        } else if (mop == Ops.CLAIM_ALL_FEES) {
            ptr = _claimAllFees(ptr);
        } else {
            revert InvalidOp(op);
        }

        return ptr;
    }

    function _swap(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        uint256 amount;
        (ptr, token) = ptr.readAddress();
        bool zeroForOne = (op & Ops.SWAP_DIR) != 0;
        (ptr, amount) = ptr.readUint(16);

        // Get the deltas
        int256 delta0;
        int256 delta1;
        // Take the fee if needed
        if (swapFeePerThousands > 0) {
            (delta0, delta1) = _getPool(token).swap(zeroForOne, amount, FEE_BPS, swapFeePerThousands);
        } else {
            (delta0, delta1) = _getPool(token).swap(zeroForOne, amount, FEE_BPS);
        }

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _addLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        address to;
        uint256 maxAmount0;
        uint256 maxAmount1;
        (ptr, token) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();
        (ptr, maxAmount0) = ptr.readUint(16);
        (ptr, maxAmount1) = ptr.readUint(16);

        (, int256 delta0, int256 delta1) = _getPool(token).addLiquidity(to, maxAmount0, maxAmount1);

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _removeLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        uint256 liq;
        (ptr, token) = ptr.readAddress();
        (ptr, liq) = ptr.readFullUint();

        (int256 delta0, int256 delta1) = _getPool(token).removeLiquidity(msg.sender, liq);

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _send(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        address to;
        uint256 amount;

        (ptr, token) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        state.tokenDeltas.accountChange(token, amount.toInt256());
        token.safeTransfer(to, amount);
        totalReservesOf[token] -= amount;

        return ptr;
    }

    function _receive(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        uint256 amount;

        (ptr, token) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        // In the case of a native token reception
        if (op & Ops.RECEIVE_NATIVE_TOKEN != 0) {
            // Try to deposit the native token
            IWrappedNativeToken(token).deposit{value: amount}();

            // Tell that we received the token
            _accountReceived(state, token);
        } else {
            // Otherwise, we just account for the received token
            _receive(state, token, amount);
        }

        return ptr;
    }

    function _sendAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        address to;

        (ptr, token) = ptr.readAddress();
        int256 delta = state.tokenDeltas.resetChange(token);
        if (delta > 0) revert NegativeAmount();

        uint256 minSend = 0;
        uint256 maxSend = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minSend) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxSend) = ptr.readUint(16);

        uint256 amount = uint256(-delta);
        if (amount < minSend || amount > maxSend) revert AmountOutsideBounds();

        (ptr, to) = ptr.readAddress();
        totalReservesOf[token] -= amount;
        token.safeTransfer(to, amount);

        return ptr;
    }

    function _sendAllAndUnwrap(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        address to;

        (ptr, token) = ptr.readAddress();
        int256 delta = state.tokenDeltas.resetChange(token);
        if (delta > 0) revert NegativeAmount();

        uint256 minSend = 0;
        uint256 maxSend = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minSend) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxSend) = ptr.readUint(16);

        uint256 amount = uint256(-delta);
        if (amount < minSend || amount > maxSend) revert AmountOutsideBounds();

        (ptr, to) = ptr.readAddress();
        // Decrease the reserve
        totalReservesOf[token] -= amount;
        // Withdraw the amount of token from the wrapped token
        IWrappedNativeToken(token).withdraw(amount);
        // Transfer the token
        to.safeTransferETH(amount);

        return ptr;
    }

    function _receiveAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;

        (ptr, token) = ptr.readAddress();

        uint256 minReceive = 0;
        uint256 maxReceive = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minReceive) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxReceive) = ptr.readUint(16);

        int256 delta = state.tokenDeltas.getChange(token);
        if (delta < 0) revert NegativeReceive();

        uint256 amount = uint256(delta);
        if (amount < minReceive || amount > maxReceive) revert AmountOutsideBounds();

        _receive(state, token, amount);

        return ptr;
    }

    function _pullAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;

        (ptr, token) = ptr.readAddress();

        uint256 minReceive = 0;
        uint256 maxReceive = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minReceive) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxReceive) = ptr.readUint(16);

        int256 delta = state.tokenDeltas.getChange(token);
        if (delta < 0) revert NegativeReceive();

        uint256 amount = uint256(delta);
        if (amount < minReceive || amount > maxReceive) revert AmountOutsideBounds();

        token.safeTransferFrom(msg.sender, address(this), amount);
        _accountReceived(state, token);

        return ptr;
    }

    function _permitViaSig(uint256 ptr) internal returns (uint256) {
        address token;
        uint256 amount;
        uint256 deadline;
        uint256 v;
        bytes32 r;
        bytes32 s;

        (ptr, token) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);
        (ptr, deadline) = ptr.readUint(6);
        (ptr, v) = ptr.readUint(1);
        (ptr, r) = ptr.readFullBytes();
        (ptr, s) = ptr.readFullBytes();

        // TODO: SOC another contract performing the permit and wrapping operations?
        // TODO: Like a pre swap hook? Or a pre swap execution layer with dedicated commands?
        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, uint8(v), r, s);

        return ptr;
    }

    function _receive(State memory state, address token, uint256 amount) internal {
        if (IGiver(msg.sender).give(token, amount) != IGiver.give.selector) {
            revert InvalidGive();
        }
        _accountReceived(state, token);
    }

    function _accountReceived(State memory state, address token) internal {
        uint256 reserves = totalReservesOf[token];
        uint256 directBalance = token.balanceOf(address(this));
        uint256 totalReceived = directBalance - reserves;

        state.tokenDeltas.accountChange(token, -totalReceived.toInt256());
        totalReservesOf[token] = directBalance;
    }

    function _claimAllFees(uint256 ptr) internal returns (uint256) {
        address token;
        address to;

        (ptr, token) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();

        // Ensure to is the fee receiver
        if (to != feeReceiver) revert NotCurrentFeeReceiver();

        // Get the pool, and thus the amount to claim
        Pool storage pool = _getPool(token);

        // Send each fee to the fee receiver
        uint256 token0Amount = pool.feeToken0;
        uint256 token1Amount = pool.feeToken1;

        // Send each fee to the fee receiver
        if (token0Amount > 0) {
            pool.feeToken0 = 0;
            totalReservesOf[baseToken] -= token0Amount;
            baseToken.safeTransfer(to, token0Amount);
        }

        if (token1Amount > 0) {
            pool.feeToken1 = 0;
            totalReservesOf[token] -= token1Amount;
            token.safeTransfer(to, token1Amount);
        }

        return ptr;
    }

    /* -------------------------------------------------------------------------- */
    /*                           External view method's                           */
    /* -------------------------------------------------------------------------- */

    /// @dev Returns the pool for the given 'token'.
    function getPool(address token)
        external
        view
        returns (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity, uint128 feeToken0, uint128 feeToken1)
    {
        Pool storage pool = _getPool(token);
        reserves0 = pool.reserves0;
        reserves1 = pool.reserves1;
        totalLiquidity = pool.totalLiquidity;
        feeToken0 = pool.feeToken0;
        feeToken1 = pool.feeToken1;
    }

    /// @dev Returns the position for the given 'token' and 'owner'.
    function getPosition(address token, address owner) external view returns (uint256) {
        return _getPool(token).positions[owner];
    }

    /// @dev Returns the amount of token that can be swapped for the given 'amount'.
    function estimateSwap(address token, uint256 inAmount, bool zeroForOne) external view returns (uint256 amountOut) {
        Pool storage pool = _getPool(token);
        uint256 reserves0 = pool.reserves0;
        uint256 reserves1 = pool.reserves1;
        if (zeroForOne) {
            amountOut = reserves1 - (reserves0 * reserves1) / (reserves0 + inAmount * (BPS - FEE_BPS) / BPS);
        } else {
            amountOut = reserves0 - (reserves0 * reserves1) / (reserves1 + inAmount * (BPS - FEE_BPS) / BPS);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal pure helper method's                       */
    /* -------------------------------------------------------------------------- */

    function _getPc(bytes calldata program) internal pure returns (uint256 ptr, uint256 endPtr) {
        assembly ("memory-safe") {
            ptr := program.offset
            endPtr := add(ptr, program.length)
        }
    }

    /// @dev Returns the pool for the given 'token'.
    function _getPool(address token) internal pure returns (Pool storage pool) {
        assembly ("memory-safe") {
            mstore(0x00, pools.slot)
            mstore(0x20, token)
            pool.slot := keccak256(0x00, 0x40)
        }
    }

    /// @dev Just tell use that this smart contract can receive native tokens
    receive() external payable {
        // TODO: directly call _accountReceived()?
        // TODO: Native token pool? If yes, how to handle multi wrapped erc20 tokens?
        // TODO: Native token pool with direct handling of native transfer via msg.value diffs?
    }
}
