pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SubPoolFactory} from "src/SubPoolFactory.sol";
import {SubPool} from "src/SubPool.sol";
import {TOKEN_WETH_MAINNET, TOKEN_COW_MAINNET} from "src/constants.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract BaseTest is Test {
    uint24 exitDelay = 4 days;
    SubPoolFactory factory = new SubPoolFactory(exitDelay, TOKEN_COW_MAINNET, address(this));
    ERC20 weth = ERC20(TOKEN_WETH_MAINNET);
    ERC20 cow = ERC20(TOKEN_COW_MAINNET);

    function setUp() public virtual {}

    function _seedAndDeployPool(
        address solver,
        address collateralToken,
        uint256 collateralAmt,
        uint256 cowAmt,
        uint256 ethAmt,
        string memory backendUri
    ) internal returns (address) {
        deal(collateralToken, solver, collateralAmt);
        deal(TOKEN_COW_MAINNET, solver, cowAmt);
        vm.startPrank(solver);
        ERC20(collateralToken).approve(address(factory), collateralAmt);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), cowAmt);
        address poolAddress = factory.create(TOKEN_WETH_MAINNET, collateralAmt, cowAmt, backendUri);
        SubPool(payable(poolAddress)).updateSolverMembership(solver, true);
        vm.stopPrank();
        vm.deal(poolAddress, ethAmt);
        return poolAddress;
    }
}
