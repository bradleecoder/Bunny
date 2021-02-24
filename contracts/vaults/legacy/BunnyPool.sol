// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../library/legacy/RewardsDistributionRecipient.sol";
import "../../library/legacy/Pausable.sol";
import "../../interfaces/legacy/IStrategyHelper.sol";
import "../../interfaces/IPancakeRouter02.sol";
import "../../interfaces/legacy/IStrategyLegacy.sol";

interface IPresale {
    function totalBalance() view external returns(uint);
    function flipToken() view external returns(address);
}

contract BunnyPool is IStrategyLegacy, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */

    IBEP20 public rewardsToken; // bunny/bnb flip，bunny wbnb池产生的liquidity币
    IBEP20 public constant stakingToken = IBEP20(0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51);   // bunny
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 90 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    mapping(address => bool) private _stakePermission;

    /* ========== PRESALE ============== */
    address private constant presaleContract = 0x641414e2a04c8f8EbBf49eD47cc87dccbA42BF07;
    address private constant deadAddress = 0x000000000000000000000000000000000000dEaD;
    mapping(address => uint256) private _presaleBalance;
    uint private constant timestamp2HoursAfterPresaleEnds = 1605585600 + (2 hours);
    uint private constant timestamp90DaysAfterPresaleEnds = 1605585600 + (90 days);

    /* ========== BUNNY HELPER ========= */
    IStrategyHelper public helper = IStrategyHelper(0xA84c09C1a2cF4918CaEf625682B429398b97A1a0);
    IPancakeRouter02 private constant ROUTER = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);

    /* ========== CONSTRUCTOR ========== */

    constructor() public {
        rewardsDistribution = msg.sender;

        _stakePermission[msg.sender] = true;
        _stakePermission[presaleContract] = true;
        //bunny币授权ROUTER转币权限
        stakingToken.safeApprove(address(ROUTER), uint(~0));
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balance() override external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function presaleBalanceOf(address account) external view returns(uint256) {
        return _presaleBalance[account];
    }

    function principalOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    //可提现额度，90天内只能提现部分，90天后可以全部提现
    function withdrawableBalanceOf(address account) override public view returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale bunny after 90 days of presale
            return _balances[account];
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            //两小时内可取余额为_balances[account]-_presaleBalance[account]
            return _balances[account].sub(_presaleBalance[account]);
        } else {
            //两小时到90天内
            uint soldInPresale = IPresale(presaleContract).totalBalance().div(2).mul(3); // mint 150% of presale for making flip token
            uint bunnySupply = stakingToken.totalSupply().sub(stakingToken.balanceOf(deadAddress));
            if (soldInPresale >= bunnySupply) {
                return _balances[account].sub(_presaleBalance[account]);
            }
            uint bunnyNewMint = bunnySupply.sub(soldInPresale);
            if (bunnyNewMint >= soldInPresale) {
                return _balances[account];
            }

            uint lockedRatio = (soldInPresale.sub(bunnyNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = _presaleBalance[account].mul(lockedRatio).div(1e18);
            return _balances[account].sub(lockedBalance);
        }
    }

    function profitOf(address account) override public view returns (uint _usd, uint _bunny, uint _bnb) {
        _usd = 0;
        _bunny = 0;
        //传入liquidity币的合约地址，此account到目前为止赚取的liquidity币的数量
        _bnb = helper.tvlInBNB(address(rewardsToken), earned(account));
    }

    function tvl() override public view returns (uint) {
        //获取bunny币价格，以bnb为单位，然后计算出锁在此合约上的总的bunny币的价值，以bnb为计价单位
        uint price = helper.tokenPriceInBNB(address(stakingToken));
        return _totalSupply.mul(price).div(1e18);
    }

    function apy() override public view returns(uint _usd, uint _bunny, uint _bnb) {
        uint tokenDecimals = 1e18;
        uint __totalSupply = _totalSupply;
        if (__totalSupply == 0) {
            __totalSupply = tokenDecimals;
        }
        //rewardRate指每秒产生多少liquidity币，除以bunny币的supply为
        uint rewardPerTokenPerSecond = rewardRate.mul(tokenDecimals).div(__totalSupply);
        uint bunnyPrice = helper.tokenPriceInBNB(address(stakingToken));
        uint flipPrice = helper.tvlInBNB(address(rewardsToken), 1e18);

        _usd = 0;
        _bunny = 0;
        //1个bunny币1年产生多少flip币，以bnb为计价单位
        _bnb = rewardPerTokenPerSecond.mul(365 days).mul(flipPrice).div(bunnyPrice);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    //计算每一个bunny币产生多少流动性的币rewardtoken
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            //如果没有存入bunny币，就返回上次保存的值，上次保存的也是每个bunny币能产生多少rewardtoken
            return rewardPerTokenStored;
        }
        return
        //(now-lastupdatetime)*rewardRate*1e18/bunny total supply
        //一段时间内产生的reward币的数量/整个bunny数量，每次计算出来都累加上次的值
        rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
        );
        //预先给池子里设置了reward数量，并转入了reward币，即liquidity币，即flip币
    }

    //返回reward币额度，计算出目前的bunny可以兑换多少rewardtoken，是一个累加值
    function earned(address account) public view returns (uint256) {
        //某个account的bunny 余额*（总的要释放的reward数量-已经释放的reward数量）/1e18+reward 数量（reward 币是bunny wbnb的liquidity）
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        //某段时间内要释放的reward币数量
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function _deposit(uint256 amount, address _to) private nonReentrant notPaused updateReward(_to) {
        //质押之前先调用updateReward
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        //从msg.sender转bunny币到此地址
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(_to, amount);
    }

    function deposit(uint256 amount) override public {
        _deposit(amount, msg.sender);
    }

    function depositAll() override external {
        deposit(stakingToken.balanceOf(msg.sender));
    }

    function withdraw(uint256 amount) override public nonReentrant updateReward(msg.sender) {
        //提现前先调用updateReward
        require(amount > 0, "amount");
        require(amount <= withdrawableBalanceOf(msg.sender), "locked");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        //从此地址转出bunny币到msg.sender
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawAll() override external {
        //获取可以取出的bunny余额
        uint _withdraw = withdrawableBalanceOf(msg.sender);
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        //将reward token转换成wbnb并转出wbnb
        getReward();
    }

    function getReward() override public nonReentrant updateReward(msg.sender) {
        //先调用updateReward
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            //reward 为liquidity币数量，按价格转换为bnb，给用户转wbnb
            reward = _flipToWBNB(reward);
            IBEP20(ROUTER.WETH()).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    //传入的是liquidity的数量
    function _flipToWBNB(uint amount) private returns(uint reward) {
        address wbnb = ROUTER.WETH();
        //移除bunny wbnb池的流动性，bunny及wbnb从swap那边转出到此合约地址，amount为liquidity的数量，返回的rewardBunny为移除的bunny币的数量
        (uint rewardBunny,) = ROUTER.removeLiquidity(
            address(stakingToken), wbnb,
            amount, 0, 0, address(this), block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(stakingToken);
        path[1] = wbnb;
        //将bunny币转换为wbnb币，并将wbnb币转入此合约地址，ROUTER转入bunny币，兑换转出wbnb币（转入bunny币用到构造函数的approve）
        ROUTER.swapExactTokensForTokens(rewardBunny, 0, path, address(this), block.timestamp);

        //返回此合约wbnb的余额
        reward = IBEP20(wbnb).balanceOf(address(this));
    }

    function harvest() override external {}

    function info(address account) override external view returns(UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = _balances[account];
        userInfo.principal = _balances[account];
        userInfo.available = withdrawableBalanceOf(account);

        Profit memory profit;
        (uint usd, uint bunny, uint bnb) = profitOf(account);
        profit.usd = usd;
        profit.bunny = bunny;
        profit.bnb = bnb;
        userInfo.profit = profit;

        userInfo.poolTVL = tvl();

        APY memory poolAPY;
        (usd, bunny, bnb) = apy();
        poolAPY.usd = usd;
        poolAPY.bunny = bunny;
        poolAPY.bnb = bnb;
        userInfo.poolAPY = poolAPY;

        return userInfo;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function setRewardsToken(address _rewardsToken) external onlyOwner {
        require(address(rewardsToken) == address(0), "set rewards token already");

        rewardsToken = IBEP20(_rewardsToken);
        IBEP20(_rewardsToken).safeApprove(address(ROUTER), uint(~0));
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function setStakePermission(address _address, bool permission) external onlyOwner {
        _stakePermission[_address] = permission;
    }

    function stakeTo(uint256 amount, address _to) external canStakeTo {
        _deposit(amount, _to);
        if (msg.sender == presaleContract) {
            _presaleBalance[_to] = _presaleBalance[_to].add(amount);
        }
    }

    //主要是设置一下rewardrate，rewardrate为每秒产生的总的reward量，即liquidity币的数量
    function notifyRewardAmount(uint256 reward) override external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            //设置每秒钟释放的reward
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            //left为剩余要发的reward，这次增加的reward+剩余没有发放的reward/duration
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.

        // bunny wbnb池产生的liquidity币（reward token）的余额，确保设置的reward不能大于swap 池里实际产生的liquidity币的数量
        uint _balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        //设置periodFinish值
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function recoverBEP20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken) && tokenAddress != address(rewardsToken), "tokenAddress");
        //主要是bunny币从此合约地址转出到owner地址
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */
    //更新某个address的reward值
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            //更新account的reward
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier canStakeTo() {
        require(_stakePermission[msg.sender], 'auth');
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}