// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

contract Auth {
    error Auth__OnlyWards();

    event Rely(address indexed);
    event Deny(address indexed);

    mapping(address => bool) public wards;

    constructor() {
        wards[msg.sender] = true;
        emit Rely(msg.sender);
    }

    modifier auth() {
        if (!wards[msg.sender]) {
            revert Auth__OnlyWards();
        }
        _;
    }

    /// @notice Allows `usr` to perform root-level functions.
    function rely(address usr) external auth {
        wards[usr] = true;
        emit Rely(usr);
    }

    /// @notice Denies `usr` to perform root-level functions.
    function deny(address usr) external auth {
        wards[usr] = false;
        emit Deny(usr);
    }
}
