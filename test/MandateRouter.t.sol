// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./BaseTest.sol";
import {MandateRouter} from "../src/MandateRouter.sol";
import {MinimalIdentityRegistry, ZeroOwnerRegistry} from "./doubles/MinimalIdentityRegistry.sol";
import {MockUSDC} from "./doubles/MockUSDC.sol";
import {MockVault} from "./doubles/MockVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Group 2's suite: DESIGN's Authorization, Revocation, Events and "the cap
/// actually binds" criteria. State isolation across ownership belongs to group 4's
/// `OwnershipIsolation.t.sol`, not here.
///
/// @dev Every test function carries `containment` -- inheriting `BaseTest` is not
/// applying it. The agent is never funded, which is what makes the invariant hold.
contract MandateRouterTest is BaseTest {
    MinimalIdentityRegistry internal registry;
    MockUSDC internal usdc;
    MockVault internal vault;
    MandateRouter internal router;

    address internal principal;
    uint256 internal principalPk;
    address internal attacker;
    address internal newOwner;
    uint256 internal newOwnerPk;

    uint256 internal constant AGENT_ID = 42;
    uint256 internal constant CAP = 1_000e6;
    uint256 internal constant ALLOWANCE = 10_000e6;

    uint64 internal expiry;

    /// @dev Computed here from the literal strings rather than read off the contract:
    /// the events criterion requires the digest be asserted against an independently
    /// computed value, "not against however the contract happens to compute it".
    bytes32 internal constant TYPEHASH =
        keccak256("Mandate(uint256 agentId,address agent,address target,uint256 cap,uint64 expiry,uint256 nonce)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        (principal, principalPk) = makeAddrAndKey("principal");
        (newOwner, newOwnerPk) = makeAddrAndKey("newOwner");
        attacker = makeAddr("attacker");
        agent = makeAddr("agent");

        registry = new MinimalIdentityRegistry();
        usdc = new MockUSDC();
        vault = new MockVault(IERC20(address(usdc)));
        router = new MandateRouter(address(registry), address(vault));

        registry.mint(principal, AGENT_ID);
        expiry = uint64(block.timestamp + 30 days);

        usdc.mint(principal, 1_000_000e6);
        vm.startPrank(principal);
        usdc.approve(address(router), ALLOWANCE);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        containedRouter = address(router);
        containedAsset = IERC20(address(usdc));
        containedShare = IERC20(address(vault));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _mandate() internal view returns (MandateRouter.Mandate memory) {
        return MandateRouter.Mandate({
            agentId: AGENT_ID, agent: agent, target: address(vault), cap: CAP, expiry: expiry, nonce: 1
        });
    }

    function _digestFor(MandateRouter.Mandate memory m, address verifying) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("MandateRouter")), keccak256(bytes("1")), block.chainid, verifying
            )
        );
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, m.agentId, m.agent, m.target, m.cap, m.expiry, m.nonce));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _digest(MandateRouter.Mandate memory m) internal view returns (bytes32) {
        return _digestFor(m, address(router));
    }

    function _sign(MandateRouter.Mandate memory m, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(m));
        return abi.encodePacked(r, s, v);
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        MandateRouter.Mandate memory m = _mandate();
        vm.prank(agent);
        shares = router.depositFor(m, _sign(m, principalPk), assets);
    }

    // ------------------------------------------------------------------
    // Authorization
    // ------------------------------------------------------------------

    function test_DepositSucceedsAndCreditsPrincipal() public containment {
        uint256 expected = vault.previewDeposit(500e6);
        uint256 shares = _deposit(500e6);

        assertEq(shares, expected, "shares returned");
        assertEq(vault.balanceOf(principal), shares, "shares credited to the principal");
        assertEq(vault.balanceOf(address(router)), 0, "router holds no shares");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no assets");
    }

    function test_InvalidSignatureIsOurErrorNotOZs() public containment {
        MandateRouter.Mandate memory m = _mandate();
        bytes memory garbage = new bytes(65);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.InvalidSignature.selector);
        router.depositFor(m, garbage, 100e6);
    }

    /// @dev A wrong-length signature is the case where `ECDSA.recover` would revert
    /// `ECDSAInvalidSignatureLength`. `tryRecover` turns it into ours.
    function test_MalformedSignatureLengthIsOurError() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(agent);
        vm.expectRevert(MandateRouter.InvalidSignature.selector);
        router.depositFor(m, hex"dead", 100e6);
    }

    function test_MalleableHighSSignatureRejected() public containment {
        MandateRouter.Mandate memory m = _mandate();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(principalPk, _digest(m));

        // Flip to the upper half of the curve order. ecrecover would still recover
        // the same signer; tryRecover returns RecoverError.InvalidSignatureS.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(agent);
        vm.expectRevert(MandateRouter.InvalidSignature.selector);
        router.depositFor(m, abi.encodePacked(r, highS, flippedV), 100e6);
    }

    /// @dev The non-conformant registry returns address(0) rather than reverting. If
    /// step 4 did not reject a zero owner, step 5 would then pass against garbage.
    function test_ZeroOwnerRegistryYieldsAgentNotRegistered() public containment {
        ZeroOwnerRegistry zeroRegistry = new ZeroOwnerRegistry();
        MandateRouter zeroRouter = new MandateRouter(address(zeroRegistry), address(vault));

        MandateRouter.Mandate memory m = _mandate();
        m.target = address(vault);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.AgentNotRegistered.selector);
        zeroRouter.depositFor(m, new bytes(65), 100e6);
    }

    function test_UnmintedAgentIdIsOurErrorOnDeposit() public containment {
        MandateRouter.Mandate memory m = _mandate();
        m.agentId = 999; // never minted; ownerOf reverts ERC721NonexistentToken

        vm.prank(agent);
        vm.expectRevert(MandateRouter.AgentNotRegistered.selector);
        router.depositFor(m, _sign(m, principalPk), 100e6);
    }

    /// @dev The redeem-sited half. Only this proves `redeemFor` calls the shared
    /// verifier rather than carrying its own copy.
    function test_UnmintedAgentIdIsOurErrorOnRedeem() public containment {
        MandateRouter.Mandate memory m = _mandate();
        m.agentId = 999;

        vm.prank(agent);
        vm.expectRevert(MandateRouter.AgentNotRegistered.selector);
        router.redeemFor(m, _sign(m, principalPk), 1);
    }

    function test_NotAgentOnDeposit() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(attacker);
        vm.expectRevert(MandateRouter.NotAgent.selector);
        router.depositFor(m, _sign(m, principalPk), 100e6);
    }

    function test_NotAgentOnRedeem() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(attacker);
        vm.expectRevert(MandateRouter.NotAgent.selector);
        router.redeemFor(m, _sign(m, principalPk), 1);
    }

    function test_WrongVaultOnDeposit() public containment {
        MandateRouter.Mandate memory m = _mandate();
        m.target = address(0xBEEF);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.WrongVault.selector);
        router.depositFor(m, _sign(m, principalPk), 100e6);
    }

    function test_WrongVaultOnRedeem() public containment {
        MandateRouter.Mandate memory m = _mandate();
        m.target = address(0xBEEF);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.WrongVault.selector);
        router.redeemFor(m, _sign(m, principalPk), 1);
    }

    function test_MandateExpiredOnDeposit() public containment {
        MandateRouter.Mandate memory m = _mandate();
        vm.warp(uint256(expiry) + 1);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateExpired.selector);
        router.depositFor(m, _sign(m, principalPk), 100e6);
    }

    /// @dev Decision 14: expiry ends the agent's authority in BOTH directions. The
    /// principal is never locked out, because they hold the shares and can redeem
    /// from the vault directly.
    function test_MandateExpiredOnRedeem() public containment {
        _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();
        vm.warp(uint256(expiry) + 1);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateExpired.selector);
        router.redeemFor(m, _sign(m, principalPk), 1);
    }

    function test_ExpiryIsInclusive() public containment {
        MandateRouter.Mandate memory m = _mandate();
        vm.warp(uint256(expiry)); // exactly at expiry: still valid

        vm.prank(agent);
        router.depositFor(m, _sign(m, principalPk), 100e6);
        assertEq(vault.balanceOf(principal), vault.previewDeposit(100e6), "accepted at expiry");
    }

    /// @dev The only test proving that deriving the principal from the registry
    /// (decision 4) is load-bearing rather than decorative.
    function test_AgentIdTransferInvalidatesExistingMandate() public containment {
        MandateRouter.Mandate memory m = _mandate();
        bytes memory sig = _sign(m, principalPk);

        vm.prank(principal);
        registry.transferFrom(principal, newOwner, AGENT_ID);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.InvalidSignature.selector);
        router.depositFor(m, sig, 100e6);
    }

    // ------------------------------------------------------------------
    // Revocation
    // ------------------------------------------------------------------

    function test_PrincipalRevokeBlocksDeposit() public containment {
        MandateRouter.Mandate memory m = _mandate();
        bytes memory sig = _sign(m, principalPk);

        vm.prank(principal);
        router.revoke(m);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateRevoked.selector);
        router.depositFor(m, sig, 100e6);
    }

    /// @dev Decision 3 claims revocation kills both directions at once. Only the
    /// redeem-sited half proves it.
    function test_PrincipalRevokeBlocksRedeem() public containment {
        _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();
        bytes memory sig = _sign(m, principalPk);

        vm.prank(principal);
        router.revoke(m);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateRevoked.selector);
        router.redeemFor(m, sig, 1);
    }

    /// @dev The DoS decision 12 must not permit. Tests the property, not a gate,
    /// since there is no gate.
    function test_ThirdPartyRevokeDoesNotBlockTheOwner() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(attacker);
        router.revoke(m);

        uint256 shares = _deposit(500e6);
        assertGt(shares, 0, "owner's deposit still succeeds");
    }

    function test_RevokeHasNoOwnershipGate() public containment {
        MandateRouter.Mandate memory m = _mandate();

        // A complete stranger, holding no agentId and having signed nothing.
        vm.prank(attacker);
        router.revoke(m); // does not revert

        bytes32 key = router.mandateKey(_digest(m), attacker);
        assertTrue(router.revoked(key), "written at msg.sender");
        assertFalse(router.revoked(router.mandateKey(_digest(m), principal)), "not written at the principal");
    }

    /// @dev The case an ownership-gated `revoke` cannot express at all, and the whole
    /// reason decision 12 writes at `msg.sender`.
    function test_SignerRevokesAfterTransferAndMandateStaysDead() public containment {
        MandateRouter.Mandate memory m = _mandate();
        bytes memory sig = _sign(m, principalPk);

        vm.prank(principal);
        registry.transferFrom(principal, newOwner, AGENT_ID);

        // The signer can still kill their own signature -- no registry lookup.
        vm.prank(principal);
        router.revoke(m);

        // The agentId comes home.
        vm.prank(newOwner);
        registry.transferFrom(newOwner, principal, AGENT_ID);

        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateRevoked.selector);
        router.depositFor(m, sig, 100e6);
    }

    /// @dev The consumption rule's reason for existing. The attacker holds the
    /// victim's real mandate in full, so the emitted digest is IDENTICAL to the live
    /// one -- any variant that changes the digest passes for the wrong reason and
    /// isolates nothing.
    function test_AttackerRevokeEmitsRealDigestYetOwnerDepositSucceeds() public containment {
        MandateRouter.Mandate memory m = _mandate();
        bytes32 digest = _digest(m);

        vm.expectEmit(true, true, true, true, address(router));
        emit MandateRouter.Revoked(digest, attacker, AGENT_ID);
        vm.prank(attacker);
        router.revoke(m);

        uint256 shares = _deposit(500e6);
        assertGt(shares, 0, "the key binding, not a gate, is what isolates this");
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    function test_DepositedEventCarriesDigestPrincipalAndAgentId() public containment {
        MandateRouter.Mandate memory m = _mandate();
        uint256 assets = 500e6;
        uint256 expectedShares = vault.previewDeposit(assets);

        vm.expectEmit(true, true, true, true, address(router));
        emit MandateRouter.Deposited(_digest(m), principal, AGENT_ID, agent, assets, expectedShares, assets);

        vm.prank(agent);
        router.depositFor(m, _sign(m, principalPk), assets);
    }

    function test_RedeemedEventCarriesDigestPrincipalAndAgentId() public containment {
        uint256 shares = _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.expectEmit(true, true, true, true, address(router));
        emit MandateRouter.Redeemed(_digest(m), principal, AGENT_ID, agent, shares, expectedAssets);

        vm.prank(agent);
        router.redeemFor(m, _sign(m, principalPk), shares);
    }

    /// @dev Asserts the CALLER, not a derived principal, so no future change can
    /// reintroduce a registry lookup into `revoke` to satisfy this test.
    function test_RevokedEventCarriesCallerNotDerivedPrincipal() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.expectEmit(true, true, true, true, address(router));
        emit MandateRouter.Revoked(_digest(m), attacker, AGENT_ID);

        vm.prank(attacker);
        router.revoke(m);
    }

    /// @dev `agentId` is echoed from calldata unvalidated -- nothing checks it exists
    /// or relates to the caller. It is an indexing hint, never attribution.
    function test_RevokedEchoesUnvalidatedAgentId() public containment {
        MandateRouter.Mandate memory m = _mandate();
        m.agentId = 123456; // never minted

        vm.expectEmit(true, true, true, true, address(router));
        emit MandateRouter.Revoked(_digest(m), attacker, 123456);

        vm.prank(attacker);
        router.revoke(m);
    }

    // ------------------------------------------------------------------
    // The cap actually binds
    // ------------------------------------------------------------------

    function test_ExceedsMandateReportsRemainingAndAttempted() public containment {
        _deposit(500e6);

        MandateRouter.Mandate memory m = _mandate();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateRouter.ExceedsMandate.selector, 500e6, 600e6));
        router.depositFor(m, _sign(m, principalPk), 600e6);
    }

    /// @dev A single deposit exceeding the whole cap reverts the same way as one
    /// exceeding only the remainder.
    function test_DepositExceedingWholeCapRevertsIdentically() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateRouter.ExceedsMandate.selector, CAP, 5_000e6));
        router.depositFor(m, _sign(m, principalPk), 5_000e6);
    }

    /// @dev `cap - Deposited.spentTotal` must reproduce the `remaining` that
    /// `ExceedsMandate` reports.
    function test_SpentTotalReproducesExceedsMandateRemaining() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.recordLogs();
        _deposit(400e6);
        // Deposited's last unindexed word is spentTotal.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 spentTotal;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MandateRouter.Deposited.selector) {
                (,,, spentTotal) = abi.decode(logs[i].data, (address, uint256, uint256, uint256));
            }
        }
        assertEq(spentTotal, 400e6, "spentTotal is the post-increment value");

        uint256 remaining = CAP - spentTotal;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateRouter.ExceedsMandate.selector, remaining, 700e6));
        router.depositFor(m, _sign(m, principalPk), 700e6);
    }

    /// @dev Falsifies risk 3: the mandate binds tighter than the ERC-20 allowance.
    function test_LoopUntilRejectionNeverPullsMoreThanCap() public containment {
        assertEq(usdc.allowance(principal, address(router)), ALLOWANCE, "10,000 allowance against a 1,000 cap");

        uint256 startBalance = usdc.balanceOf(principal);
        MandateRouter.Mandate memory m = _mandate();
        bytes memory sig = _sign(m, principalPk);

        for (uint256 i = 0; i < 20; i++) {
            vm.prank(agent);
            try router.depositFor(m, sig, 300e6) {}
            catch {
                break;
            }
        }

        uint256 pulled = startBalance - usdc.balanceOf(principal);
        assertLe(pulled, CAP, "never pulls more than the cap");
        assertEq(router.spent(router.mandateKey(_digest(m), principal)), pulled, "spent tracks what was pulled");
        assertLt(pulled, ALLOWANCE, "and far less than the allowance");
    }

    // ------------------------------------------------------------------
    // Direct assertions the WISH requires be asserted, not inferred
    // ------------------------------------------------------------------

    function test_TransferFromPullsFromPrincipalNeverAgent() public containment {
        MandateRouter.Mandate memory m = _mandate();

        vm.expectCall(address(usdc), abi.encodeCall(IERC20.transferFrom, (principal, address(router), 500e6)));

        vm.prank(agent);
        router.depositFor(m, _sign(m, principalPk), 500e6);
    }

    function test_RedeemPassesOnlyTheDerivedPrincipalAsOwner() public containment {
        uint256 shares = _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();

        vm.expectCall(address(vault), abi.encodeCall(IERC4626.redeem, (shares, principal, principal)));

        vm.prank(agent);
        router.redeemFor(m, _sign(m, principalPk), shares);
    }

    function test_RedeemDoesNotChangeSpent() public containment {
        uint256 shares = _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();
        bytes32 key = router.mandateKey(_digest(m), principal);

        assertEq(router.spent(key), 500e6, "spent after deposit");

        vm.prank(agent);
        router.redeemFor(m, _sign(m, principalPk), shares);

        assertEq(router.spent(key), 500e6, "the counter never decreases");
    }

    /// @dev `cap` and `assets` are 6-decimal asset units end to end, and `shares` is
    /// passed to the vault untouched. Only a router test can observe this.
    function test_RouterPerformsNoDecimalsConversion() public containment {
        assertEq(usdc.decimals(), 6, "asset is 6dp");
        assertEq(vault.decimals(), 6, "MockVault shares inherit 6dp via a zero offset");

        uint256 shares = _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();

        assertEq(router.spent(router.mandateKey(_digest(m), principal)), 500e6, "spent is in 6dp asset units");
        assertEq(shares, vault.previewDeposit(500e6), "shares passed through untouched");
    }

    function test_RouterAndAgentHoldNothingAfterRoundTrip() public containment {
        uint256 shares = _deposit(500e6);
        MandateRouter.Mandate memory m = _mandate();

        vm.prank(agent);
        router.redeemFor(m, _sign(m, principalPk), shares);

        assertEq(usdc.balanceOf(address(router)), 0, "router holds no asset");
        assertEq(vault.balanceOf(address(router)), 0, "router holds no shares");
        assertEq(usdc.balanceOf(agent), 0, "agent holds no asset");
        assertEq(vault.balanceOf(agent), 0, "agent holds no shares");
    }

    function test_ConstructorRejectsCodelessAddresses() public containment {
        vm.expectRevert("MandateRouter: registry has no code");
        new MandateRouter(address(0xDEAD), address(vault));

        vm.expectRevert("MandateRouter: vault has no code");
        new MandateRouter(address(registry), address(0xDEAD));
    }
}
