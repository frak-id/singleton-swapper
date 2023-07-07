// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {Pool} from "./libs/PoolLib.sol";
import {Accounter} from "./libs/AccounterLib.sol";
import {BPS} from "./libs/SwapLib.sol";
import {Ops} from "./Ops.sol";

import {IGiver} from "./interfaces/IGiver.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {OpDecoderLib} from "./utils/operation/OpDecoderLib.sol";

/// @title MegaPool
/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
/// @notice The multi pool contract that handles all the pools and their actions
contract MegaPool is ReentrancyGuard {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using OpDecoderLib for uint256;

    /* -------------------------------------------------------------------------- */
    /*                                   Storage                                  */
    /* -------------------------------------------------------------------------- */

    uint256 public immutable FEE_BPS;

    mapping(address poolKey => Pool pool) internal pools;
    mapping(address poolKey => uint256 totalReserve) public totalReservesOf;

    /* -------------------------------------------------------------------------- */
    /*                               Custom error's                               */
    /* -------------------------------------------------------------------------- */

    error InvalidTokens();
    error InvalidOp(uint256 op);
    error LeftoverDelta();
    error InvalidGive();
    error NegativeAmount();
    error NegativeReceive();
    error AmountOutsideBounds();

    constructor(uint256 feeBps) {
        require(feeBps < BPS);
        FEE_BPS = feeBps;
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
     * @notice Execute a program of operations on pools. The `program` is a serialized list of operations, encoded in a specific format.
     * @dev This function uses a non-ABI encoding to ensure a custom set of operations, each taking on a different amount of data while keeping calldata size minimal. It is not reentrant.
     * @param program Serialized list of operations, with each operation consisting of an 8-bit operation specifier and parameters. The structure is as follows:
     *  2 bytes: accounting hash map size (in tokens) e.g. 0x0040 => up to 64 key, value pairs in the accounting map
     *  For every operation:
     *    1 byte:  8-bit operation (4-bits operation id and 4-bits flags)
     *    n bytes: opcode data
     * Refer to the function documentation for details on individual operations.
     */
    function execute(bytes calldata program) external nonReentrant {
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
        if (mop == Ops.SWAP) {
            ptr = _swap(state, ptr, op);
        } else if (mop == Ops.ADD_LIQ) {
            ptr = _addLiquidity(state, ptr);
        } else if (mop == Ops.RM_LIQ) {
            ptr = _removeLiquidity(state, ptr);
        } else if (mop == Ops.SEND) {
            ptr = _send(state, ptr);
        } else if (mop == Ops.RECEIVE) {
            ptr = _receive(state, ptr);
        } else if (mop == Ops.SWAP_HEAD) {
            ptr = _swapHead(state, ptr, op);
        } else if (mop == Ops.SWAP_HOP) {
            ptr = _swapHop(state, ptr);
        } else if (mop == Ops.SEND_ALL) {
            ptr = _sendAll(state, ptr, op);
        } else if (mop == Ops.RECEIVE_ALL) {
            ptr = _receiveAll(state, ptr, op);
        } else if (mop == Ops.PULL_ALL) {
            ptr = _pullAll(state, ptr, op);
        } else {
            revert InvalidOp(op);
        }

        return ptr;
    }

    function _swap(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token0;
        address token1;
        uint256 amount;
        (ptr, token0) = ptr.readAddress();
        (ptr, token1) = ptr.readAddress();
        bool zeroForOne = (op & Ops.SWAP_DIR) != 0;
        (ptr, amount) = ptr.readUint(16);

        (int256 delta0, int256 delta1) = _getPool(token0, token1).swap(zeroForOne, amount, FEE_BPS);

        state.tokenDeltas.accountChange(token0, delta0);
        state.tokenDeltas.accountChange(token1, delta1);

        return ptr;
    }

    function _addLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token0;
        address token1;
        address to;
        uint256 maxAmount0;
        uint256 maxAmount1;
        (ptr, token0) = ptr.readAddress();
        (ptr, token1) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();
        (ptr, maxAmount0) = ptr.readUint(16);
        (ptr, maxAmount1) = ptr.readUint(16);

        (, int256 delta0, int256 delta1) = _getPool(token0, token1).addLiquidity(to, maxAmount0, maxAmount1);

        state.tokenDeltas.accountChange(token0, delta0);
        state.tokenDeltas.accountChange(token1, delta1);

        return ptr;
    }

    function _removeLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token0;
        address token1;
        uint256 liq;
        (ptr, token0) = ptr.readAddress();
        (ptr, token1) = ptr.readAddress();
        (ptr, liq) = ptr.readUint(32);

        (int256 delta0, int256 delta1) = _getPool(token0, token1).removeLiquidity(msg.sender, liq);

        state.tokenDeltas.accountChange(token0, delta0);
        state.tokenDeltas.accountChange(token1, delta1);

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

    function _receive(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        uint256 amount;

        (ptr, token) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        _receive(state, token, amount);

        return ptr;
    }

    function _swapHead(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token0;
        address token1;
        uint256 amount;
        (ptr, token0) = ptr.readAddress();
        (ptr, token1) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        bool zeroForOne = (op & Ops.SWAP_DIR) != 0;

        (int256 delta0, int256 delta1) = _getPool(token0, token1).swap(zeroForOne, amount, FEE_BPS);
        state.lastToken = zeroForOne ? token1 : token0;

        state.tokenDeltas.accountChange(token0, delta0);
        state.tokenDeltas.accountChange(token1, delta1);

        return ptr;
    }

    function _swapHop(State memory state, uint256 ptr) internal returns (uint256) {
        address lastToken = state.lastToken;
        address nextToken;
        (ptr, nextToken) = ptr.readAddress();

        (address token0, address token1, bool zeroForOne) =
            nextToken > lastToken ? (lastToken, nextToken, true) : (nextToken, lastToken, false);

        int256 delta = state.tokenDeltas.resetChange(lastToken);
        if (delta > 0) revert NegativeAmount();

        (int256 delta0, int256 delta1) = _getPool(token0, token1).swap(zeroForOne, uint256(-delta), FEE_BPS);
        state.lastToken = nextToken;
        state.tokenDeltas.accountChange(nextToken, zeroForOne ? delta1 : delta0);

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

    /* -------------------------------------------------------------------------- */
    /*                           External view method's                           */
    /* -------------------------------------------------------------------------- */

    function getPool(address token0, address token1)
        external
        view
        returns (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity)
    {
        Pool storage pool = _getPool(token0, token1);
        reserves0 = pool.reserves0;
        reserves1 = pool.reserves1;
        totalLiquidity = pool.totalLiquidity;
    }

    function getPosition(address token0, address token1, address owner) external view returns (uint256) {
        return _getPool(token0, token1).positions[owner];
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal pure helper method's                       */
    /* -------------------------------------------------------------------------- */

    function _getPc(bytes calldata program) internal pure returns (uint256 ptr, uint256 endPtr) {
        assembly {
            ptr := program.offset
            endPtr := add(ptr, program.length)
        }
    }

    function _getPool(address token0, address token1) internal pure returns (Pool storage pool) {
        if (token0 >= token1) revert InvalidTokens();

        assembly {
            let freeMem := mload(0x40)
            mstore(0x00, pools.slot)
            mstore(0x20, token0)
            mstore(0x40, token1)
            pool.slot := keccak256(0x00, 0x60)
            mstore(0x40, freeMem)
        }
    }
}
