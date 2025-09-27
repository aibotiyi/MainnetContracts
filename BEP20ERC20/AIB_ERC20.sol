// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AIBToken is ERC20, Ownable {
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isBlacklisted;

    address public feeReceiver;
    address public bridgeMinter;

    uint256 public buyFee = 300; // 3% (in basis points, 100 = 1%)
    uint256 public sellFee = 500; // 5% (in basis points)
    uint256 public maxSellPercent = 200; // 2% (in basis points)

    bool public tradingEnabled = false;

    uint256 public constant BRIDGE_CHAIN_ID = 1; // Ethereum mainnet

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
        if (from != address(0) && isBlacklisted[from]) {
            revert("Sender blacklisted");
        }
        if (to != address(0) && isBlacklisted[to]) {
            revert("Recipient blacklisted");
        }

        // Block adding liquidity until trading enabled (user -> pool transfer)
        if (!tradingEnabled && from != address(0) && to != address(0)) {
            require(!_isLiquidityPool(to), "Adding liquidity disabled");
        }

        // Check max sell limit (only for sells to contracts/pools)
        if (from != address(0) && _isLiquidityPool(to) && !isWhitelisted[from]) {
            uint256 maxSellAmount = (totalSupply() * maxSellPercent) / 10000;
            require(value <= maxSellAmount, "Sell amount exceeds max sell limit");
        }

        bool takeFee = from != address(0) && to != address(0) &&
            !isWhitelisted[from] && !isWhitelisted[to];

        uint256 transferAmount = value;
        uint256 feeAmount = 0;

        if (takeFee && (from != address(0) && to != address(0))) {
            uint256 currentFee = 0;

            // Determine if it's a buy or sell from any contract/pool
            if (_isLiquidityPool(from)) {
                // Buy transaction (Pool -> user)
                currentFee = buyFee;
            } else if (_isLiquidityPool(to)) {
                // Sell transaction (user -> Pool)
                currentFee = sellFee;
            }

            if (currentFee > 0) {
                feeAmount = (value * currentFee) / 10000;
                transferAmount = value - feeAmount;
            }
        }

        if (feeAmount > 0) {
            super._update(from, feeReceiver, feeAmount);
        }

        super._update(from, to, transferAmount);
    }

    // Owner functions
    function setFees(uint256 _buyFee, uint256 _sellFee) external onlyOwner {
        require(_buyFee >= 100 && _buyFee <= 1000, "Buy fee must be between 1% and 10%");
        require(_sellFee >= 100 && _sellFee <= 1000, "Sell fee must be between 1% and 10%");

        buyFee = _buyFee;
        sellFee = _sellFee;

        emit FeeUpdated(_buyFee, _sellFee);
    }

    function setMaxSellPercent(uint256 _maxSellPercent) external onlyOwner {
        require(_maxSellPercent >= 50 && _maxSellPercent <= 1000, "Max sell must be between 0.5% and 10%");
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
        require(account != address(0), "Invalid address");
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    function updateFeeReceiver(address _feeReceiver) external onlyOwner {
        require(_feeReceiver != address(0), "Fee receiver cannot be zero address");
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
        return (totalSupply() * maxSellPercent) / 10000;
    }

    function calculateFee(uint256 amount, bool isBuy) external view returns (uint256) {
        uint256 fee = isBuy ? buyFee : sellFee;
        return (amount * fee) / 10000;
    }

    function updateBridgeMinter(address bridge) external onlyOwner {
        require(bridge != address(0), "Invalid bridge");
        bridgeMinter = bridge;
        emit BridgeMinterUpdated(bridge);
    }

    function bridgeMint(address to, uint256 amount) external {
        require(msg.sender == bridgeMinter, "Not bridge");
        require(block.chainid == BRIDGE_CHAIN_ID, "Bridge mint disabled");
        _mint(to, amount);
        emit BridgeMint(to, amount);
    }
}