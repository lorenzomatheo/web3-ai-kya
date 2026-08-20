// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.sol";
import {AllowlistedERC4626} from "../src/AllowlistedERC4626.sol";
import {MockUSDC} from "./doubles/MockUSDC.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Group 3's suite. The contract name is pinned: the group's validation
/// selects on it with `--match-contract`, and `forge test` exits 0 on a zero-match
/// run, so a rename would turn the whole gate green while running nothing.
///
/// @dev Extends `BaseTest` and applies `containment` to every test function.
/// `containedRouter` is deliberately left unset -- group 3 deploys no router, which
/// is the one legitimate skip-on-unset case the fixture allows.
contract AllowlistedERC4626Test is BaseTest {
    MockUSDC internal usdc;
    AllowlistedERC4626 internal vault;

    address internal principal = makeAddr("principal");
    address internal outsider = makeAddr("outsider");
    address internal admin = makeAddr("admin");

    uint256 internal constant AMOUNT = 500e6;

    function setUp() public {
        agent = makeAddr("agent");

        usdc = new MockUSDC();
        vault = new AllowlistedERC4626(IERC20(address(usdc)), "Allowlisted USDC Vault", "aUSDC", admin);

        vm.prank(admin);
        vault.setAllowlisted(principal, true);

        // The outsider is funded and approved but NEVER allowlisted: they can push
        // assets in, they just cannot end up holding the shares.
        usdc.mint(outsider, 1_000_000e6);
        vm.prank(outsider);
        usdc.approve(address(vault), type(uint256).max);

        // The agent is deliberately never funded. The containment invariant holds
        // only because the NotAllowlisted revert fires before any transferFrom.
        containedAsset = IERC20(address(usdc));
        containedShare = IERC20(address(vault));
    }

    /// @dev First four bytes of revert data. The cast is safe: it reads the leading
    /// selector word and cannot truncate a value, since revert data is not a number.
    function _selectorOf(bytes memory reason) internal pure returns (bytes4) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason);
    }

    // ------------------------------------------------------------------
    // The gate keys on `receiver`, not on `caller`
    // ------------------------------------------------------------------

    /// @dev The negative case, and demo transaction 11. "From any caller" is covered
    /// here: the outsider is allowed to call, and still cannot make the agent a holder.
    function test_DepositToAgentRevertsNotAllowlisted() public containment {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllowlistedERC4626.NotAllowlisted.selector, agent));
        vault.deposit(AMOUNT, agent);
    }

    /// @dev The positive case. Called from a funded neutral `outsider`, NOT from the
    /// agent slot: OZ's `_deposit` pulls via `safeTransferFrom(asset, caller, ...)`,
    /// so an agent-called success would require dealing the agent USDC -- which the
    /// containment invariant asserts never happens. This is a deliberate deviation
    /// from DESIGN's Vault-mechanics wording, taking the containment side; it is not
    /// a transcription error.
    function test_DepositToPrincipalFromOutsiderSucceeds() public containment {
        vm.prank(outsider);
        uint256 shares = vault.deposit(AMOUNT, principal);

        assertGt(shares, 0, "shares minted");
        assertEq(vault.balanceOf(principal), shares, "shares land with the allowlisted receiver");
        assertEq(vault.balanceOf(outsider), 0, "the caller holds nothing");
        assertEq(usdc.balanceOf(address(vault)), AMOUNT, "assets held idle by the vault");
    }

    /// @dev Together with the two above, this is what proves the gate keys on
    /// `receiver`. An allowlisted caller is still refused an unallowlisted receiver.
    function test_GateKeysOnReceiverNotCaller() public containment {
        usdc.mint(principal, AMOUNT);
        vm.startPrank(principal);
        usdc.approve(address(vault), AMOUNT);

        // The principal IS allowlisted, and is the caller -- but the receiver is not.
        vm.expectRevert(abi.encodeWithSelector(AllowlistedERC4626.NotAllowlisted.selector, outsider));
        vault.deposit(AMOUNT, outsider);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The revert is OURS, not OZ's -- decision 6's ordering hazard
    // ------------------------------------------------------------------

    /// @dev `maxDeposit` returns 0 for an unallowlisted receiver, which is exactly the
    /// condition under which OZ's `deposit` would revert `ERC4626ExceededMaxDeposit`.
    /// The explicit check fires first, so the selector must still be ours.
    function test_RevertIsOursEvenThoughMaxDepositReturnsZero() public containment {
        assertEq(vault.maxDeposit(agent), 0, "maxDeposit reports the gate, for conformance");

        vm.prank(outsider);
        try vault.deposit(AMOUNT, agent) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_selectorOf(reason), AllowlistedERC4626.NotAllowlisted.selector, "our error, not OZ's");
            assertTrue(_selectorOf(reason) != ERC4626.ERC4626ExceededMaxDeposit.selector, "never OZ's max error");
        }
    }

    function test_MintIsGatedIdenticallyAndRevertIsOurs() public containment {
        assertEq(vault.maxMint(agent), 0, "maxMint reports the gate too");

        vm.prank(outsider);
        try vault.mint(AMOUNT, agent) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_selectorOf(reason), AllowlistedERC4626.NotAllowlisted.selector, "our error, not OZ's");
            assertTrue(_selectorOf(reason) != ERC4626.ERC4626ExceededMaxMint.selector, "never OZ's max error");
        }
    }

    function test_MintToAllowlistedReceiverSucceeds() public containment {
        vm.prank(outsider);
        uint256 assets = vault.mint(AMOUNT, principal);

        assertGt(assets, 0, "assets pulled");
        assertEq(vault.balanceOf(principal), AMOUNT, "shares minted to the allowlisted receiver");
    }

    /// @dev Conformance: the limits open up once the receiver is allowlisted.
    function test_MaxDepositAndMaxMintOpenForAllowlistedReceiver() public view containment {
        assertEq(vault.maxDeposit(principal), type(uint256).max, "no cap beyond the gate");
        assertEq(vault.maxMint(principal), type(uint256).max, "no cap beyond the gate");
        assertEq(vault.maxDeposit(agent), 0, "gated");
        assertEq(vault.maxMint(agent), 0, "gated");
    }

    // ------------------------------------------------------------------
    // Asset and decimals
    // ------------------------------------------------------------------

    /// @dev Shares are 6-decimal here -- OZ 5.x `decimals()` is
    /// `_underlyingDecimals + _decimalsOffset()` with the offset 0 by default --
    /// unlike `mwUSDC`'s 18. The router performs no conversion either way; that is
    /// asserted in group 2, where a router test can observe it.
    function test_AssetIsSixDecimalsAndSharesMatch() public view containment {
        assertEq(vault.asset(), address(usdc), "asset is the 6dp token");
        assertEq(usdc.decimals(), 6, "asset decimals");
        assertEq(vault.decimals(), 6, "share decimals inherit via a zero offset");
    }

    /// @dev The hatched branch: assets sit idle in the vault rather than being
    /// supplied to a Morpho market. `totalAssets` is just the balance.
    function test_VaultHoldsAssetsIdle() public containment {
        vm.prank(outsider);
        vault.deposit(AMOUNT, principal);

        assertEq(vault.totalAssets(), AMOUNT, "totalAssets is the idle balance");
        assertEq(usdc.balanceOf(address(vault)), AMOUNT, "held, not forwarded anywhere");
    }

    // ------------------------------------------------------------------
    // The admin surface
    // ------------------------------------------------------------------

    function test_SetAllowlistedIsOwnerOnly() public containment {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        vault.setAllowlisted(outsider, true);
    }

    function test_SetAllowlistedEmitsAndOpensTheGate() public containment {
        assertFalse(vault.allowlisted(outsider), "not allowlisted to begin with");

        vm.expectEmit(true, true, true, true, address(vault));
        emit AllowlistedERC4626.AllowlistUpdated(outsider, true);
        vm.prank(admin);
        vault.setAllowlisted(outsider, true);

        assertTrue(vault.allowlisted(outsider), "allowlisted");

        vm.prank(outsider);
        vault.deposit(AMOUNT, outsider); // now permitted
        assertGt(vault.balanceOf(outsider), 0, "gate opened");
    }

    /// @dev De-allowlisting closes the gate again -- the operator can withdraw KYC.
    function test_DeAllowlistingClosesTheGate() public containment {
        vm.prank(admin);
        vault.setAllowlisted(principal, false);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllowlistedERC4626.NotAllowlisted.selector, principal));
        vault.deposit(AMOUNT, principal);
    }

    /// @dev Existing holders keep their position and can still exit -- de-allowlisting
    /// gates entry, it does not confiscate.
    function test_DeAllowlistedHolderCanStillRedeem() public containment {
        vm.prank(outsider);
        uint256 shares = vault.deposit(AMOUNT, principal);

        vm.prank(admin);
        vault.setAllowlisted(principal, false);

        vm.prank(principal);
        uint256 assets = vault.redeem(shares, principal, principal);
        assertEq(assets, AMOUNT, "exit is never gated");
    }
}
