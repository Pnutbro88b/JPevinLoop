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
    error JPL_Frozen();
    error JPL_PoolUnknown(uint64 poolId);
    error JPL_PoolAlreadyLive(uint64 poolId);
    error JPL_PoolNotLive(uint64 poolId);
    error JPL_PoolSealed(uint64 poolId);
    error JPL_PoolRetired(uint64 poolId);
    error JPL_PoolIdOutOfRange(uint64 poolId);
    error JPL_StrategyRootZero();
    error JPL_RouteTagZero();
    error JPL_StatusInvalid(uint8 status);
    error JPL_WindowInvalid(uint64 windowSec);
    error JPL_AlreadyJoined(uint64 poolId, address depositor);
    error JPL_NotJoined(uint64 poolId, address depositor);
    error JPL_IntentZero();
    error JPL_DepositTooSmall(uint256 sent, uint256 minWei);
    error JPL_WithdrawZero();
    error JPL_SharesInsufficient(uint256 requested, uint256 held);
    error JPL_AssetsInsufficient(uint256 requested, uint256 available);
    error JPL_HarvestProofReplay(bytes32 proof);
    error JPL_HarvestCooldown(uint64 nextAllowed);
    error JPL_HarvestTipShort(uint256 sent, uint256 required);
    error JPL_RingUnknown(uint64 poolId, uint64 ringId);
    error JPL_RingRevoked(uint64 poolId, uint64 ringId);
    error JPL_LaneUnknown(uint64 poolId, uint64 laneId);
    error JPL_LaneClosed(uint64 poolId, uint64 laneId);
    error JPL_LaneNotReady(uint64 executeAfter);
    error JPL_LaneAlreadyExecuted(uint64 poolId, uint64 laneId);
    error JPL_PlanUnknown(uint256 planId);
    error JPL_PlanInactive(uint256 planId);
    error JPL_PlanNotDue(uint64 nextRunAt);
    error JPL_BatchTooLarge(uint256 n, uint256 maxN);
    error JPL_FeeBpsTooHigh(uint32 bps, uint32 cap);
    error JPL_ApySampleTooHigh(uint32 bps);
    error JPL_TipPoolShort(uint256 requested, uint256 available);
    error JPL_TransferFailed();
    error JPL_Reentrant();
    error JPL_StrayWei();
    error JPL_FallbackBlocked();
    error JPL_BadAddress();

    event JPL_Genesis(uint64 indexed genesisNonce, address indexed curator, uint256 chainId, uint64 buildTag, uint32 buildStamp);
    event JPL_CuratorHandoffStarted(address indexed curator, address indexed pending, uint64 at);
    event JPL_CuratorHandoffDone(address indexed previous, address indexed next, uint64 at);
    event JPL_FreezeSet(bool frozen, address indexed by, uint64 at);
    event JPL_PoolOpened(uint64 indexed poolId, bytes32 strategyRoot, bytes32 routeTag, uint64 openedAt, uint64 closesAt, uint8 status);
    event JPL_PoolExtended(uint64 indexed poolId, uint64 newClosesAt, uint64 at);
    event JPL_PoolSealed(uint64 indexed poolId, uint32 harvestCount, uint32 depositorCount, uint256 totalAssets);
    event JPL_PoolRetired(uint64 indexed poolId, uint64 at);
    event JPL_Deposited(uint64 indexed poolId, address indexed depositor, uint256 assetsWei, uint256 sharesMinted, uint256 poolAssets);
    event JPL_Withdrawn(uint64 indexed poolId, address indexed depositor, uint256 sharesBurned, uint256 assetsOut, uint256 poolAssets);
    event JPL_HarvestLogged(uint64 indexed poolId, uint64 indexed ringId, address indexed reporter, bytes32 yieldProof, uint32 apySampleBps, uint64 at);
    event JPL_HarvestRevoked(uint64 indexed poolId, uint64 indexed ringId, address indexed curator, uint64 at);
    event JPL_ApySnapshotted(uint64 indexed poolId, uint64 epoch, uint32 sampleBps, bytes32 blendHash, uint64 at);
    event JPL_RebalanceFiled(uint64 indexed poolId, uint64 indexed laneId, address indexed proposer, uint256 notionalWei, uint64 executeAfter);
    event JPL_RebalanceExecuted(uint64 indexed poolId, uint64 indexed laneId, address indexed executor, uint256 notionalWei, uint64 at);
    event JPL_CompoundScheduled(uint256 indexed planId, uint64 indexed poolId, address indexed owner, uint64 intervalSec, uint256 sliceWei);
    event JPL_CompoundPoked(uint256 indexed planId, uint64 poolId, address indexed owner, uint256 movedWei, uint64 nextRunAt);
    event JPL_CompoundCancelled(uint256 indexed planId, address indexed owner, uint64 at);
    event JPL_TipReceived(uint64 indexed poolId, address indexed from, uint256 amountWei, uint256 tipReserve);
    event JPL_TipsWithdrawn(address indexed curator, uint256 amountWei, uint64 at);
    event JPL_WeiPing(address indexed from, uint256 amountWei, uint64 at);

    constructor() {
        if (block.chainid == 0) revert JPL_BadAddress();

        ADDRESS_A = 0x4F68e004B62BCbe1255fa0Ec3FcCED73981DBe30;
        ADDRESS_B = 0x222E6FF0A6500F610d1Cb420566D9Ec21Cf68A56;
        ADDRESS_C = 0xF241bA28D416815e0E2053570B14Fc00b983cEf4;

        deployChainId = uint64(block.chainid);
        curator = msg.sender;
        genesisNonce = uint64(uint256(keccak256(abi.encodePacked(deployChainId, msg.sender, block.prevrandao, JPL_SEED))) >> 192);

        emit JPL_Genesis(genesisNonce, msg.sender, block.chainid, JPL_BUILD_TAG, JPL_BUILD_STAMP);
    }

    receive() external payable {
        emit JPL_WeiPing(msg.sender, msg.value, uint64(block.timestamp));
        revert JPL_StrayWei();
    }

    fallback() external payable {
        revert JPL_FallbackBlocked();
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert JPL_NotCurator(msg.sender);
        _;
    }

    modifier whenUnfrozen() {
        if (frozen) revert JPL_Frozen();
        _;
    }

    modifier nonReentrant() {
        if (_guard != 1) revert JPL_Reentrant();
        _guard = 2;
        _;
        _guard = 1;
    }

    function startCuratorHandoff(address next) external onlyCurator {
        if (next == address(0)) revert JPL_BadAddress();
        pendingCurator = next;
        emit JPL_CuratorHandoffStarted(curator, next, uint64(block.timestamp));
    }

    function acceptCuratorHandoff() external {
        if (msg.sender != pendingCurator) revert JPL_NotPendingCurator(msg.sender);
        address prev = curator;
        curator = msg.sender;
        pendingCurator = address(0);
        emit JPL_CuratorHandoffDone(prev, msg.sender, uint64(block.timestamp));
    }

    function setFrozen(bool isFrozen) external onlyCurator {
        frozen = isFrozen;
        emit JPL_FreezeSet(isFrozen, msg.sender, uint64(block.timestamp));
    }

    function openPool(uint64 poolId, bytes32 strategyRoot, bytes32 routeTag, uint64 windowSec) external onlyCurator whenUnfrozen {
        _openPool(poolId, strategyRoot, routeTag, windowSec, POOL_STATUS_LIVE);
    }

    function openPoolDormant(uint64 poolId, bytes32 strategyRoot, bytes32 routeTag, uint64 windowSec) external onlyCurator whenUnfrozen {
        _openPool(poolId, strategyRoot, routeTag, windowSec, POOL_STATUS_DORMANT);
    }

    function _openPool(uint64 poolId, bytes32 strategyRoot, bytes32 routeTag, uint64 windowSec, uint8 status) private {
        if (poolId > MAX_POOL_ID) revert JPL_PoolIdOutOfRange(poolId);
        if (strategyRoot == bytes32(0)) revert JPL_StrategyRootZero();
        if (routeTag == bytes32(0)) revert JPL_RouteTagZero();
        if (windowSec == 0 || windowSec > HARVEST_COOLDOWN_SEC * 48) revert JPL_WindowInvalid(windowSec);
        if (status != POOL_STATUS_DORMANT && status != POOL_STATUS_LIVE) revert JPL_StatusInvalid(status);

        YieldPool storage p = _pools[poolId];
        if (p.openedAt != 0) revert JPL_PoolAlreadyLive(poolId);

        p.strategyRoot = strategyRoot;
        p.routeTag = routeTag;
        p.curatorNote = msg.sender;
        p.status = status;
        p.harvestOpen = true;
        p.openedAt = uint64(block.timestamp);
        p.closesAt = p.openedAt + windowSec;

        if (poolId > lastPoolId) lastPoolId = poolId;

        emit JPL_PoolOpened(poolId, strategyRoot, routeTag, p.openedAt, p.closesAt, status);
    }

    function extendPool(uint64 poolId, uint64 extraSec) external onlyCurator whenUnfrozen {
        YieldPool storage p = _requirePool(poolId);
        if (p.sealed) revert JPL_PoolSealed(poolId);
        if (extraSec == 0 || extraSec > HARVEST_COOLDOWN_SEC * 24) revert JPL_WindowInvalid(extraSec);
        p.closesAt += extraSec;
        emit JPL_PoolExtended(poolId, p.closesAt, uint64(block.timestamp));
    }

    function activatePool(uint64 poolId) external onlyCurator whenUnfrozen {
        YieldPool storage p = _requirePool(poolId);
        if (p.sealed) revert JPL_PoolSealed(poolId);
        if (p.status == POOL_STATUS_RETIRED) revert JPL_PoolRetired(poolId);
        p.status = POOL_STATUS_LIVE;
    }

    function sealPool(uint64 poolId) external onlyCurator {
        YieldPool storage p = _requirePool(poolId);
        p.sealed = true;
        p.harvestOpen = false;
        emit JPL_PoolSealed(poolId, p.harvestCount, p.depositorCount, p.totalAssetsWei);
    }

    function retirePool(uint64 poolId) external onlyCurator {
        YieldPool storage p = _requirePool(poolId);
        p.status = POOL_STATUS_RETIRED;
        p.harvestOpen = false;
        emit JPL_PoolRetired(poolId, uint64(block.timestamp));
    }

    function deposit(uint64 poolId, bytes32 intentHash) external payable whenUnfrozen nonReentrant {
        if (msg.value < MIN_DEPOSIT_WEI) revert JPL_DepositTooSmall(msg.value, MIN_DEPOSIT_WEI);
        if (intentHash == bytes32(0)) revert JPL_IntentZero();

        YieldPool storage p = _requireLivePool(poolId);
        if (_joined[poolId][msg.sender]) revert JPL_AlreadyJoined(poolId, msg.sender);

        uint256 shares = JPLYieldMath.sharesFromDeposit(msg.value, p.totalAssetsWei, p.totalShares);
        if (shares == 0) shares = msg.value;

        DepositorSeat storage seat = _seats[poolId][msg.sender];
        seat.intentHash = intentHash;
        seat.active = true;
        seat.joinedAt = uint64(block.timestamp);
        seat.shares = shares;
        seat.creditedWei = msg.value;

        p.totalAssetsWei += msg.value;
        p.totalShares += shares;
        p.depositorCount += 1;
        globalDepositWei += msg.value;

        _joined[poolId][msg.sender] = true;
        _depositors[poolId].push(msg.sender);
        _poolsOf[msg.sender].push(poolId);

        emit JPL_Deposited(poolId, msg.sender, msg.value, shares, p.totalAssetsWei);
    }

    function depositMore(uint64 poolId) external payable whenUnfrozen nonReentrant {
        if (msg.value < MIN_DEPOSIT_WEI) revert JPL_DepositTooSmall(msg.value, MIN_DEPOSIT_WEI);
        YieldPool storage p = _requireLivePool(poolId);
        if (!_joined[poolId][msg.sender]) revert JPL_NotJoined(poolId, msg.sender);

        uint256 shares = JPLYieldMath.sharesFromDeposit(msg.value, p.totalAssetsWei, p.totalShares);
        if (shares == 0) shares = msg.value;

        DepositorSeat storage seat = _seats[poolId][msg.sender];
        seat.shares += shares;
        seat.creditedWei += msg.value;

        p.totalAssetsWei += msg.value;
        p.totalShares += shares;
        globalDepositWei += msg.value;

        emit JPL_Deposited(poolId, msg.sender, msg.value, shares, p.totalAssetsWei);
    }
