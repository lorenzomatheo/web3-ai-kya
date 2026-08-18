// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Makes `foundry.toml`'s profile exclusion falsifiable in BOTH directions,
/// immediately, rather than being discovered in group 4 when `test/fork/` is first
/// populated for real.
///
/// @dev Fails if the DEFAULT profile ever reaches it -- which is what proves
/// `no_match_path = "test/fork/**"` under `[profile.default]` actually excludes.
/// Passes under the fork profile -- which is what proves `[profile.fork]`'s sentinel
/// override is not silently inheriting that exclusion and running nothing.
///
/// `forge test` exits 0 when a filter matches nothing, so a leaked `no_match_path`,
/// a wrong glob and a renamed directory all present identically as a green fork run.
/// That is why every fork invocation in this wish pairs itself with a suite-named
/// grep asserting a non-zero test count.
contract ProfileGuardTest is Test {
    function test_RunsOnlyUnderForkProfile() public view {
        // Solidity has no `==` on string, so this is the literal form.
        assertEq(vm.envOr("FOUNDRY_PROFILE", string("default")), "fork");
    }
}
