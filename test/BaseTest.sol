// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared fixture carrying the suite-wide containment invariant: the agent
/// address and the router end every test holding zero asset and zero shares.
///
/// @dev Imports NOTHING from `src/` -- the router does not exist until group 2, and
/// this ships in group 1 so every test file authored in waves 2 and 3 inherits the
/// modifier at authoring time rather than being retro-edited into it.
///
/// The token pair differs per consumer (MockUSDC/MockVault in group 2,
/// MockUSDC/AllowlistedERC4626 in group 3 and group 4's local file, real Base
/// USDC/mwUSDC in the fork file), so no address can be hardcoded here.
///
/// Inheriting this contract is NOT applying the invariant. Every test function must
/// carry the `containment` modifier explicitly.
abstract contract BaseTest is Test {
    /// @dev Mandatory. Unset reads as `address(0)`, whose balances are trivially
    /// zero -- the agent leg would then pass while checking nobody.
    address internal agent;

    /// @dev The ONLY skip-on-unset slot, because group 3 legitimately deploys no
    /// router. That also makes it the one slot that cannot fail loudly, which is
    /// why group 4 audits it by inspection rather than by a negative test.
    address internal containedRouter;

    /// @dev Mandatory.
    IERC20 internal containedAsset;

    /// @dev Mandatory.
    IERC20 internal containedShare;

    modifier containment() {
        // Wiring is validated before the body so an unwired subclass fails loudly
        // with a wiring message instead of passing inert against address(0).
        require(agent != address(0), "BaseTest: agent unset");
        require(address(containedAsset) != address(0), "BaseTest: containedAsset unset");
        require(address(containedShare) != address(0), "BaseTest: containedShare unset");

        _;

        assertEq(containedAsset.balanceOf(agent), 0, "containment: agent holds asset");
        assertEq(containedShare.balanceOf(agent), 0, "containment: agent holds shares");

        if (containedRouter != address(0)) {
            assertEq(containedAsset.balanceOf(containedRouter), 0, "containment: router holds asset");
            assertEq(containedShare.balanceOf(containedRouter), 0, "containment: router holds shares");
        }
    }
}
