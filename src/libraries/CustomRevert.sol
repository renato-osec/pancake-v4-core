// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
library CustomRevert {
    /// @notice bubble up the revert message returned by a call and revert with the selector provided
    /// @dev this function should only be used with custom errors of the type `CustomError(address target, bytes revertReason)`
    /// @dev we know what we are doing and immediately revert thus we can use 0x00 even in memory-safe mode
    function bubbleUpAndRevertWith(bytes4 selector, address addr) internal pure {
        //FIXME
        assembly ("memory-safe") {
            let size := returndatasize()
            // Encode selector, address, offset, size, data
            mstore(0, selector)
            mstore(add(0, 0x04), addr)
            mstore(add(0, 0x24), 0x40)
            mstore(add(0, 0x44), size)
            returndatacopy(add(0, 0x64), 0, size)

            // Ensure the size is a multiple of 32 bytes
            let encodedSize := add(0x64, mul(div(add(size, 31), 32), 32))
            revert(0, encodedSize)
        }
    }
}
