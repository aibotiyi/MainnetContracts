// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AIBToken is ERC20, Ownable {
    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MIN_FEE_BPS = 100; // 1%
    uint256 private constant MAX_FEE_BPS = 1_000; // 10%
    uint256 private constant MIN_MAX_SELL_PERCENT = 50; // 0.5%
    uint256 private constant MAX_MAX_SELL_PERCENT = 1_000; // 10%

    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isBlacklisted;

    address public feeReceiver;
    address public bridgeMinter;

    uint256 public buyFee = 300; // 3% (in basis points, 100 = 1%)
    uint256 public sellFee = 500; // 5% (in basis points)
    uint256 public maxSellPercent = 200; // 2% (in basis points)

    bool public tradingEnabled = false;

    uint256 public constant BRIDGE_CHAIN_ID = 1; // Ethereum mainnet

    error SenderBlacklisted();
    error RecipientBlacklisted();
    error TradingNotEnabled();
    error SellAmountExceedsLimit();
    error BuyFeeOutOfBounds(uint256 fee); // Fee denominated in basis points
    error SellFeeOutOfBounds(uint256 fee);
    error MaxSellPercentOutOfBounds(uint256 percent);
    error InvalidAddress();
    error UnauthorizedBridgeCaller();
    error BridgeMintDisabled();

    event FeeUpdated(uint256 newBuyFee, uint256 newSellFee);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);
    event TradingUpdated(bool isTrading);
    event MaxSellPercentUpdated(uint256 newPercent);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event BridgeMinterUpdated(address indexed newBridge);
    event BridgeMint(address indexed to, uint256 amount);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _feeReceiver,
        address _owner
    ) ERC20(_name, _symbol) Ownable(_owner) {
        feeReceiver = _feeReceiver;

        uint256 supply = _totalSupply * 10**decimals();
        _mint(_owner, supply);

        // Whitelist owner
        isWhitelisted[_owner] = true;
        isWhitelisted[address(this)] = true;
        isWhitelisted[_feeReceiver] = true;
    }

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function _isLiquidityPool(address account) internal view returns (bool) {
        return _isContract(account) && account != address(this) && !isWhitelisted[account];
    }

    function _update(address from, address to, uint256 value) internal override {
        _enforceBlacklist(from, to);
        _enforceTradingWindow(from, to);
        _enforceSellLimit(from, to, value);

        (uint256 netAmount, uint256 feeAmount) = _splitTransferAmount(from, to, value);

        if (feeAmount > 0) {
            super._update(from, feeReceiver, feeAmount);
        }

        super._update(from, to, netAmount);
    }

    // Owner functions
    function setFees(uint256 _buyFee, uint256 _sellFee) external onlyOwner {
        if (_buyFee < MIN_FEE_BPS || _buyFee > MAX_FEE_BPS) {
            revert BuyFeeOutOfBounds(_buyFee);
        }
        if (_sellFee < MIN_FEE_BPS || _sellFee > MAX_FEE_BPS) {
            revert SellFeeOutOfBounds(_sellFee);
        }

        buyFee = _buyFee;
        sellFee = _sellFee;

        emit FeeUpdated(_buyFee, _sellFee);
    }

    function setMaxSellPercent(uint256 _maxSellPercent) external onlyOwner {
        if (_maxSellPercent < MIN_MAX_SELL_PERCENT || _maxSellPercent > MAX_MAX_SELL_PERCENT) {
            revert MaxSellPercentOutOfBounds(_maxSellPercent);
        }
        maxSellPercent = _maxSellPercent;
        emit MaxSellPercentUpdated(_maxSellPercent);
    }

    function addToWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = true;
        isBlacklisted[account] = false;
        emit WhitelistUpdated(account, true);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = false;
        emit WhitelistUpdated(account, false);
    }

    function setTrading(bool _isTrading) external onlyOwner {
        tradingEnabled = _isTrading;
        emit TradingUpdated(_isTrading);
    }

    function setBlacklist(address account, bool blacklisted) external onlyOwner {
        if (account == address(0)) {
            revert InvalidAddress();
        }
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    function updateFeeReceiver(address _feeReceiver) external onlyOwner {
        if (_feeReceiver == address(0)) {
            revert InvalidAddress();
        }
        feeReceiver = _feeReceiver;
        isWhitelisted[_feeReceiver] = true;
    }

    // Emergency functions
    function withdrawStuckTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    function withdrawStuckETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // View functions
    function isLiquidityPool(address account) external view returns (bool) {
        return _isLiquidityPool(account);
    }

    function isContract(address account) external view returns (bool) {
        return _isContract(account);
    }

    function getMaxSellAmount() external view returns (uint256) {
        return (totalSupply() * maxSellPercent) / BASIS_POINTS;
    }

    function calculateFee(uint256 amount, bool isBuy) external view returns (uint256) {
        uint256 fee = isBuy ? buyFee : sellFee;
        return (amount * fee) / BASIS_POINTS;
    }

    function updateBridgeMinter(address bridge) external onlyOwner {
        if (bridge == address(0)) {
            revert InvalidAddress();
        }
        bridgeMinter = bridge;
        emit BridgeMinterUpdated(bridge);
    }

    function bridgeMint(address to, uint256 amount) external {
        if (msg.sender != bridgeMinter) {
            revert UnauthorizedBridgeCaller();
        }
        if (block.chainid != BRIDGE_CHAIN_ID) {
            revert BridgeMintDisabled();
        }
        _mint(to, amount);
        emit BridgeMint(to, amount);
    }

    function _enforceBlacklist(address from, address to) private view {
        if (from != address(0) && isBlacklisted[from]) {
            revert SenderBlacklisted();
        }
        if (to != address(0) && isBlacklisted[to]) {
            revert RecipientBlacklisted();
        }
    }

    function _enforceTradingWindow(address from, address to) private view {
        if (tradingEnabled || from == address(0) || to == address(0)) {
            return;
        }

        if (_isLiquidityPool(to) || _isLiquidityPool(from)) {
            revert TradingNotEnabled();
        }
    }

    function _enforceSellLimit(address from, address to, uint256 value) private view {
        if (from == address(0) || !_isLiquidityPool(to) || isWhitelisted[from]) {
            return;
        }

        uint256 maxSellAmount = (totalSupply() * maxSellPercent) / BASIS_POINTS;
        if (value > maxSellAmount) {
            revert SellAmountExceedsLimit();
        }
    }

    function _splitTransferAmount(address from, address to, uint256 value)
        private
        view
        returns (uint256 netAmount, uint256 feeAmount)
    {
        if (from == address(0) || to == address(0) || isWhitelisted[from] || isWhitelisted[to]) {
            return (value, 0);
        }

        uint256 currentFee;
        if (_isLiquidityPool(from)) {
            currentFee = buyFee;
        } else if (_isLiquidityPool(to)) {
            currentFee = sellFee;
        }

        if (currentFee == 0) {
            return (value, 0);
        }

        feeAmount = (value * currentFee) / BASIS_POINTS;
        netAmount = value - feeAmount;
    }
}