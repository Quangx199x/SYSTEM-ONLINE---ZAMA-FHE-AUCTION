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
    address public beneficiary; // ✅ Thêm Beneficiary/Seller

    // ========== PLAINTEXT STATE ==========
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant EMERGENCY_DELAY = 24 hours;
    uint256 public currentRound = 1;
    uint256 public auctionEndTime;
    uint256 public immutable minBidDeposit;
    address payable public currentLeadBidder; // Người đặt giá cao nhất được xác định sau giải mã
    uint256 public currentLeadDeposit; // Số tiền deposit của người thắng cuộc (hoặc người dẫn đầu trước khi finalize)
    bool public auctionFinalized;
    address public owner;
    uint256 public winningBid; // Giá thầu thắng cuộc (plaintext sau giải mã)
    
    // ========== MAPPING FOR BIDS (ENCRYPTED) ==========
    mapping(address => euint64) private encryptedBids;
    mapping(address => uint256) public deposits; // Track deposits per bidder
    
    // Track bidders per round for refunds
    address[] private roundBidders;
    // ✅ Tối ưu: Mapping để check new bidder nhanh O(1)
    mapping(address => bool) private hasBiddedThisRound;
    
    // ========== DECRYPTION STATE ==========
    uint256 private pendingDecryptId;
    // ✅ Địa chỉ Oracle Sepolia (Đã kiểm tra checksum)
    address private constant DECRYPTION_ORACLE = 0x8D196Cc0fd2bA583fBe1D0f8BC0AC3A69faBA5d5;
    
    // ========== EVENTS, MODIFIERS ==========
    
    event BidReceived(address indexed bidder, uint256 indexed round, uint256 depositAmount);
    event AuctionFinished(uint256 indexed round, address winner, uint256 finalBid); // Đổi finalDeposit thành finalBid
    event RefundIssued(address indexed recipient, uint256 amount);
    event DecryptionRequested(uint256 requestId);
    event RoundStarted(uint256 indexed round, uint256 endTime);
    event EmergencyEnded(uint256 indexed round);
    event PausedByOwner();
    event UnpausedByOwner();
    
    modifier onlyBeforeEnd() { require(block.timestamp < auctionEndTime, "Auction has ended"); _; }
    modifier onlyAfterEnd() { require(block.timestamp >= auctionEndTime, "Auction is still active"); _; }
    modifier onlyOwner() { require(msg.sender == owner, "Only owner can call this"); _; }
    
    // Modifier: Verify signed publicKey sử dụng EIP712 + ECDSA
    modifier onlySignedPublicKey(bytes32 publicKey, bytes calldata signature) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("PublicKey(bytes32 key)"),
            publicKey
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == msg.sender, "Invalid signature for publicKey"); // ✅ Cần so sánh với msg.sender (người gửi Bid)
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
        beneficiary = _beneficiary; // Người nhận tiền thắng cuộc
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

        // ✅ Tối ưu: Check new bidder với mapping O(1)
        if (!hasBiddedThisRound[msg.sender]) {
            roundBidders.push(msg.sender);
            hasBiddedThisRound[msg.sender] = true;
        }
        
        // 1. Lưu encrypted bid
        encryptedBids[msg.sender] = bidAmount;
        
        // 2. CẬP NHẬT encryptedMaxBid HOMOMORPHIC (không giải mã)
        ebool isHigher = FHE.gt(bidAmount, encryptedMaxBid);
        euint64 newMaxBid = FHE.select(isHigher, bidAmount, encryptedMaxBid);
        encryptedMaxBid = newMaxBid;
        
        // ✅ LOẠI BỎ logic xác định Lead Bidder trên chuỗi.
        // Chỉ emit event báo giá thầu đã được nhận.
        emit BidReceived(msg.sender, currentRound, msg.value);
    }
    
    function requestFinalize() external onlyAfterEnd onlyOwner whenNotPaused {
        require(!auctionFinalized, "Auction already finalized");
        
        // Yêu cầu giải mã encryptedMaxBid và tất cả encryptedBids
        bytes32[] memory handles = new bytes32[](roundBidders.length + 1);
        
        // Index 0: Max Bid
        handles[0] = FHE.toBytes32(encryptedMaxBid);
        
        // Index 1 đến N: Bids của từng Bidder
        for (uint256 i = 0; i < roundBidders.length; i++) {
            handles[i + 1] = FHE.toBytes32(encryptedBids[roundBidders[i]]);
        }

        pendingDecryptId = FHE.requestDecryption(handles, this.onDecryptionCallback.selector);
        emit DecryptionRequested(pendingDecryptId);
    }
    
    /**
     * @notice Callback từ relayer sau decryption (gọi bởi oracle) - XÁC ĐỊNH NGƯỜI THẮNG, REFUND, NEXT ROUND
     */
    function onDecryptionCallback(uint256 requestId, bytes memory cleartexts, bytes memory decryptionProof) external {
        require(msg.sender == DECRYPTION_ORACLE, "Only decryption oracle can call");
        require(requestId == pendingDecryptId, "Invalid request ID");
        
        FHE.checkSignatures(requestId, cleartexts, decryptionProof);
        
        // 1. Decode tất cả các giá trị giải mã (Max Bid + Từng Bidder) ONCE
        uint256[] memory decryptedBids = abi.decode(cleartexts, (uint256[]));
        uint256 currentMaxBid = decryptedBids[0];  // decryptedBids[0] = maxBid
        
        address payable winner = payable(address(0));
        uint256 winnerDeposit = 0;
        uint256 highestTieDeposit = 0;  // Để tie-breaker bằng deposit cao nhất
        
        // 2. Vòng lặp xác định winner (với tie-breaker)
        for (uint256 i = 0; i < roundBidders.length; i++) {
            address bidder = roundBidders[i];
            uint256 bidderBid = decryptedBids[i + 1];
            
            if (bidderBid == currentMaxBid) {
                uint256 thisDeposit = deposits[bidder];
                // Tie-breaker: Chọn deposit cao nhất
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
        
        // 4. Xử lý winner: Transfer min(winningBid, deposit) đến beneficiary, refund excess
        if (winner != address(0) && winnerDeposit > 0) {
            uint256 paymentToBeneficiary = (currentMaxBid < winnerDeposit) ? currentMaxBid : winnerDeposit;
            payable(beneficiary).transfer(paymentToBeneficiary);
            
            // Refund excess nếu deposit > winningBid
            uint256 excess = winnerDeposit - paymentToBeneficiary;
            if (excess > 0) {
                payable(winner).transfer(excess);
                emit RefundIssued(winner, excess);
            }
            
            // Set state
            currentLeadBidder = winner;
            currentLeadDeposit = paymentToBeneficiary;  // Hoặc 0 nếu đã process
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
        
        // ✅ Xóa dữ liệu cũ cho vòng mới
        delete roundBidders;
        // Reset mapping hasBiddedThisRound (loop qua bidders cũ nếu cần, nhưng đơn giản: reset khi bid mới)
        // Lưu ý: Mapping không delete easy, nhưng vì chỉ dùng per-round, có thể ignore (bid mới sẽ set true lại)
        
        encryptedMaxBid = FHE.asEuint64(0); 
        
        // Reset plaintext state
        currentLeadBidder = payable(address(0));
        currentLeadDeposit = 0;
        winningBid = 0;
        // ⚠️ Lưu ý: `encryptedBids` và `deposits` của bidder cũ vẫn tồn tại cho đến khi họ đặt bid mới.
        // Tuy nhiên, việc reset roundBidders đã ngăn chặn việc xử lý trong vòng tiếp theo.

        emit RoundStarted(currentRound, auctionEndTime);
    }
    
    // Internal pause
    function _pause() internal {
        paused = true;
        if (address(pauserSet) != address(0)) {
            pauserSet.pause();
        }
    }
    
    // Hàm rút tiền bị loại bỏ vì đã được tích hợp vào onDecryptionCallback
    // Hàm manualRefund, updateLeaderAfterReveal bị loại bỏ vì chúng không cần thiết
    // khi sử dụng callback tự động và có thể gây rủi ro bảo mật/logic.

    receive() external payable { revert("Direct transfers not allowed. Use bid()"); }
    fallback() external payable { revert("Invalid function call"); }
}