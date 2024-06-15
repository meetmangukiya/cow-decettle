// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Auth} from "./Auth.sol";
import {ISubPoolFactory} from "./interfaces/ISubPoolFactory.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract SubPool is Auth {
    error SubPool__OnlyFactory();
    error SubPool__ExitDelayNotElapsedYet();
    error SubPool__CollateralTokenAlreadyInitialized();

    /// @dev cannot be immutable because that allows for multiple pools per solver address.
    address public collateralToken;
    address public immutable owner;
    address public immutable COW;
    ISubPoolFactory public immutable factory;

    string public backendUrl;

    constructor(address _owner, address _cow) {
        owner = _owner;
        factory = ISubPoolFactory(msg.sender);
        COW = _cow;

        // rely the owner
        wards[owner] = true;
        emit Rely(owner);
    }

    function initializeCollateralToken(address token) external {
        if (collateralToken != address(0)) revert SubPool__CollateralTokenAlreadyInitialized();
        collateralToken = token;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) {
            revert SubPool__OnlyFactory();
        }
        _;
    }

    /// @notice Determine the amount of tokens that are due to put the pool
    ///         above collateralization requirements.
    function dues() external view returns (uint256 amt, uint256 cowAmt) {
        (amt, cowAmt) = factory.dues(address(this));
    }

    /// @notice Pull required number of tokens from the sender to push the pool
    ///         above collateralization.
    function heal() external {
        (uint256 amt, uint256 cowAmt) = factory.dues(address(this));
        if (amt > 0) SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), amt);
        if (cowAmt > 0) SafeTransferLib.safeTransferFrom(COW, msg.sender, address(this), cowAmt);
    }

    /// @notice Signal the intent to quit the solver pool.
    function quit() external auth {
        factory.quitPool();
    }

    /// @notice Execute the exit after the exit delay has elapsed.
    function exit() external {
        uint256 exitTimestamp = factory.exitTimestamp(address(this));
        if (exitTimestamp == 0 || block.timestamp < exitTimestamp) revert SubPool__ExitDelayNotElapsedYet();

        uint256 collateralBalance = ERC20(collateralToken).balanceOf(address(this));
        uint256 cowBalance = ERC20(COW).balanceOf(address(this));
        SafeTransferLib.safeTransfer(collateralToken, owner, collateralBalance);
        SafeTransferLib.safeTransfer(COW, owner, cowBalance);

        factory.exitPool();
    }

    /// @notice Slip tokens for fines.
    function slip(uint256 amt, uint256 cowAmt, address to) external onlyFactory {
        if (amt > 0) SafeTransferLib.safeTransfer(collateralToken, to, amt);
        if (cowAmt > 0) SafeTransferLib.safeTransfer(COW, to, cowAmt);
    }

    /// @notice Update the backend api url.
    function updateBackendUrl(string calldata url) external auth {
        backendUrl = url;
    }
}
