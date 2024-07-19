pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SubPoolFactory, IAggregatorV3Interface} from "src/SubPoolFactory.sol";
import {TOKEN_WETH_MAINNET, TOKEN_COW_MAINNET, CHAINLINK_PRICE_FEED_WETH_MAINNET} from "src/constants.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract BaseTest is Test {
    uint24 exitDelay = 4 days;
    uint24 freezeDelay = 1 days;
    uint104 minCowAmt = 100_000 ether;
    uint104 minUsdAmt = 50_000e8;
    SubPoolFactory factory = new SubPoolFactory(exitDelay, minCowAmt, TOKEN_COW_MAINNET);
    ERC20 weth = ERC20(TOKEN_WETH_MAINNET);
    ERC20 cow = ERC20(TOKEN_COW_MAINNET);

    function setUp() public virtual {}
}