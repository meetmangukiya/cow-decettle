// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @dev explicitly define first owner in inheriting contracts in the constructor.
abstract contract Auth {
    error Auth__OnlyOwners();

    event OwnerAdded(address indexed);
    event OwnerRemoved(address indexed);

    mapping(address => bool) public isOwner;

    modifier auth() {
        if (!isOwner[msg.sender]) {
            revert Auth__OnlyOwners();
        }
        _;
    }

    /// @notice Allows `usr` to perform root-level functions.
    function addOwner(address usr) external auth {
        _addOwner(usr);
    }

    /// @notice Denies `usr` to perform root-level functions.
    function removeOwner(address usr) external auth {
        _removeOwner(usr);
    }

    function _addOwner(address usr) internal {
        isOwner[usr] = true;
        emit OwnerAdded(usr);
    }

    function _removeOwner(address usr) internal {
        isOwner[usr] = false;
        emit OwnerRemoved(usr);
    }
}
