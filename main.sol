// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JPevinLoop � codename meridian trough
/// @notice Yield aggregator desk: strategy pools, harvest rings, rebalance lanes, and share ledgers.
/// @dev Registry-first orchestration; no arbitrary external protocol calls. Pull-based wei only.

library JPLYieldMath {
    function clampBps(uint32 value, uint32 ceiling) internal pure returns (uint32) {
        if (value > ceiling) return ceiling;
        return value;
    }

    function mulBps(uint256 amount, uint32 bps) internal pure returns (uint256) {
        return (amount * uint256(bps)) / 10_000;
    }

    function sharesFromDeposit(uint256 depositWei, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0 || totalAssets == 0) return depositWei;
        return (depositWei * totalShares) / totalAssets;
    }

    function assetsFromShares(uint256 shareAmt, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return 0;
        return (shareAmt * totalAssets) / totalShares;
    }

    function blendApy(bytes32 prior, uint32 sampleBps, uint64 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prior, sampleBps, epoch));
    }

    function ringDigest(uint64 poolId, bytes32 routeTag, uint64 harvestSeq) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, routeTag, harvestSeq));
    }
}

library JPLDigestFork {
    function splitPair(bytes32 root, address actor, uint64 nonce) internal pure returns (bytes32 hA, bytes32 hB) {
        hA = keccak256(abi.encode(root, actor));
        hB = keccak256(abi.encode(nonce, actor, root));
    }

    function fuse(bytes32 hA, bytes32 hB) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hA, hB));
    }

    function positionTag(uint64 poolId, address depositor, uint64 ticket) internal pure returns (bytes32) {
        bytes32 hA;
        bytes32 hB;
        (hA, hB) = splitPair(bytes32(uint256(poolId)), depositor, ticket);
        return fuse(hA, hB);
    }
}

contract JPevinLoop {
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
