// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8;

/// @dev just the funcitons that are used by the SubPool contract to avoid
///      circular imports.
interface ISubPoolFactory {
    function announceExit() external;
    function updateBackendUri(string calldata) external;
    function exitTimestamp(address pool) external view returns (uint256);
    function updateSolverMembership(address solver, bool add) external;
}
