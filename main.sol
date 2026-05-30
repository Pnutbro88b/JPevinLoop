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
    address public immutable ADDRESS_C;

    bytes32 private constant JPL_DOMAIN_SALT = keccak256("JPevinLoop.meridian_trough");
    bytes16 private constant JPL_SEED = 0x7c3e91b4d8f02a651e9c4b7d3a1f8065;
    uint64 public constant JPL_BUILD_TAG = 0x9A4E2C71B8D03F56;
    uint32 public constant JPL_BUILD_STAMP = 1847293156;

    uint64 public constant MAX_POOL_ID = 847_291;
    uint32 public constant MAX_STRATEGY_BPS = 9_847;
    uint32 public constant MAX_PERF_FEE_BPS = 2_500;
    uint32 public constant MAX_MGMT_FEE_BPS = 500;
    uint32 public constant MAX_ROUTE_BYTES = 384;
    uint32 public constant MAX_BATCH = 56;
    uint32 public constant MAX_SNAPSHOT_RING = 128;
    uint32 public constant HARVEST_COOLDOWN_SEC = 3_601;
    uint256 public constant MIN_DEPOSIT_WEI = 512;
    uint256 public constant MIN_HARVEST_TIP_WEI = 271;
    uint8 public constant POOL_STATUS_DORMANT = 0;
    uint8 public constant POOL_STATUS_LIVE = 1;
    uint8 public constant POOL_STATUS_RETIRED = 2;

    struct YieldPool {
        bytes32 strategyRoot;
        bytes32 routeTag;
        address curatorNote;
        uint8 status;
        bool harvestOpen;
        bool sealed;
        uint64 openedAt;
        uint64 closesAt;
        uint32 harvestCount;
        uint32 depositorCount;
        uint256 totalAssetsWei;
        uint256 totalShares;
        uint256 tipReserve;
    }

    struct DepositorSeat {
        bytes32 intentHash;
        bytes32 lastHarvestTag;
        bool active;
        uint64 joinedAt;
        uint256 shares;
        uint256 creditedWei;
        uint64 lastHarvestAt;
    }

    struct HarvestRing {
        bytes32 yieldProof;
        bytes32 apyBlend;
        address reporter;
        uint64 poolId;
        uint64 recordedAt;
        uint32 apySampleBps;
        bool revoked;
    }

    struct RebalanceLane {
        bytes32 targetTag;
        bytes32 sourceTag;
        address proposer;
        uint64 poolId;
        uint64 filedAt;
        uint64 executeAfter;
        uint256 notionalWei;
        bool open;
        bool executed;
    }

    struct ApySnapshot {
        bytes32 blendHash;
        uint32 sampleBps;
        uint64 capturedAt;
        uint64 epoch;
    }

    struct CompoundPlan {
        bytes32 scheduleTag;
        address owner;
        uint64 poolId;
        uint64 intervalSec;
        uint64 nextRunAt;
        uint256 sliceWei;
        bool active;
    }

    address public curator;
    address public pendingCurator;
    bool public frozen;

    uint64 public genesisNonce;
    uint64 public deployChainId;
    uint64 public lastPoolId;
    uint256 public globalHarvestCount;
    uint256 public globalDepositWei;
    uint256 public rebalanceSeq;
    uint256 public compoundSeq;
    uint256 public harvestLeafSeq;

    mapping(uint64 => YieldPool) private _pools;
    mapping(uint64 => mapping(address => DepositorSeat)) private _seats;
    mapping(uint64 => mapping(address => bool)) private _joined;
    mapping(uint64 => mapping(uint64 => HarvestRing)) private _rings;
    mapping(uint64 => mapping(uint64 => RebalanceLane)) private _lanes;
    mapping(uint64 => ApySnapshot[]) private _apyHistory;
    mapping(uint256 => CompoundPlan) private _plans;
    mapping(bytes32 => bool) private _usedHarvestProof;
    mapping(address => uint64[]) private _poolsOf;
    mapping(uint64 => address[]) private _depositors;

    uint256 private _guard = 1;

    error JPL_NotCurator(address caller);
    error JPL_NotPendingCurator(address caller);
