// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Interface for Moonwell's mERC20 Token (Similar to Compound's cTokens)
interface IMToken {
    function mint(uint mintAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function borrowBalanceCurrent(address account) external returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function exchangeRateStored() external view returns (uint);
}

interface IMultiRewardDistributor {
    struct RewardInfo {
        address emissionToken;
        uint totalAmount;
        uint supplySide;
        uint borrowSide;
    }

    function getOutstandingRewardsForUser(IMToken _mToken, address _user) external view returns (RewardInfo[] memory);
}

/// @dev Interface for Moonwell's Comptroller (Similar to Compound)
interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function claimReward(address holder) external;
    function claimReward(address holder, address[] memory mTokens) external;
    function markets(address) external view returns (bool, uint256);
}

contract LeveragedYieldFarm is IFlashLoanRecipient, Ownable {
    struct AssetInfo {
        address tokenAddress;
        address mTokenAddress;
        uint256 maxLeverage;
    }

    // Balancer Contract
    IVault constant vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Moonwell's Base Mainnet Comptroller
    IComptroller constant comptroller = IComptroller(0xfBb21d0380beE3312B33c4353c8936a0F13EF26C);

    // Moonwell's Base Reward Distributor
    IMultiRewardDistributor constant multiRewardDistributor = IMultiRewardDistributor(0xe9005b078701e2A0948D2EaC43010D35870Ad9d2);

    // Moonwell's WELL ERC-20 token
    IERC20 constant WELL = IERC20(0xA88594D404727625A9437C3f886C7643872296AE);

    mapping(address => AssetInfo) public supportedAssets;
    address[] public assetList;

    struct MyFlashData {
        address flashToken;
        uint256 flashAmount;
        uint256 totalAmount;
        bool isDeposit;
    }

    event Deposit(address indexed token, uint256 amount, uint256 leverage);
    event Withdraw(address indexed token, uint256 amount, uint256 profit);

    constructor() {
        // Add USDC as a supported asset
        addSupportedAsset(
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22, // mUSDC
            3 // Max leverage of 3x
        );
    }

    function addSupportedAsset(address _tokenAddress, address _mTokenAddress, uint256 _maxLeverage) public onlyOwner {
        require(_tokenAddress != address(0) && _mTokenAddress != address(0), "Invalid addresses");
        require(_maxLeverage > 1 && _maxLeverage <= 5, "Invalid max leverage");

        supportedAssets[_tokenAddress] = AssetInfo({
            tokenAddress: _tokenAddress,
            mTokenAddress: _mTokenAddress,
            maxLeverage: _maxLeverage
        });
        assetList.push(_tokenAddress);

        // Enter the market
        address[] memory mTokens = new address[](1);
        mTokens[0] = _mTokenAddress;
        uint256[] memory errors = comptroller.enterMarkets(mTokens);
        require(errors[0] == 0, "Comptroller.enterMarkets failed");
    }

    function deposit(address _tokenAddress, uint256 initialAmount, uint256 leverage) external onlyOwner returns (bool) {
        require(supportedAssets[_tokenAddress].tokenAddress != address(0), "Unsupported asset");
        require(leverage > 1 && leverage <= supportedAssets[_tokenAddress].maxLeverage, "Invalid leverage");

        uint256 totalAmount = initialAmount * leverage;
        uint256 flashLoanAmount = totalAmount - initialAmount;

        // Get Flash Loan for "DEPOSIT"
        getFlashLoan(_tokenAddress, flashLoanAmount, totalAmount, true);

        emit Deposit(_tokenAddress, initialAmount, leverage);
        return true;
    }

    function withdraw(address _tokenAddress, uint256 amount) external onlyOwner returns (bool) {
        require(supportedAssets[_tokenAddress].tokenAddress != address(0), "Unsupported asset");

        AssetInfo memory asset = supportedAssets[_tokenAddress];
        IMToken mToken = IMToken(asset.mTokenAddress);
        
        uint256 borrowBalance = mToken.borrowBalanceCurrent(address(this));
        uint256 supplyBalance = (mToken.balanceOf(address(this)) * mToken.exchangeRateStored()) / 1e18;
        
        require(supplyBalance >= borrowBalance + amount, "Insufficient balance");

        uint256 flashLoanAmount = borrowBalance;

        // Use flash loan to payback borrowed amount
        getFlashLoan(_tokenAddress, flashLoanAmount, amount + flashLoanAmount, false);

        // Claim WELL tokens
        address[] memory mTokens = new address[](1);
        mTokens[0] = asset.mTokenAddress;
        comptroller.claimReward(address(this), mTokens);

        // Calculate profit
        uint256 initialBalance = IERC20(_tokenAddress).balanceOf(address(this));
        uint256 wellBalance = WELL.balanceOf(address(this));

        // Transfer tokens to owner
        IERC20(_tokenAddress).transfer(owner(), initialBalance);
        WELL.transfer(owner(), wellBalance);

        emit Withdraw(_tokenAddress, amount, wellBalance);
        return true;
    }

    function getFlashLoan(address flashToken, uint256 flashAmount, uint256 totalAmount, bool isDeposit) internal {
        bytes memory userData = abi.encode(
            MyFlashData({
                flashToken: flashToken,
                flashAmount: flashAmount,
                totalAmount: totalAmount,
                isDeposit: isDeposit
            })
        );

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(flashToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        vault.flashLoan(this, tokens, amounts, userData);
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(vault), "LeveragedYieldFarm: Not Balancer!");

        MyFlashData memory data = abi.decode(userData, (MyFlashData));
        uint256 flashTokenBalance = IERC20(data.flashToken).balanceOf(address(this));

        require(
            flashTokenBalance >= data.flashAmount + feeAmounts[0],
            "LeveragedYieldFarm: Not enough funds to repay Balancer loan!"
        );

        if (data.isDeposit) {
            handleDeposit(data.flashToken, data.totalAmount, data.flashAmount);
        } else {
            handleWithdraw(data.flashToken, data.totalAmount);
        }

        IERC20(data.flashToken).transfer(address(vault), data.flashAmount + feeAmounts[0]);
    }

    function handleDeposit(address tokenAddress, uint256 totalAmount, uint256 flashLoanAmount) internal {
        AssetInfo memory asset = supportedAssets[tokenAddress];
        IERC20 token = IERC20(tokenAddress);
        IMToken mToken = IMToken(asset.mTokenAddress);

        // Approve tokens as collateral
        token.approve(asset.mTokenAddress, totalAmount);

        // Provide collateral by minting mTokens
        mToken.mint(totalAmount);

        // Borrow tokens (to pay back the flash loan)
        mToken.borrow(flashLoanAmount);
    }

    function handleWithdraw(address tokenAddress, uint256 totalAmount) internal {
        AssetInfo memory asset = supportedAssets[tokenAddress];
        IERC20 token = IERC20(tokenAddress);
        IMToken mToken = IMToken(asset.mTokenAddress);

        // Repay borrowed amount
        uint256 borrowBalance = mToken.borrowBalanceCurrent(address(this));
        token.approve(asset.mTokenAddress, borrowBalance);
        mToken.repayBorrow(borrowBalance);

        // Redeem supplied tokens
        uint256 redeemAmount = (totalAmount * 1e18) / mToken.exchangeRateStored();
        mToken.redeem(redeemAmount);
    }

    function getPositionInfo(address _tokenAddress) public view returns (uint256 supplied, uint256 borrowed, uint256 rewards) {
        AssetInfo memory asset = supportedAssets[_tokenAddress];
        IMToken mToken = IMToken(asset.mTokenAddress);
        
        supplied = (mToken.balanceOf(address(this)) * mToken.exchangeRateStored()) / 1e18;
        borrowed = mToken.borrowBalanceCurrent(address(this));
        
        IMultiRewardDistributor.RewardInfo[] memory rewardInfo = multiRewardDistributor.getOutstandingRewardsForUser(mToken, address(this));
        for (uint i = 0; i < rewardInfo.length; i++) {
            rewards += rewardInfo[i].totalAmount;
        }
    }

    function withdrawToken(address _tokenAddress) public onlyOwner {
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(owner(), balance);
    }

    function claimRewards(address _tokenAddress) public onlyOwner {
        address[] memory mTokens = new address[](1);
        mTokens[0] = supportedAssets[_tokenAddress].mTokenAddress;
        comptroller.claimReward(address(this), mTokens);
    }

    function getOutstandingRewards(address _tokenAddress) public view returns (IMultiRewardDistributor.RewardInfo[] memory) {
        return multiRewardDistributor.getOutstandingRewardsForUser(
            IMToken(supportedAssets[_tokenAddress].mTokenAddress),
            address(this)
        );
    }
}
