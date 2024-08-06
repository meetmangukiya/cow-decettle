// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8;

interface IDelegateRegistry {
    /// @dev Sets a delegate for the msg.sender and a specific id.
    ///      The combination of msg.sender and the id can be seen as a unique key.
    /// @param id Id for which the delegate should be set
    /// @param delegate Address of the delegate
    function setDelegate(bytes32 id, address delegate) external;
}
