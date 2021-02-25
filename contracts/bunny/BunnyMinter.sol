// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "../interfaces/IBunnyMinter.sol";
import "../interfaces/legacy/IStakingRewards.sol";
import "./PancakeSwap.sol";
import "../interfaces/legacy/IStrategyHelper.sol";

contract BunnyMinter is IBunnyMinter, Ownable, PancakeSwap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    BEP20 private constant bunny = BEP20(0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51);
    address public constant dev = 0xe87f02606911223C2Cf200398FFAF353f60801F7;
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint public override WITHDRAWAL_FEE_FREE_PERIOD = 3 days;//0.5% fee for withdrawals within 3 days
    uint public override WITHDRAWAL_FEE = 50;
    uint public constant FEE_MAX = 10000;

    uint public PERFORMANCE_FEE = 3000; // 30%

    uint public override bunnyPerProfitBNB;//每个bnb产生多少bunny
    uint public bunnyPerBunnyBNBFlip;//每个flip产生多少bunny
    //bunny pool 合约，非swap那边的合约
    address public constant bunnyPool = 0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D;
    IStrategyHelper public helper = IStrategyHelper(0xA84c09C1a2cF4918CaEf625682B429398b97A1a0);

    mapping (address => bool) private _minters;//指某个合约地址还是个人地址？

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "not minter");
        _;
    }

    constructor() public {
        bunnyPerProfitBNB = 10e18;//1个bnb产生10个bunny币？
        bunnyPerBunnyBNBFlip = 6e18;//1个flip产生6个bunny币？
        //此合约授权bunnyPool合约转bunny币
        bunny.approve(bunnyPool, uint(~0));
    }
    //此合约时bunny币的owner
    function transferBunnyOwner(address _owner) external onlyOwner {
        Ownable(address(bunny)).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");   // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setBunnyPerProfitBNB(uint _ratio) external onlyOwner {
        bunnyPerProfitBNB = _ratio;
    }

    function setBunnyPerBunnyBNBFlip(uint _bunnyPerBunnyBNBFlip) external onlyOwner {
        bunnyPerBunnyBNBFlip = _bunnyPerBunnyBNBFlip;
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function isMinter(address account) override view public returns(bool) {
        //bunny币合约的owner是此合约？
        if (bunny.getOwner() != address(this)) {
            return false;
        }

        if (block.timestamp < 1605585600) { // 12:00 SGT 17th November 2020
            return false;
        }
        return _minters[account];
    }

    function amountBunnyToMint(uint bnbProfit) override view public returns(uint) {
        //转换bnb to bunny币数量
        return bnbProfit.mul(bunnyPerProfitBNB).div(1e18);
    }

    function amountBunnyToMintForBunnyBNB(uint amount, uint duration) override view public returns(uint) {
        //某段时间内产生的bunny数量，bunnyPerBunnyBNBFlip是一年时间内，每一个flip币产生多少bunny
        return amount.mul(bunnyPerBunnyBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) override view external returns(uint) {
        //3天内收取0.5% fee，depositedAt为存入时的时间，amount为bunny币的数量
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) override view public returns(uint) {
        //返回profit*30%，bunny币的
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint) override external onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        //转入费用，从msg.sender转入flip 币作为费用到此合约上
        //_withdrawalFee，_performanceFee均为flip币的数量
        IBEP20(flip).safeTransferFrom(msg.sender, address(this), feeSum);

        //flip合约地址为PancakePair的pool地址
        //传入flip币合约地址，此合约flip币余额，将此合约上的flip币转换为相应的两种币，然后add liquidity到pool（pancakeswap那边的wbnb bunny pool）上，产生bunny wbnb的流动性币
        uint bunnyBNBAmount = tokenToBunnyBNB(flip, IBEP20(flip).balanceOf(address(this)));
        address flipToken = bunnyBNBFlipToken();//获取bunny wbnb的pair地址，即flip合约的地址
        //给bunnypool转入liquidity币作为reward token
        //将flip币从pancakeswap那边转入到bunnyPool里
        IBEP20(flipToken).safeTransfer(bunnyPool, bunnyBNBAmount);
        //转入flip币后调用notifyRewardAmount更新rewardrate
        IStakingRewards(bunnyPool).notifyRewardAmount(bunnyBNBAmount);

        //这个bunnyBNBAmount数量的liquidity对应的pancakeswap那边的pool里的本次增加的币的额度，以flip为计量单位
        //pancakeswap那边的pool里的总的锁仓的币的额度*_performanceFee在feeSum里的占比，也就是将_performanceFee转换为bunny币
        uint contribution = helper.tvlInBNB(flipToken, bunnyBNBAmount).mul(_performanceFee).div(feeSum);
        //contribution为多少wbnb，按照1个wbnb产生10个bunny币返回数量
        uint mintBunny = amountBunnyToMint(contribution);
        mint(mintBunny, to);
    }

    function mintForBunnyBNB(uint amount, uint duration, address to) override external onlyMinter {
        uint mintBunny = amountBunnyToMintForBunnyBNB(amount, duration);
        if (mintBunny == 0) return;
        mint(mintBunny, to);
    }

    function mint(uint amount, address to) private {
        bunny.mint(amount);
        bunny.transfer(to, amount);
        //额外mint 15%作为开发者费用质押到bunnyPool
        uint bunnyForDev = amount.mul(15).div(100);
        bunny.mint(bunnyForDev);
        IStakingRewards(bunnyPool).stakeTo(bunnyForDev, dev);
    }
}