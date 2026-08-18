// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Test-only stand-in for the ERC-8004 AgentIdentity registry. The router
/// only ever reads `ownerOf`, which is why this can be minimal.
/// @dev DESIGN decision 7 makes the registry a constructor parameter rather than a
/// constant, so this contract is also the deployable fallback if the live registry
/// ever stops cooperating.
contract MinimalIdentityRegistry is ERC721 {
    constructor() ERC721("Minimal Identity", "MID") {}

    /// @dev Unpermissioned on purpose. Minting is not part of ERC-721 and five
    /// downstream criteria need an `agentId` to exist and then transfer.
    function mint(address to, uint256 agentId) external {
        _mint(to, agentId);
    }
}

/// @notice Deliberately non-conformant: returns `address(0)` for an unknown id
/// instead of reverting `ERC721NonexistentToken`.
/// @dev Exists to prove the router turns a zero owner into `AgentNotRegistered`
/// rather than proceeding to verify a signature against a zero principal. It is
/// intentionally NOT an ERC721 -- inheriting one would make `ownerOf` revert,
/// which is the behaviour this double exists to avoid.
contract ZeroOwnerRegistry {
    mapping(uint256 agentId => address owner) private _owners;

    function mint(address to, uint256 agentId) external {
        _owners[agentId] = to;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _owners[agentId];
    }
}
