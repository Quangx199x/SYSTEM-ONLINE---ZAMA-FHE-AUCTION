// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, ebool, externalEuint64 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPauserSet {
    function pause() external;
    function unpause() external;
    function isPaused() external view returns (bool);
}

/**
* @title FHEAuction
* @dev Blind auction với FHEVM, đã tối ưu hóa logic Lead Bidder và loại bỏ Decrypt On-Chain.
* Updated: Full privacy in bidding, comprehensive decryption in callback, tie-breaker by deposit,
* min(payment, deposit) transfer to beneficiary, efficient decode, added views/pause.
*/
contract FHEAuction is SepoliaConfig, EIP712, ReentrancyGuard {
    
    // ========== v0.9.0 PAUSER ==========
    IPauserSet public pauserSet;
    bool public paused;
    
    // ========== FHE ENCRYPTED STATE ==========
    euint64 private encryptedMaxBid;
    address public beneficiary; // ✅ add Beneficiary/Seller

    // ========== PLAINTEXT STATE ==========
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant EMERGENCY_DELAY = 24 hours;
    uint256 public currentRound = 1;
    uint256 public auctionEndTime;
    uint256 public immutable minBidDeposit;
    address payable public currentLeadBidder; // The highest bidder is determined after decoding.
    uint256 public currentLeadDeposit; // Winner's (or leader's) deposit amount before finalize
    bool public auctionFinalized;
    address public owner;
    uint256 public winningBid; // Winning bid (plaintext after decryption)
    
    // ========== MAPPING FOR BIDS (ENCRYPTED) ==========
    mapping(address => euint64) private encryptedBids;
    mapping(address => uint256) public deposits; // Track deposits per bidder
    
    // Track bidders per round for refunds
    address[] private roundBidders;
    // ✅ Tối ưu: Mapping để check new bidder nhanh O(1)
    mapping(address => bool) private hasBiddedThisRound;
    
    // ========== DECRYPTION STATE ==========
    uint256 private pendingDecryptId;
    // ✅ Oracle Sepolia Address (Checksum checked)
    address private constant DECRYPTION_ORACLE = 0x8D196Cc0fd2bA583fBe1D0f8BC0AC3A69faBA5d5;
    
    // ========== EVENTS, MODIFIERS ==========
    
    event BidReceived(address indexed bidder, uint256 indexed round, uint256 depositAmount);
    event AuctionFinished(uint256 indexed round, address winner, uint256 finalBid); // Change finalDeposit to finalBid
    event RefundIssued(address indexed recipient, uint256 amount);
    event DecryptionRequested(uint256 requestId);
    event RoundStarted(uint256 indexed round, uint256 endTime);
    event EmergencyEnded(uint256 indexed round);
    event PausedByOwner();
    event UnpausedByOwner();
    
    modifier onlyBeforeEnd() { require(block.timestamp < auctionEndTime, "Auction has ended"); _; }
    modifier onlyAfterEnd() { require(block.timestamp >= auctionEndTime, "Auction is still active"); _; }
    modifier onlyOwner() { require(msg.sender == owner, "Only owner can call this"); _; }
    
    // Modifier: Verify signed publicKey use EIP712 + ECDSA
    modifier onlySignedPublicKey(bytes32 publicKey, bytes calldata signature) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("PublicKey(bytes32 key)"),
            publicKey
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == msg.sender, "Invalid signature for publicKey"); // ✅ Need to compare with msg.sender (Bid sender)
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused && (address(pauserSet) == address(0) || !pauserSet.isPaused()), "Paused");
        _;
    }
    
    // Emergency modifier
    modifier onlyEmergencyWindow() {
        require(block.timestamp >= auctionEndTime + EMERGENCY_DELAY, "Emergency too early");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(uint256 _minDeposit, address _pauserSet, address _beneficiary) EIP712("FHEAuction", "1") {
        require(_minDeposit > 0, "Min deposit must be positive");
        
        owner = msg.sender;
        beneficiary = _beneficiary; // Winners
        minBidDeposit = _minDeposit;
        pauserSet = IPauserSet(_pauserSet);
        
        _startNewRound();
        
        encryptedMaxBid = FHE.asEuint64(0);
        currentLeadBidder = payable(address(0));
        currentLeadDeposit = 0;
        auctionFinalized = false;
    }
    
    // ========== MAIN FUNCTIONS ==========
    
    function bid(
        externalEuint64 encryptedBid,
        bytes calldata proof,
        bytes32 publicKey,
        bytes calldata signature
    ) external payable onlyBeforeEnd whenNotPaused nonReentrant onlySignedPublicKey(publicKey, signature) {
        require(msg.value >= minBidDeposit, "Deposit below minimum");
        
        euint64 bidAmount = FHE.fromExternal(encryptedBid, proof);
        
        // CỘNG DỒN DEPOSIT
        // Nếu người dùng đã đặt giá trước đó, họ sẽ cần đặt thêm deposit
        deposits[msg.sender] += msg.value;

        // ✅ Optimization: Check new bidder with O(1) mapping
        if (!hasBiddedThisRound[msg.sender]) {
            roundBidders.push(msg.sender);
            hasBiddedThisRound[msg.sender] = true;
        }
        
        // 1.Save encrypted bid
        encryptedBids[msg.sender] = bidAmount;
        
        // 2. Update encryptedMaxBid HOMOMORPHIC (not decoded)
        ebool isHigher = FHE.gt(bidAmount, encryptedMaxBid);
        euint64 newMaxBid = FHE.select(isHigher, bidAmount, encryptedMaxBid);
        encryptedMaxBid = newMaxBid;
        
        // ✅ REMOVE on-chain Lead Bidder determination logic.
        // Only emit event that bid quote has been received.
        emit BidReceived(msg.sender, currentRound, msg.value);
    }
    
    function requestFinalize() external onlyAfterEnd onlyOwner whenNotPaused {
        require(!auctionFinalized, "Auction already finalized");
        
        // Request decryption of encryptedMaxBid and all encryptedBids
        bytes32[] memory handles = new bytes32[](roundBidders.length + 1);
        
        // Index 0: Max Bid
        handles[0] = FHE.toBytes32(encryptedMaxBid);
        
        // Index 1 to N: Bids of each Bidder
        for (uint256 i = 0; i < roundBidders.length; i++) {
            handles[i + 1] = FHE.toBytes32(encryptedBids[roundBidders[i]]);
        }

        pendingDecryptId = FHE.requestDecryption(handles, this.onDecryptionCallback.selector);
        emit DecryptionRequested(pendingDecryptId);
    }
    
    /**
     * @notice Callback from relayer after decryption (called by oracle) - DETERMINE WINNER, REFUND, NEXT ROUND
     */
    function onDecryptionCallback(uint256 requestId, bytes memory cleartexts, bytes memory decryptionProof) external {
        require(msg.sender == DECRYPTION_ORACLE, "Only decryption oracle can call");
        require(requestId == pendingDecryptId, "Invalid request ID");
        
        FHE.checkSignatures(requestId, cleartexts, decryptionProof);
        
        // 1. Decode all decode values ​​(Max Bid + Each Bidder) ONCE
        uint256[] memory decryptedBids = abi.decode(cleartexts, (uint256[]));
        uint256 currentMaxBid = decryptedBids[0];  // decryptedBids[0] = maxBid
        
        address payable winner = payable(address(0));
        uint256 winnerDeposit = 0;
        uint256 highestTieDeposit = 0;  // To tie-breaker with highest deposit
        
        // 2. Winner determination round (with tie-breaker)
        for (uint256 i = 0; i < roundBidders.length; i++) {
            address bidder = roundBidders[i];
            uint256 bidderBid = decryptedBids[i + 1];
            
            if (bidderBid == currentMaxBid) {
                uint256 thisDeposit = deposits[bidder];
                // Tie-breaker: Choose the highest deposit
                if (winner == address(0) || thisDeposit > highestTieDeposit) {
                    winner = payable(bidder);
                    winnerDeposit = thisDeposit;
                    highestTieDeposit = thisDeposit;
                }
            }
        }
        
        // 3. Refund losers (ngoài loop winner check)
        for (uint256 i = 0; i < roundBidders.length; i++) {
            address bidder = roundBidders[i];
            if (payable(bidder) != winner) {  // Refund non-winner
                uint256 refundAmt = deposits[bidder];
                if (refundAmt > 0) {
                    deposits[bidder] = 0;
                    payable(bidder).transfer(refundAmt);
                    emit RefundIssued(bidder, refundAmt);
                }
            }
        }
        
        // 4. Proccess winner: Transfer min(winningBid, deposit) to beneficiary, refund excess
        if (winner != address(0) && winnerDeposit > 0) {
            uint256 paymentToBeneficiary = (currentMaxBid < winnerDeposit) ? currentMaxBid : winnerDeposit;
            payable(beneficiary).transfer(paymentToBeneficiary);
            
            // Refund excess if deposit > winningBid
            uint256 excess = winnerDeposit - paymentToBeneficiary;
            if (excess > 0) {
                payable(winner).transfer(excess);
                emit RefundIssued(winner, excess);
            }
            
            // Set state
            currentLeadBidder = winner;
            currentLeadDeposit = paymentToBeneficiary;  // or 0 if process
            winningBid = currentMaxBid;
            deposits[winner] = 0;
        }
        
        auctionFinalized = true;
        emit AuctionFinished(currentRound, currentLeadBidder, currentMaxBid);
        
        // 5. Auto next round
        _startNewRound();
    }
    
    // ========== EMERGENCY & PAUSE ==========
    
    /**
     * @notice Owner auto-end after 24h post-end, refund all
     */
    function emergencyEnd() external onlyOwner onlyEmergencyWindow nonReentrant {
        // Pause first (v0.9.0)
        _pause();
        
        // Refund all
        for (uint256 i = 0; i < roundBidders.length; i++) {
            address bidder = roundBidders[i];
            uint256 amt = deposits[bidder];
            if (amt > 0) {
                deposits[bidder] = 0;
                payable(bidder).transfer(amt);
                emit RefundIssued(bidder, amt);
            }
        }
        
        auctionFinalized = true;
        emit EmergencyEnded(currentRound);
    }
    
    // Pause/Unpause (v0.9.0 PauserSet)
    function pauseAuction() external onlyOwner {
        paused = true;
        if (address(pauserSet) != address(0)) {
            pauserSet.pause();
        }
        emit PausedByOwner();
    }
    
    function unpauseAuction() external onlyOwner {
        paused = false;
        if (address(pauserSet) != address(0)) {
            pauserSet.unpause();
        }
        emit UnpausedByOwner();
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    function getAuctionEndTime() external view returns (uint256) {
        return auctionEndTime;
    }
    
    function getMinBidDeposit() external view returns (uint256) {
        return minBidDeposit;
    }
    
    function getCurrentLeadBidder() external view returns (address payable) {
        return currentLeadBidder;
    }
    
    function getCurrentLeadDeposit() external view returns (uint256) {
        return currentLeadDeposit;
    }
    
    function isAuctionFinalized() external view returns (bool) {
        return auctionFinalized;
    }
    
    function getWinningBid() external view returns (uint256) {
        return winningBid;
    }
    
    function getBeneficiary() external view returns (address) {
        return beneficiary;
    }
    
    // ========== UTILITY FUNCTIONS ==========
    
    function emergencyCancel() external onlyOwner onlyBeforeEnd whenNotPaused nonReentrant {
        require(!auctionFinalized, "Already finalized");
        if (currentLeadDeposit > 0 && currentLeadBidder != address(0)) {
            uint256 refundAmount = currentLeadDeposit;
            address payable recipient = currentLeadBidder;
            currentLeadBidder = payable(address(0));
            currentLeadDeposit = 0;
            (bool success, ) = recipient.call{value: refundAmount}("");
            require(success, "Emergency refund failed");
            emit RefundIssued(recipient, refundAmount);
        }
        // Reset encryptedMaxBid
        encryptedMaxBid = FHE.asEuint64(0);
        auctionFinalized = true;
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    function _startNewRound() internal {
        currentRound++;
        auctionEndTime = block.timestamp + AUCTION_DURATION;
        auctionFinalized = false;
        
        // ✅ Clear old data for new round
        delete roundBidders;
        // Reset mapping hasBiddedThisRound (loop through old bidders if needed, but simple: reset when new bid)
        // Note: Mapping is not easy to delete, but since it is only used per-round, it can be ignored (new bid will set true again)
        
        encryptedMaxBid = FHE.asEuint64(0); 
        
        // Reset plaintext state
        currentLeadBidder = payable(address(0));
        currentLeadDeposit = 0;
        winningBid = 0;
        // ⚠️ Note: The old bidder's `encryptedBids` and `deposits` remain until they place a new bid.
        // However, resetting roundBidders prevented processing in the next round.

        emit RoundStarted(currentRound, auctionEndTime);
    }
    
    // Internal pause
    function _pause() internal {
        paused = true;
        if (address(pauserSet) != address(0)) {
            pauserSet.pause();
        }
    }
    
// Withdraw function removed because it is integrated into onDecryptionCallback
// ManualRefund, updateLeaderAfterReveal functions removed because they are unnecessary
// when using automatic callback and can cause security/logic risks.

    receive() external payable { revert("Direct transfers not allowed. Use bid()"); }
    fallback() external payable { revert("Invalid function call"); }
}
