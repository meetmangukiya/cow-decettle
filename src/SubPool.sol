// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Auth} from "./Auth.sol";
import {ISubPoolFactory} from "./interfaces/ISubPoolFactory.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

using SafeTransferLib for address;

contract SubPool is Auth {
    error SubPool__OnlyFactory();
    error SubPool__CollateralTokenAlreadyInitialized();
    error SubPool__InsufficientETH();
    error SubPool__InvalidWithdraw();

    /// @dev cannot be immutable because that allows for multiple pools per solver address.
    address public collateralToken;
    address public immutable COW;
    ISubPoolFactory public immutable factory;

    uint256 collateralDue;
    uint256 cowDue;
    uint256 ethDue;

    modifier onlyFactory() {
        if (msg.sender != address(factory)) {
            revert SubPool__OnlyFactory();
        }
        _;
    }

    constructor(address _owner, address _cow) {
        factory = ISubPoolFactory(msg.sender);
        COW = _cow;

        // rely the owner
        _addOwner(_owner);
    }

    function initializeCollateralToken(address token) external {
        if (collateralToken != address(0)) revert SubPool__CollateralTokenAlreadyInitialized();
        collateralToken = token;
    }

    /// @notice Signal the intent to announce exit the solver pool.
    function announceExit() external auth {
        factory.announceExit();
    }

    /// @notice withdraw arbitrary tokens; if the pool can be exited, the natie eth balance is also withdrawn
    /// @dev Can only withdraw non cow and non collateral tokens while the pool is active or in exit delay.
    ///      When the pool's exit delay has elapsed it can withdraw any token and ether balance.
    function withdrawTokens(address[] calldata tokens) external auth {
        uint256 exitTimestamp = factory.exitTimestamp(address(this));
        bool exitElapsed = exitTimestamp != 0 && block.timestamp >= exitTimestamp;

        if (exitElapsed) {
            for (uint256 i = 0; i < tokens.length;) {
                tokens[i].safeTransfer(msg.sender, ERC20(tokens[i]).balanceOf(address(this)));
                unchecked {
                    ++i;
                }
            }
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                msg.sender.safeTransferETH(address(this).balance);
            }
        } else {
            for (uint256 i = 0; i < tokens.length;) {
                address token = tokens[i];
                if (token == COW || token == collateralToken) revert SubPool__InvalidWithdraw();
                token.safeTransfer(msg.sender, ERC20(token).balanceOf(address(this)));
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Pull required number of tokens from the sender to push the pool
    ///         back to the collateralization requirements.
    function heal() external payable {
        uint256 amt = collateralDue;
        uint256 cowAmt = cowDue;
        uint256 ethAmt = ethDue;
        if (msg.value != ethAmt) revert SubPool__InsufficientETH();
        if (cowAmt > 0) {
            cowDue = 0;
            COW.safeTransferFrom(msg.sender, address(this), cowAmt);
        }
        if (ethAmt > 0) {
            ethDue = 0;
        }
        if (amt > 0) {
            collateralDue = 0;
            collateralToken.safeTransferFrom(msg.sender, address(this), amt);
        }
    }

    /// @notice Bill a subpool.
    /// @dev    The check to not allow billing after exit delay is done in factory.
    function bill(uint256 amt, uint256 cowAmt, uint256 ethAmt, address to) external onlyFactory {
        if (amt > 0) {
            collateralToken.safeTransfer(to, amt);
            collateralDue += amt;
        }
        if (cowAmt > 0) {
            COW.safeTransfer(to, cowAmt);
            cowDue += cowAmt;
        }
        if (ethAmt > 0) {
            to.safeTransferETH(ethAmt);
            ethDue += ethAmt;
        }
    }

    /// @notice Update the backend api uri.
    function updateBackendUri(string calldata uri) external auth {
        factory.updateBackendUri(uri);
    }

    /// @notice Update solver membership.
    function updateSolverMembership(address solver, bool add) external auth {
        factory.updateSolverMembership(solver, add);
    }

    /// @notice Determine the amount of tokens(collateral, COW, ETH) that are due to put the pool
    ///         above collateralization requirements.
    function dues() external view returns (uint256 amt, uint256 cowAmt, uint256 ethAmt) {
        amt = collateralDue;
        cowAmt = cowDue;
        ethAmt = ethDue;
    }

    receive() external payable {}
}
