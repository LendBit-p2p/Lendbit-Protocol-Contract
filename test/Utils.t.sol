// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/utils/functions/Utils.sol";

contract UtilsTest is Test {
    function setUp() public {}
    function testCalculatePercentage() public pure {
        assertEq(Utils.calculatePercentage(10000, 1000), 1000);
        assertEq(Utils.calculatePercentage(5000, 5000), 2500);
        assertEq(Utils.calculatePercentage(100, 100), 1);
    }
}
