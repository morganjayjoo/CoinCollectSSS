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
