pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

contract MockToken is ERC20 {
    string name_;
    string symbol_;

    constructor(string memory _name, string memory _symbol) {
        name_ = _name;
        symbol_ = _symbol;
    }

    function name() public view override returns (string memory) {
        return name_;
    }

    function symbol() public view override returns (string memory) {
        return symbol_;
    }
}
