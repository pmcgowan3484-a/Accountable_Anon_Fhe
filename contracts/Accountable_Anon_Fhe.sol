pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AccountableAnonFhe is SepoliaConfig {
    using FHE for euint32;
    using FHE for ebool;

    address public owner;
    mapping(address => bool) public isProvider;
    bool public paused;
    uint256 public cooldownSeconds;
    mapping(address => uint256) public lastSubmissionTime;
    mapping(address => uint256) public lastDecryptionRequestTime;

    uint256 public currentBatchId;
    mapping(uint256 => bool) public isBatchOpen;
    mapping(uint256 => uint256) public submissionsInBatch;
    mapping(uint256 => mapping(uint256 => euint32)) public encryptedReputationUpdates;
    mapping(uint256 => mapping(uint256 => ebool)) public encryptedIsMalicious;
    mapping(uint256 => uint256) public submissionsCount;

    struct DecryptionContext {
        uint256 batchId;
        bytes32 stateHash;
        bool processed;
    }
    mapping(uint256 => DecryptionContext) public decryptionContexts;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProviderAdded(address indexed provider);
    event ProviderRemoved(address indexed provider);
    event ContractPaused(address indexed account);
    event ContractUnpaused(address indexed account);
    event CooldownSecondsSet(uint256 oldCooldown, uint256 newCooldown);
    event BatchOpened(uint256 indexed batchId);
    event BatchClosed(uint256 indexed batchId);
    event Submission(uint256 indexed batchId, uint256 indexed submissionIndex, address indexed provider);
    event DecryptionRequested(uint256 indexed requestId, uint256 indexed batchId);
    event DecryptionCompleted(uint256 indexed requestId, uint256 indexed batchId, uint256[] reputationUpdates, bool[] isMaliciousFlags);

    error NotOwner();
    error NotProvider();
    error Paused();
    error CooldownActive();
    error BatchClosedOrInvalid();
    error InvalidCooldown();
    error ReplayDetected();
    error StateMismatch();
    error InvalidProof();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyProvider() {
        if (!isProvider[msg.sender]) revert NotProvider();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier respectCooldown() {
        if (block.timestamp < lastSubmissionTime[msg.sender] + cooldownSeconds) {
            revert CooldownActive();
        }
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        isProvider[owner] = true;
        emit ProviderAdded(owner);
        cooldownSeconds = 60;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function addProvider(address provider) external onlyOwner {
        if (!isProvider[provider]) {
            isProvider[provider] = true;
            emit ProviderAdded(provider);
        }
    }

    function removeProvider(address provider) external onlyOwner {
        if (isProvider[provider]) {
            isProvider[provider] = false;
            emit ProviderRemoved(provider);
        }
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert Paused(); // Already unpaused
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    function setCooldownSeconds(uint256 newCooldownSeconds) external onlyOwner {
        if (newCooldownSeconds == 0) revert InvalidCooldown();
        uint256 oldCooldown = cooldownSeconds;
        cooldownSeconds = newCooldownSeconds;
        emit CooldownSecondsSet(oldCooldown, newCooldownSeconds);
    }

    function openBatch() external onlyOwner whenNotPaused {
        currentBatchId++;
        isBatchOpen[currentBatchId] = true;
        submissionsInBatch[currentBatchId] = 0;
        emit BatchOpened(currentBatchId);
    }

    function closeBatch() external onlyOwner whenNotPaused {
        if (!isBatchOpen[currentBatchId]) revert BatchClosedOrInvalid();
        isBatchOpen[currentBatchId] = false;
        emit BatchClosed(currentBatchId);
    }

    function submitReputationUpdate(
        uint256 _batchId,
        euint32 encryptedReputationDelta,
        ebool encryptedMaliciousFlag
    ) external onlyProvider whenNotPaused respectCooldown {
        if (!_isValidBatch(_batchId)) revert BatchClosedOrInvalid();

        _initIfNeeded(encryptedReputationDelta);
        _initIfNeeded(encryptedMaliciousFlag);

        uint256 submissionIndex = submissionsInBatch[_batchId];
        encryptedReputationUpdates[_batchId][submissionIndex] = encryptedReputationDelta;
        encryptedIsMalicious[_batchId][submissionIndex] = encryptedMaliciousFlag;

        submissionsInBatch[_batchId]++;
        submissionsCount[_batchId]++;
        lastSubmissionTime[msg.sender] = block.timestamp;

        emit Submission(_batchId, submissionIndex, msg.sender);
    }

    function requestBatchDecryption(uint256 _batchId) external onlyOwner whenNotPaused respectCooldown {
        if (submissionsCount[_batchId] == 0) revert BatchClosedOrInvalid(); // Or specific error

        uint256 numSubmissions = submissionsCount[_batchId];
        bytes32[] memory cts = new bytes32[](2 * numSubmissions);

        for (uint256 i = 0; i < numSubmissions; i++) {
            cts[i] = FHE.toBytes32(encryptedReputationUpdates[_batchId][i]);
            cts[i + numSubmissions] = FHE.toBytes32(encryptedIsMalicious[_batchId][i]);
        }

        bytes32 stateHash = _hashCiphertexts(cts);
        uint256 requestId = FHE.requestDecryption(cts, this.myCallback.selector);

        decryptionContexts[requestId] = DecryptionContext({
            batchId: _batchId,
            stateHash: stateHash,
            processed: false
        });

        lastDecryptionRequestTime[msg.sender] = block.timestamp;
        emit DecryptionRequested(requestId, _batchId);
    }

    function myCallback(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        if (decryptionContexts[requestId].processed) revert ReplayDetected();

        uint256 _batchId = decryptionContexts[requestId].batchId;
        uint256 numSubmissions = submissionsCount[_batchId];

        bytes32[] memory currentCts = new bytes32[](2 * numSubmissions);
        for (uint256 i = 0; i < numSubmissions; i++) {
            currentCts[i] = FHE.toBytes32(encryptedReputationUpdates[_batchId][i]);
            currentCts[i + numSubmissions] = FHE.toBytes32(encryptedIsMalicious[_batchId][i]);
        }
        bytes32 currentStateHash = _hashCiphertexts(currentCts);

        if (currentStateHash != decryptionContexts[requestId].stateHash) {
            revert StateMismatch();
        }

        try FHE.checkSignatures(requestId, cleartexts, proof) {
            uint256[] memory reputationUpdates = new uint256[](numSubmissions);
            bool[] memory isMaliciousFlags = new bool[](numSubmissions);

            uint256 offset = 0;
            for (uint256 i = 0; i < numSubmissions; i++) {
                reputationUpdates[i] = abi.decode(cleartexts, (uint32));
                offset += 4; // uint32 is 4 bytes
                isMaliciousFlags[i] = abi.decode(cleartexts[offset:], (bool));
                offset += 1; // bool is 1 byte
            }

            decryptionContexts[requestId].processed = true;
            emit DecryptionCompleted(requestId, _batchId, reputationUpdates, isMaliciousFlags);
        } catch {
            revert InvalidProof();
        }
    }

    function _hashCiphertexts(bytes32[] memory cts) internal pure returns (bytes32) {
        return keccak256(abi.encode(cts, address(this)));
    }

    function _initIfNeeded(euint32 val) internal pure {
        if (!val.isInitialized()) {
            val = FHE.asEuint32(0);
        }
    }

    function _initIfNeeded(ebool val) internal pure {
        if (!val.isInitialized()) {
            val = FHE.asEbool(false);
        }
    }

    function _requireInitialized(euint32 val) internal pure {
        if (!val.isInitialized()) revert("Not initialized");
    }

    function _requireInitialized(ebool val) internal pure {
        if (!val.isInitialized()) revert("Not initialized");
    }

    function _isValidBatch(uint256 _batchId) internal view returns (bool) {
        return _batchId > 0 && _batchId <= currentBatchId && isBatchOpen[_batchId];
    }
}