// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MandateRouter} from "../../src/MandateRouter.sol";

/// @notice A hostile "vault" that calls straight back into the router that is
/// mid-call on it. Exists to make `nonReentrant` falsifiable.
///
/// @dev DESIGN risk 6 calls the guard "load-bearing here, not belt-and-braces -- do
/// not drop it", yet before this double both `nonReentrant` modifiers could be
/// deleted with the suite staying 100% green. That is the same
/// asserted-but-unproven shape the wish was written to eliminate.
///
/// Deliberately NOT an ERC-4626 and not an ERC-20. The router only ever calls
/// `asset()` at construction, then `deposit`/`redeem`, so those three are the
/// entire surface it needs. `asset()` in particular is required to satisfy
/// `src/MandateRouter.sol`'s constructor, which reads it before any test body runs.
///
/// The re-entry is not required to be well-formed: `ReentrancyGuard` checks its slot
/// *before* the modified function's body, so the inner call reverts at the guard
/// whether or not its mandate would have verified.
contract ReenteringVault {
    /// @dev A public immutable generates the `asset()` getter the router's
    /// constructor calls.
    address public immutable asset;

    MandateRouter public router;

    MandateRouter.Mandate private mandate;
    bytes private signature;

    constructor(address asset_) {
        asset = asset_;
    }

    /// @dev Two-phase because the router's constructor reads `asset()` off this
    /// contract, so the vault must exist before the router it re-enters.
    function arm(MandateRouter router_, MandateRouter.Mandate calldata m, bytes calldata sig) external {
        router = router_;
        mandate = m;
        signature = sig;
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        return router.depositFor(mandate, signature, assets);
    }

    function redeem(uint256 shares, address, address) external returns (uint256) {
        return router.redeemFor(mandate, signature, shares);
    }
}
