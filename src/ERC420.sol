// SPDX-License-Identifier: Beerware
pragma solidity ^0.8.13;

import "openzeppelin/contracts/token/ERC20/ERC20.sol";
import "openzeppelin/contracts/utils/cryptography/ECDSA.sol";

struct OwnerBalance {
    address owner;
    uint96 balance;
}

uint32 constant TxFlag_delegateCall = 1;
uint32 constant TxFlag_vaultLock = 2;
uint32 constant TxFlag_chainLock = 4;
uint32 constant TxFlag_saveRecord = 8;

struct TransactionData {
    uint32 flags;
    uint64 expiry; // timestamp
    address target;
    uint256 value;
    bytes data;
}

struct ExecutionRecord {
    uint64 block;
    uint64 timestamp;
    uint64 gasUsed;
    bool success;
}

// TODO: do not inherit from erc20 - just reimpl necessary features for smaller size
contract ERC420 is ERC20 {
    uint256 public immutable QUORUM;

    // sighash contains param names. it sucks when it does, but it sucks harder when it doesn't.
    // also include struct type, fuckkk ittt, this is true innovation
    bytes32 public constant SIGHASH = keccak256("ERC420(uint256 chainId,address vault,TransactionData txn)");

    mapping(bytes32 => ExecutionRecord) public executionHistory;

    constructor(
        string memory name,
        string memory symbol,
        uint256 quorum,
        OwnerBalance[] memory initBalances
    ) ERC20(name, symbol) {
        QUORUM = quorum;

        for (uint256 i = 0; i < initBalances.length; i++) {
            OwnerBalance memory ownerBalance = initBalances[i];
            _mint(ownerBalance.owner, ownerBalance.balance);
        }

        require(totalSupply() >= QUORUM, "total supply cannot reach quorum");
    }

    // TODO: should this contract prevent calls to itself, or specific token transfers??

    function getSigHash(TransactionData calldata txn) public returns (bytes32) {
        return keccak256(abi.encode(
            SIGHASH,
            txn.flags & TxFlag_chainLock != 0 ? block.chainid : 0,
            txn.flags & TxFlag_vaultLock != 0 ? address(this) : address(0),
            txn
        ));
    }

    function getSigningPower(bytes32 hash, bytes32[] calldata signatures) public returns (uint256) {
        if (signatures.length == 0) {
            return balanceOf(msg.sender);
        }

        require(signatures.length % 2 == 0, "got partial signature");

        uint256 signingPower = 0;
        address prevSigner = address(0);
        for (uint256 i = 0; i < signatures.length; i += 2) {
            bytes32 r = signatures[i];
            bytes32 vs = signatures[i + 1];
            address signer = ECDSA.recover(hash, r, vs);
            require(signer > prevSigner, "signers must have ascending order");
            // TODO: uncomment for prod, comment for testing only to avoid stupid sort...
            // prevSigner = signer;
            signingPower += balanceOf(signer);
        }

        return signingPower;
    }

    function execute(
        TransactionData calldata txn,
        bytes32[] calldata signatures
    ) external payable returns (bool success, bytes memory res) {
        require(txn.expiry > block.timestamp || txn.expiry == 0, "transaction expired");

        bytes32 hash = getSigHash(txn);
        uint256 signingPower = getSigningPower(hash, signatures);
        require(signingPower >= QUORUM, "quorum unmet");

        ExecutionRecord memory record = ExecutionRecord({
            block: uint64(block.number),
            timestamp: uint64(block.timestamp),
            gasUsed: 0,
            success: false
        });

        // NOTE: callee can consume remaining gas by returning large memory amounts...
        // need to ensure executionHistory record is created before calling, maybe should give up on the gas used
        // and shave a few gas on the second storage write... (although slot is warm so no biggie)
        executionHistory[hash] = record;

        // if (txn.flags & TxFlag_saveRecord != 0) {
        //     executionHistory.push(txn);
        // }

        // gasUsed only measures the call itself, not the quorum calculation
        uint256 gasBefore = gasleft();

        if (txn.flags & TxFlag_delegateCall != 0) {
            // delegatecall can be used to transfer ownership tokens, hence requires full quorum
            require(signingPower == totalSupply(), "delegatecall requires total quorum");
            require(
                uint256(txn.value) == msg.value,
                "delegatecall expects txn.value to match msg.value"
            );
            (success, res) = txn.target.delegatecall(txn.data);
        } else {
            require(
                txn.value >= address(this).balance,
                "insufficient eth balance"
            );
            (success, res) = txn.target.call{value: txn.value}(txn.data);
        }

        record.gasUsed = uint64(gasBefore - gasleft());
        record.success = success;
        executionHistory[hash] = record;

        return (success, res);
    }
}
