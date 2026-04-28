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
