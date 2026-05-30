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

    function withdraw(uint64 poolId, uint256 shareAmt) external whenUnfrozen nonReentrant {
        if (shareAmt == 0) revert JPL_WithdrawZero();
        YieldPool storage p = _requirePool(poolId);
        DepositorSeat storage seat = _seats[poolId][msg.sender];
        if (!seat.active) revert JPL_NotJoined(poolId, msg.sender);
        if (seat.shares < shareAmt) revert JPL_SharesInsufficient(shareAmt, seat.shares);

        uint256 assetsOut = JPLYieldMath.assetsFromShares(shareAmt, p.totalAssetsWei, p.totalShares);
        if (assetsOut > p.totalAssetsWei) revert JPL_AssetsInsufficient(assetsOut, p.totalAssetsWei);

        seat.shares -= shareAmt;
        p.totalShares -= shareAmt;
        p.totalAssetsWei -= assetsOut;

        if (seat.shares == 0) {
            seat.active = false;
            p.depositorCount -= 1;
        }

        _sendWei(msg.sender, assetsOut);
        emit JPL_Withdrawn(poolId, msg.sender, shareAmt, assetsOut, p.totalAssetsWei);
    }

    function logHarvest(uint64 poolId, bytes32 yieldProof, uint32 apySampleBps) external payable whenUnfrozen {
        if (yieldProof == bytes32(0)) revert JPL_StrategyRootZero();
        if (apySampleBps > MAX_STRATEGY_BPS) revert JPL_ApySampleTooHigh(apySampleBps);
        if (msg.value < MIN_HARVEST_TIP_WEI) revert JPL_HarvestTipShort(msg.value, MIN_HARVEST_TIP_WEI);
        if (_usedHarvestProof[yieldProof]) revert JPL_HarvestProofReplay(yieldProof);

        YieldPool storage p = _requireLivePool(poolId);
        if (!p.harvestOpen) revert JPL_PoolSealed(poolId);

        uint64 ringId = p.harvestCount;
        HarvestRing storage ring = _rings[poolId][ringId];
        ring.yieldProof = yieldProof;
        ring.reporter = msg.sender;
        ring.poolId = poolId;
        ring.recordedAt = uint64(block.timestamp);
        ring.apySampleBps = apySampleBps;
        ring.apyBlend = JPLYieldMath.blendApy(p.strategyRoot, apySampleBps, ringId);

        p.harvestCount += 1;
        p.tipReserve += msg.value;
        globalHarvestCount += 1;
        harvestLeafSeq += 1;
        _usedHarvestProof[yieldProof] = true;

        _pushApySnapshot(poolId, apySampleBps, ring.apyBlend, ringId);

        emit JPL_HarvestLogged(poolId, ringId, msg.sender, yieldProof, apySampleBps, ring.recordedAt);
        emit JPL_TipReceived(poolId, msg.sender, msg.value, p.tipReserve);
    }

    function revokeHarvest(uint64 poolId, uint64 ringId) external onlyCurator {
        HarvestRing storage ring = _rings[poolId][ringId];
        if (ring.recordedAt == 0) revert JPL_RingUnknown(poolId, ringId);
        if (ring.revoked) revert JPL_RingRevoked(poolId, ringId);
        ring.revoked = true;
        emit JPL_HarvestRevoked(poolId, ringId, msg.sender, uint64(block.timestamp));
    }

    function fileRebalance(
        uint64 poolId,
        bytes32 targetTag,
        bytes32 sourceTag,
        uint256 notionalWei,
        uint64 delaySec
    ) external whenUnfrozen {
        if (targetTag == bytes32(0) || sourceTag == bytes32(0)) revert JPL_RouteTagZero();
        _requireLivePool(poolId);

        uint64 laneId = uint64(rebalanceSeq);
        RebalanceLane storage lane = _lanes[poolId][laneId];
        lane.targetTag = targetTag;
        lane.sourceTag = sourceTag;
        lane.proposer = msg.sender;
        lane.poolId = poolId;
        lane.filedAt = uint64(block.timestamp);
        lane.executeAfter = lane.filedAt + delaySec;
        lane.notionalWei = notionalWei;
        lane.open = true;

        rebalanceSeq += 1;
        emit JPL_RebalanceFiled(poolId, laneId, msg.sender, notionalWei, lane.executeAfter);
    }

    function executeRebalance(uint64 poolId, uint64 laneId) external whenUnfrozen {
        RebalanceLane storage lane = _lanes[poolId][laneId];
        if (!lane.open) revert JPL_LaneUnknown(poolId, laneId);
        if (lane.executed) revert JPL_LaneAlreadyExecuted(poolId, laneId);
        if (block.timestamp < lane.executeAfter) revert JPL_LaneNotReady(lane.executeAfter);

        lane.executed = true;
        lane.open = false;
        emit JPL_RebalanceExecuted(poolId, laneId, msg.sender, lane.notionalWei, uint64(block.timestamp));
    }

    function scheduleCompound(uint64 poolId, bytes32 scheduleTag, uint64 intervalSec, uint256 sliceWei) external whenUnfrozen {
        if (scheduleTag == bytes32(0)) revert JPL_IntentZero();
        if (intervalSec == 0) revert JPL_WindowInvalid(intervalSec);
        if (sliceWei == 0) revert JPL_WithdrawZero();
        _requireLivePool(poolId);
        if (!_joined[poolId][msg.sender]) revert JPL_NotJoined(poolId, msg.sender);

        uint256 planId = compoundSeq;
        CompoundPlan storage plan = _plans[planId];
        plan.scheduleTag = scheduleTag;
        plan.owner = msg.sender;
        plan.poolId = poolId;
        plan.intervalSec = intervalSec;
        plan.nextRunAt = uint64(block.timestamp) + intervalSec;
        plan.sliceWei = sliceWei;
        plan.active = true;

        compoundSeq += 1;
        emit JPL_CompoundScheduled(planId, poolId, msg.sender, intervalSec, sliceWei);
    }

    function pokeCompound(uint256 planId) external whenUnfrozen nonReentrant {
        CompoundPlan storage plan = _plans[planId];
        if (!plan.active) revert JPL_PlanInactive(planId);
        if (msg.sender != plan.owner) revert JPL_NotJoined(plan.poolId, msg.sender);
        if (block.timestamp < plan.nextRunAt) revert JPL_PlanNotDue(plan.nextRunAt);

        YieldPool storage p = _requireLivePool(plan.poolId);
        DepositorSeat storage seat = _seats[plan.poolId][msg.sender];
        if (seat.shares < plan.sliceWei) revert JPL_SharesInsufficient(plan.sliceWei, seat.shares);

        uint256 assets = JPLYieldMath.assetsFromShares(plan.sliceWei, p.totalAssetsWei, p.totalShares);
        if (assets < MIN_DEPOSIT_WEI) revert JPL_DepositTooSmall(assets, MIN_DEPOSIT_WEI);

        seat.shares -= plan.sliceWei;
        uint256 newShares = JPLYieldMath.sharesFromDeposit(assets, p.totalAssetsWei - assets, p.totalShares - plan.sliceWei);
        seat.shares += newShares;

        p.totalShares = p.totalShares - plan.sliceWei + newShares;
        plan.nextRunAt = uint64(block.timestamp) + plan.intervalSec;

        bytes32 tag = JPLDigestFork.positionTag(plan.poolId, msg.sender, uint64(planId));
        seat.lastHarvestTag = tag;
        seat.lastHarvestAt = uint64(block.timestamp);

        emit JPL_CompoundPoked(planId, plan.poolId, msg.sender, assets, plan.nextRunAt);
    }

    function cancelCompound(uint256 planId) external {
        CompoundPlan storage plan = _plans[planId];
        if (plan.owner == address(0)) revert JPL_PlanUnknown(planId);
        if (msg.sender != plan.owner && msg.sender != curator) revert JPL_NotCurator(msg.sender);
        plan.active = false;
        emit JPL_CompoundCancelled(planId, plan.owner, uint64(block.timestamp));
    }

    function tipPool(uint64 poolId) external payable whenUnfrozen {
        _requirePool(poolId);
        _pools[poolId].tipReserve += msg.value;
        emit JPL_TipReceived(poolId, msg.sender, msg.value, _pools[poolId].tipReserve);
    }

    function withdrawTips(uint64 poolId, uint256 amountWei) external onlyCurator nonReentrant {
        YieldPool storage p = _requirePool(poolId);
        if (amountWei > p.tipReserve) revert JPL_TipPoolShort(amountWei, p.tipReserve);
        p.tipReserve -= amountWei;
        _sendWei(curator, amountWei);
        emit JPL_TipsWithdrawn(curator, amountWei, uint64(block.timestamp));
    }

    function _pushApySnapshot(uint64 poolId, uint32 sampleBps, bytes32 blendHash, uint64 epoch) private {
        ApySnapshot[] storage hist = _apyHistory[poolId];
        if (hist.length >= MAX_SNAPSHOT_RING) {
            for (uint256 i = 0; i < hist.length - 1; ++i) {
                hist[i] = hist[i + 1];
            }
            hist.pop();
        }
        hist.push(ApySnapshot({blendHash: blendHash, sampleBps: sampleBps, capturedAt: uint64(block.timestamp), epoch: epoch}));
        emit JPL_ApySnapshotted(poolId, epoch, sampleBps, blendHash, uint64(block.timestamp));
    }

    function _requirePool(uint64 poolId) private view returns (YieldPool storage p) {
        p = _pools[poolId];
        if (p.openedAt == 0) revert JPL_PoolUnknown(poolId);
    }

    function _requireLivePool(uint64 poolId) private view returns (YieldPool storage p) {
        p = _requirePool(poolId);
        if (p.status != POOL_STATUS_LIVE) revert JPL_PoolNotLive(poolId);
        if (p.sealed) revert JPL_PoolSealed(poolId);
        if (block.timestamp > p.closesAt) revert JPL_PoolNotLive(poolId);
    }

    function _sendWei(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert JPL_TransferFailed();
    }


    function poolCount() external view returns (uint64) {
        return lastPoolId;
    }

    function readPool(uint64 poolId)
        external
        view
        returns (
            bytes32 strategyRoot,
            bytes32 routeTag,
            address curatorNote,
            uint8 status,
            bool harvestOpen,
            bool sealed,
            uint64 openedAt,
            uint64 closesAt,
            uint32 harvestCount,
            uint32 depositorCount,
            uint256 totalAssetsWei,
            uint256 totalShares,
            uint256 tipReserve
        )
    {
        YieldPool storage p = _pools[poolId];
        return (
            p.strategyRoot,
            p.routeTag,
            p.curatorNote,
            p.status,
            p.harvestOpen,
            p.sealed,
            p.openedAt,
            p.closesAt,
            p.harvestCount,
            p.depositorCount,
            p.totalAssetsWei,
            p.totalShares,
            p.tipReserve
        );
    }

    function readSeat(uint64 poolId, address depositor)
        external
        view
        returns (
            bytes32 intentHash,
            bytes32 lastHarvestTag,
            bool active,
            uint64 joinedAt,
            uint256 shares,
            uint256 creditedWei,
            uint64 lastHarvestAt
        )
    {
        DepositorSeat storage s = _seats[poolId][depositor];
        return (s.intentHash, s.lastHarvestTag, s.active, s.joinedAt, s.shares, s.creditedWei, s.lastHarvestAt);
    }

    function readRing(uint64 poolId, uint64 ringId)
        external
        view
        returns (
            bytes32 yieldProof,
            bytes32 apyBlend,
            address reporter,
            uint64 recordedAt,
            uint32 apySampleBps,
            bool revoked
        )
    {
        HarvestRing storage r = _rings[poolId][ringId];
        return (r.yieldProof, r.apyBlend, r.reporter, r.recordedAt, r.apySampleBps, r.revoked);
    }

    function readLane(uint64 poolId, uint64 laneId)
        external
        view
        returns (
            bytes32 targetTag,
            bytes32 sourceTag,
            address proposer,
            uint64 filedAt,
            uint64 executeAfter,
            uint256 notionalWei,
            bool open,
            bool executed
        )
    {
        RebalanceLane storage l = _lanes[poolId][laneId];
        return (l.targetTag, l.sourceTag, l.proposer, l.filedAt, l.executeAfter, l.notionalWei, l.open, l.executed);
    }

    function readPlan(uint256 planId)
        external
        view
        returns (
            bytes32 scheduleTag,
            address owner,
            uint64 poolId,
            uint64 intervalSec,
            uint64 nextRunAt,
            uint256 sliceWei,
            bool active
        )
    {
        CompoundPlan storage c = _plans[planId];
        return (c.scheduleTag, c.owner, c.poolId, c.intervalSec, c.nextRunAt, c.sliceWei, c.active);
    }

    function apyHistoryLength(uint64 poolId) external view returns (uint256) {
        return _apyHistory[poolId].length;
    }

    function readApySnapshot(uint64 poolId, uint256 index)
        external
        view
        returns (bytes32 blendHash, uint32 sampleBps, uint64 capturedAt, uint64 epoch)
    {
        ApySnapshot storage snap = _apyHistory[poolId][index];
        return (snap.blendHash, snap.sampleBps, snap.capturedAt, snap.epoch);
    }

    function poolsOf(address depositor) external view returns (uint64[] memory) {
        return _poolsOf[depositor];
    }

    function depositorsOf(uint64 poolId) external view returns (address[] memory) {
        return _depositors[poolId];
    }

    function positionDigest(uint64 poolId, address depositor, uint64 ticket) external pure returns (bytes32) {
        return JPLDigestFork.positionTag(poolId, depositor, ticket);
    }

    function splitDigest(bytes32 root, address actor, uint64 nonce) external pure returns (bytes32 hA, bytes32 hB) {
        return JPLDigestFork.splitPair(root, actor, nonce);
    }

    function fusedDigest(bytes32 hA, bytes32 hB) external pure returns (bytes32) {
        return JPLDigestFork.fuse(hA, hB);
    }

    function anchorA() external view returns (address) {
        return ADDRESS_A;
    }

    function anchorB() external view returns (address) {
        return ADDRESS_B;
    }

    function anchorC() external view returns (address) {
        return ADDRESS_C;
    }

    function domainSalt() external pure returns (bytes32) {
        return JPL_DOMAIN_SALT;
    }

    function isJoined(uint64 poolId, address depositor) external view returns (bool) {
        return _joined[poolId][depositor];
    }

    function harvestProofUsed(bytes32 proof) external view returns (bool) {
        return _usedHarvestProof[proof];
    }

    function readPool_0(uint64 poolId)
        external
        view
        returns (
            bytes32 strategyRoot,
            bytes32 routeTag,
            uint8 status,
            uint256 totalAssetsWei,
            uint256 totalShares
        )
    {
        YieldPool storage p = _pools[poolId];
        return (p.strategyRoot, p.routeTag, p.status, p.totalAssetsWei, p.totalShares);
    }
    function readPool_1(uint64 poolId)
        external
        view
        returns (
            bytes32 strategyRoot,
            bytes32 routeTag,
            uint8 status,
            uint256 totalAssetsWei,
            uint256 totalShares
        )
    {
        YieldPool storage p = _pools[poolId];
        return (p.strategyRoot, p.routeTag, p.status, p.totalAssetsWei, p.totalShares);
    }
    function readPool_2(uint64 poolId)
        external
        view
        returns (
            bytes32 strategyRoot,
            bytes32 routeTag,
            uint8 status,
