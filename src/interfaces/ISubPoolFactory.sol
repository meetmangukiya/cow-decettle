// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @dev just the funcitons that are used by the SubPool contract to avoid
///      circular imports.
interface ISubPoolFactory {
    function dues(address pool) external view returns (uint256 amt, uint256 cowAmt);
    function quitPool() external;
    function exitPool() external;
    function exitTimestamp(address pool) external view returns (uint256);
}
