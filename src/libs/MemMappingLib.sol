// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

type MemMapping is uint256;

type MapKVPair is uint256;

using MemMappingLib for MemMapping global;
using MemMappingLib for MapKVPair global;

/// @author philogy <https://github.com/philogy>
/// @notice In memory map of key value pair
/// @dev Store, from the first free mem pointer, on 32 bytes, key-value-key-value-key-value...
/// @dev The free mem pointer is moved after the the mam allocated size (defined during the init)
library MemMappingLib {
    function init(uint256 z) internal pure returns (MemMapping map) {
        assembly ("memory-safe") {
            // Allocate memory: 1 + 2 * size
            map := mload(0x40)
            mstore(map, z)
            let valueOffset := add(map, 0x20)
            let dataSize := mul(z, 0x40)
            mstore(0x40, add(valueOffset, dataSize))
            // Clears potentially dirty free memory.
            calldatacopy(valueOffset, calldatasize(), dataSize)
        }
    }

    function size(MemMapping map) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := mload(map)
        }
    }

    function key(MapKVPair kvPair) internal pure returns (uint256 k) {
        assembly ("memory-safe") {
            k := mload(kvPair)
        }
    }

    function value(MapKVPair kvPair) internal pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := mload(add(kvPair, 0x20))
        }
    }

    function setValue(MapKVPair kvPair, uint256 v) internal pure {
        assembly ("memory-safe") {
            mstore(add(kvPair, 0x20), v)
        }
    }

    function set(MapKVPair kvPair, uint256 k, uint256 v) internal pure {
        assembly ("memory-safe") {
            mstore(kvPair, k)
            mstore(add(kvPair, 0x20), v)
        }
    }

    function getPair(MemMapping map, uint256 k) internal pure returns (MapKVPair kvPair) {
        require(k != 0);

        assembly ("memory-safe") {
            let z := mload(map)
            let baseOffset := add(map, 0x20)
            let i := mod(k, z)
            kvPair := add(mul(i, 0x40), baseOffset)
            let storedKey := mload(kvPair)

            for {} iszero(or(eq(storedKey, k), iszero(storedKey))) {} {
                i := mod(add(i, 1), z)
                kvPair := add(mul(i, 0x40), baseOffset)
                storedKey := mload(kvPair)
            }
        }
    }

    function set(MemMapping map, uint256 k, uint256 v) internal pure {
        map.getPair(k).set(k, v);
    }

    function get(MemMapping map, uint256 k) internal pure returns (bool isNull, uint256 v) {
        MapKVPair pair = map.getPair(k);
        isNull = pair.key() == 0;
        v = pair.value();
    }
}
