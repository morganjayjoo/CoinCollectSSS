// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    CoinCollectSSS — "signal-sprinkle / street-arcade mint"
    ------------------------------------------------------
    A season-based on-chain coin-collecting game designed for mainnet safety:
    - Players collect "coins" (points) via signed drops (EIP-712), trade-in crafting, and streak play.
    - ETH is only handled through explicit entry/season pots, using pull-based withdrawals.
    - Admin controls are role-based, with pausability and explicit guardrails.

    Notes:
    - This is not an ERC20/721/1155 token; it’s a game ledger with verifiable claims.
    - External signing is intended for AI-style gameplay (offchain engine emits drops).
*/

/// @notice CoinCollectSSS (Coin Collect SSS) — an on-chain points game with signed drops.
contract CoinCollectSSS {
    // =============================================================
    //                          VERSIONING
    // =============================================================

    string public constant NAME = "CoinCollectSSS";
    string public constant VERSION = "1.0.0";

    // =============================================================
    //                              ERRORS
    // =============================================================

    error CCS_BadInput();
    error CCS_Unauthorized();
    error CCS_Paused();
    error CCS_SeasonInactive();
    error CCS_SeasonAlreadyActive();
    error CCS_SeasonAlreadyFinal();
    error CCS_AlreadyRegistered();
    error CCS_NotRegistered();
    error CCS_Expired();
    error CCS_SignatureInvalid();
    error CCS_NonceUsed();
    error CCS_InsufficientBalance();
    error CCS_TransferFailed();
    error CCS_Reentrancy();
    error CCS_TooMany();
    error CCS_FeeMismatch();
    error CCS_PotLocked();
    error CCS_RankNotReady();
    error CCS_ProofInvalid();

    // =============================================================
    //                              EVENTS
    // =============================================================

    event CCS_RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event CCS_RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event CCS_PausedSet(bool indexed paused, uint64 at);
    event CCS_PlayerRegistered(address indexed player, bytes32 indexed handleHash, uint64 at);
    event CCS_SeasonOpened(uint32 indexed seasonId, uint64 startAt, uint64 endAt, uint256 entryFeeWei);
    event CCS_SeasonFinalized(uint32 indexed seasonId, uint64 finalizedAt, uint256 potWei, bytes32 resultTag);
    event CCS_Entry(address indexed player, uint32 indexed seasonId, uint256 amountWei, uint64 at);
    event CCS_CoinDropClaimed(
        address indexed player,
        uint32 indexed seasonId,
        uint16 indexed coinType,
        uint96 amount,
        uint64 at,
        bytes32 dropId
    );
    event CCS_Craft(
        address indexed player,
        uint32 indexed seasonId,
        uint16 indexed fromType,
        uint16 toType,
        uint96 burnAmount,
        uint96 mintAmount,
        uint64 at
    );
    event CCS_StreakUpdated(address indexed player, uint32 indexed seasonId, uint16 newStreak, uint64 at);
    event CCS_Withdrawn(address indexed to, uint256 amountWei, uint64 at);
    event CCS_PrizeAccrued(address indexed player, uint32 indexed seasonId, uint256 amountWei, uint64 at);
    event CCS_SettingsUpdated(bytes32 indexed key, uint256 value, uint64 at);
    event CCS_SignerRotated(address indexed newSigner, address indexed oldSigner, uint64 at);
    event CCS_MetaAnchored(bytes32 indexed tag, bytes32 indexed payloadHash, uint64 at);

    // =============================================================
    //                              ROLES
    // =============================================================

    bytes32 public constant ROLE_ADMIN = keccak256("CCS_ROLE_ADMIN");
    bytes32 public constant ROLE_OPERATOR = keccak256("CCS_ROLE_OPERATOR");
    bytes32 public constant ROLE_SIGNER = keccak256("CCS_ROLE_SIGNER");
    bytes32 public constant ROLE_PAUSER = keccak256("CCS_ROLE_PAUSER");
    bytes32 public constant ROLE_TREASURER = keccak256("CCS_ROLE_TREASURER");

    // =============================================================
    //                       UNIQUE ADDRESSES (GENERIC)
    // =============================================================
    // These are included as immutables for per-output uniqueness and optional ops routing.
    // They are not auto-used for moving funds; all transfers are explicit & pull-based.

    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    // =============================================================
    //                      EIP-712 / SIGNATURES
    // =============================================================

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");

    // A unique domain salt to reduce accidental cross-app collisions.
    bytes32 private constant _DOMAIN_SALT =
        hex"c8e2b8b7b2a8bb1f6e9a2f1ed94b0e3cfae01a31c4b2c6f0a2f36c88f3cc7a19";

    // Drop claim typehash. Includes coinType, amount, deadline, and a dropId.
    bytes32 private constant _DROP_TYPEHASH =
        keccak256("Drop(address player,uint32 seasonId,uint16 coinType,uint96 amount,uint64 deadline,bytes32 dropId,uint256 nonce)");

    // =============================================================
    //                          REENTRANCY
    // =============================================================

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert CCS_Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // =============================================================
    //                             PAUSE
    // =============================================================

    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert CCS_Paused();
        _;
    }

    // =============================================================
    //                            STORAGE
    // =============================================================

    struct PlayerProfile {
        // handleHash is a 32-byte identifier (e.g., keccak256 of a handle string).
        bytes32 handleHash;
        uint64 registeredAt;
        uint32 lastSeasonPlayed;
        uint16 flags; // reserved, future-proofing
    }

    struct Season {
        uint64 startAt;
        uint64 endAt;
        uint64 finalizedAt;
        uint256 entryFeeWei;
        uint256 potWei;
        bytes32 resultTag;
        bool active;
        bool finalized;
    }

    // Coin types are arbitrary game categories. Default max coin type id set by admin.
    // Balances are non-transferable; they represent in-game points by season & type.
    uint16 public maxCoinTypeId;

    // Prize weights / configuration values (all in simple ints for readability).
    uint256 public maxDropsPerTx;
    uint256 public craftFeeBps;
    uint256 public streakWindowSeconds;
    uint256 public streakBonusPerStep; // points added as bonus per streak step
    uint256 public maxStreakBonus; // cap to prevent runaway
    uint256 public operatorTipWei; // optional tip per claim, paid into pot

    // Role mapping
    mapping(bytes32 => mapping(address => bool)) private _hasRole;

    // Player registry
    mapping(address => PlayerProfile) public playerOf;

    // Season data
    mapping(uint32 => Season) public seasonOf;
    uint32 public currentSeasonId;

    // Balances: seasonId => player => coinType => amount
    mapping(uint32 => mapping(address => mapping(uint16 => uint96))) private _coinBal;

    // Aggregated score: seasonId => player => score (sum of coin balances + bonuses)
    mapping(uint32 => mapping(address => uint256)) public scoreOf;

    // Streak: seasonId => player => (streak, lastClaimAt)
    mapping(uint32 => mapping(address => uint16)) public streakOf;
    mapping(uint32 => mapping(address => uint64)) public lastClaimAtOf;

    // Nonce usage for EIP-712 claims: player => nonce => used
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    // dropId replay protection: seasonId => dropId => used
    mapping(uint32 => mapping(bytes32 => bool)) public dropIdUsed;

    // Prize accounting: player => withdrawable wei
    mapping(address => uint256) public pendingWithdrawals;

    // Signer used for drops
    address public dropSigner;

    // Anchor tags (metadata)
    mapping(bytes32 => bool) public anchoredTag;

    // =============================================================
    //                           CONSTRUCTOR
    // =============================================================

    constructor() {
        // Role setup: deployer is admin + operator + pauser + treasurer.
        _grantRole(ROLE_ADMIN, msg.sender);
        _grantRole(ROLE_OPERATOR, msg.sender);
        _grantRole(ROLE_PAUSER, msg.sender);
        _grantRole(ROLE_TREASURER, msg.sender);

        // Default signer: deployer (can be rotated).
        dropSigner = msg.sender;
        emit CCS_SignerRotated(msg.sender, address(0), uint64(block.timestamp));

        // Unique immutable addresses for this output.
        ADDRESS_A = 0x6A6e83c8d3cD1d9d3E9f2a0aC2F8B5aD2a7E4b91;
        ADDRESS_B = 0x1C7bF0D2e9a1b4A8C0dE6F2A3b9cD7e8F1a2B3c4;
        ADDRESS_C = 0x9bA1D2e3F4c5A6b7C8d9E0f1A2b3C4D5e6F7a8B9;

        // Game defaults (can be updated by admin)
        maxCoinTypeId = 48; // supports 0..48
        maxDropsPerTx = 24;
        craftFeeBps = 140; // 1.40%
        streakWindowSeconds = 26 hours;
        streakBonusPerStep = 7;
        maxStreakBonus = 250;
        operatorTipWei = 0; // disabled by default

        emit CCS_SettingsUpdated(keccak256("maxCoinTypeId"), maxCoinTypeId, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("maxDropsPerTx"), maxDropsPerTx, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("craftFeeBps"), craftFeeBps, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("streakWindowSeconds"), streakWindowSeconds, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("streakBonusPerStep"), streakBonusPerStep, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("maxStreakBonus"), maxStreakBonus, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("operatorTipWei"), operatorTipWei, uint64(block.timestamp));
    }

    receive() external payable {
        // Only accept ETH through explicit entry or prize funding routes.
        revert CCS_BadInput();
    }

    fallback() external payable {
        revert CCS_BadInput();
    }

    // =============================================================
    //                           ROLE LOGIC
    // =============================================================

    modifier onlyRole(bytes32 role) {
        if (!_hasRole[role][msg.sender]) revert CCS_Unauthorized();
        _;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _hasRole[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(ROLE_ADMIN) {
        if (account == address(0)) revert CCS_BadInput();
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(ROLE_ADMIN) {
        if (account == address(0)) revert CCS_BadInput();
        _revokeRole(role, account);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_hasRole[role][account]) {
            _hasRole[role][account] = true;
            emit CCS_RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_hasRole[role][account]) {
            _hasRole[role][account] = false;
            emit CCS_RoleRevoked(role, account, msg.sender);
        }
    }

    // =============================================================
    //                             ADMIN
    // =============================================================

    function setPaused(bool value) external onlyRole(ROLE_PAUSER) {
        paused = value;
        emit CCS_PausedSet(value, uint64(block.timestamp));
    }

    function rotateSigner(address newSigner) external onlyRole(ROLE_ADMIN) {
        if (newSigner == address(0)) revert CCS_BadInput();
        address old = dropSigner;
        dropSigner = newSigner;
        emit CCS_SignerRotated(newSigner, old, uint64(block.timestamp));
    }

    function setMaxCoinTypeId(uint16 value) external onlyRole(ROLE_ADMIN) {
        if (value < 4) revert CCS_BadInput();
        maxCoinTypeId = value;
        emit CCS_SettingsUpdated(keccak256("maxCoinTypeId"), value, uint64(block.timestamp));
    }

    function setMaxDropsPerTx(uint256 value) external onlyRole(ROLE_ADMIN) {
        if (value == 0 || value > 120) revert CCS_BadInput();
        maxDropsPerTx = value;
        emit CCS_SettingsUpdated(keccak256("maxDropsPerTx"), value, uint64(block.timestamp));
    }

    function setCraftFeeBps(uint256 value) external onlyRole(ROLE_ADMIN) {
        if (value > 1_200) revert CCS_BadInput(); // <= 12%
        craftFeeBps = value;
        emit CCS_SettingsUpdated(keccak256("craftFeeBps"), value, uint64(block.timestamp));
    }

    function setStreakWindowSeconds(uint256 value) external onlyRole(ROLE_ADMIN) {
        if (value < 3 hours || value > 120 hours) revert CCS_BadInput();
        streakWindowSeconds = value;
        emit CCS_SettingsUpdated(keccak256("streakWindowSeconds"), value, uint64(block.timestamp));
    }

    function setStreakBonus(uint256 perStep, uint256 cap) external onlyRole(ROLE_ADMIN) {
        if (perStep > 200 || cap > 2_000) revert CCS_BadInput();
        streakBonusPerStep = perStep;
        maxStreakBonus = cap;
        emit CCS_SettingsUpdated(keccak256("streakBonusPerStep"), perStep, uint64(block.timestamp));
        emit CCS_SettingsUpdated(keccak256("maxStreakBonus"), cap, uint64(block.timestamp));
    }

    function setOperatorTipWei(uint256 value) external onlyRole(ROLE_ADMIN) {
        if (value > 0.01 ether) revert CCS_BadInput();
        operatorTipWei = value;
        emit CCS_SettingsUpdated(keccak256("operatorTipWei"), value, uint64(block.timestamp));
    }

    function anchorMeta(bytes32 tag, bytes32 payloadHash) external onlyRole(ROLE_OPERATOR) {
        if (tag == bytes32(0) || payloadHash == bytes32(0)) revert CCS_BadInput();
        anchoredTag[tag] = true;
        emit CCS_MetaAnchored(tag, payloadHash, uint64(block.timestamp));
    }

    // =============================================================
    //                           PLAYER FLOW
    // =============================================================

    function register(bytes32 handleHash) external whenNotPaused {
        if (handleHash == bytes32(0)) revert CCS_BadInput();
        PlayerProfile storage p = playerOf[msg.sender];
        if (p.registeredAt != 0) revert CCS_AlreadyRegistered();
        p.handleHash = handleHash;
        p.registeredAt = uint64(block.timestamp);
        emit CCS_PlayerRegistered(msg.sender, handleHash, p.registeredAt);
    }

    function isRegistered(address player) public view returns (bool) {
        return playerOf[player].registeredAt != 0;
    }

    // =============================================================
    //                          SEASON CONTROL
    // =============================================================

    function openSeason(uint64 startAt, uint64 endAt, uint256 entryFeeWei) external onlyRole(ROLE_ADMIN) {
        if (paused) revert CCS_Paused();
        if (endAt <= startAt) revert CCS_BadInput();
        if (endAt <= uint64(block.timestamp)) revert CCS_BadInput();
        uint32 newId = currentSeasonId + 1;

        Season storage cur = seasonOf[currentSeasonId];
        if (cur.active && !cur.finalized) revert CCS_SeasonAlreadyActive();

        Season storage s = seasonOf[newId];
        if (s.startAt != 0) revert CCS_BadInput();

        s.startAt = startAt;
        s.endAt = endAt;
        s.entryFeeWei = entryFeeWei;
        s.active = true;
        currentSeasonId = newId;

        emit CCS_SeasonOpened(newId, startAt, endAt, entryFeeWei);
    }

    function finalizeSeason(uint32 seasonId, bytes32 resultTag) external onlyRole(ROLE_OPERATOR) {
        Season storage s = seasonOf[seasonId];
        if (!s.active) revert CCS_SeasonInactive();
        if (s.finalized) revert CCS_SeasonAlreadyFinal();
        if (uint64(block.timestamp) < s.endAt) revert CCS_BadInput();
        s.finalized = true;
        s.finalizedAt = uint64(block.timestamp);
        s.resultTag = resultTag;
        s.active = false;

        emit CCS_SeasonFinalized(seasonId, s.finalizedAt, s.potWei, resultTag);
    }

    function seasonStatus(uint32 seasonId)
        external
        view
        returns (
            bool active,
            bool finalized,
            uint64 startAt,
            uint64 endAt,
            uint64 finalizedAt,
            uint256 entryFeeWei,
            uint256 potWei,
            bytes32 resultTag
        )
    {
        Season memory s = seasonOf[seasonId];
        return (s.active, s.finalized, s.startAt, s.endAt, s.finalizedAt, s.entryFeeWei, s.potWei, s.resultTag);
    }

    function enterSeason() external payable whenNotPaused nonReentrant {
        uint32 sid = currentSeasonId;
        Season storage s = seasonOf[sid];
        if (!s.active) revert CCS_SeasonInactive();
        if (uint64(block.timestamp) < s.startAt || uint64(block.timestamp) > s.endAt) revert CCS_SeasonInactive();
        if (!isRegistered(msg.sender)) revert CCS_NotRegistered();

        if (msg.value != s.entryFeeWei) revert CCS_FeeMismatch();
        s.potWei += msg.value;
        playerOf[msg.sender].lastSeasonPlayed = sid;
        emit CCS_Entry(msg.sender, sid, msg.value, uint64(block.timestamp));
    }

    // =============================================================
    //                          COIN BALANCES
    // =============================================================

    function coinBalance(uint32 seasonId, address player, uint16 coinType) external view returns (uint96) {
        return _coinBal[seasonId][player][coinType];
    }

    function coinBalancesBatch(uint32 seasonId, address player, uint16[] calldata coinTypes)
        external
        view
        returns (uint96[] memory out)
    {
        uint256 n = coinTypes.length;
        if (n == 0 || n > 128) revert CCS_TooMany();
        out = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _coinBal[seasonId][player][coinTypes[i]];
        }
    }

    // =============================================================
    //                        SIGNED AI DROP CLAIMS
    // =============================================================

    struct DropClaim {
        uint32 seasonId;
        uint16 coinType;
        uint96 amount;
        uint64 deadline;
        bytes32 dropId;
        uint256 nonce;
        bytes signature;
    }

    function claimDrops(DropClaim[] calldata claims) external payable whenNotPaused nonReentrant {
        uint256 n = claims.length;
        if (n == 0 || n > maxDropsPerTx) revert CCS_TooMany();
        if (!isRegistered(msg.sender)) revert CCS_NotRegistered();

        uint32 sid = currentSeasonId;
        Season storage s = seasonOf[sid];
        if (!s.active) revert CCS_SeasonInactive();
        if (uint64(block.timestamp) < s.startAt || uint64(block.timestamp) > s.endAt) revert CCS_SeasonInactive();

        // optional operator tip per claim (paid into pot)
        uint256 expectedTip = operatorTipWei * n;
        if (msg.value != expectedTip) revert CCS_FeeMismatch();
        if (expectedTip != 0) {
            s.potWei += expectedTip;
            emit CCS_Entry(msg.sender, sid, expectedTip, uint64(block.timestamp));
        }

        for (uint256 i = 0; i < n; i++) {
            DropClaim calldata c = claims[i];
            if (c.seasonId != sid) revert CCS_BadInput();
            _claimOne(msg.sender, c);
        }
    }

    function _claimOne(address player, DropClaim calldata c) internal {
        if (c.coinType > maxCoinTypeId) revert CCS_BadInput();
        if (c.amount == 0) revert CCS_BadInput();
        if (c.deadline < uint64(block.timestamp)) revert CCS_Expired();
        if (c.dropId == bytes32(0)) revert CCS_BadInput();

        if (nonceUsed[player][c.nonce]) revert CCS_NonceUsed();
        nonceUsed[player][c.nonce] = true;

        if (dropIdUsed[c.seasonId][c.dropId]) revert CCS_NonceUsed();
        dropIdUsed[c.seasonId][c.dropId] = true;

        bytes32 digest = _hashDrop(player, c);
        address recovered = _recover(digest, c.signature);
        if (recovered != dropSigner) revert CCS_SignatureInvalid();

        // streak update + bonus
        (uint16 newStreak, uint256 streakBonus) = _updateStreak(c.seasonId, player);

        // apply
        uint96 prev = _coinBal[c.seasonId][player][c.coinType];
        uint96 next = _safeAdd96(prev, c.amount);
        _coinBal[c.seasonId][player][c.coinType] = next;

        uint256 baseScore = uint256(c.amount);
        uint256 addScore = baseScore + streakBonus;
        scoreOf[c.seasonId][player] += addScore;

        emit CCS_CoinDropClaimed(player, c.seasonId, c.coinType, c.amount, uint64(block.timestamp), c.dropId);
        if (newStreak != 0) {
            emit CCS_StreakUpdated(player, c.seasonId, newStreak, uint64(block.timestamp));
        }
    }

    function _updateStreak(uint32 seasonId, address player) internal returns (uint16 newStreak, uint256 bonus) {
        uint64 lastAt = lastClaimAtOf[seasonId][player];
        uint64 nowAt = uint64(block.timestamp);

        if (lastAt == 0 || nowAt > lastAt + uint64(streakWindowSeconds)) {
            newStreak = 1;
        } else {
            uint16 prev = streakOf[seasonId][player];
            unchecked {
                newStreak = prev + 1;
            }
        }
