// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AllowlistedERC4626} from "../src/AllowlistedERC4626.sol";
import {MandateRouter} from "../src/MandateRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev The ERC-8004 registry's write surface. Only `register()` is used here;
/// `ownerOf` comes from `IERC721`. Declared locally because the registry is an
/// external deployment we consume, not a contract this repository builds.
interface IAgentIdentity {
    function register() external returns (uint256);
}

/// @notice Deploys the vault and the router, allowlists the principal, and registers
/// the agent identity **to the principal**.
///
/// @dev Run with the deployer key; the principal's key is read from the environment
/// and broadcast separately for exactly one call. See `registerAgent` below -- that
/// split is the whole reason this script is not four lines.
///
/// The vault is PRODUCED here, not supplied: the router's `target` scoping is only
/// meaningful if the vault address it is bound to came from this same run.
contract Deploy is Script {
    /// @dev Cap and allowance figures live in the demo, not here. This script's only
    /// numeric commitment is the agent id it registers.
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address registry = vm.envAddress("REGISTRY_ADDRESS");

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 principalPk = vm.envUint("PRINCIPAL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address principal = vm.addr(principalPk);
        address agent = vm.addr(vm.envUint("AGENT_PRIVATE_KEY"));

        // Checked before anything is broadcast. `MandateRouter`'s constructor checks
        // it again, but that revert would land mid-run with the vault already
        // deployed and paid for; this one aborts the simulation with nothing spent.
        require(registry.code.length != 0, "Deploy: registry has no code");
        require(usdc.code.length != 0, "Deploy: usdc has no code");

        vm.startBroadcast(deployerPk);

        AllowlistedERC4626 vault = new AllowlistedERC4626(IERC20(usdc), "KYC USDC Vault", "kUSDC", deployer);
        MandateRouter router = new MandateRouter(registry, address(vault));

        // The principal is allowlisted; the AGENT DELIBERATELY IS NOT. Demo
        // transaction 11 is `vault.deposit(assets, agent)` reverting
        // `NotAllowlisted(agent)`, and allowlisting the agent here -- an easy
        // "completeness" edit -- would make that transaction succeed and silently
        // delete the demo's closing case.
        vault.setAllowlisted(principal, true);

        vm.stopBroadcast();

        uint256 agentId = registerAgent(registry, principalPk);

        // The assertion this entire script exists to make true. Without it, nine of
        // the eleven demo transactions cannot even be constructed, and the failure
        // presents as `InvalidSignature` -- indistinguishable from a bad key.
        require(IERC721(registry).ownerOf(agentId) == principal, "Deploy: agentId is not owned by the principal");

        console2.log("VAULT_ADDRESS", address(vault));
        console2.log("ROUTER_ADDRESS", address(router));
        console2.log("AGENT_ID", agentId);
        console2.log("PRINCIPAL", principal);
        console2.log("AGENT", agent);
    }

    /// @dev Broadcast under the PRINCIPAL's key, not the deployer's, and that is the
    /// single most important line in this file.
    ///
    /// ERC-8004 `register()` mints to `msg.sender`. The WISH's own validation invokes
    /// this script with `--private-key "$DEPLOYER_PRIVATE_KEY"`, so inheriting the
    /// CLI key would make the DEPLOYER the agent owner. `_verify` derives the
    /// principal from `registry.ownerOf(m.agentId)` and requires the recovered signer
    /// to equal it, so every principal-signed mandate would then die at step 5 with
    /// `InvalidSignature` -- the hardest failure in the design to debug, because it is
    /// exactly what a malformed signature, a typehash typo and a domain mismatch all
    /// produce too.
    ///
    /// Registering from the deployer and `transferFrom`-ing to the principal in the
    /// same run is equally acceptable and was the other option on the table. This one
    /// is preferred because it never puts the token at the wrong address at all,
    /// rather than putting it there and moving it.
    function registerAgent(address registry, uint256 principalPk) internal returns (uint256 agentId) {
        vm.startBroadcast(principalPk);
        agentId = IAgentIdentity(registry).register();
        vm.stopBroadcast();
    }
}
