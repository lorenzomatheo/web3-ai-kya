// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";
import {MandateRouter} from "../../src/MandateRouter.sol";
import {MinimalIdentityRegistry} from "../doubles/MinimalIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Group 4's fork half: the router composed with a REAL production vault.
///
/// @dev Runs against Moonwell Flagship USDC (`mwUSDC`), a MetaMorpho vault over Morpho
/// Blue on Base mainnet, at the block pinned in `[profile.fork]`.
///
/// **No `vm.createSelectFork` here on purpose.** `foundry.toml`'s fork profile already
/// carries `eth_rpc_url = "base"` and `fork_block_number`, so they are not retyped per
/// invocation. If this file is ever reached by the default profile it will fail for
/// want of a fork, which is what `ProfileGuard` exists to catch first.
///
/// Per decision 8: our own registry double (we consume exactly one function, so
/// mocking it is zero-risk) but the **real** vault -- mocking a vault would hide the
/// rounding behaviour that is the entire reason this file exists.
///
/// This is the one part of group 4 the WISH marks trimmable if the schedule slips,
/// which is why it is isolated by path from `OwnershipIsolation.t.sol`.
contract MandateRouterForkTest is BaseTest {
    /// @dev Moonwell Flagship USDC on Base mainnet. 18-decimal shares over a
    /// 6-decimal asset -- the asymmetry decision 1 exists to avoid reconciling.
    IERC4626 internal constant MW_USDC = IERC4626(0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @dev Fallback funding source. Base USDC is the older zeppelinos FiatTokenProxy,
    /// an awkward target for `stdstore`, so if `deal` cannot write the balance slot we
    /// take real USDC from Morpho Blue, which holds ~252M at the pinned block.
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @notice Round-trip tolerance, in **asset** units (USDC, 6 decimals).
    /// @dev Measured loss at the pinned block is exactly 1 wei, consistent across
    /// 100 / 1,000 / 10,000 USDC -- the two rounding layers, each truncating. 10 wei
    /// gives an order of magnitude of headroom while staying tight enough to catch a
    /// real regression. DESIGN warns a one-wei bound would be flaky.
    /// No share-side epsilon is implied: mwUSDC shares are 18 decimals.
    uint256 internal constant ROUND_TRIP_TOLERANCE = 10;

    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant CAP = 10_000e6;
    uint256 internal constant AGENT_ID = 1;

    MinimalIdentityRegistry internal registry;
    MandateRouter internal router;

    address internal principal;
    uint256 internal principalPk;
    uint64 internal expiry;

    bytes32 internal constant TYPEHASH =
        keccak256("Mandate(uint256 agentId,address agent,address target,uint256 cap,uint64 expiry,uint256 nonce)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        (principal, principalPk) = makeAddrAndKey("principal");
        agent = makeAddr("agent");

        // Sanity-check we are actually on the fork before anything depends on it.
        assertGt(address(MW_USDC).code.length, 0, "mwUSDC has no code -- not forked?");
        assertEq(MW_USDC.asset(), address(USDC), "pinned vault's asset");
        assertEq(MW_USDC.decimals(), 18, "mwUSDC shares are 18dp, unlike the asset's 6");

        registry = new MinimalIdentityRegistry();
        router = new MandateRouter(address(registry), address(MW_USDC));
        registry.mint(principal, AGENT_ID);
        expiry = uint64(block.timestamp + 30 days);

        _fundWithRealUSDC(principal, 100_000e6);

        vm.startPrank(principal);
        USDC.approve(address(router), type(uint256).max);
        IERC20(address(MW_USDC)).approve(address(router), type(uint256).max);
        vm.stopPrank();

        containedRouter = address(router);
        containedAsset = USDC;
        containedShare = IERC20(address(MW_USDC));
    }

    /// @dev `deal` first; fall back to a live whale if the proxy's storage layout
    /// defeats it. Either way the principal ends up holding real USDC.
    function _fundWithRealUSDC(address to, uint256 amount) internal {
        try this.dealExternal(to, amount) {
            if (USDC.balanceOf(to) >= amount) return;
        } catch {}

        vm.prank(MORPHO_BLUE);
        require(USDC.transfer(to, amount), "whale transfer failed");
        assertGe(USDC.balanceOf(to), amount, "whale funding failed");
    }

    function dealExternal(address to, uint256 amount) external {
        deal(address(USDC), to, amount);
    }

    function _mandate(uint256 nonce) internal view returns (MandateRouter.Mandate memory) {
        return MandateRouter.Mandate({
            agentId: AGENT_ID, agent: agent, target: address(MW_USDC), cap: CAP, expiry: expiry, nonce: nonce
        });
    }

    function _sign(MandateRouter.Mandate memory m, uint256 pk) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("MandateRouter")),
                keccak256(bytes("1")),
                block.chainid,
                address(router)
            )
        );
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, m.agentId, m.agent, m.target, m.cap, m.expiry, m.nonce));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------

    /// @dev Shares are credited to the principal, never to the router.
    function test_RouterDepositsIntoRealMwUSDC() public containment {
        MandateRouter.Mandate memory m = _mandate(1);
        uint256 expected = MW_USDC.previewDeposit(DEPOSIT);

        vm.prank(agent);
        uint256 shares = router.depositFor(m, _sign(m, principalPk), DEPOSIT);

        assertEq(shares, expected, "shares match the vault's own preview");
        assertEq(MW_USDC.balanceOf(principal), shares, "credited to the principal");
        assertEq(MW_USDC.balanceOf(address(router)), 0, "router holds no shares");
        assertEq(USDC.balanceOf(address(router)), 0, "router holds no assets");
    }

    /// @dev The rounding behaviour that justifies testing against a real vault
    /// (decision 8). Tolerance is asserted AND the actual gap is reported, so a
    /// regression that widens it becomes visible rather than being absorbed.
    function test_RoundTripReturnsAssetsWithinTolerance() public containment {
        MandateRouter.Mandate memory m = _mandate(2);
        uint256 before = USDC.balanceOf(principal);

        vm.prank(agent);
        uint256 shares = router.depositFor(m, _sign(m, principalPk), DEPOSIT);

        vm.prank(agent);
        uint256 assets = router.redeemFor(m, _sign(m, principalPk), shares);

        uint256 gap = DEPOSIT - assets;
        emit log_named_uint("round-trip loss (USDC wei)", gap);

        assertLe(gap, ROUND_TRIP_TOLERANCE, "round trip within the stated tolerance");
        assertEq(USDC.balanceOf(principal), before - gap, "principal made whole to within the gap");
        assertEq(MW_USDC.balanceOf(address(router)), 0, "router left holding nothing");
        assertEq(USDC.balanceOf(address(router)), 0, "router left holding nothing");
    }

    /// @dev The monotonic counter survives contact with a production vault: a full
    /// round trip permanently consumes budget (risk 4).
    function test_RoundTripStillConsumesBudgetOnRealVault() public containment {
        MandateRouter.Mandate memory m = _mandate(3);

        vm.prank(agent);
        uint256 shares = router.depositFor(m, _sign(m, principalPk), DEPOSIT);
        vm.prank(agent);
        router.redeemFor(m, _sign(m, principalPk), shares);

        assertEq(router.spent(router.mandateKey(_digestOf(m), principal)), DEPOSIT, "counter never decreases");
    }

    function _digestOf(MandateRouter.Mandate memory m) internal view returns (bytes32) {
        return router.mandateDigest(m);
    }
}
